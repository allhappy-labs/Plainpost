import CryptoKit
import Darwin
import Foundation
import GRDB
import PlainpostCore
import PlainpostDB
import PlainpostTestSupport

enum MailSearchBenchmarkExitCode: Int32 {
    case success = 0
    case runtimeFailure = 1
    case budgetExceeded = 2
    case invalidArguments = 64
}

enum MailSearchBenchmarkConfigurationError: Error, CustomStringConvertible {
    case helpRequested
    case missingValue(String)
    case missingRequiredOption(String)
    case invalidValue(option: String, value: String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .helpRequested:
            return MailSearchBenchmarkConfiguration.usage
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .missingRequiredOption(let option):
            return "Missing required option \(option)."
        case .invalidValue(let option, let value):
            return "Invalid value '\(value)' for \(option)."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        }
    }
}

struct MailSearchBenchmarkConfiguration: Equatable {
    let messageCount: Int
    let iterations: Int
    let warmupIterations: Int
    let outputJSON: URL
    let sourceDatabase: URL?
    let enforceBudgets: Bool
    let workingDirectory: URL?

    static let usage = """
        Usage: PlainpostSearchBenchmark --messages 10000|50000|100000 --iterations N \\
          --output-json PATH [--warmups N] [--source-db PATH] [--enforce-budgets]

        --source-db is always opened read-only and copied with SQLite online backup.
        Migration and benchmarks run only against the disposable backup.
        """

    static func parse(arguments: [String]) throws -> Self {
        var messageCount: Int?
        var iterations = 30
        var warmupIterations = 3
        var outputJSON: URL?
        var sourceDatabase: URL?
        var enforceBudgets = false
        var workingDirectory: URL?
        var index = 0

        func value(after option: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw MailSearchBenchmarkConfigurationError.missingValue(option)
            }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--help", "-h":
                throw MailSearchBenchmarkConfigurationError.helpRequested
            case "--messages":
                let rawValue = try value(after: option)
                guard let value = Int(rawValue),
                      MailSearchBenchmarkDataset.supportedMessageCounts.contains(value)
                else {
                    throw MailSearchBenchmarkConfigurationError.invalidValue(
                        option: option,
                        value: rawValue
                    )
                }
                messageCount = value
                index += 2
            case "--iterations":
                let rawValue = try value(after: option)
                guard let value = Int(rawValue), value > 0, value <= 1_000 else {
                    throw MailSearchBenchmarkConfigurationError.invalidValue(
                        option: option,
                        value: rawValue
                    )
                }
                iterations = value
                index += 2
            case "--warmups":
                let rawValue = try value(after: option)
                guard let value = Int(rawValue), value >= 0, value <= 1_000 else {
                    throw MailSearchBenchmarkConfigurationError.invalidValue(option: option, value: rawValue)
                }
                warmupIterations = value
                index += 2
            case "--output-json":
                outputJSON = URL(fileURLWithPath: try value(after: option)).standardizedFileURL
                index += 2
            case "--source-db":
                sourceDatabase = URL(fileURLWithPath: try value(after: option)).standardizedFileURL
                index += 2
            case "--enforce-budgets":
                enforceBudgets = true
                index += 1
            case "--working-directory":
                workingDirectory = URL(fileURLWithPath: try value(after: option), isDirectory: true)
                    .standardizedFileURL
                index += 2
            default:
                throw MailSearchBenchmarkConfigurationError.unknownOption(option)
            }
        }

        guard let messageCount else {
            throw MailSearchBenchmarkConfigurationError.missingRequiredOption("--messages")
        }
        guard let outputJSON else {
            throw MailSearchBenchmarkConfigurationError.missingRequiredOption("--output-json")
        }
        return Self(
            messageCount: messageCount,
            iterations: iterations,
            warmupIterations: warmupIterations,
            outputJSON: outputJSON,
            sourceDatabase: sourceDatabase,
            enforceBudgets: enforceBudgets,
            workingDirectory: workingDirectory
        )
    }
}

enum MailSearchBenchmarkPathSafetyError: Error, CustomStringConvertible, Equatable {
    case aliasesProtectedSource(String)

    var description: String {
        switch self {
        case let .aliasesProtectedSource(path):
            return "benchmark output aliases the read-only source: \(path)"
        }
    }
}

enum MailSearchBenchmarkPathSafety {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    static func validate(
        sourceDatabase: URL,
        outputJSON: URL,
        workingDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let canonicalSource = sourceDatabase.standardizedFileURL.resolvingSymlinksInPath()
        let sourceSidecars = [
            canonicalSource,
            URL(fileURLWithPath: canonicalSource.path + "-wal"),
            URL(fileURLWithPath: canonicalSource.path + "-shm"),
        ]
        let destination = workingDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent("production-copy.sqlite")
        let destructiveTargets = [
            outputJSON,
            destination,
            URL(fileURLWithPath: destination.path + "-wal"),
            URL(fileURLWithPath: destination.path + "-shm"),
        ]

        let protectedPaths = Set(sourceSidecars.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        })
        let protectedIdentities = try Set(sourceSidecars.compactMap {
            try fileIdentity($0, fileManager: fileManager)
        })

        for target in destructiveTargets {
            let canonicalTarget = target.standardizedFileURL.resolvingSymlinksInPath()
            if protectedPaths.contains(canonicalTarget.path) {
                throw MailSearchBenchmarkPathSafetyError.aliasesProtectedSource(target.path)
            }
            if let identity = try fileIdentity(target, fileManager: fileManager),
               protectedIdentities.contains(identity) {
                throw MailSearchBenchmarkPathSafetyError.aliasesProtectedSource(target.path)
            }
        }
    }

    private static func fileIdentity(
        _ url: URL,
        fileManager: FileManager
    ) throws -> FileIdentity? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return FileIdentity(device: device, inode: inode)
    }
}

enum MailSearchBenchmarkDatasetCoverage: String, Codable, CaseIterable, Hashable {
    case attachments
    case mailStates
    case commonAndRareTerms
    case dateDistribution
    case multiMessageThreads
}

struct MailSearchBenchmarkDatasetSample: Equatable {
    let index: Int
    let threadIndex: Int
    let accountIndex: Int
    let subject: String
    let body: String
    let attachmentFilename: String?
    let labels: [String]
    let mailboxPath: String
    let sentAt: TimeInterval
    let messageIdentifier: String
}

struct MailSearchBenchmarkDataset {
    static let supportedMessageCounts = [10_000, 50_000, 100_000]
    static let fixedAnchor = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

    let messageCount: Int
    let seed: UInt64
    let threadCount: Int
    let accounts: [String]
    let mailboxes: [String]
    let coverage: Set<MailSearchBenchmarkDatasetCoverage>

    init(messageCount: Int) {
        self.messageCount = messageCount
        seed = 0x4550_4953_5459_4E22 ^ UInt64(messageCount)
        threadCount = (messageCount + 4) / 5
        accounts = ["account-0", "account-1"]
        mailboxes = accounts.flatMap { account in
            ["\(account)-inbox", "\(account)-sent", "\(account)-archive", "\(account)-trash"]
        }
        coverage = Set(MailSearchBenchmarkDatasetCoverage.allCases)
    }

    func sample(at index: Int) -> MailSearchBenchmarkDatasetSample {
        precondition(index >= 0 && index < messageCount)
        let rare = index % 997 == 0
        let mailboxPath: String
        switch index % 20 {
        case 0: mailboxPath = "Trash"
        case 1 ... 4: mailboxPath = "Sent"
        case 5 ... 8: mailboxPath = "Archive"
        default: mailboxPath = "INBOX"
        }
        let labels: [String]
        if index % 17 == 0 {
            labels = ["flagged"]
        } else if index % 29 == 0 {
            labels = ["delegated"]
        } else {
            labels = []
        }
        return MailSearchBenchmarkDatasetSample(
            index: index,
            threadIndex: index / 5,
            accountIndex: index % accounts.count,
            subject: rare
                ? "Nebula rare\(String(format: "%08d", index)) quarterly project"
                : (index % 10 == 0 ? "Quarterly project update" : "Team schedule discussion"),
            body: rare
                ? "Deterministic rare token rare\(String(format: "%08d", index)) in the project archive."
                : (index % 10 == 0
                    ? "Common project notes, milestones, budget, participants, and a deterministic message body."
                    : "Common local mail notes, schedule, participants, and a deterministic message body."),
            attachmentFilename: index % 11 == 0
                ? (index % 22 == 0 ? "forecast-\(index).pdf" : "notes-\(index).txt")
                : nil,
            labels: labels,
            mailboxPath: mailboxPath,
            sentAt: Self.fixedAnchor.timeIntervalSince1970 - Double(index * 600),
            messageIdentifier: "<benchmark-\(String(seed, radix: 16))-\(String(format: "%08d", index))@example.com>"
        )
    }
}

enum MailSearchBenchmarkStatistics {
    static func percentile<T: BinaryFloatingPoint>(_ values: [T], _ percentile: Double) -> T? {
        guard !values.isEmpty, percentile.isFinite, percentile > 0, percentile <= 1 else {
            return nil
        }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[rank - 1]
    }
}

struct MailSearchBenchmarkStorageRow: Codable, Equatable {
    let name: String
    let bytes: Int64
}

enum MailSearchBenchmarkStorageAccounting {
    static func databaseBytes(pageCount: Int64, pageSize: Int64) -> Int64 {
        pageCount * pageSize
    }

    static func searchStructureBytes(_ rows: [MailSearchBenchmarkStorageRow]) -> Int64 {
        rows.lazy
            .filter { row in
                row.name == "mail_search_documents"
                    || row.name.hasPrefix("mail_search_documents_")
                    || row.name == "mail_search_fts"
                    || row.name.hasPrefix("mail_search_fts_")
                    || row.name == "mail_search_state"
                    || row.name == "mail_search_maintenance"
            }
            .reduce(0) { $0 + $1.bytes }
    }
}

enum MailSearchBenchmarkRSS {
    static func currentResidentBytes() -> Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.resident_size)
    }
}

struct MailSearchBenchmarkPeakRSSAccumulator {
    let baselineBytes: Int64
    private(set) var peakBytes: Int64

    init(baselineBytes: Int64) throws {
        guard baselineBytes > 0 else {
            throw MailSearchBenchmarkRuntimeError.invalidRSS
        }
        self.baselineBytes = baselineBytes
        self.peakBytes = baselineBytes
    }

    mutating func record(_ residentBytes: Int64) throws {
        guard residentBytes > 0 else {
            throw MailSearchBenchmarkRuntimeError.invalidRSS
        }
        peakBytes = max(peakBytes, residentBytes)
    }

    func summary(
        finalBytes: Int64,
        periodicSampleCount: Int,
        samplingIntervalNanoseconds: UInt64
    ) -> MailSearchBenchmarkRSSSummary {
        .init(
            baselineBytes: baselineBytes,
            peakBytes: peakBytes,
            finalBytes: finalBytes,
            peakDeltaBytes: max(0, peakBytes - baselineBytes),
            periodicSampleCount: periodicSampleCount,
            samplingIntervalNanoseconds: samplingIntervalNanoseconds
        )
    }
}

struct MailSearchBenchmarkPeakRSSSamplerConfiguration: Sendable {
    let samplingIntervalNanoseconds: UInt64
    let maximumPeriodicSamples: Int

    init(samplingIntervalNanoseconds: UInt64, maximumPeriodicSamples: Int) {
        self.samplingIntervalNanoseconds = max(1, samplingIntervalNanoseconds)
        self.maximumPeriodicSamples = max(1, maximumPeriodicSamples)
    }

    static let benchmark = Self(
        samplingIntervalNanoseconds: 1_000_000,
        maximumPeriodicSamples: 600_000
    )
}

struct MailSearchBenchmarkMeasuredValue<Value> {
    let value: Value
    let rss: MailSearchBenchmarkRSSSummary
}

private actor MailSearchBenchmarkPeakRSSReadiness {
    private var isReady = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
            } else {
                precondition(waiter == nil)
                waiter = continuation
            }
        }
    }

    func signal() {
        guard !isReady else { return }
        isReady = true
        waiter?.resume()
        waiter = nil
    }
}

private final class MailSearchBenchmarkPeakRSSState: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: MailSearchBenchmarkPeakRSSAccumulator
    private var periodicSamples = 0
    private var samplingFailed = false
    private var samplingWindowExhausted = false

    init(baselineBytes: Int64) throws {
        accumulator = try MailSearchBenchmarkPeakRSSAccumulator(baselineBytes: baselineBytes)
    }

    func recordPeriodic(_ residentBytes: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        guard let residentBytes else {
            samplingFailed = true
            return
        }
        do {
            try accumulator.record(residentBytes)
            periodicSamples += 1
        } catch {
            samplingFailed = true
        }
    }

    func recordSamplingWindowExhausted() {
        lock.withLock {
            samplingWindowExhausted = true
        }
    }

    func finish(
        finalBytes: Int64?,
        samplingIntervalNanoseconds: UInt64
    ) throws -> MailSearchBenchmarkRSSSummary {
        lock.lock()
        defer { lock.unlock() }
        guard !samplingFailed, let finalBytes, finalBytes > 0 else {
            throw MailSearchBenchmarkRuntimeError.invalidRSS
        }
        guard !samplingWindowExhausted else {
            throw MailSearchBenchmarkRuntimeError.rssSamplingWindowExceeded
        }
        try accumulator.record(finalBytes)
        return accumulator.summary(
            finalBytes: finalBytes,
            periodicSampleCount: periodicSamples,
            samplingIntervalNanoseconds: samplingIntervalNanoseconds
        )
    }
}

struct MailSearchBenchmarkPeakRSSSampler: Sendable {
    private let configuration: MailSearchBenchmarkPeakRSSSamplerConfiguration
    private let sampleRSS: @Sendable () -> Int64?

    init(
        configuration: MailSearchBenchmarkPeakRSSSamplerConfiguration = .benchmark,
        sampleRSS: @escaping @Sendable () -> Int64? = MailSearchBenchmarkRSS.currentResidentBytes
    ) {
        self.configuration = configuration
        self.sampleRSS = sampleRSS
    }

    func measure<Value>(
        operation: () async throws -> Value
    ) async throws -> MailSearchBenchmarkMeasuredValue<Value> {
        guard let baselineBytes = sampleRSS() else {
            throw MailSearchBenchmarkRuntimeError.invalidRSS
        }
        let state = try MailSearchBenchmarkPeakRSSState(baselineBytes: baselineBytes)
        let readiness = MailSearchBenchmarkPeakRSSReadiness()
        let samplingTask = Task {
            for sampleIndex in 0 ..< configuration.maximumPeriodicSamples {
                guard !Task.isCancelled else { return }
                state.recordPeriodic(sampleRSS())
                if sampleIndex == 0 {
                    await readiness.signal()
                }
                guard sampleIndex + 1 < configuration.maximumPeriodicSamples else {
                    guard !Task.isCancelled else { return }
                    state.recordSamplingWindowExhausted()
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: configuration.samplingIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
        await readiness.wait()

        do {
            let value = try await operation()
            samplingTask.cancel()
            await samplingTask.value
            let summary = try state.finish(
                finalBytes: sampleRSS(),
                samplingIntervalNanoseconds: configuration.samplingIntervalNanoseconds
            )
            return .init(value: value, rss: summary)
        } catch {
            samplingTask.cancel()
            await samplingTask.value
            throw error
        }
    }
}

struct MailSearchBenchmarkBudget: Codable, Equatable {
    let structuredP95Milliseconds: Double
    let messageP95Milliseconds: Double
    let conversationP95Milliseconds: Double
    let coldFirstPageMilliseconds: Double
    let cancellationMilliseconds: Double
    let rssPeakDeltaBytes: Int64
    let searchStructureBytes: Int64

    static let tenThousand = Self(
        structuredP95Milliseconds: 75,
        messageP95Milliseconds: 250,
        conversationP95Milliseconds: 400,
        coldFirstPageMilliseconds: 1_000,
        cancellationMilliseconds: 100,
        rssPeakDeltaBytes: 25 * 1_024 * 1_024,
        searchStructureBytes: 106_900_000
    )
}

struct MailSearchBenchmarkBudgetMeasurements: Codable, Equatable {
    let structuredP95Milliseconds: Double
    let messageP95Milliseconds: Double
    let conversationP95Milliseconds: Double
    let coldFirstPageMilliseconds: Double
    let cancellationMilliseconds: Double
    let rssPeakDeltaBytes: Int64
    let searchStructureBytes: Int64
}

struct MailSearchBenchmarkBudgetEvaluation: Codable, Equatable {
    let violations: [String]
    let exitCode: Int32

    static func evaluate(
        measurements: MailSearchBenchmarkBudgetMeasurements,
        budget: MailSearchBenchmarkBudget
    ) -> Self {
        var violations: [String] = []
        if measurements.structuredP95Milliseconds > budget.structuredP95Milliseconds {
            violations.append("structured_p95_milliseconds")
        }
        if measurements.messageP95Milliseconds > budget.messageP95Milliseconds {
            violations.append("message_p95_milliseconds")
        }
        if measurements.conversationP95Milliseconds > budget.conversationP95Milliseconds {
            violations.append("conversation_p95_milliseconds")
        }
        if measurements.coldFirstPageMilliseconds >= budget.coldFirstPageMilliseconds {
            violations.append("cold_first_page_milliseconds")
        }
        if measurements.cancellationMilliseconds > budget.cancellationMilliseconds {
            violations.append("cancellation_milliseconds")
        }
        if measurements.rssPeakDeltaBytes >= budget.rssPeakDeltaBytes {
            violations.append("rss_peak_delta_bytes")
        }
        if measurements.searchStructureBytes > budget.searchStructureBytes {
            violations.append("search_structure_bytes")
        }
        return Self(
            violations: violations,
            exitCode: violations.isEmpty
                ? MailSearchBenchmarkExitCode.success.rawValue
                : MailSearchBenchmarkExitCode.budgetExceeded.rawValue
        )
    }
}

enum MailSearchBenchmarkOutcome {
    static func passed(
        enforcePerformanceBudgets: Bool,
        performanceViolations: [String],
        correctnessViolations: [String]
    ) -> Bool {
        correctnessViolations.isEmpty
            && (!enforcePerformanceBudgets || performanceViolations.isEmpty)
    }

    static func exitCode(
        enforcePerformanceBudgets: Bool,
        performanceViolations: [String],
        correctnessViolations: [String]
    ) -> Int32 {
        if !correctnessViolations.isEmpty {
            return MailSearchBenchmarkExitCode.runtimeFailure.rawValue
        }
        if enforcePerformanceBudgets, !performanceViolations.isEmpty {
            return MailSearchBenchmarkExitCode.budgetExceeded.rawValue
        }
        return MailSearchBenchmarkExitCode.success.rawValue
    }

    static func productionStorageViolations(
        searchStructureBytes: Int64,
        baselineBytes: Int64
    ) -> [String] {
        searchStructureBytes > baselineBytes
            ? ["production_search_structure_bytes"]
            : []
    }
}

struct MailSearchBenchmarkLatencySummary: Codable {
    let warmupIterations: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let samplesMilliseconds: [Double]
}

struct MailSearchBenchmarkStorageSummary: Codable {
    let databaseBytes: Int64
    let searchStructureBytes: Int64
    let oldSearchBaselineBytes: Int64
    let rows: [MailSearchBenchmarkStorageRow]
}

struct MailSearchBenchmarkRSSSummary: Codable {
    let baselineBytes: Int64
    let peakBytes: Int64
    let finalBytes: Int64
    let peakDeltaBytes: Int64
    let periodicSampleCount: Int
    let samplingIntervalNanoseconds: UInt64
}

struct MailSearchBenchmarkDatasetSummary: Codable {
    let requestedMessages: Int
    let actualMessages: Int
    let threads: Int
    let accounts: Int
    let mailboxes: Int
    let deterministicSeed: UInt64?
    let coverage: [String]
    let source: String
}

struct MailSearchBenchmarkFileSnapshot: Codable, Equatable {
    let path: String
    let exists: Bool
    let bytes: Int64
    let modificationNanoseconds: Int64?
    let sha256: String?
}

struct MailSearchBenchmarkSourceSnapshot: Codable, Equatable {
    let database: MailSearchBenchmarkFileSnapshot
    let wal: MailSearchBenchmarkFileSnapshot
}

struct MailSearchBenchmarkMigrationSummary: Codable {
    let sourcePath: String
    let sourceBefore: MailSearchBenchmarkSourceSnapshot
    let sourceAfter: MailSearchBenchmarkSourceSnapshot
    let sourceUnchanged: Bool
    let backupDatabaseBytesBeforeMigration: Int64
    let databaseBytesAfterMigration: Int64
    let preparationMethod: String
    let naturallyCapturedV21Source: Bool
    let sourceBackupSchemaVersion: Int
    let preparedCanonicalMessageCount: Int
    let preparedLegacyMetadataCount: Int
    let preparedLegacyFTSCount: Int
    let schemaVersionBefore: Int
    let schemaVersionAfter: Int
    let v22MigrationRegisteredBefore: Bool
    let v22MigrationRegisteredAfter: Bool
    let v22MigrationExecuted: Bool
    let v23MigrationRegisteredBefore: Bool
    let v23MigrationRegisteredAfter: Bool
    let v23MigrationExecuted: Bool
    let projectionCount: Int
    let ftsCount: Int
    let projectionMatchesFTS: Bool
    let sqliteIntegrityValidationPassed: Bool
    let ftsIntegrityValidationPassed: Bool
    let legacyTablesAbsent: Bool
}

struct MailSearchBenchmarkProductionShapePreparation: Codable, Equatable {
    let method: String
    let sourceSchemaVersion: Int
    let preparedSchemaVersion: Int
    let canonicalMessageCount: Int
    let legacyMetadataCount: Int
    let legacyFTSCount: Int
}

enum MailSearchBenchmarkMigrationProof {
    static let targetSchemaVersion = 23
    static let v22Identifier = "v32-unified-local-mail-search"
    static let v23Identifier = "v33-search-attachment-mime-metadata"
    static let productionShapedV21PreparationMethod =
        "transactional-current-backup-to-production-shaped-v21-legacy-reconstruction"

    static func migrationIsRegistered(_ identifier: String, database: Database) throws -> Bool {
        guard try database.tableExists("grdb_migrations") else { return false }
        return try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?)",
            arguments: [identifier]
        ) ?? false
    }

    static func v22MigrationIsRegistered(_ database: Database) throws -> Bool {
        try migrationIsRegistered(v22Identifier, database: database)
    }

    static func v23MigrationIsRegistered(_ database: Database) throws -> Bool {
        try migrationIsRegistered(v23Identifier, database: database)
    }

    /// Reconstructs the real v21 legacy search schema and data from a current,
    /// transactionally backed-up production-shaped destination. The protected
    /// source database is opened read-only and is never passed to this helper.
    static func prepareV21ProductionShapedCandidate(
        _ database: Database
    ) throws -> MailSearchBenchmarkProductionShapePreparation {
        let userVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        guard userVersion == targetSchemaVersion else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Production-shaped v21 preparation requires a current schema-v\(targetSchemaVersion) backup."
            )
        }
        try SQLiteMailSearchSchema.validate(database)
        guard try v22MigrationIsRegistered(database),
              try v23MigrationIsRegistered(database),
              try SQLiteMailSearchSchema.legacyStructuresAreAbsent(database) else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Current backup is missing migration registrations or contains legacy search tables."
            )
        }

        let canonicalMessageCount = try Int.fetchOne(
            database,
            sql: "SELECT count(*) FROM messages"
        ) ?? 0
        let projectionCount = try Int.fetchOne(
            database,
            sql: "SELECT count(*) FROM mail_search_documents"
        ) ?? 0
        guard projectionCount == canonicalMessageCount else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Current backup projection does not cover every canonical production row."
            )
        }

        try SQLiteMailSearchSchema.createLegacyStructures(database)
        try database.execute(sql: """
            INSERT INTO message_search_metadata (
                message_id, from_value, to_value, cc_value, bcc_value, subject,
                body_text, attachment_filenames, message_identifiers, mailbox_path, labels
            )
            SELECT
                d.message_id, d.sender, d.to_value, d.cc_value, d.bcc_value, d.subject,
                d.body_text, d.filenames, d.identifiers, m.mailbox_path, d.labels
            FROM mail_search_documents d
            JOIN messages m ON m.id = d.message_id
            ORDER BY d.message_id;
            """)
        try SQLiteMailSearchSchema.backfillLegacyStructures(database)

        let legacyMetadataCount = try Int.fetchOne(
            database,
            sql: "SELECT count(*) FROM message_search_metadata"
        ) ?? 0
        let legacyFTSCount = try Int.fetchOne(
            database,
            sql: "SELECT count(*) FROM message_fts"
        ) ?? 0
        guard legacyMetadataCount == canonicalMessageCount,
              legacyFTSCount == canonicalMessageCount else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Production-shaped v21 legacy search rows do not match canonical production rows."
            )
        }
        try database.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('integrity-check')")

        try database.execute(sql: """
            DROP TRIGGER IF EXISTS mail_search_documents_after_insert;
            DROP TRIGGER IF EXISTS mail_search_documents_after_delete;
            DROP TRIGGER IF EXISTS mail_search_documents_after_update;
            DROP TABLE mail_search_fts;
            DROP TABLE mail_search_documents;
            DROP TABLE mail_search_state;
            DROP TABLE mail_search_maintenance;
            """)
        try database.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?)",
            arguments: [v22Identifier, v23Identifier]
        )
        try database.execute(sql: "PRAGMA user_version = 21")

        guard try database.tableExists("message_search_metadata"),
              try database.tableExists("message_fts"),
              try !database.tableExists("mail_search_documents"),
              try !database.tableExists("mail_search_fts"),
              try !v22MigrationIsRegistered(database),
              try !v23MigrationIsRegistered(database) else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Production-shaped v21 preparation did not reach the exact legacy boundary."
            )
        }

        return .init(
            method: productionShapedV21PreparationMethod,
            sourceSchemaVersion: userVersion,
            preparedSchemaVersion: 21,
            canonicalMessageCount: canonicalMessageCount,
            legacyMetadataCount: legacyMetadataCount,
            legacyFTSCount: legacyFTSCount
        )
    }
}

struct MailSearchBenchmarkCancellationSummary: Codable {
    let milliseconds: Double
    let cancellationObserved: Bool
}

struct MailSearchBenchmarkHardware: Codable {
    let model: String
    let architecture: String
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let buildConfiguration: String
}

/// Dedicated wrapper-provided provenance only; never capture the entire environment.
struct MailSearchBenchmarkProvenance: Codable {
    let sourceSHA: String?
    let dirtyPaths: [String]?
    let toolchain: String?
    let cacheIdentity: String?
    let commandArguments: [String]

    static func capture(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        func stringArray(_ name: String) -> [String]? {
            guard let value = environment[name], let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        return Self(
            sourceSHA: environment["PLAINPOST_BENCH_SOURCE_SHA"],
            dirtyPaths: stringArray("PLAINPOST_BENCH_DIRTY_PATHS"),
            toolchain: environment["PLAINPOST_BENCH_TOOLCHAIN"],
            cacheIdentity: environment["PLAINPOST_BENCH_CACHE_IDENTITY"],
            commandArguments: stringArray("PLAINPOST_BENCH_COMMAND_ARGUMENTS") ?? []
        )
    }
}

struct MailSearchBenchmarkResult: Codable {
    let provenance: MailSearchBenchmarkProvenance
    let formatVersion: Int
    let generatedAt: Date
    let hardware: MailSearchBenchmarkHardware
    let dataset: MailSearchBenchmarkDatasetSummary
    let coldFirstPageMilliseconds: Double
    let warm: [String: MailSearchBenchmarkLatencySummary]
    let queryPlans: [String: [String]]
    let cancellation: MailSearchBenchmarkCancellationSummary
    let rss: MailSearchBenchmarkRSSSummary
    let storage: MailSearchBenchmarkStorageSummary
    let migration: MailSearchBenchmarkMigrationSummary?
    let budget: MailSearchBenchmarkBudget
    let budgetsEnforced: Bool
    let performanceBudgetViolations: [String]
    let correctnessViolations: [String]
    let passed: Bool
}

private struct MailSearchBenchmarkPreparedStore {
    let store: SQLiteMailStore
    let databaseURL: URL
    let dataset: MailSearchBenchmarkDatasetSummary
    let migration: MailSearchBenchmarkMigrationSummary?
}

struct MailSearchBenchmarkSyntheticCounts: Equatable {
    let messages: Int
    let threads: Int
    let accounts: Int
    let mailboxes: Int
    let projections: Int
    let ftsRows: Int
    let coverage: Set<MailSearchBenchmarkDatasetCoverage>
    let generatorMatchesModel: Bool
}

enum MailSearchBenchmarkSyntheticDatabase {
    static func populate(
        store: SQLiteMailStore,
        dataset: MailSearchBenchmarkDataset,
        limit: Int? = nil
    ) throws -> MailSearchBenchmarkSyntheticCounts {
        let messageCount = limit ?? dataset.messageCount
        precondition(messageCount > 0 && messageCount <= dataset.messageCount)
        let threadCount = (messageCount + 4) / 5
        return try store.databasePool.write { database in
            try database.execute(sql: MailSearchBenchmarkRunner.syntheticDatasetSQL(
                messageCount: messageCount,
                threadCount: threadCount,
                anchor: MailSearchBenchmarkDataset.fixedAnchor.timeIntervalSince1970,
                seed: dataset.seed
            ))
            try SQLiteMailSearchSchema.validate(database)
            try SQLiteMailSearchSchema.validateFTSIntegrity(database)
            let messages = try Int.fetchOne(database, sql: "SELECT count(*) FROM messages") ?? 0
            let threads = try Int.fetchOne(database, sql: "SELECT count(*) FROM threads") ?? 0
            let accounts = try Int.fetchOne(database, sql: "SELECT count(*) FROM accounts") ?? 0
            let mailboxes = try Int.fetchOne(database, sql: "SELECT count(*) FROM mailboxes") ?? 0
            let projections = try Int.fetchOne(
                database,
                sql: "SELECT count(*) FROM mail_search_documents"
            ) ?? 0
            let ftsRows = try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_fts") ?? 0
            var coverage: Set<MailSearchBenchmarkDatasetCoverage> = []
            if try database.scalarBool("SELECT EXISTS(SELECT 1 FROM mail_search_documents WHERE filenames <> '')") {
                coverage.insert(.attachments)
            }
            if try database.scalarBool("""
                SELECT EXISTS(
                    SELECT 1 FROM mail_search_documents
                    WHERE is_seen = 0 OR is_flagged = 1 OR is_delegated = 1
                       OR is_trash = 1 OR is_inbox = 1 OR is_sent = 1
                ) AND EXISTS(SELECT 1 FROM mail_search_documents WHERE is_seen = 1)
                """) {
                coverage.insert(.mailStates)
            }
            if try database.scalarBool("""
                SELECT EXISTS(SELECT 1 FROM mail_search_documents WHERE subject LIKE '%project%')
                   AND EXISTS(SELECT 1 FROM mail_search_documents WHERE subject NOT LIKE '%project%')
                   AND EXISTS(SELECT 1 FROM mail_search_documents WHERE subject LIKE 'Nebula rare%')
                """) {
                coverage.insert(.commonAndRareTerms)
            }
            if try database.scalarBool("SELECT min(sent_at) < max(sent_at) FROM mail_search_documents") {
                coverage.insert(.dateDistribution)
            }
            if try database.scalarBool("""
                SELECT EXISTS(
                    SELECT 1 FROM mail_search_documents GROUP BY thread_id HAVING count(*) > 1
                )
                """) {
                coverage.insert(.multiMessageThreads)
            }
            let sentinelIndexes = Set([0, min(137, messageCount - 1), messageCount - 1])
            let generatorMatchesModel = try sentinelIndexes.allSatisfy { index in
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT m.subject, m.body_text, m.mailbox_path, m.sent_at,
                               m.rfc_message_id, d.filenames
                        FROM messages m
                        JOIN mail_search_documents d ON d.message_id = m.id
                        WHERE m.id = ?
                        """,
                    arguments: [String(format: "message-%08d", index)]
                ) else { return false }
                let expected = dataset.sample(at: index)
                let filenames: String = row["filenames"]
                return row["subject"] == expected.subject
                    && row["body_text"] == expected.body
                    && row["mailbox_path"] == expected.mailboxPath
                    && abs((row["sent_at"] as Double) - expected.sentAt) < 0.001
                    && row["rfc_message_id"] == expected.messageIdentifier
                    && (filenames.isEmpty ? nil : filenames) == expected.attachmentFilename
            }
            return .init(
                messages: messages,
                threads: threads,
                accounts: accounts,
                mailboxes: mailboxes,
                projections: projections,
                ftsRows: ftsRows,
                coverage: coverage,
                generatorMatchesModel: generatorMatchesModel
            )
        }
    }
}

private extension Database {
    func scalarBool(_ sql: String) throws -> Bool {
        try Bool.fetchOne(self, sql: sql) ?? false
    }
}

enum MailSearchBenchmarkRuntimeError: Error, CustomStringConvertible {
    case missingSource(String)
    case invalidSourceSnapshot
    case sourceChanged
    case invalidRSS
    case rssSamplingWindowExceeded
    case emptyMeasurements
    case validation(String)

    var description: String {
        switch self {
        case .missingSource(let path): return "Source database does not exist: \(path)"
        case .invalidSourceSnapshot: return "Could not snapshot source database metadata and checksum."
        case .sourceChanged: return "Source database or WAL changed during disposable-copy verification."
        case .invalidRSS: return "Could not sample Darwin task RSS."
        case .rssSamplingWindowExceeded:
            return "Peak RSS sampling window ended before the benchmark operation completed."
        case .emptyMeasurements: return "No benchmark measurements were recorded."
        case .validation(let reason): return reason
        }
    }
}

enum MailSearchBenchmarkRunner {
    static func run(configuration: MailSearchBenchmarkConfiguration) async throws -> MailSearchBenchmarkResult {
        let fileManager = FileManager.default
        let ownsWorkingDirectory = configuration.workingDirectory == nil
        let workingDirectory = configuration.workingDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "plainpost-search-benchmark-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        if let source = configuration.sourceDatabase {
            try MailSearchBenchmarkPathSafety.validate(
                sourceDatabase: source,
                outputJSON: configuration.outputJSON,
                workingDirectory: workingDirectory
            )
        }
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            if ownsWorkingDirectory {
                try? fileManager.removeItem(at: workingDirectory)
            }
        }

        let prepared = if let source = configuration.sourceDatabase {
            try prepareProductionCopy(source: source, workingDirectory: workingDirectory)
        } else {
            try prepareSynthetic(
                messageCount: configuration.messageCount,
                workingDirectory: workingDirectory
            )
        }
        let service = SQLiteMailSearchService(store: prepared.store)

        let sampledOperations = try await MailSearchBenchmarkPeakRSSSampler().measure {
            let coldStart = DispatchTime.now().uptimeNanoseconds
            _ = try await service.search(.init(query: "project", mode: .messages, limit: 50))
            let coldMilliseconds = elapsedMilliseconds(since: coldStart)

            let workloadRequests: [(String, MailSearchRequest)] = [
                ("structured", .init(query: "is:unread in:inbox", mode: .messages, limit: 50)),
                ("message_common", .init(query: "project", mode: .messages, limit: 50)),
                ("message_rare", .init(query: "rare00000000", mode: .messages, limit: 50)),
                ("message_phrase", .init(query: "\"quarterly project\"", mode: .messages, limit: 50)),
                ("message_fielded", .init(query: "from:sender017@example.com project", mode: .messages, limit: 50)),
                ("conversation_common", .init(query: "project", mode: .conversations, limit: 50)),
            ]
            var warm: [String: MailSearchBenchmarkLatencySummary] = [:]
            for (name, request) in workloadRequests {
                warm[name] = try await measure(iterations: configuration.iterations, warmupIterations: configuration.warmupIterations) {
                    _ = try await service.search(request)
                }
            }
            warm["paged_message"] = try await measure(iterations: configuration.iterations, warmupIterations: configuration.warmupIterations) {
                let first = try await service.search(
                    .init(query: "project", mode: .messages, limit: 25)
                )
                if let cursor = first.nextCursor {
                    _ = try await service.search(
                        .init(query: "project", mode: .messages, limit: 25, cursor: cursor)
                    )
                }
            }

            let queryPlans = try representativeQueryPlans(
                store: prepared.store,
                requests: workloadRequests
            )
            let cancellation = await measureCancellation(service: service)
            return (coldMilliseconds, warm, queryPlans, cancellation)
        }
        let coldMilliseconds = sampledOperations.value.0
        let warm = sampledOperations.value.1
        let queryPlans = sampledOperations.value.2
        let cancellation = sampledOperations.value.3
        let rss = sampledOperations.rss
        let storage = try storageSummary(store: prepared.store)

        guard let structured = warm["structured"],
              let message = warm["message_common"],
              let conversation = warm["conversation_common"]
        else {
            throw MailSearchBenchmarkRuntimeError.emptyMeasurements
        }
        let evaluation = MailSearchBenchmarkBudgetEvaluation.evaluate(
            measurements: .init(
                structuredP95Milliseconds: structured.p95Milliseconds,
                messageP95Milliseconds: message.p95Milliseconds,
                conversationP95Milliseconds: conversation.p95Milliseconds,
                coldFirstPageMilliseconds: coldMilliseconds,
                cancellationMilliseconds: cancellation.milliseconds,
                rssPeakDeltaBytes: rss.peakDeltaBytes,
                searchStructureBytes: storage.searchStructureBytes
            ),
            budget: .tenThousand
        )
        let performanceViolations = evaluation.violations
        var correctnessViolations: [String] = []
        if !cancellation.cancellationObserved {
            correctnessViolations.append("cancellation_not_observed")
        }
        if let migration = prepared.migration {
            if !migration.sourceUnchanged { correctnessViolations.append("source_changed") }
            if migration.preparationMethod
                != MailSearchBenchmarkMigrationProof.productionShapedV21PreparationMethod {
                correctnessViolations.append("production_shaped_v21_preparation")
            }
            if migration.naturallyCapturedV21Source {
                correctnessViolations.append("production_shaped_v21_natural_capture_claim")
            }
            if migration.sourceBackupSchemaVersion
                != MailSearchBenchmarkMigrationProof.targetSchemaVersion {
                correctnessViolations.append("source_backup_schema_version")
            }
            if migration.schemaVersionBefore != 21 {
                correctnessViolations.append("schema_version_before")
            }
            if migration.schemaVersionAfter != MailSearchBenchmarkMigrationProof.targetSchemaVersion {
                correctnessViolations.append("schema_version")
            }
            if migration.v22MigrationRegisteredBefore {
                correctnessViolations.append("v22_migration_preexisting")
            }
            if !migration.v22MigrationRegisteredAfter {
                correctnessViolations.append("v22_migration_registration")
            }
            if !migration.v22MigrationExecuted {
                correctnessViolations.append("v22_migration_execution")
            }
            if migration.v23MigrationRegisteredBefore {
                correctnessViolations.append("v23_migration_preexisting")
            }
            if !migration.v23MigrationRegisteredAfter {
                correctnessViolations.append("v23_migration_registration")
            }
            if !migration.v23MigrationExecuted {
                correctnessViolations.append("v23_migration_execution")
            }
            if !migration.projectionMatchesFTS { correctnessViolations.append("projection_fts_count") }
            if !migration.sqliteIntegrityValidationPassed {
                correctnessViolations.append("sqlite_integrity_validation")
            }
            if !migration.ftsIntegrityValidationPassed {
                correctnessViolations.append("fts_integrity_validation")
            }
            if !migration.legacyTablesAbsent { correctnessViolations.append("legacy_tables") }
            if migration.preparedCanonicalMessageCount != prepared.dataset.actualMessages
                || migration.preparedLegacyMetadataCount != prepared.dataset.actualMessages
                || migration.preparedLegacyFTSCount != prepared.dataset.actualMessages {
                correctnessViolations.append("production_shaped_v21_counts")
            }
            correctnessViolations.append(contentsOf:
                MailSearchBenchmarkOutcome.productionStorageViolations(
                    searchStructureBytes: storage.searchStructureBytes,
                    baselineBytes: MailSearchBenchmarkBudget.tenThousand.searchStructureBytes
                )
            )
        }
        correctnessViolations = Array(Set(correctnessViolations)).sorted()
        let passed = MailSearchBenchmarkOutcome.passed(
            enforcePerformanceBudgets: configuration.enforceBudgets,
            performanceViolations: performanceViolations,
            correctnessViolations: correctnessViolations
        )

        return MailSearchBenchmarkResult(
            provenance: .capture(),
            formatVersion: 4,
            generatedAt: Date(),
            hardware: hardware(),
            dataset: prepared.dataset,
            coldFirstPageMilliseconds: coldMilliseconds,
            warm: warm,
            queryPlans: queryPlans,
            cancellation: cancellation,
            rss: rss,
            storage: storage,
            migration: prepared.migration,
            budget: .tenThousand,
            budgetsEnforced: configuration.enforceBudgets,
            performanceBudgetViolations: performanceViolations,
            correctnessViolations: correctnessViolations,
            passed: passed
        )
    }

    static func write(_ result: MailSearchBenchmarkResult, to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(result)
        data.append(0x0A)
        try data.write(to: outputURL, options: .atomic)
    }

    private static func prepareSynthetic(
        messageCount: Int,
        workingDirectory: URL
    ) throws -> MailSearchBenchmarkPreparedStore {
        let databaseURL = workingDirectory.appendingPathComponent("synthetic.sqlite")
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let dataset = MailSearchBenchmarkDataset(messageCount: messageCount)
        let counts = try MailSearchBenchmarkSyntheticDatabase.populate(
            store: store,
            dataset: dataset
        )
        guard counts.messages == messageCount,
              counts.threads == dataset.threadCount,
              counts.accounts == dataset.accounts.count,
              counts.mailboxes == dataset.mailboxes.count,
              counts.projections == counts.messages,
              counts.ftsRows == counts.messages,
              counts.coverage == dataset.coverage,
              counts.generatorMatchesModel else {
            throw MailSearchBenchmarkRuntimeError.validation(
                "Synthetic SQL population does not match its deterministic dataset contract."
            )
        }
        return MailSearchBenchmarkPreparedStore(
            store: store,
            databaseURL: databaseURL,
            dataset: .init(
                requestedMessages: messageCount,
                actualMessages: counts.messages,
                threads: counts.threads,
                accounts: counts.accounts,
                mailboxes: counts.mailboxes,
                deterministicSeed: dataset.seed,
                coverage: counts.coverage.map(\.rawValue).sorted(),
                source: "synthetic"
            ),
            migration: nil
        )
    }

    private static func prepareProductionCopy(
        source: URL,
        workingDirectory: URL
    ) throws -> MailSearchBenchmarkPreparedStore {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MailSearchBenchmarkRuntimeError.missingSource(source.path)
        }
        let sourceBefore = try sourceSnapshot(source)
        let destination = workingDirectory.appendingPathComponent("production-copy.sqlite")
        var readOnlyConfiguration = Configuration()
        readOnlyConfiguration.readonly = true
        readOnlyConfiguration.label = "PlainpostSearchBenchmarkSourceReadOnly"
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: readOnlyConfiguration)
        let destinationQueue = try DatabaseQueue(path: destination.path)
        try sourceQueue.backup(to: destinationQueue)
        let preparation = try destinationQueue.write(
            MailSearchBenchmarkMigrationProof.prepareV21ProductionShapedCandidate
        )

        let backupBytesBeforeMigration = try destinationQueue.read { database in
            try databaseBytes(database)
        }
        let schemaVersionBefore = try destinationQueue.read { database in
            try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        }
        let v22MigrationRegisteredBefore = try destinationQueue.read(
            MailSearchBenchmarkMigrationProof.v22MigrationIsRegistered
        )
        let v23MigrationRegisteredBefore = try destinationQueue.read(
            MailSearchBenchmarkMigrationProof.v23MigrationIsRegistered
        )

        let store = try SQLiteMailStore(path: destination.path)
        try store.migrate()
        let ftsIntegrityValidationPassed: Bool
        do {
            try store.databasePool.writeWithoutTransaction(SQLiteMailSearchSchema.validateFTSIntegrity)
            ftsIntegrityValidationPassed = true
        } catch {
            ftsIntegrityValidationPassed = false
        }
        let validation = try store.databasePool.read { database -> (
            databaseBytes: Int64,
            schemaVersion: Int,
            v22MigrationRegistered: Bool,
            v23MigrationRegistered: Bool,
            projectionCount: Int,
            ftsCount: Int,
            sqliteIntegrityValidationPassed: Bool,
            legacyTablesAbsent: Bool
        ) in
            try SQLiteMailSearchSchema.validate(database)
            let sqliteIntegrityRows = try String.fetchAll(database, sql: "PRAGMA integrity_check")
            let sqliteIntegrityValidationPassed = sqliteIntegrityRows == ["ok"]
            let legacyAbsent = try SQLiteMailSearchSchema.legacyStructuresAreAbsent(database)
            return (
                try databaseBytes(database),
                try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0,
                try MailSearchBenchmarkMigrationProof.v22MigrationIsRegistered(database),
                try MailSearchBenchmarkMigrationProof.v23MigrationIsRegistered(database),
                try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_documents") ?? 0,
                try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_fts") ?? 0,
                sqliteIntegrityValidationPassed,
                legacyAbsent
            )
        }
        let sourceAfter = try sourceSnapshot(source)
        guard sourceBefore == sourceAfter else {
            throw MailSearchBenchmarkRuntimeError.sourceChanged
        }
        let counts = try store.databasePool.read { database -> (Int, Int, Int, Int) in
            (
                try Int.fetchOne(database, sql: "SELECT count(*) FROM messages") ?? 0,
                try Int.fetchOne(database, sql: "SELECT count(*) FROM threads") ?? 0,
                try Int.fetchOne(database, sql: "SELECT count(*) FROM accounts") ?? 0,
                try Int.fetchOne(database, sql: "SELECT count(*) FROM mailboxes") ?? 0
            )
        }
        let migration = MailSearchBenchmarkMigrationSummary(
            sourcePath: source.path,
            sourceBefore: sourceBefore,
            sourceAfter: sourceAfter,
            sourceUnchanged: true,
            backupDatabaseBytesBeforeMigration: backupBytesBeforeMigration,
            databaseBytesAfterMigration: validation.databaseBytes,
            preparationMethod: preparation.method,
            naturallyCapturedV21Source: false,
            sourceBackupSchemaVersion: preparation.sourceSchemaVersion,
            preparedCanonicalMessageCount: preparation.canonicalMessageCount,
            preparedLegacyMetadataCount: preparation.legacyMetadataCount,
            preparedLegacyFTSCount: preparation.legacyFTSCount,
            schemaVersionBefore: schemaVersionBefore,
            schemaVersionAfter: validation.schemaVersion,
            v22MigrationRegisteredBefore: v22MigrationRegisteredBefore,
            v22MigrationRegisteredAfter: validation.v22MigrationRegistered,
            v22MigrationExecuted: !v22MigrationRegisteredBefore && validation.v22MigrationRegistered,
            v23MigrationRegisteredBefore: v23MigrationRegisteredBefore,
            v23MigrationRegisteredAfter: validation.v23MigrationRegistered,
            v23MigrationExecuted: !v23MigrationRegisteredBefore && validation.v23MigrationRegistered,
            projectionCount: validation.projectionCount,
            ftsCount: validation.ftsCount,
            projectionMatchesFTS: validation.projectionCount == validation.ftsCount,
            sqliteIntegrityValidationPassed: validation.sqliteIntegrityValidationPassed,
            ftsIntegrityValidationPassed: ftsIntegrityValidationPassed,
            legacyTablesAbsent: validation.legacyTablesAbsent
        )
        return MailSearchBenchmarkPreparedStore(
            store: store,
            databaseURL: destination,
            dataset: .init(
                requestedMessages: counts.0,
                actualMessages: counts.0,
                threads: counts.1,
                accounts: counts.2,
                mailboxes: counts.3,
                deterministicSeed: nil,
                coverage: [],
                source: "disposable-production-copy"
            ),
            migration: migration
        )
    }

    fileprivate static func syntheticDatasetSQL(
        messageCount: Int,
        threadCount: Int,
        anchor: TimeInterval,
        seed: UInt64
    ) -> String {
        let seedHex = String(seed, radix: 16)
        return """
        INSERT INTO accounts (
            id, display_name, email, username, sent_mailbox,
            imap_host, imap_port, smtp_host, smtp_port
        ) VALUES
            ('account-0', 'Benchmark Personal', 'personal@example.com', 'personal@example.com',
             'Sent', '127.0.0.1', 993, '127.0.0.1', 587),
            ('account-1', 'Benchmark Work', 'work@example.com', 'work@example.com',
             'Sent', '127.0.0.1', 993, '127.0.0.1', 587);

        INSERT INTO mailboxes(id, account_id, name, path, special_use) VALUES
            ('account-0-inbox', 'account-0', 'Inbox', 'INBOX', '\\Inbox'),
            ('account-0-sent', 'account-0', 'Sent', 'Sent', '\\Sent'),
            ('account-0-archive', 'account-0', 'Archive', 'Archive', '\\Archive'),
            ('account-0-trash', 'account-0', 'Trash', 'Trash', '\\Trash'),
            ('account-1-inbox', 'account-1', 'Inbox', 'INBOX', '\\Inbox'),
            ('account-1-sent', 'account-1', 'Sent', 'Sent', '\\Sent'),
            ('account-1-archive', 'account-1', 'Archive', 'Archive', '\\Archive'),
            ('account-1-trash', 'account-1', 'Trash', 'Trash', '\\Trash');

        WITH RECURSIVE generated(value) AS (
            SELECT 0 UNION ALL SELECT value + 1 FROM generated WHERE value + 1 < \(threadCount)
        )
        INSERT INTO threads(id, account_id, subject_normalized, participant_emails)
        SELECT
            printf('thread-%08d', value),
            printf('account-%d', value % 2),
            printf('benchmark project thread %08d', value),
            printf('sender%03d@example.com\\nperson%03d@example.com', value % 211, value % 97)
        FROM generated;

        WITH RECURSIVE generated(value) AS (
            SELECT 0 UNION ALL SELECT value + 1 FROM generated WHERE value + 1 < \(messageCount)
        )
        INSERT INTO messages (
            id, account_id, thread_id, from_email, from_display_name, subject, preview,
            body_text, body_html, smart_category, labels_json, is_seen, mailbox_path,
            is_deleted, sent_at, rfc_message_id, in_reply_to, references_json,
            reply_to_email, to_emails, cc_emails
        )
        SELECT
            printf('message-%08d', value),
            printf('account-%d', value % 2),
            printf('thread-%08d', value / 5),
            printf('sender%03d@example.com', value % 211),
            printf('Sender %03d', value % 211),
            CASE
                WHEN value % 997 = 0 THEN printf('Nebula rare%08d quarterly project', value)
                WHEN value % 10 = 0 THEN 'Quarterly project update'
                ELSE 'Team schedule discussion'
            END,
            printf('Project preview %08d with deterministic milestones and budget.', value),
            CASE
                WHEN value % 997 = 0 THEN printf('Deterministic rare token rare%08d in the project archive.', value)
                WHEN value % 10 = 0
                    THEN 'Common project notes, milestones, budget, participants, and a deterministic message body.'
                ELSE 'Common local mail notes, schedule, participants, and a deterministic message body.'
            END,
            CASE WHEN value % 13 = 0
                 THEN printf('<p>Project HTML body %08d with a quarterly milestone.</p>', value)
                 ELSE NULL END,
            CASE value % 4 WHEN 0 THEN 'personal' WHEN 1 THEN 'work' WHEN 2 THEN 'newsletter' ELSE 'transaction' END,
            CASE WHEN value % 17 = 0 THEN '["flagged"]'
                 WHEN value % 29 = 0 THEN '["delegated"]' ELSE '[]' END,
            CASE WHEN value % 3 = 0 THEN 0 ELSE 1 END,
            CASE WHEN value % 20 = 0 THEN 'Trash'
                 WHEN value % 20 BETWEEN 1 AND 4 THEN 'Sent'
                 WHEN value % 20 BETWEEN 5 AND 8 THEN 'Archive' ELSE 'INBOX' END,
            0,
            \(anchor) - value * 600,
            printf('<benchmark-\(seedHex)-%08d@example.com>', value),
            CASE WHEN value % 5 = 0 THEN NULL ELSE printf('<benchmark-\(seedHex)-%08d@example.com>', value - 1) END,
            '[]',
            NULL,
            printf('person%03d@example.com', value % 97),
            CASE WHEN value % 7 = 0 THEN printf('copy%03d@example.com', value % 43) ELSE '' END
        FROM generated;

        WITH RECURSIVE generated(value) AS (
            SELECT 0 UNION ALL SELECT value + 1 FROM generated WHERE value + 1 < \(messageCount)
        )
        INSERT INTO mailbox_messages (
            account_id, mailbox_path, uid_validity, uid, message_id,
            flags, mod_sequence, internal_date, byte_size
        )
        SELECT
            printf('account-%d', value % 2),
            CASE WHEN value % 20 = 0 THEN 'Trash'
                 WHEN value % 20 BETWEEN 1 AND 4 THEN 'Sent'
                 WHEN value % 20 BETWEEN 5 AND 8 THEN 'Archive' ELSE 'INBOX' END,
            1,
            value + 1,
            printf('message-%08d', value),
            trim((CASE WHEN value % 3 != 0 THEN '\\Seen ' ELSE '' END) ||
                 (CASE WHEN value % 17 = 0 THEN '\\Flagged' ELSE '' END)),
            value + 1,
            \(anchor) - value * 600,
            512 + (value % 4096)
        FROM generated;

        WITH RECURSIVE generated(value) AS (
            SELECT 0 UNION ALL SELECT value + 1 FROM generated WHERE value + 1 < \(messageCount)
        )
        INSERT INTO mail_search_documents (
            message_id, thread_id, account_id, sent_at, sort_date,
            sender, sender_email, sender_display_name, to_value, cc_value, bcc_value,
            subject, preview, body_text, filenames, identifiers, labels,
            mailbox_ids, mailbox_names, is_seen, is_flagged, is_delegated, is_deleted,
            is_trash, is_inbox, is_sent, has_attachments, has_documents
        )
        SELECT
            m.id, m.thread_id, m.account_id, m.sent_at, m.sent_at,
            trim(m.from_display_name || ' ' || m.from_email), m.from_email, m.from_display_name,
            m.to_emails, m.cc_emails, '', m.subject, m.preview, m.body_text,
            CASE WHEN value % 11 = 0
                 THEN CASE WHEN value % 22 = 0 THEN printf('forecast-%d.pdf', value)
                           ELSE printf('notes-%d.txt', value) END
                 ELSE '' END,
            m.rfc_message_id,
            CASE WHEN value % 17 = 0 THEN 'flagged'
                 WHEN value % 29 = 0 THEN 'delegated' ELSE '' END,
            printf('account-%d-%s', value % 2,
                CASE WHEN value % 20 = 0 THEN 'trash'
                     WHEN value % 20 BETWEEN 1 AND 4 THEN 'sent'
                     WHEN value % 20 BETWEEN 5 AND 8 THEN 'archive' ELSE 'inbox' END),
            CASE WHEN value % 20 = 0 THEN 'Trash'
                 WHEN value % 20 BETWEEN 1 AND 4 THEN 'Sent'
                 WHEN value % 20 BETWEEN 5 AND 8 THEN 'Archive' ELSE 'Inbox' END,
            m.is_seen,
            CASE WHEN value % 17 = 0 THEN 1 ELSE 0 END,
            CASE WHEN value % 29 = 0 THEN 1 ELSE 0 END,
            0,
            CASE WHEN value % 20 = 0 THEN 1 ELSE 0 END,
            CASE WHEN value % 20 >= 9 THEN 1 ELSE 0 END,
            CASE WHEN value % 20 BETWEEN 1 AND 4 THEN 1 ELSE 0 END,
            CASE WHEN value % 11 = 0 THEN 1 ELSE 0 END,
            CASE WHEN value % 22 = 0 THEN 1 ELSE 0 END
        FROM generated
        JOIN messages m ON m.id = printf('message-%08d', value);

        PRAGMA optimize;
        """
    }

    static func measure(
        iterations: Int,
        warmupIterations: Int,
        operation: () async throws -> Void
    ) async throws -> MailSearchBenchmarkLatencySummary {
        for _ in 0 ..< warmupIterations {
            try await operation()
        }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try await operation()
            samples.append(elapsedMilliseconds(since: start))
        }
        guard let p50 = MailSearchBenchmarkStatistics.percentile(samples, 0.50),
              let p95 = MailSearchBenchmarkStatistics.percentile(samples, 0.95)
        else {
            throw MailSearchBenchmarkRuntimeError.emptyMeasurements
        }
        return .init(warmupIterations: warmupIterations, p50Milliseconds: p50, p95Milliseconds: p95, samplesMilliseconds: samples)
    }

    private static func measureCancellation(
        service: SQLiteMailSearchService
    ) async -> MailSearchBenchmarkCancellationSummary {
        let task = Task {
            try await service.search(
                .init(query: "project", mode: .conversations, limit: MailSearchRequest.maximumLimit)
            )
        }
        try? await Task.sleep(for: .milliseconds(1))
        let cancellationStart = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        var observed = false
        do {
            _ = try await task.value
        } catch let error as MailSearchError {
            observed = error == .cancelled
        } catch is CancellationError {
            observed = true
        } catch {
            observed = false
        }
        return .init(
            milliseconds: elapsedMilliseconds(since: cancellationStart),
            cancellationObserved: observed
        )
    }

    private static func representativeQueryPlans(
        store: SQLiteMailStore,
        requests: [(String, MailSearchRequest)]
    ) throws -> [String: [String]] {
        let parser = MailSearchQueryParser()
        let compiler = SQLiteMailSearchQueryCompiler()
        var result: [String: [String]] = [:]
        for (name, request) in requests {
            let parsed = try parser.parse(request.query, now: MailSearchBenchmarkDataset.fixedAnchor)
            let compiled = try compiler.compile(
                parsed,
                request: request,
                snippetMarkers: .init(nonce: "benchmark-plan")
            )
            result[name] = try store.databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: "EXPLAIN QUERY PLAN \(compiled.sql)",
                    arguments: compiled.arguments
                ).map { row in
                    let detail: String = row["detail"]
                    return detail
                }
            }
        }
        return result
    }

    private static func storageSummary(store: SQLiteMailStore) throws -> MailSearchBenchmarkStorageSummary {
        try store.databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY name"
            ).map { row in
                MailSearchBenchmarkStorageRow(name: row["name"], bytes: row["bytes"])
            }
            return .init(
                databaseBytes: try databaseBytes(database),
                searchStructureBytes: MailSearchBenchmarkStorageAccounting.searchStructureBytes(rows),
                oldSearchBaselineBytes: MailSearchBenchmarkBudget.tenThousand.searchStructureBytes,
                rows: rows
            )
        }
    }

    private static func databaseBytes(_ database: Database) throws -> Int64 {
        let pageCount = try Int64.fetchOne(database, sql: "PRAGMA page_count") ?? 0
        let pageSize = try Int64.fetchOne(database, sql: "PRAGMA page_size") ?? 0
        return MailSearchBenchmarkStorageAccounting.databaseBytes(
            pageCount: pageCount,
            pageSize: pageSize
        )
    }

    private static func sourceSnapshot(_ source: URL) throws -> MailSearchBenchmarkSourceSnapshot {
        MailSearchBenchmarkSourceSnapshot(
            database: try fileSnapshot(source),
            wal: try fileSnapshot(URL(fileURLWithPath: source.path + "-wal"))
        )
    }

    private static func fileSnapshot(_ url: URL) throws -> MailSearchBenchmarkFileSnapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return .init(path: url.path, exists: false, bytes: 0, modificationNanoseconds: nil, sha256: nil)
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationNanoseconds = (attributes[.modificationDate] as? Date).map {
            Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
        }
        return .init(
            path: url.path,
            exists: true,
            bytes: bytes,
            modificationNanoseconds: modificationNanoseconds,
            sha256: try sha256(url)
        )
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func hardware() -> MailSearchBenchmarkHardware {
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var modelBuffer = [CChar](repeating: 0, count: max(modelSize, 1))
        sysctlbyname("hw.model", &modelBuffer, &modelSize, nil, 0)
        let modelBytes = modelBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        let model = String(decoding: modelBytes, as: UTF8.self)
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return .init(
            model: model,
            architecture: architecture,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            buildConfiguration: configuration
        )
    }
}

@main
enum PlainpostSearchBenchmarkMain {
    static func main() async {
        let configuration: MailSearchBenchmarkConfiguration
        do {
            configuration = try .parse(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch MailSearchBenchmarkConfigurationError.helpRequested {
            print(MailSearchBenchmarkConfiguration.usage)
            Darwin.exit(MailSearchBenchmarkExitCode.success.rawValue)
        } catch {
            fputs("error: \(error)\n\(MailSearchBenchmarkConfiguration.usage)\n", stderr)
            Darwin.exit(MailSearchBenchmarkExitCode.invalidArguments.rawValue)
        }

        do {
            let result = try await MailSearchBenchmarkRunner.run(configuration: configuration)
            try MailSearchBenchmarkRunner.write(result, to: configuration.outputJSON)
            print("Wrote \(configuration.outputJSON.path)")
            let exitCode = MailSearchBenchmarkOutcome.exitCode(
                enforcePerformanceBudgets: configuration.enforceBudgets,
                performanceViolations: result.performanceBudgetViolations,
                correctnessViolations: result.correctnessViolations
            )
            if exitCode != MailSearchBenchmarkExitCode.success.rawValue {
                if !result.performanceBudgetViolations.isEmpty {
                    fputs(
                        "Performance budget violations: \(result.performanceBudgetViolations.joined(separator: ", "))\n",
                        stderr
                    )
                }
                if !result.correctnessViolations.isEmpty {
                    fputs(
                        "Correctness violations: \(result.correctnessViolations.joined(separator: ", "))\n",
                        stderr
                    )
                }
                Darwin.exit(exitCode)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            Darwin.exit(MailSearchBenchmarkExitCode.runtimeFailure.rawValue)
        }
    }
}
