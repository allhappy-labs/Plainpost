import Foundation
import PlainpostCore

/// Mail search's presentation, its hand-offs to the mailbox and Ask Mail, and the index
/// rebuild it offers, independent of any platform UI. PlainpostRootView owns one; a future
/// iPhone UI shares it.
@MainActor
final class SearchController: ObservableObject {
    @Published var isPresented: Bool = false
    /// Bumped on every `present` so the workspace starts fresh.
    @Published private(set) var presentationGeneration: Int = 0
    let search: MailSearchViewModel
    /// Starts an Ask Mail conversation with the search query. Settable so a view can
    /// connect it once its own state exists.
    var askMail: @MainActor (String) -> Void
    /// Runs after a hit opens, with its message ID. Settable for the same reason as `askMail`.
    var afterOpen: @MainActor (String) -> Void

    private let rebuild: MailSearchIndexRebuildController
    private let mailbox: MailboxController
    var mailboxForTesting: MailboxController { mailbox }
    private let accounts: @MainActor () -> [MailSearchAccount]
    private let canAskMail: @MainActor () -> Bool

    init(
        search: MailSearchViewModel,
        rebuild: MailSearchIndexRebuildController,
        mailbox: MailboxController,
        accounts: @escaping @MainActor () -> [MailSearchAccount],
        askMail: @escaping @MainActor (String) -> Void,
        canAskMail: @escaping @MainActor () -> Bool,
        afterOpen: @escaping @MainActor (String) -> Void
    ) {
        self.search = search
        self.rebuild = rebuild
        self.mailbox = mailbox
        self.accounts = accounts
        self.askMail = askMail
        self.canAskMail = canAskMail
        self.afterOpen = afterOpen
    }

    /// `accountScope`, when given, replaces the accounts searched: empty for every account,
    /// one for a search started inside that account's folder.
    func present(query: String?, accountScope: [AccountID]? = nil) {
        search.reset(
            query: query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            accounts: accounts(),
            accountScope: accountScope
        )
        presentationGeneration &+= 1
        isPresented = true
    }

    func close() {
        search.reset(query: "", accounts: accounts())
        isPresented = false
    }

    /// Opens a hit. Keeps the query and results unless `closesSearch` (the Mac replaces search with the mailbox).
    func open(_ messageID: MessageID, closesSearch: Bool) {
        let destination = PlainpostDestination.allInboxes
        let mode = mailbox.mailboxNavigation.rememberedMode(
            for: destination,
            fallback: InboxDisplayMode(rawValue: mailbox.selectedInboxMode) ?? .focusedList
        )
        let context = mailbox.listContext(
            destination: destination,
            mode: mode,
            preserveActiveBundle: false
        )
        mailbox.openMessage(messageID.rawValue, destination: destination, from: context)
        if closesSearch {
            close()
        }
        afterOpen(messageID.rawValue)
    }

    /// Hands the query to Ask Mail; nil while no AI provider can answer.
    var askMailAction: (() -> Void)? {
        guard canAskMail() else { return nil }
        return { [self] in
            let question = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
            isPresented = false
            askMail(question)
        }
    }

    /// Rebuilds the search index, then reruns the search; nil when rebuilding isn't allowed.
    var rebuildAction: (() -> Void)? {
        guard rebuild.allowsRebuild else { return nil }
        return { [rebuild, search] in
            Task {
                await rebuild.rebuild()
                guard rebuild.state == .ready else { return }
                search.retry()
            }
        }
    }
}
