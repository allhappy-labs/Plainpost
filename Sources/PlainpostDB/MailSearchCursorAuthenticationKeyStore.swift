import Darwin
import Foundation

enum MailSearchCursorAuthenticationKeyStore {
    static func loadOrCreate(forDatabasePath databasePath: String) throws -> Data {
        let keyURL = URL(fileURLWithPath: databasePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathExtension("search-cursor-key")
        if FileManager.default.fileExists(atPath: keyURL.path) {
            return try readKey(at: keyURL)
        }

        let key = try randomKey()
        let temporaryURL = keyURL.deletingLastPathComponent().appendingPathComponent(
            ".\(keyURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        try writeKey(key, to: descriptor)
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
        }
        try syncDescriptor(descriptor)

        if Darwin.link(temporaryURL.path, keyURL.path) == 0 {
            try syncDirectory(containing: keyURL)
            guard Darwin.unlink(temporaryURL.path) == 0 else {
                throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
            }
            try syncDirectory(containing: keyURL)
            shouldRemoveTemporaryFile = false
            return key
        }

        let linkError = errno
        guard linkError == EEXIST else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(linkError)
        }
        return try readKey(at: keyURL)
    }

    private static func randomKey() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func readKey(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_size == 32,
              information.st_mode & 0o077 == 0
        else {
            throw MailSearchCursorAuthenticationKeyStoreError.invalidKey
        }

        var key = Data(count: 32)
        var offset = 0
        try key.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw MailSearchCursorAuthenticationKeyStoreError.invalidKey
            }
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw MailSearchCursorAuthenticationKeyStoreError.posix(
                        count < 0 ? errno : EIO
                    )
                }
                offset += count
            }
        }
        return key
    }

    private static func writeKey(_ key: Data, to descriptor: Int32) throws {
        var offset = 0
        try key.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw MailSearchCursorAuthenticationKeyStoreError.invalidKey
            }
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw MailSearchCursorAuthenticationKeyStoreError.posix(
                        count < 0 ? errno : EIO
                    )
                }
                offset += count
            }
        }
    }

    private static func syncDirectory(containing url: URL) throws {
        let descriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try syncDescriptor(descriptor)
    }

    private static func syncDescriptor(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw MailSearchCursorAuthenticationKeyStoreError.posix(errno)
            }
        }
    }
}

private enum MailSearchCursorAuthenticationKeyStoreError: Error {
    case invalidKey
    case posix(Int32)
}
