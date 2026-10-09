import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class ForwardTests: XCTestCase {
    private func context() -> ComposerForwardContext {
        ComposerForwardContext(
            sourceMessageID: MessageID("m1"), subject: "Photos", senderName: "Aisha Khan",
            senderAddress: "aisha@studio.example", dateLabel: "Sep 25", quotedBody: "Here are the photos!"
        )
    }

    func testForwardPrefixesSubjectLeavesRecipientsEmptyAndQuotesOriginal() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        let file = DraftAttachment(id: "a1", filename: "lake.png", mimeType: "image/png", data: Data([1]))
        composer.prepareForward(context: context(), attachments: [file], unavailable: [])
        XCTAssertEqual(composer.subject, "Fwd: Photos")
        XCTAssertEqual(composer.to, "")
        XCTAssertTrue(composer.bodyMarkdown.contains("Forwarded message"))
        XCTAssertTrue(composer.bodyMarkdown.contains("From: Aisha Khan <aisha@studio.example>"))
        XCTAssertTrue(composer.bodyMarkdown.contains("Here are the photos!"))
        XCTAssertEqual(composer.attachments.map(\.filename), ["lake.png"])
    }

    func testForwardDoesNotDoublePrefix() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        var ctx = context()
        ctx = ComposerForwardContext(sourceMessageID: ctx.sourceMessageID, subject: "Fwd: Photos", senderName: ctx.senderName,
                                     senderAddress: ctx.senderAddress, dateLabel: ctx.dateLabel, quotedBody: ctx.quotedBody)
        composer.prepareForward(context: ctx, attachments: [], unavailable: [])
        XCTAssertEqual(composer.subject, "Fwd: Photos")
    }

    func testForwardReportsUnavailableAttachments() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: ["lake.png"])
        XCTAssertEqual(composer.statusMessage, "Couldn't attach lake.png. Forwarding without it.")
    }

    func testForwardReportsSeveralUnavailableAttachments() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: ["lake.png", "dock.png"])
        XCTAssertEqual(composer.statusMessage, "Couldn't attach lake.png, dock.png. Forwarding without them.")
    }

    /// A forward carries the original's content, so it is an unsaved draft and drops no reply threading.
    func testForwardIsANewUnsavedMessageWithoutReplyContext() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareReply(context: ComposerReplyContext(
            sourceThreadID: nil, sourceMessageID: MessageID("m0"), rfcMessageID: "<m0@x>", references: [],
            recipient: "old@x.example", subject: "Old", senderName: "Old", dateLabel: "", quotedBody: "old"
        ))
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        XCTAssertNil(composer.replyContext)
        XCTAssertEqual(composer.presentationMode, .newMessage)
        XCTAssertTrue(composer.hasUnsavedChanges)
        XCTAssertNil(composer.quotedHistoryMarkdown)
    }

    /// The macOS composer window prepares the body first and attaches the files once they load.
    func testForwardedFilesAttachAfterTheBodyWithoutLosingEdits() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.beginAttachingForwardedFiles(count: 2)
        composer.to = "ben@x.example"
        let file = DraftAttachment(id: "a1", filename: "lake.png", mimeType: "image/png", data: Data([1]))

        composer.attachForwardedFiles([file], unavailable: ["dock.png"])

        XCTAssertEqual(composer.to, "ben@x.example")
        XCTAssertTrue(composer.bodyMarkdown.contains("Here are the photos!"))
        XCTAssertEqual(composer.attachments.map(\.filename), ["lake.png"])
        XCTAssertEqual(composer.statusMessage, "Couldn't attach dock.png. Forwarding without it.")
    }

    /// A forward whose files are still loading can't be sent, so it never goes out without them.
    func testForwardCannotBeSentWhileItsFilesLoad() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.to = "ben@x.example"
        XCTAssertTrue(composer.canSend)

        composer.beginAttachingForwardedFiles(count: 2)

        XCTAssertTrue(composer.isLoadingForwardAttachments)
        XCTAssertFalse(composer.canSend)
        XCTAssertTrue(composer.canSaveDraft)
        XCTAssertEqual(composer.statusMessage, "Attaching 2 original files...")
        composer.bodyMarkdown += "\nFYI"
        XCTAssertEqual(composer.displayStatusMessage, "Attaching 2 original files...")

        let file = DraftAttachment(id: "a1", filename: "lake.png", mimeType: "image/png", data: Data([1]))
        composer.attachForwardedFiles([file], unavailable: [])

        XCTAssertFalse(composer.isLoadingForwardAttachments)
        XCTAssertTrue(composer.canSend)
        XCTAssertEqual(composer.attachments, [file])
        XCTAssertEqual(composer.displayStatusMessage, "Unsaved changes")
    }

    func testLoadingStatusNamesASingleFile() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.beginAttachingForwardedFiles(count: 1)
        XCTAssertEqual(composer.statusMessage, "Attaching 1 original file...")
    }

    func testForwardWithoutFilesIsNotHeldBack() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.beginAttachingForwardedFiles(count: 0)
        XCTAssertFalse(composer.isLoadingForwardAttachments)
        XCTAssertNil(composer.statusMessage)
    }

    /// Saving mid-load is allowed; files that arrive afterwards leave the draft unsaved and say so.
    func testFilesArrivingAfterASaveLeaveTheDraftUnsaved() async throws {
        let composer = ComposerViewModel(composer: SavingComposer())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.to = "ben@x.example"
        composer.beginAttachingForwardedFiles(count: 1)
        try await composer.saveDraft()
        XCTAssertNotNil(composer.lastDraftID)
        XCTAssertFalse(composer.hasUnsavedChanges)

        let file = DraftAttachment(id: "a1", filename: "lake.png", mimeType: "image/png", data: Data([1]))
        composer.attachForwardedFiles([file], unavailable: [])

        XCTAssertEqual(composer.attachments, [file])
        XCTAssertTrue(composer.hasUnsavedChanges)
        XCTAssertEqual(
            composer.statusMessage,
            "Original files attached after the draft was saved. Save again to keep them."
        )
    }

    /// Files that arrive after the forward was replaced by another draft are not attached to it.
    func testFilesArrivingAfterTheDraftWasReplacedAreIgnored() {
        let composer = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        composer.prepareForward(context: context(), attachments: [], unavailable: [])
        composer.beginAttachingForwardedFiles(count: 1)
        composer.prepareNewMessage()
        XCTAssertFalse(composer.isLoadingForwardAttachments)

        let file = DraftAttachment(id: "a1", filename: "lake.png", mimeType: "image/png", data: Data([1]))
        composer.attachForwardedFiles([file], unavailable: [])

        XCTAssertEqual(composer.attachments, [])
    }

    func testForwardContextUsesTheSenderDisplayNameAndBareAddress() {
        let context = ComposeCoordinator.forwardContext(
            sourceMessageID: "m1",
            subject: "Photos",
            senderDisplayName: nil,
            sender: "Aisha Khan <aisha@studio.example>",
            dateLabel: "Sep 25",
            quotedBody: "Here are the photos!"
        )
        XCTAssertEqual(context.sourceMessageID, MessageID("m1"))
        XCTAssertEqual(context.senderName, "Aisha Khan")
        XCTAssertEqual(context.senderAddress, "aisha@studio.example")
        XCTAssertEqual(context.subject, "Photos")
    }

    func testForwardAttachmentsReportFilesThatCannotBeRead() async {
        struct Offline: Error {}
        let sources = [
            MailAttachment(id: "n1", filename: "lake.png", mimeType: "image/png", disposition: "attachment",
                           byteCount: 1, contentDigest: nil),
            MailAttachment(id: "n2", filename: "dock.png", mimeType: "image/png", disposition: "attachment",
                           byteCount: 1, contentDigest: nil),
        ]
        let result = await PlainpostAppRuntime.forwardDraftAttachments(from: sources) { attachment in
            guard attachment.id == "n1" else { throw Offline() }
            return Data([7])
        }
        XCTAssertEqual(result.attachments.map(\.filename), ["lake.png"])
        XCTAssertEqual(result.attachments.map(\.data), [Data([7])])
        XCTAssertEqual(result.attachments.map(\.mimeType), ["image/png"])
        XCTAssertEqual(result.unavailable, ["dock.png"])
    }

    /// Files a draft can't carry (too large, too many) are reported, not downloaded, so the
    /// forward stays sendable.
    func testForwardAttachmentsSkipFilesBeyondTheDraftLimits() async {
        let oversized = MailAttachment(
            id: "big", filename: "video.mov", mimeType: "video/quicktime", disposition: "attachment",
            byteCount: DraftAttachmentContract.maximumBytesPerAttachment + 1, contentDigest: nil
        )
        let small = (0 ..< DraftAttachmentContract.maximumCount + 1).map { index in
            MailAttachment(id: "s\(index)", filename: "note-\(index).txt", mimeType: "text/plain",
                           disposition: "attachment", byteCount: 1, contentDigest: nil)
        }
        var readIDs: [String] = []
        let result = await PlainpostAppRuntime.forwardDraftAttachments(from: [oversized] + small) { attachment in
            readIDs.append(attachment.id)
            return Data([1])
        }
        XCTAssertFalse(readIDs.contains("big"))
        XCTAssertEqual(result.attachments.count, DraftAttachmentContract.maximumCount)
        XCTAssertEqual(result.unavailable, ["video.mov", "note-10.txt"])
        XCTAssertNoThrow(try DraftAttachmentContract.validate(result.attachments))
    }
}

private struct SavingComposer: ComposerHandling {
    func saveDraft(input: ComposerDraftInput) throws -> Draft {
        Draft(
            id: DraftID("drf_forward"),
            accountID: AccountID("acc_test"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("ben@x.example")],
            cc: [],
            bcc: [],
            subject: input.subject,
            bodyPlain: input.bodyPlain,
            createdBy: "test",
            aiGenerated: false,
            sourceThreadID: nil
        )
    }
}
