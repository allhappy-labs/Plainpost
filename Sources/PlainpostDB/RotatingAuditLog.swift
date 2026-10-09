import Darwin
import Foundation
import PlainpostCore

private struct AuditRollbackError: Error, CustomStringConvertible {
    let operationError: Error
    let restorationError: Error

    var description: String {
        "Audit transaction failed: \(operationError); audit restoration failed: \(restorationError)"
    }
}

struct AuditRedactionCleanupPendingError: Error, CustomStringConvertible {
    let operationError: Error

    var description: String {
        "Account deletion committed; audit redaction cleanup remains pending: \(operationError)"
    }
}

private enum AuditProcessLockRegistry {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]

    static func lock(for path: String) -> NSLock {
        registryLock.withLock {
            if let existing = locks[path] {
                return existing
            }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }
}

struct PersistedAuditRecord: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let occurredAt: Date?
    let actorID: String
    let action: String
    let targetType: String
    let targetID: String
    let result: String
    let ownerAccountID: String?

    init(entry: AuditEntry, occurredAt: Date?, ownerAccountID: String? = nil) {
        self.schemaVersion = 1
        self.id = entry.id
        self.occurredAt = occurredAt
        self.actorID = entry.actorID
        self.action = entry.action
        self.targetType = entry.targetType
        self.targetID = entry.targetID
        self.result = entry.result
        self.ownerAccountID = ownerAccountID
    }

    var entry: AuditEntry {
        AuditEntry(
            id: id,
            actorID: actorID,
            action: action,
            targetType: targetType,
            targetID: targetID,
            result: result
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, occurredAt, actorID, action, targetType, targetID, result,
            ownerAccountID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        if let occurredAt {
            try container.encode(occurredAt, forKey: .occurredAt)
        } else {
            try container.encodeNil(forKey: .occurredAt)
        }
        try container.encode(actorID, forKey: .actorID)
        try container.encode(action, forKey: .action)
        try container.encode(targetType, forKey: .targetType)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(ownerAccountID, forKey: .ownerAccountID)
    }
}

enum AuditRedactionFailpoint: Equatable, Sendable {
    case beforeJournalWrite
    case afterJournalWrite
    case afterSQLiteCommit
    case beforeSegmentRename
    case afterSegmentRename
    case beforeJournalCleanup
    case afterJournalCleanup
}

final class RotatingAuditLog: @unchecked Sendable {
    let fileURL: URL

    private let directoryURL: URL
    private let lockURL: URL
    private let maximumFileBytes: Int
    private let archiveCount: Int
    private let fileManager: FileManager
    private let processLock: NSLock
    private let redactionJournalURL: URL
    private let auditRedactionFailpoint: (@Sendable (AuditRedactionFailpoint) throws -> Void)?
    private let onBeforeRewrite: (() throws -> Void)?
    private let onBeforeSnapshot: (() throws -> Void)?
    private let onBeforeSnapshotDiscard: (() throws -> Void)?

    init(
        databaseURL: URL,
        maximumFileBytes: Int = 5 * 1_024 * 1_024,
        archiveCount: Int = 4,
        fileManager: FileManager = .default,
        onBeforeRewrite: (() throws -> Void)? = nil,
        onBeforeSnapshot: (() throws -> Void)? = nil,
        onBeforeSnapshotDiscard: (() throws -> Void)? = nil,
        auditRedactionFailpoint: (@Sendable (AuditRedactionFailpoint) throws -> Void)? = nil,
        readOnly: Bool = false
    ) throws {
        let baseName = databaseURL.deletingPathExtension().lastPathComponent
        let directoryURL = databaseURL.deletingLastPathComponent().appendingPathComponent("Audit", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("\(baseName).audit.log")
        let lockURL = directoryURL.appendingPathComponent("\(baseName).audit.lock")
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.lockURL = lockURL
        self.redactionJournalURL = directoryURL.appendingPathComponent(
            ".\(baseName).audit.redaction-journal.json"
        )
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.archiveCount = max(0, archiveCount)
        self.fileManager = fileManager
        self.processLock = AuditProcessLockRegistry.lock(for: lockURL.standardizedFileURL.path)
        self.onBeforeRewrite = onBeforeRewrite
        self.onBeforeSnapshot = onBeforeSnapshot
        self.onBeforeSnapshotDiscard = onBeforeSnapshotDiscard
        self.auditRedactionFailpoint = auditRedactionFailpoint
        if !readOnly {
            try ensureStorage()
        }
    }

    @discardableResult
    func drain(
        load: () throws -> [PersistedAuditRecord],
        didPersist: ([String]) throws -> Void
    ) throws -> Int {
        try withExclusiveLock {
            let records = try load()
            guard !records.isEmpty else { return 0 }
            try repairIncompleteTailLocked()
            let persistedIDs = Set(try allRecordsLocked().map(\.id))
            let newRecords = records.filter { !persistedIDs.contains($0.id) }
            if !newRecords.isEmpty {
                try appendLocked(newRecords)
            }
            try didPersist(records.map(\.id))
            return records.count
        }
    }

    @discardableResult
    func drainAll(
        loadNextBatch: () throws -> [PersistedAuditRecord],
        didPersist: ([String]) throws -> Void
    ) throws -> Int {
        try withExclusiveLock {
            try repairIncompleteTailLocked()
            var persistedIDs = Set(try allRecordsLocked().map(\.id))
            var total = 0
            while true {
                let records = try loadNextBatch()
                guard !records.isEmpty else { return total }
                let newRecords = records.filter { !persistedIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    try appendLocked(newRecords)
                    persistedIDs.formUnion(newRecords.map(\.id))
                }
                try didPersist(records.map(\.id))
                total += records.count
            }
        }
    }

    func entries() throws -> [AuditEntry] {
        try withExclusiveLock {
            try repairIncompleteTailLocked()
            return try allRecordsLocked().map(\.entry)
        }
    }

    func entries(ownerAccountID: String) throws -> [AuditEntry] {
        try timestampedEntries(ownerAccountID: ownerAccountID).map(\.entry)
    }

    func timestampedEntries(ownerAccountID: String) throws -> [TimestampedAuditEntry] {
        try withExclusiveLock {
            try repairIncompleteTailLocked()
            return try allRecordsLocked()
                .filter { $0.ownerAccountID == ownerAccountID }
                .map { TimestampedAuditEntry(entry: $0.entry, occurredAt: $0.occurredAt) }
        }
    }

    func withRedactionJournal<Result>(
        ownerAccountID: String,
        acceptedRecordIDs: Set<String>,
        performSQLiteCommit: (String) throws -> Result,
        clearSQLiteCommit: (String) throws -> Void
    ) throws -> Result {
        try withExclusiveLock {
            guard !fileManager.fileExists(atPath: redactionJournalURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let explicitlyOwnedIDs = Set(
                try allRecordsLocked()
                    .filter { $0.ownerAccountID == ownerAccountID }
                    .map(\.id)
            )
            let journal = AuditRedactionJournal(
                schemaVersion: 1,
                id: UUID().uuidString.lowercased(),
                recordIDs: acceptedRecordIDs.union(explicitlyOwnedIDs).sorted()
            )
            try auditRedactionFailpoint?(.beforeJournalWrite)
            try writeRedactionJournalLocked(journal)
            try auditRedactionFailpoint?(.afterJournalWrite)
            let result = try performSQLiteCommit(journal.id)
            do {
                try auditRedactionFailpoint?(.afterSQLiteCommit)
                try applyRedactionLocked(journal)
                try clearSQLiteCommit(journal.id)
                try removeRedactionJournalLocked()
                return result
            } catch {
                throw AuditRedactionCleanupPendingError(operationError: error)
            }
        }
    }

    func recoverRedactionJournal(
        isSQLiteCommitted: (String) throws -> Bool,
        clearSQLiteCommit: (String) throws -> Void
    ) throws {
        try withExclusiveLock {
            guard fileManager.fileExists(atPath: redactionJournalURL.path) else { return }
            let journal = try readRedactionJournalLocked()
            if try isSQLiteCommitted(journal.id) {
                try applyRedactionLocked(journal)
                try clearSQLiteCommit(journal.id)
            }
            try removeRedactionJournalLocked()
        }
    }

    func withRecordsRemoved<Result>(
        where shouldRemove: @escaping (PersistedAuditRecord) throws -> Bool,
        perform: () throws -> Result
    ) throws -> Result {
        try withRecordTransaction { removeRecords, finalize in
            try removeRecords(shouldRemove)
            let result = try perform()
            try finalize()
            return result
        }
    }

    /// Holds the process/file audit lock for the full caller transaction. The
    /// caller computes ownership inside its database transaction, then invokes
    /// `removeRecords`. It invokes `finalize` before committing the companion
    /// transaction, so snapshot-disposal failure can still roll that transaction
    /// back. In-memory copies retain a restoration path if the commit itself fails.
    func withRecordTransaction<Result>(
        _ perform: (
            _ removeRecords: ((PersistedAuditRecord) throws -> Bool) throws -> Void,
            _ finalize: () throws -> Void
        ) throws -> Result
    ) throws -> Result {
        try withExclusiveLock {
            try repairIncompleteTailLocked()
            let snapshots = try snapshotFilesLocked()
            var finalized = false
            do {
                let result = try perform(
                    { shouldRemove in
                        try rewriteRecordsLocked(where: shouldRemove)
                    },
                    {
                        guard !finalized else { return }
                        try discardSnapshotsLocked(snapshots)
                        finalized = true
                    }
                )
                guard finalized else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return result
            } catch {
                let operationError = error
                do {
                    try restoreSnapshotsLocked(snapshots)
                } catch let restorationError {
                    throw AuditRollbackError(
                        operationError: operationError,
                        restorationError: restorationError
                    )
                }
                throw operationError
            }
        }
    }

    private func ensureStorage() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try ensureStorage()
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { throw posixError() }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        try discardInterruptedTemporarySiblingsLocked()
        return try body()
    }

    private func appendLocked(_ records: [PersistedAuditRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try records.reduce(into: Data()) { result, record in
            result.append(try encoder.encode(record))
            result.append(0x0A)
        }
        try rotateIfNeededLocked(adding: payload.count)

        let descriptor = Darwin.open(fileURL.path, O_CREAT | O_APPEND | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        try payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func repairIncompleteTailLocked() throws {
        let data = try Data(contentsOf: fileURL)
        guard let lastByte = data.last, lastByte != 0x0A else { return }
        let validLength = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let descriptor = Darwin.open(fileURL.path, O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, off_t(validLength)) == 0 else { throw posixError() }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func rotateIfNeededLocked(adding byteCount: Int) throws {
        let currentSize = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard currentSize > 0, currentSize + byteCount > maximumFileBytes else { return }

        if archiveCount > 0 {
            for index in stride(from: archiveCount, through: 1, by: -1) {
                let destination = archiveURL(index)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                let source = index == 1 ? fileURL : archiveURL(index - 1)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        } else {
            try fileManager.removeItem(at: fileURL)
        }
        guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func allRecordsLocked() throws -> [PersistedAuditRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = managedFileURLs()
        return try urls.flatMap { url -> [PersistedAuditRecord] in
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            return try recordsLocked(at: url, decoder: decoder)
        }
    }

    private struct FileSnapshot {
        let originalURL: URL
        let snapshotURL: URL?
        let originalData: Data?
    }

    private struct AuditRedactionJournal: Codable {
        let schemaVersion: Int
        let id: String
        let recordIDs: [String]
    }

    private func managedFileURLs() -> [URL] {
        stride(from: archiveCount, through: 1, by: -1).map(archiveURL) + [fileURL]
    }

    private func snapshotFilesLocked() throws -> [FileSnapshot] {
        var snapshots: [FileSnapshot] = []
        do {
            for url in managedFileURLs() {
                guard fileManager.fileExists(atPath: url.path) else {
                    snapshots.append(FileSnapshot(originalURL: url, snapshotURL: nil, originalData: nil))
                    continue
                }
                try onBeforeSnapshot?()
                let snapshotURL = temporarySiblingURL(for: url, purpose: "snapshot")
                let originalData = try Data(contentsOf: url)
                try replaceFileAtomically(originalData, at: snapshotURL)
                snapshots.append(FileSnapshot(
                    originalURL: url,
                    snapshotURL: snapshotURL,
                    originalData: originalData
                ))
            }
            return snapshots
        } catch {
            try? discardSnapshotsLocked(snapshots)
            throw error
        }
    }

    private func rewriteRecordsLocked(
        where shouldRemove: (PersistedAuditRecord) throws -> Bool
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in managedFileURLs() where fileManager.fileExists(atPath: url.path) {
            let retained = try recordsLocked(at: url, decoder: decoder).filter { record in
                try !shouldRemove(record)
            }
            try onBeforeRewrite?()
            try writeRecordsLocked(retained, to: url)
        }
    }

    private func writeRedactionJournalLocked(_ journal: AuditRedactionJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try replaceFileAtomically(try encoder.encode(journal), at: redactionJournalURL)
    }

    private func readRedactionJournalLocked() throws -> AuditRedactionJournal {
        let journal = try JSONDecoder().decode(
            AuditRedactionJournal.self,
            from: Data(contentsOf: redactionJournalURL)
        )
        guard journal.schemaVersion == 1,
              !journal.id.isEmpty,
              journal.recordIDs == Array(Set(journal.recordIDs)).sorted() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return journal
    }

    private func applyRedactionLocked(_ journal: AuditRedactionJournal) throws {
        let removedIDs = Set(journal.recordIDs)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in managedFileURLs() where fileManager.fileExists(atPath: url.path) {
            let retained = try recordsLocked(at: url, decoder: decoder).filter {
                !removedIDs.contains($0.id)
            }
            try onBeforeRewrite?()
            try writeRecordsLocked(retained, to: url, usesRedactionFailpoints: true)
        }
    }

    private func removeRedactionJournalLocked() throws {
        try auditRedactionFailpoint?(.beforeJournalCleanup)
        if fileManager.fileExists(atPath: redactionJournalURL.path) {
            try fileManager.removeItem(at: redactionJournalURL)
            try synchronizeDirectoryLocked()
        }
        try auditRedactionFailpoint?(.afterJournalCleanup)
    }

    private func restoreSnapshotsLocked(_ snapshots: [FileSnapshot]) throws {
        var restorationError: Error?
        for snapshot in snapshots {
            do {
                if let originalData = snapshot.originalData {
                    let restorationData: Data
                    if let snapshotURL = snapshot.snapshotURL,
                       fileManager.fileExists(atPath: snapshotURL.path) {
                        restorationData = try Data(contentsOf: snapshotURL)
                    } else {
                        restorationData = originalData
                    }
                    try replaceFileAtomically(restorationData, at: snapshot.originalURL)
                }
            } catch {
                restorationError = restorationError ?? error
            }
        }
        if let restorationError { throw restorationError }
        try discardSnapshotsLocked(snapshots)
    }

    private func discardSnapshotsLocked(_ snapshots: [FileSnapshot]) throws {
        for snapshot in snapshots {
            guard let snapshotURL = snapshot.snapshotURL else { continue }
            try onBeforeSnapshotDiscard?()
            if fileManager.fileExists(atPath: snapshotURL.path) {
                do {
                    try fileManager.removeItem(at: snapshotURL)
                } catch CocoaError.fileNoSuchFile {
                    // A concurrent filesystem observer may win the unlink;
                    // absence is the desired verified end state.
                }
            }
            guard !fileManager.fileExists(atPath: snapshotURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private func discardInterruptedTemporarySiblingsLocked() throws {
        let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        let managedPrefixes = managedFileURLs().map { ".\($0.lastPathComponent)." }
        for name in names where managedPrefixes.contains(where: name.hasPrefix) {
            guard name.contains(".snapshot.") || name.contains(".rewrite.") else { continue }
            let url = directoryURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    continue
                }
            }
        }
    }

    private func recordsLocked(
        at url: URL,
        decoder: JSONDecoder
    ) throws -> [PersistedAuditRecord] {
        try Data(contentsOf: url)
            .split(separator: 0x0A)
            .map { try decoder.decode(PersistedAuditRecord.self, from: Data($0)) }
    }

    private func writeRecordsLocked(
        _ records: [PersistedAuditRecord],
        to url: URL,
        usesRedactionFailpoints: Bool = false
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try records.reduce(into: Data()) { data, record in
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try replaceFileAtomically(
            payload,
            at: url,
            beforeRename: usesRedactionFailpoints ? { [auditRedactionFailpoint] in
                try auditRedactionFailpoint?(.beforeSegmentRename)
            } : nil,
            afterRename: usesRedactionFailpoints ? { [auditRedactionFailpoint] in
                try auditRedactionFailpoint?(.afterSegmentRename)
            } : nil
        )
    }

    private func temporarySiblingURL(for url: URL, purpose: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(purpose).\(UUID().uuidString.lowercased())"
        )
    }

    private func replaceFileAtomically(
        _ data: Data,
        at url: URL,
        beforeRename: (() throws -> Void)? = nil,
        afterRename: (() throws -> Void)? = nil
    ) throws {
        let temporaryURL = temporarySiblingURL(for: url, purpose: "rewrite")
        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            let descriptor = Darwin.open(temporaryURL.path, O_RDONLY)
            guard descriptor >= 0 else { throw posixError() }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
            try beforeRename?()
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else { throw posixError() }
            try synchronizeDirectoryLocked()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try afterRename?()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func synchronizeDirectoryLocked() throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: "\(fileURL.path).\(index)")
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
