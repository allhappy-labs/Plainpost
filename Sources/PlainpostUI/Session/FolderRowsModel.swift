import Foundation
import PlainpostCore

/// One account folder: its account, path, name and role. The iPhone's Mailboxes screen and
/// the Mac sidebar list them; choosing one shows only that folder.
struct MailFolderRef: Hashable, Sendable {
    let accountID: AccountID
    let path: String
    let name: String
    var role: MailboxFolder.Role = .other
}

/// One account folder's rows for a folder list (the iPhone's, or the Mac mail list narrowed to
/// a folder), loaded when the folder opens and again whenever the mailbox changes. The newest
/// load wins. The list shows one page and grows by a page when it scrolls to its last row; a
/// reload keeps the pages it has.
@MainActor
final class FolderRowsModel: ObservableObject {
    @Published private(set) var rows: [MessageRowModel] = []
    @Published private(set) var folder: MailFolderRef?
    @Published private(set) var isLoaded = false
    /// Set when the latest load failed; the rows are those of the last load that worked.
    @Published private(set) var failure: String?
    /// True while the last load filled every row it asked for, so the folder may hold more.
    @Published private(set) var hasMore = false
    private(set) var limit = FolderRowsModel.pageSize
    private var isLoadingMore = false
    private var generation = 0

    static let pageSize = InboxProjectionRepository.pageSize

    static let failureMessage = "Plainpost couldn't read this folder."

    func load(_ folder: MailFolderRef, using load: (AccountID, String, Int) async throws -> [MessageRowModel]) async {
        generation += 1
        let current = generation
        if self.folder != folder {
            self.folder = folder
            rows = []
            isLoaded = false
            failure = nil
            hasMore = false
            limit = Self.pageSize
        }
        let limit = limit
        do {
            let loaded = try await load(folder.accountID, folder.path, limit)
            guard current == generation else { return }
            rows = loaded
            hasMore = loaded.count >= limit
            failure = nil
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            failure = Self.failureMessage
        }
        isLoaded = true
    }

    /// Asks for one more page of the loaded folder, once the last load filled its page.
    func loadMore(using load: (AccountID, String, Int) async throws -> [MessageRowModel]) async {
        guard let folder, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        limit += Self.pageSize
        await self.load(folder, using: load)
    }

    /// Applies an action that reached the backend to the loaded rows, so the row stays as
    /// the action left it once its overlay clears; the reload that follows confirms it.
    /// A load already running read the folder before the commit, so its rows are dropped.
    func applyCommitted(_ messageID: String, _ action: InboxMailAction) {
        generation += 1
        guard let index = rows.firstIndex(where: { $0.id == messageID }) else { return }
        switch action {
        case .archive, .delete, .deletePermanently, .move: rows.remove(at: index)
        case .markRead: rows[index] = rows[index].replacing(isUnread: false)
        case .markUnread: rows[index] = rows[index].replacing(isUnread: true)
        case .flag: rows[index] = rows[index].replacing(isFlagged: true)
        case .unflag: rows[index] = rows[index].replacing(isFlagged: false)
        }
    }

    /// The rows with pending archives and deletes hidden and pending read changes shown, as
    /// the inbox projection does.
    /// The rows a list shows for `folder`: its rows with pending actions applied, or none while
    /// another folder's rows are still loaded.
    func listRows(for folder: MailFolderRef?, hiding overlays: [String: OptimisticMailboxOverlay]) -> [MessageRowModel] {
        guard let folder, folder == self.folder else { return [] }
        return visible(hiding: overlays)
    }

    func visible(hiding overlays: [String: OptimisticMailboxOverlay]) -> [MessageRowModel] {
        rows.compactMap { row in
            guard let overlay = overlays[row.id] else { return row }
            guard !overlay.hidesRow else { return nil }
            return row.replacing(isUnread: overlay.unreadOverride ?? row.isUnread)
                .replacing(isFlagged: overlay.action.flaggedChange ?? row.isFlagged)
        }
    }
}
