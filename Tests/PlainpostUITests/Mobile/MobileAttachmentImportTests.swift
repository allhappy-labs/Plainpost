import XCTest
import PlainpostCore
@testable import PlainpostUI

final class MobileAttachmentImportTests: XCTestCase {
    func testReadsThePickedFileWithItsTypeAndName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let attachment = try MobileAttachmentImport.attachment(from: url, id: "fixed")

        XCTAssertEqual(attachment.id, "fixed")
        XCTAssertEqual(attachment.filename, url.lastPathComponent)
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.data, Data("hi".utf8))
    }

    func testUnknownTypesAreOctetStream() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString).zzqx")
        try Data([1, 2]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try MobileAttachmentImport.attachment(from: url).mimeType, "application/octet-stream")
    }
}

final class MobileAttachmentImportLimitTests: XCTestCase {
    private func file(bytes: Int, named name: String = "file") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).bin")
        try Data(count: bytes).write(to: url)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func attached(bytes: Int, id: String) -> DraftAttachment {
        DraftAttachment(id: id, filename: "\(id).bin", mimeType: "application/octet-stream", data: Data(count: bytes))
    }

    func testAFileOverThePerFileCapIsRefusedBeforeItIsRead() throws {
        let url = try file(bytes: DraftAttachmentContract.maximumBytesPerAttachment + 1)
        // Unreadable: a refusal that comes from reading would be a different error.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(try MobileAttachmentImport.attachment(from: url)) { error in
            XCTAssertEqual(error as? MobileAttachmentImport.Failure, .fileTooLarge)
            XCTAssertEqual(error.localizedDescription, "That file is too large to attach (limit 2 MB).")
        }
    }

    func testAFileThatWouldTakeTheDraftOverTheTotalCapIsRefusedBeforeItIsRead() throws {
        let existing = (0..<4).map { attached(bytes: DraftAttachmentContract.maximumBytesPerAttachment, id: "a\($0)") }
        let url = try file(bytes: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(try MobileAttachmentImport.attachment(from: url, addingTo: existing)) { error in
            XCTAssertEqual(error as? MobileAttachmentImport.Failure, .draftTooLarge)
            XCTAssertEqual(
                error.localizedDescription,
                "That file would take this message over its attachment limit (8 MB in total)."
            )
        }
    }

    func testAFileWithinBothCapsIsAttached() throws {
        let existing = [attached(bytes: 1_024 * 1_024, id: "a")]
        let url = try file(bytes: DraftAttachmentContract.maximumBytesPerAttachment)

        let attachment = try MobileAttachmentImport.attachment(from: url, addingTo: existing, id: "b")

        XCTAssertEqual(attachment.id, "b")
        XCTAssertEqual(attachment.data.count, DraftAttachmentContract.maximumBytesPerAttachment)
    }

    /// Ledger Task 20: the draft's filename rules are checked when the file is picked, before
    /// it is read, not later when the draft is saved.
    func testAFileNameTheDraftWouldRefuseIsRefusedBeforeItIsRead() throws {
        for name in ["back\\slash", "line\nbreak"] {
            let url = try file(bytes: 1, named: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

            XCTAssertThrowsError(try MobileAttachmentImport.attachment(from: url)) { error in
                XCTAssertEqual(error as? MobileAttachmentImport.Failure, .invalidName, name)
                XCTAssertEqual(
                    error.localizedDescription,
                    "Plainpost can't attach a file with that name. Rename it and try again."
                )
            }
        }
    }

    func testADraftAlreadyAtTheCountCapTakesNoMoreFiles() throws {
        let existing = (0..<DraftAttachmentContract.maximumCount).map { attached(bytes: 1, id: "a\($0)") }
        let url = try file(bytes: 1)

        XCTAssertThrowsError(try MobileAttachmentImport.attachment(from: url, addingTo: existing)) { error in
            XCTAssertEqual(error as? MobileAttachmentImport.Failure, .tooManyFiles)
            XCTAssertEqual(error.localizedDescription, "A message can have at most 10 attachments.")
        }
    }
}
