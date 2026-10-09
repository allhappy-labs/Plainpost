import Foundation
import PlainpostCore

@MainActor
final class InboxViewModelSnapshotStore: ObservableObject {
    @Published private(set) var model: InboxViewModel
    private var canonicalModel: InboxViewModel
    private let provider: (String?) async -> InboxViewModel
    private let loadMoreProvider: ((String?) async -> InboxViewModel)?
    /// Reads just the conversation holding a message, without rebuilding the mailbox, so an
    /// opened message shows before mark-read and the list refresh finish. Nil when the
    /// runtime can't read a thread on its own.
    private let threadProvider: ((String) async -> ThreadDetailModel?)?
    private let projector: (InboxViewModel) -> InboxViewModel
    /// The last conversations shown, newest last: reopening one shows it at once while the
    /// fresh copy loads.
    private var recentThreads: [ThreadDetailModel] = []
    private static let recentThreadCapacity = 24
    @Published private(set) var isLoadingMore = false
    /// True after the first finished refresh, so a fresh list can show placeholders
    /// instead of an empty state before any data has arrived.
    @Published private(set) var hasRefreshed = false
    /// How many refreshes have landed; a superseded one never counts. Lists that derive from
    /// the refreshed mail (a Sync Node folder reads its snapshot page) reload when it changes.
    @Published private(set) var completedRefreshes = 0
    private var refreshGeneration: UInt64 = 0

    init(
        initialModel: InboxViewModel,
        provider: @escaping (String?) async -> InboxViewModel,
        loadMoreProvider: ((String?) async -> InboxViewModel)? = nil,
        threadProvider: ((String) async -> ThreadDetailModel?)? = nil,
        projector: @escaping (InboxViewModel) -> InboxViewModel = { $0 }
    ) {
        self.canonicalModel = initialModel
        self.model = projector(initialModel)
        self.provider = provider
        self.loadMoreProvider = loadMoreProvider
        self.threadProvider = threadProvider
        self.projector = projector
    }

    func reproject() {
        model = projector(canonicalModel)
    }

    func refresh(selectedMessageID: String?, canPublish: () -> Bool = { true }) async {
        guard !Task.isCancelled else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refreshedModel = await provider(selectedMessageID)
        guard !Task.isCancelled, refreshGeneration == generation, canPublish() else {
            return
        }
        hasRefreshed = true
        canonicalModel = retainingCachedRows(on: refreshedModel, selectedMessageID: selectedMessageID)
        reproject()
        remember(canonicalModel.selectedThread)
        completedRefreshes &+= 1
    }

    /// Shows the last copy of `messageID`'s conversation, if it was shown recently and isn't
    /// already the selected thread. Synchronous, so a reopened message never shows a spinner.
    func showRecentThread(containing messageID: String) {
        guard !canonicalModel.selectedThread.contains(messageID: messageID),
              let thread = recentThreads.last(where: { $0.contains(messageID: messageID) }) else { return }
        publish(selectedThread: thread)
    }

    /// Loads and shows `messageID`'s conversation alone, leaving the rows as they are. A
    /// refresh still in flight is superseded, so it can't replace the thread with an older
    /// selection; the caller refreshes the mailbox afterwards.
    func loadThread(messageID: String, canPublish: () -> Bool = { true }) async {
        guard let threadProvider, !Task.isCancelled else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let thread = await threadProvider(messageID) else { return }
        guard !Task.isCancelled, refreshGeneration == generation, canPublish(),
              thread.contains(messageID: messageID) else { return }
        publish(selectedThread: thread)
    }

    /// Drops the remembered conversations, when the accounts they came from changed.
    func forgetRecentThreads() {
        recentThreads.removeAll()
    }

    private func publish(selectedThread thread: ThreadDetailModel) {
        canonicalModel = canonicalModel.withMailboxLoadFailure(
            canonicalModel.mailboxLoadFailure, selectedThread: thread
        )
        reproject()
        remember(thread)
    }

    private func remember(_ thread: ThreadDetailModel) {
        guard !thread.messages.isEmpty else { return }
        let ids = Set(thread.messages.map(\.id))
        recentThreads.removeAll { $0.messages.contains { ids.contains($0.id) } }
        recentThreads.append(thread)
        if recentThreads.count > Self.recentThreadCapacity {
            recentThreads.removeFirst(recentThreads.count - Self.recentThreadCapacity)
        }
    }

    func loadMore(selectedMessageID: String?, destination: PlainpostDestination = .allInboxes) async {
        let hasMore = destination == .sent ? model.hasMoreSentRows : model.hasMoreRows
        guard hasMore, !isLoadingMore, let loadMoreProvider else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refreshedModel = await loadMoreProvider(selectedMessageID)
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        canonicalModel = retainingCachedRows(on: refreshedModel, selectedMessageID: selectedMessageID)
        reproject()
        remember(canonicalModel.selectedThread)
    }

    private func retainingCachedRows(
        on refreshedModel: InboxViewModel, selectedMessageID: String?
    ) -> InboxViewModel {
        guard let failure = refreshedModel.mailboxLoadFailure,
              !canonicalModel.classicRows.isEmpty || !canonicalModel.sentRows.isEmpty else {
            return refreshedModel
        }
        let keepsSelectedThread = selectedMessageID.map { id in
            canonicalModel.selectedThread.messages.contains { $0.id == id }
        } ?? false
        return canonicalModel.withMailboxLoadFailure(
            failure,
            selectedThread: keepsSelectedThread
                ? canonicalModel.selectedThread
                : refreshedModel.selectedThread
        )
    }
}

private extension ThreadDetailModel {
    func contains(messageID: String) -> Bool {
        messages.contains { $0.id == messageID }
    }
}

final class EmailBodyRenderCache {
    typealias Renderer = (EmailBodyInput) -> RenderedEmailBody

    private struct Entry {
        let input: EmailBodyInput
        let renderedBody: RenderedEmailBody
    }

    private var entries: [String: Entry] = [:]
    private let renderer: Renderer

    init(renderer: @escaping Renderer = EmailBodyRenderer.render) {
        self.renderer = renderer
    }

    func renderedBody(messageID: String, input: EmailBodyInput) -> RenderedEmailBody {
        if let entry = entries[messageID], entry.input == input {
            return entry.renderedBody
        }

        let renderedBody = renderer(input)
        entries[messageID] = Entry(input: input, renderedBody: renderedBody)
        return renderedBody
    }

    func retain(messageIDs: Set<String>) {
        entries = entries.filter { messageIDs.contains($0.key) }
    }
}

actor DeferredEmailBodyRenderStore {
    static let shared = DeferredEmailBodyRenderStore()

    private let cache: RenderedBodyCache

    init(capacity: Int = 64) {
        cache = RenderedBodyCache(capacity: capacity)
    }

    /// The body already rendered for this exact input, read without waiting on the actor, so
    /// a message opened again shows its HTML on the first frame.
    nonisolated func cachedBody(messageID: String, input: EmailBodyInput) -> RenderedEmailBody? {
        cache.body(messageID: messageID, input: input)
    }

    func render(messageID: String, input: EmailBodyInput) -> RenderedEmailBody {
        if let body = cache.body(messageID: messageID, input: input) {
            return body
        }
        let body = EmailBodyRenderer.render(input)
        cache.insert(body, messageID: messageID, input: input)
        return body
    }
}

/// A small least-recently-used map of rendered bodies, safe to read from any thread.
final class RenderedBodyCache: @unchecked Sendable {
    private struct Entry {
        let input: EmailBodyInput
        let body: RenderedEmailBody
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func body(messageID: String, input: EmailBodyInput) -> RenderedEmailBody? {
        lock.withLock {
            guard let entry = entries[messageID], entry.input == input else { return nil }
            touch(messageID)
            return entry.body
        }
    }

    func insert(_ body: RenderedEmailBody, messageID: String, input: EmailBodyInput) {
        lock.withLock {
            entries[messageID] = Entry(input: input, body: body)
            touch(messageID)
            while entries.count > capacity, let oldest = recency.first {
                recency.removeFirst()
                entries[oldest] = nil
            }
        }
    }

    private func touch(_ messageID: String) {
        recency.removeAll { $0 == messageID }
        recency.append(messageID)
    }
}

/// The last measured height of each message's HTML, so a message opened again lays out at
/// its size instead of growing from the placeholder height.
@MainActor
enum HTMLMessageHeightCache {
    private static var heights: [String: CGFloat] = [:]
    private static var recency: [String] = []
    private static let capacity = 128

    static func height(for messageID: String) -> CGFloat? {
        heights[messageID]
    }

    static func record(_ height: CGFloat, for messageID: String) {
        if heights.updateValue(height, forKey: messageID) == nil {
            recency.append(messageID)
            if recency.count > capacity {
                heights[recency.removeFirst()] = nil
            }
        }
    }
}
