import Foundation

func writeNodeAttachmentArtifact(
    bytes: Data,
    filename: String,
    temporaryRoot: URL,
    write: (Data, URL) throws -> Void,
    setFilePermissions: (URL) throws -> Void
) throws -> PlainpostAttachmentArtifact {
    let directory = temporaryRoot
        .appendingPathComponent("Plainpost-Attachment-\(UUID().uuidString)", isDirectory: true)
    var ownsDirectory = false
    defer {
        if ownsDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    ownsDirectory = true
    let url = directory.appendingPathComponent(filename)
    try write(bytes, url)
    try setFilePermissions(url)
    let artifact = PlainpostAttachmentArtifact(url: url, filename: filename)
    ownsDirectory = false
    return artifact
}
