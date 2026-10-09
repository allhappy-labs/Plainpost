import Foundation
import PlainpostCore
import UniformTypeIdentifiers

/// Turns a file picked in Compose into a draft attachment.
enum MobileAttachmentImport {
    /// Why a picked file wasn't attached. Each is decided before the file is read.
    enum Failure: Error, Equatable, LocalizedError {
        case fileTooLarge
        case draftTooLarge
        case tooManyFiles
        case invalidName

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                "That file is too large to attach (limit \(megabytes(DraftAttachmentContract.maximumBytesPerAttachment)))."
            case .draftTooLarge:
                "That file would take this message over its attachment limit "
                    + "(\(megabytes(DraftAttachmentContract.maximumAggregateBytes)) in total)."
            case .tooManyFiles:
                "A message can have at most \(DraftAttachmentContract.maximumCount) attachments."
            case .invalidName:
                "Plainpost can't attach a file with that name. Rename it and try again."
            }
        }

        private func megabytes(_ bytes: Int) -> String { "\(bytes / (1_024 * 1_024)) MB" }
    }

    /// Reads `url` as an attachment for a draft that already carries `existing`. The file's
    /// size is checked against the per-file and total caps before it is read, as
    /// `PlainpostAppRuntime.forwardDraftAttachments` does, so an oversized file never lands in
    /// memory only to fail at save. It blocks while an iCloud file downloads, so Compose calls it
    /// through `ComposerViewModel.importAttachments`, off the main thread.
    static func attachment(
        from url: URL,
        addingTo existing: [DraftAttachment] = [],
        id: String = UUID().uuidString
    ) throws -> DraftAttachment {
        guard existing.count < DraftAttachmentContract.maximumCount else { throw Failure.tooManyFiles }
        let filename = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // The draft's own rules, checked now rather than when the draft is saved.
        do {
            try DraftAttachmentContract.validate([DraftAttachment(id: id, filename: filename, mimeType: mimeType, data: Data())])
        } catch {
            throw Failure.invalidName
        }
        // Files from the document picker are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let existingBytes = existing.reduce(0) { $0 + $1.data.count }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            try check(size: size, existingBytes: existingBytes)
        }
        let data = try coordinatedRead(url)
        // The size the file system reported can be missing or stale.
        try check(size: data.count, existingBytes: existingBytes)
        return DraftAttachment(id: id, filename: filename, mimeType: mimeType, data: data)
    }

    /// Reads through a file coordinator, which downloads an iCloud Drive file that isn't on the
    /// device yet and waits for it. That can take a while: call this off the main thread.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func check(size: Int, existingBytes: Int) throws {
        guard size <= DraftAttachmentContract.maximumBytesPerAttachment else { throw Failure.fileTooLarge }
        guard existingBytes + size <= DraftAttachmentContract.maximumAggregateBytes else { throw Failure.draftTooLarge }
    }
}
