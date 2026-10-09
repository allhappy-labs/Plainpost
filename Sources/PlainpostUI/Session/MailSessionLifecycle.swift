import Foundation
import PlainpostCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What a mail root decides for itself when it hosts a `MailSession`: where failures and
/// Ask Mail show, and the few choices only it can make. Every choice is required at
/// assembly, including an explicit no-op when a platform has no approval selection.
struct MailSessionLifecycleHooks {
    /// Shows a mailbox action's failure.
    var reportFailure: @MainActor (String) -> Void
    /// Shows Ask Mail after search has handed it a question.
    var presentAskMail: @MainActor (String) -> Void
    /// Runs in the bootstrap once the approval queue has loaded.
    var didRefreshApprovals: @MainActor () -> Void
    /// The root's own reasons to skip the on-appear Smart Inbox refresh (a design preview, a
    /// pending account setup). The session adds the rerun and AI-availability checks.
    var allowsSmartInboxRefreshOnAppear: @MainActor () -> Bool
    /// Marking the opened message read failed.
    var markReadFailed: @MainActor () -> Void
    /// An attachment finished saving, or failed to.
    var attachmentEvent: @MainActor (PlainpostAttachmentEvent) -> Void
}

extension MailSession {
    /// First-run setup is showing: the local account isn't set up yet, and setup hasn't just
    /// connected one. The iPhone shell shows setup instead of mail meanwhile, and skips the
    /// on-appear Smart Inbox refresh (macOS gates the same refresh on its own setup state).
    var isAccountSetupPending: Bool {
        guard inboxSnapshot.model.shouldPresentLegacyAccountSetup else { return false }
        if case .connected = accountSetup.status { return false }
        return true
    }

    /// Whether an on-appear Smart Inbox run should fire for a host gated on account-setup
    /// status: not while first-run setup shows, since there's no mail to triage yet. Shared by
    /// `MobileMailShell`'s `allowsSmartInboxRefreshOnAppear` hook and its tests, so the
    /// predicate can't drift between what the hook does and what a test asserts it does.
    static func allowsSmartInboxRefreshOnAppear(isAccountSetupPending: Bool) -> Bool {
        !isAccountSetupPending
    }

    /// Points the session's settable hooks at a root's `hooks`. `MailSessionLifecycle` calls
    /// this once, before `activity.attach()`.
    func connectLifecycle(_ hooks: MailSessionLifecycleHooks, locale: Locale) {
        actions.reportFailure = hooks.reportFailure
        search.askMail = { [weak askMail] query in
            askMail?.newConversation()
            askMail?.input = query
            hooks.presentAskMail(query)
        }
        activity.locale = locale
        activity.didRefreshApprovals = hooks.didRefreshApprovals
        activity.refreshSmartInbox = { [weak self] in
            guard let self,
                  hooks.allowsSmartInboxRefreshOnAppear(),
                  !maintenance.isRerunActive,
                  aiGenerationAvailable() else { return }
            await refreshSmartInbox(
                using: aiProviderSettings.selectedProviderID,
                mode: .incremental,
                locale: locale
            )
        }
    }

    /// The admitted read mutation may finish after navigation or detach. Only its presentation
    /// and snapshot publication are fenced; durable operation ownership stays in the runtime.
    func markOpenedMessageRead(reportFailure: @MainActor () -> Void) async {
        // A conversation shown moments ago shows again at once, before anything is read.
        if let messageID = mailbox.selectedMessageID {
            inboxSnapshot.showRecentThread(containing: messageID)
        }
        // Commit the list selection before rebuilding reader state, so row feedback stays
        // immediate even for a large HTML thread.
        await Task.yield()
        guard !Task.isCancelled else { return }
        let messageID = mailbox.selectedMessageID
        let accountRevision = storeChangeMonitor.accountRevision
        let isCurrent = {
            !Task.isCancelled && self.mailbox.selectedMessageID == messageID
                && self.storeChangeMonitor.accountRevision == accountRevision
        }
        // The conversation alone first: marking it read and refreshing the mailbox can take
        // far longer, and the reader shouldn't wait for either.
        if let messageID {
            await inboxSnapshot.loadThread(messageID: messageID, canPublish: isCurrent)
            guard isCurrent() else { return }
        }
        do {
            try await humanMessageOpenCoordinator.openIfPresent(messageID)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            reportFailure()
        }
        guard isCurrent() else { return }
        await inboxSnapshot.refresh(selectedMessageID: messageID, canPublish: isCurrent)
    }
}

/// The host wiring every mail root needs around its `MailSession`: AI provider changes,
/// mark-read on open, attachment events, account changes, Ask Mail re-attachment, the
/// composer's unsaved state and the activity coordinator's lifetime. The macOS root and the
/// iPhone shell both apply it, so neither hand-copies the other's wiring.
struct MailSessionLifecycle: ViewModifier {
    private let session: MailSession
    private let hooks: MailSessionLifecycleHooks
    @ObservedObject private var mailbox: MailboxController
    @ObservedObject private var accountSetup: AccountSetupViewModel
    @ObservedObject private var attachmentState: PlainpostAttachmentState
    @ObservedObject private var storeChangeMonitor: MailStoreChangeMonitor
    @ObservedObject private var compose: ComposeCoordinator
    @Environment(\.locale) private var locale
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init(session: MailSession, hooks: MailSessionLifecycleHooks) {
        self.session = session
        self.hooks = hooks
        _mailbox = ObservedObject(wrappedValue: session.mailbox)
        _accountSetup = ObservedObject(wrappedValue: session.accountSetup)
        _attachmentState = ObservedObject(wrappedValue: session.attachmentState)
        _storeChangeMonitor = ObservedObject(wrappedValue: session.storeChangeMonitor)
        _compose = ObservedObject(wrappedValue: session.compose)
    }

    func body(content: Content) -> some View {
        content
            .modifier(RootAITranslationConfigurationModifier(
                aiAssistant: session.aiAssistant,
                askMail: session.askMail,
                conversationAskMail: session.conversationAskMail,
                aiProviderSettings: session.aiProviderSettings,
                translationSettings: session.translationSettings,
                threadTranslation: session.threadTranslation,
                conversationAI: session.conversationAI,
                configureAIAssistant: session.configureAIAssistant,
                configureAskMail: session.configureAskMail,
                configureThreadTranslation: session.configureThreadTranslation
            ))
            .modifier(ComposerActivityReporter(
                composer: session.composer,
                isPresented: compose.isPresented,
                activity: session.composerActivity
            ))
            .onChange(of: attachmentState.event) { _, event in
                guard let event else { return }
                hooks.attachmentEvent(event)
            }
            .onChange(of: accountSetup.completedAddEvent) { _, event in
                guard let event else { return }
                session.onAccountSetupConnected(event.accountID)
            }
            .onChange(of: accountSetup.accounts) { _, _ in
                session.accountsChanged()
                session.mailSearch.updateAccounts(MailSession.mailSearchAccounts(accountSetup))
                session.activity.requestSearchMailboxRefresh()
            }
            .onChange(of: storeChangeMonitor.accountRevision) { _, _ in
                // Account sources changed: a remembered conversation may no longer be readable.
                session.inboxSnapshot.forgetRecentThreads()
                // Account sources changed: Ask Mail's gate and actions follow them.
                session.attachAskMailHost()
            }
            .onChange(of: locale) { _, locale in
                session.activity.locale = locale
            }
            .task(id: mailbox.selectedMessageID) {
                await session.markOpenedMessageRead(reportFailure: hooks.markReadFailed)
            }
            .task {
                session.connectLifecycle(hooks, locale: locale)
                // Bootstraps the mailbox, then keeps it current (and polls the Sync Node
                // status every 5 s) until SwiftUI cancels this with the view.
                await session.activity.attach()
            }
            #if os(iOS)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { MailSessionBackgroundCommit().run(session.actions) }
            }
            #endif
    }

}

@MainActor
struct RootAITranslationConfigurationModifier: ViewModifier {
    @ObservedObject var aiAssistant: ThreadAIAssistantViewModel
    @ObservedObject var askMail: AskMailViewModel
    @ObservedObject var conversationAskMail: AskMailViewModel
    @ObservedObject var aiProviderSettings: AIProviderSettingsViewModel
    @ObservedObject var translationSettings: TranslationLanguageSettingsViewModel
    @ObservedObject var threadTranslation: ThreadTranslationViewModel
    /// Told after the assistant is configured, so the ✦ pane prepares its conversation again.
    let conversationAI: ConversationAIPaneModel
    let configureAIAssistant: (ThreadAIAssistantViewModel, String) -> Void
    let configureAskMail: (AskMailViewModel, String) -> Void
    let configureThreadTranslation: (ThreadTranslationViewModel, String) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: aiProviderSettings.providerConfigurationKey, initial: true) { _, _ in
                let providerID = aiProviderSettings.selectedProviderID
                PlainpostRootView.applyAIProviderChange(
                    providerID: providerID,
                    aiAssistant: aiAssistant,
                    askMail: askMail,
                    threadTranslation: threadTranslation,
                    configureAIAssistant: configureAIAssistant,
                    configureAskMail: configureAskMail,
                    configureThreadTranslation: configureThreadTranslation
                )
                configureAskMail(conversationAskMail, providerID)
                conversationAI.assistantDidReconfigure()
            }
            .onChange(of: translationSettings.selectedLanguageID) {
                PlainpostRootView.applyTranslationLanguageChange(
                    threadTranslation: threadTranslation
                )
            }
    }
}

/// Reports whether the embedded composer is open with unsaved changes to the
/// runtime that owns this root view.
struct ComposerActivityReporter: ViewModifier {
    @ObservedObject var composer: ComposerViewModel
    let isPresented: Bool
    let activity: PlainpostComposerActivity?

    private var hasUnsavedOpenComposer: Bool {
        isPresented && composer.hasUnsavedChanges
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: hasUnsavedOpenComposer, initial: true) { _, value in
                activity?.update(hasUnsavedOpenComposer: value)
            }
            .onDisappear {
                activity?.update(hasUnsavedOpenComposer: false)
            }
    }
}

/// Commits pending grace-period mail actions when the scene goes to the background, holding a
/// background-task assertion until the backend has answered, so suspension never strands an
/// archive inside its Undo window. `begin` and `end` are the assertion hooks; on iOS, `init()`
/// uses `UIApplication`'s, and tests inject their own.
@MainActor
struct MailSessionBackgroundCommit {
    static let taskName = "Plainpost.commitPendingMailActions"

    /// Begins an assertion named `name` and returns its ID. The system calls `expiry` if it
    /// runs out of time first.
    typealias Begin = @MainActor (_ name: String, _ expiry: @escaping @MainActor @Sendable () -> Void) -> Int
    typealias End = @MainActor (_ id: Int) -> Void

    private let begin: Begin
    private let end: End

    init(begin: @escaping Begin, end: @escaping End) {
        self.begin = begin
        self.end = end
    }

    /// Returns the commit task, or nil when nothing is waiting out a grace period.
    @discardableResult
    func run(_ actions: MessageActionController) -> Task<Void, Never>? {
        guard actions.hasPendingGraceActions else { return nil }
        let token = BackgroundTaskToken(end: end)
        token.id = begin(Self.taskName) { token.finish() }
        return Task { @MainActor in
            await actions.commitPendingAndWait()
            token.finish()
        }
    }

    /// Ends the assertion once, whichever of commit and expiry comes first.
    @MainActor
    private final class BackgroundTaskToken {
        var id: Int?
        private let end: End

        init(end: @escaping End) { self.end = end }

        func finish() {
            guard let id else { return }
            self.id = nil
            end(id)
        }
    }
}

#if os(iOS)
extension MailSessionBackgroundCommit {
    /// Uses `UIApplication`'s background-task assertion.
    init() {
        self.init(
            begin: { name, expiry in
                UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiry).rawValue
            },
            end: { id in
                let task = UIBackgroundTaskIdentifier(rawValue: id)
                guard task != .invalid else { return }
                UIApplication.shared.endBackgroundTask(task)
            }
        )
    }
}
#endif
