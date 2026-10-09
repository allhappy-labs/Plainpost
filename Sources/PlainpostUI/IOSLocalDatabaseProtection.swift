import Darwin
import Foundation

public enum IOSLocalDatabaseProtection {
    public static let databaseFilename = "Plainpost-iOS-Direct.sqlite"
    private static let untilFirstUnlockProtectionClass: Int32 = 3

    public static func databaseURL(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(databaseFilename)
    }

    /// Call before opening SQLite, then again after migration and on reopen.
    /// Existing WAL/SHM files need an explicit attribute update because they
    /// may have been created before the directory protection was established.
    public static func prepare(url: URL) throws {
        #if os(iOS)
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // On Simulator, Foundation accepts directory protection attributes but
        // does not apply them. Class C is UntilFirstUserAuthentication.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryDescriptor) }
        guard fcntl(directoryDescriptor, F_SETPROTECTIONCLASS, untilFirstUnlockProtectionClass) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for file in protectedURLs(for: url) where manager.fileExists(atPath: file.path) {
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path
            )
        }
        #else
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #endif
    }

    public static func verify(url: URL) throws {
        #if os(iOS)
        let manager = FileManager.default
        for file in protectedURLs(for: url) {
            guard manager.fileExists(atPath: file.path) else {
                if file == url { throw CocoaError(.fileNoSuchFile) }
                continue
            }
            let actual = try file.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
            guard actual == .completeUntilFirstUserAuthentication else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        #endif
    }

    private static func protectedURLs(for url: URL) -> [URL] {
        [
            url.deletingLastPathComponent(),
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
    }
}
