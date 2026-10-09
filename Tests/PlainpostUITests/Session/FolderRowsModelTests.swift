import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class FolderRowsModelTests: XCTestCase {
    private let sent = MailFolderRef(accountID: AccountID("a"), path: "Sent", name: "Sent")
    private let trash = MailFolderRef(accountID: AccountID("a"), path: "Trash", name: "Trash")

    private func row(_ id: String) -> MessageRowModel {
        MessageRowModel(id: id, sender: "a@x", subject: id, preview: "", category: .personal, categoryLabel: "",
                        isUnread: false, isPinned: false, dateLabel: "", actions: [])
    }

    func testLoadsTheFolderAndMarksItLoaded() async {
        let model = FolderRowsModel()
        XCTAssertFalse(model.isLoaded)
        await model.load(sent) { _, path, _ in path == "Sent" ? [self.row("s1")] : [] }
        XCTAssertEqual(model.rows.map(\.id), ["s1"])
        XCTAssertEqual(model.folder, sent)
        XCTAssertTrue(model.isLoaded)
    }

    private struct ReadFailure: Error {}

    func testAFailedLoadIsAFailureNotAnEmptyFolder() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in throw ReadFailure() }
        XCTAssertTrue(model.isLoaded, "the placeholder rows go")
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.failure, FolderRowsModel.failureMessage)

        await model.load(sent) { _, _, _ in [self.row("s1")] }
        XCTAssertNil(model.failure, "Retry that works clears the failure")
        XCTAssertEqual(model.rows.map(\.id), ["s1"])
    }

    func testAFailedReloadKeepsTheRowsItHas() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("s1")] }
        await model.load(sent) { _, _, _ in throw ReadFailure() }
        XCTAssertEqual(model.rows.map(\.id), ["s1"])
        XCTAssertEqual(model.failure, FolderRowsModel.failureMessage)
    }

    func testAnotherFolderStartsWithoutTheOldFailure() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in throw ReadFailure() }
        var failureDuringLoad: String? = "unset"
        await model.load(trash) { _, _, _ in
            failureDuringLoad = model.failure
            return []
        }
        XCTAssertNil(failureDuringLoad, "Trash never shows Sent's failure")
        XCTAssertNil(model.failure)
    }

    func testSwitchingFoldersClearsTheOldRowsFirst() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("s1")] }
        var rowsDuringLoad: [String] = []
        await model.load(trash) { _, _, _ in
            rowsDuringLoad = model.rows.map(\.id)
            return [self.row("t1")]
        }
        XCTAssertEqual(rowsDuringLoad, [], "Trash never shows Sent's rows")
        XCTAssertEqual(model.rows.map(\.id), ["t1"])
    }

    func testPendingArchiveAndDeleteAreHidden() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b"), self.row("c")] }
        let overlays = [
            "a": OptimisticMailboxOverlay(rowID: "a", action: .archive),
            "b": OptimisticMailboxOverlay(rowID: "b", action: .markRead),
        ]
        XCTAssertEqual(model.visible(hiding: overlays).map(\.id), ["b", "c"])
    }

    /// The Mac list for the open folder: that folder's rows with pending actions applied, and
    /// nothing while another folder's rows are still loaded.
    func testListRowsAreTheOpenFoldersWithPendingActionsApplied() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b")] }
        let overlays = ["a": OptimisticMailboxOverlay(rowID: "a", action: .archive)]
        XCTAssertEqual(model.listRows(for: sent, hiding: overlays).map(\.id), ["b"])
        XCTAssertEqual(model.listRows(for: trash, hiding: overlays).map(\.id), [], "Trash never shows Sent's rows")
    }

    func testPendingReadStateShowsBeforeTheFolderReloads() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b")] }
        let overlays = ["a": OptimisticMailboxOverlay(rowID: "a", action: .markUnread)]
        XCTAssertEqual(model.visible(hiding: overlays).map(\.isUnread), [true, false])
    }

    func testCommittedArchiveAndDeleteLeaveTheLoadedRows() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b"), self.row("c")] }
        model.applyCommitted("a", .archive)
        model.applyCommitted("c", .delete)
        XCTAssertEqual(model.rows.map(\.id), ["b"], "a committed removal never flashes back before the reload")
    }

    func testCommittedReadChangesUpdateTheLoadedRows() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b")] }
        model.applyCommitted("a", .markUnread)
        XCTAssertEqual(model.rows.map(\.isUnread), [true, false])
        model.applyCommitted("a", .markRead)
        XCTAssertEqual(model.rows.map(\.isUnread), [false, false])
    }

    func testAReloadStartedBeforeACommitNeverRestoresTheRow() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b")] }
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "the reload has read the folder")
        let reload = Task {
            await model.load(sent) { _, _, _ in
                // The folder as read before the archive of "a" committed.
                await withCheckedContinuation { release = $0; started.fulfill() }
                return [self.row("a"), self.row("b")]
            }
        }
        await fulfillment(of: [started], timeout: 5)
        model.applyCommitted("a", .archive)
        release?.resume()
        await reload.value
        XCTAssertEqual(model.rows.map(\.id), ["b"], "the stale reload is dropped, not shown")
        await model.load(sent) { _, _, _ in [self.row("b")] }
        XCTAssertEqual(model.rows.map(\.id), ["b"], "the reload after the commit still lands")
    }

    private func page(_ limit: Int, of total: Int) -> [MessageRowModel] {
        (0..<min(limit, total)).map { row("m\($0)") }
    }

    func testAFullFolderLoadsMoreAPageAtATime() async {
        let model = FolderRowsModel()
        var limits: [Int] = []
        let folder: (AccountID, String, Int) async throws -> [MessageRowModel] = { _, _, limit in
            limits.append(limit)
            return self.page(limit, of: 450)
        }
        await model.load(sent, using: folder)
        XCTAssertEqual(model.rows.count, 200)
        XCTAssertTrue(model.hasMore)

        await model.loadMore(using: folder)
        XCTAssertEqual(model.rows.count, 400)
        XCTAssertTrue(model.hasMore)

        await model.load(sent, using: folder)
        XCTAssertEqual(model.rows.count, 400, "a reload keeps the pages already shown")

        await model.loadMore(using: folder)
        XCTAssertEqual(model.rows.count, 450)
        XCTAssertFalse(model.hasMore, "the last page is short")

        await model.loadMore(using: folder)
        XCTAssertEqual(limits, [200, 400, 400, 600], "nothing more is asked for once the folder is exhausted")
    }

    func testAShortFolderHasNoMore() async {
        let model = FolderRowsModel()
        var calls = 0
        await model.load(sent) { _, _, limit in
            calls += 1
            return self.page(limit, of: 3)
        }
        XCTAssertFalse(model.hasMore)
        await model.loadMore { _, _, _ in
            calls += 1
            return []
        }
        XCTAssertEqual(calls, 1)
    }

    func testAnotherFolderStartsAtOnePage() async {
        let model = FolderRowsModel()
        let folder: (AccountID, String, Int) async throws -> [MessageRowModel] = { _, _, limit in self.page(limit, of: 900) }
        await model.load(sent, using: folder)
        await model.loadMore(using: folder)
        var trashLimit = 0
        await model.load(trash) { _, _, limit in
            trashLimit = limit
            return self.page(limit, of: 900)
        }
        XCTAssertEqual(trashLimit, 200)
        XCTAssertEqual(model.rows.count, 200)
    }

    func testCommittedFlagsAndMovesApplyToTheLoadedRows() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a"), self.row("b")] }
        model.applyCommitted("a", .flag)
        XCTAssertEqual(model.rows.map(\.isFlagged), [true, false])
        model.applyCommitted("a", .unflag)
        XCTAssertEqual(model.rows.map(\.isFlagged), [false, false])
        model.applyCommitted("b", .move(to: "Receipts"))
        XCTAssertEqual(model.rows.map(\.id), ["a"], "a moved message leaves the folder")
        let overlays = ["a": OptimisticMailboxOverlay(rowID: "a", action: .flag)]
        XCTAssertEqual(model.visible(hiding: overlays).map(\.isFlagged), [true], "a pending flag shows")
    }

    func testACommitForAnotherRowChangesNothing() async {
        let model = FolderRowsModel()
        await model.load(sent) { _, _, _ in [self.row("a")] }
        model.applyCommitted("zzz", .archive)
        XCTAssertEqual(model.rows.map(\.id), ["a"])
    }

    /// A Sync Node folder reads the cached snapshot page, which is replaced only when the
    /// snapshot refresh a bump starts has finished. The folder must reload again then.
    func testANodeFolderReloadsOnceTheSnapshotLands() async {
        var cachedPage = [row("a"), row("b")]
        let snapshot = InboxViewModelSnapshotStore(initialModel: .preview(), provider: { _ in
            cachedPage = [self.row("b")]
            return .preview()
        })
        let bus = MailboxRefreshBus()
        let model = FolderRowsModel()
        var lastKey: MobileFolderLoadKey?
        func reloadIfTheKeyChanged() async {
            let key = MobileFolderLoadKey(kind: .folder(sent), refreshRevision: bus.revision,
                                          completedSnapshotRefreshes: snapshot.completedRefreshes)
            guard key != lastKey else { return }
            lastKey = key
            await model.load(sent) { _, _, _ in cachedPage }
        }

        await reloadIfTheKeyChanged()
        bus.bump()
        await reloadIfTheKeyChanged()
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"], "the bump's reload still reads the old page")

        await snapshot.refresh(selectedMessageID: nil)
        await reloadIfTheKeyChanged()
        XCTAssertEqual(model.rows.map(\.id), ["b"], "the landed snapshot reloads the folder")
    }
}
