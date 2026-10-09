import Combine
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostUI
import SwiftUI

/// The part of a mail runtime the iOS mail root manages: its authority, its
/// pending or failed undoable send, its open composer, and its shutdown.
@MainActor
protocol MobileMailRuntime: AnyObject {
    var mailAuthority: (any PlainpostMailAuthority)? { get }
    var isSendPending: Bool { get }
    var sendPendingPublisher: AnyPublisher<Bool, Never> { get }
    /// A delivery failed and its notice, with the draft restore, is showing.
    var hasFailedSend: Bool { get }
    func dismissFailedSend()
    /// Publishes whether the embedded composer is open with unsaved changes,
    /// starting with the current value. Replacing the runtime discards it.
    var unsavedOpenComposerPublisher: AnyPublisher<Bool, Never> { get }
    func shutdown() async
}

extension PlainpostAppRuntime: MobileMailRuntime {}

/// A weak reference to a mail authority, or to no authority. It matches only
/// the same authority object: a released authority never matches, even when a
/// new one reuses its address.
struct MobileMailAuthorityReference: Equatable {
    private let hasAuthority: Bool
    private weak var authority: AnyObject?
    /// The provider account a scoped Node authority is bound to.
    private let logicalMailboxID: LogicalMailboxID?

    init(_ authority: (any PlainpostMailAuthority)?) {
        hasAuthority = authority != nil
        self.authority = authority.map { $0 as AnyObject }
        logicalMailboxID = Self.scopedAccount(of: authority)?.logicalMailboxID
    }

    init(object: AnyObject?) {
        hasAuthority = object != nil
        authority = object
        logicalMailboxID = nil
    }

    /// Whether `other` serves the same account: the same authority object, or
    /// another scoped Node authority bound to the same provider account (a
    /// refreshed session). Authorities without a scoped account match only
    /// themselves.
    func refersToAccount(of other: (any PlainpostMailAuthority)?) -> Bool {
        if refers(to: other) { return true }
        guard let logicalMailboxID else { return false }
        return Self.scopedAccount(of: other)?.logicalMailboxID == logicalMailboxID
    }

    /// The provider account a scoped Node authority is bound to. Authorities
    /// without one (a legacy single-account Node, a development fixture)
    /// belong to no listed account.
    static func scopedAccount(of authority: (any PlainpostMailAuthority)?) -> NodeMailAccount? {
        (authority as? PlainpostNodeMailAuthority)?.mailAccount
    }

    func refers(to other: (any PlainpostMailAuthority)?) -> Bool {
        refers(toObject: other.map { $0 as AnyObject })
    }

    func refers(toObject other: AnyObject?) -> Bool {
        guard hasAuthority else { return other == nil }
        guard let authority, let other else { return false }
        return authority === other
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasAuthority == rhs.hasAuthority && lhs.authority === rhs.authority
    }
}

/// A destination opened from a notification, bound to the authority of the
/// runtime it was resolved for. A runtime serving any other authority never
/// receives it, so a message is never shown or marked read under another account.
struct MobileNotificationOpenState: Equatable {
    let destination: PlainpostNotificationOpenDestination
    let authority: MobileMailAuthorityReference

    init(destination: PlainpostNotificationOpenDestination, authority: (any PlainpostMailAuthority)?) {
        self.destination = destination
        self.authority = MobileMailAuthorityReference(authority)
    }

    /// Whether a runtime serving `authority` may receive this destination.
    func isBound(to authority: (any PlainpostMailAuthority)?) -> Bool {
        self.authority.refers(to: authority)
    }
}

/// Why a runtime replacement is waiting on the current runtime's send.
enum MobileMailRuntimeSwitchHold: Equatable {
    /// The send is in its undo window or being delivered.
    case finishingSend
    /// The send failed. Its notice and draft restore stay until the user
    /// reopens the draft or dismisses the failure.
    case sendFailed
    /// Local setup has completed, but its composer still has unsaved edits.
    case unsavedComposer

    static let statusIdentifier = "mail-account.switch-hold"
    static let dismissIdentifier = "mail-account.switch-hold.dismiss"

    var statusText: String {
        switch self {
        case .finishingSend: "Finishing send…"
        case .sendFailed: "Couldn’t send. Open the draft or dismiss to switch."
        case .unsavedComposer: "Save or close the draft to finish account setup."
        }
    }

    var canDismiss: Bool { self == .sendFailed }
}

/// Content built from one runtime. Its identity is the runtime's generation,
/// so SwiftUI discards every state object built for an earlier runtime (its
/// composer, inbox actions and settings) even when the switch is never
/// rendered in between.
struct MobileMailRuntimeScoped<Content: View>: View {
    let generation: UInt64
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(generation)
    }
}

extension EnvironmentValues {
    /// True while typing on an iPhone in landscape, where the account chrome
    /// above the mail steps aside so the composer keeps the little height left.
    @Entry var mobileCompactKeyboardEditing = false
}

/// The deferred-switch status shown above the mail while a runtime
/// replacement waits on the current runtime's send.
struct MobileMailRuntimeSwitchHoldStatus: View {
    let hold: MobileMailRuntimeSwitchHold
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if hold == .finishingSend {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sending")
                } else if hold == .unsavedComposer {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("Draft open")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Send failed")
                }
                Text(hold.statusText)
                    .font(.footnote)
            }
            // One element: the icon or spinner and its text are read together.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(MobileMailRuntimeSwitchHold.statusIdentifier)
            Spacer(minLength: 0)
            if hold.canDismiss {
                Button("Dismiss", action: dismiss)
                    .font(.footnote)
                    .accessibilityIdentifier(MobileMailRuntimeSwitchHold.dismissIdentifier)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { announce(hold) }
        .onChange(of: hold) { _, next in announce(next) }
    }

    private func announce(_ hold: MobileMailRuntimeSwitchHold) {
        AccessibilityNotification.Announcement(hold.statusText).post()
    }
}

/// A failed send that a replacement other than the user's own switch
/// released, together with the account it belonged to. That runtime's
/// "Couldn't send" notice went with it; the draft is saved on the Sync Node,
/// in that account's Drafts, which is not the account now on screen.
struct MobileReleasedFailedSend: Equatable {
    /// The provider identity of the released runtime's account, when it
    /// served a scoped Node account.
    let providerIdentity: String?

    var statusText: String {
        guard let providerIdentity, !providerIdentity.isEmpty else {
            return "A message couldn’t be sent. It’s in Drafts."
        }
        return "A message from \(providerIdentity) couldn’t be sent. It’s in that account’s Drafts."
    }
}

/// Shown above the mail after a replacement that was not the user's own
/// switch released a runtime whose send had failed. The controller posts the
/// accessibility announcement when the notice becomes visible, so a rebuilt
/// view never repeats it.
struct MobileMailReleasedFailedSendNotice: View {
    static let statusIdentifier = "mail-account.send-failed-notice"
    static let dismissIdentifier = "mail-account.send-failed-notice.dismiss"

    let notice: MobileReleasedFailedSend
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Send failed")
                Text(notice.statusText)
                    .font(.footnote)
            }
            // One element: the icon and its text are read together.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(Self.statusIdentifier)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss)
                .font(.footnote)
                .accessibilityIdentifier(Self.dismissIdentifier)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

typealias MobileMailRuntimeModel = MobileMailRuntimeController<PlainpostAppRuntime>

extension MobileMailRuntimeController where Runtime == PlainpostAppRuntime {
    convenience init(localLaunchModel: MobileLocalMailLaunchModel = MobileLocalMailLaunchModel()) {
        self.init(makeRouteRuntime: { readOnly, route in
            switch route {
            case .localSetup:
                return try localLaunchModel.makeLocalRuntime()
            case .allDirect:
                return try localLaunchModel.makeLocalRuntime(readOnly: readOnly)
            case .node(let authority):
                guard let accountID = authority.accountID else {
                    throw PlainpostError.permissionDenied("Selected Sync Node account is unavailable.")
                }
                return try localLaunchModel.makeNodeRuntime(
                    for: accountID, authority: authority, readOnly: readOnly
                )
            case .nodeUnavailable:
                throw PlainpostError.permissionDenied("Sync Node is unavailable.")
            }
        })
    }
}

private enum MobilePreparedRoute: Equatable {
    case localSetup
    case allDirect
    case node(MobileMailAuthorityReference)
    case nodeUnavailable(AccountID)

    init(_ route: MobileMailRoute) {
        switch route {
        case .localSetup: self = .localSetup
        case .allDirect: self = .allDirect
        case .node(let authority): self = .node(MobileMailAuthorityReference(authority))
        case .nodeUnavailable(let id): self = .nodeUnavailable(id)
        }
    }
}

@MainActor
final class MobileMailRuntimeController<Runtime: MobileMailRuntime>: ObservableObject {
    typealias MakeRuntime = @MainActor (_ readOnly: Bool, _ route: MobileMailRoute) throws -> Runtime

    @Published private(set) var runtime: Runtime?
    @Published private(set) var failure: String?
    /// Advances whenever the published runtime changes. Views built from a
    /// runtime use it as their identity.
    @Published private(set) var runtimeGeneration: UInt64 = 0
    /// The current runtime has an undoable send that is not yet delivered,
    /// failed or undone. The account switcher is disabled meanwhile.
    @Published private(set) var isSendPending = false
    /// The current runtime's composer is open with unsaved changes. The
    /// account switcher is disabled meanwhile, since a switch discards it.
    @Published private(set) var hasUnsavedComposer = false
    /// Set while a runtime replacement waits on the current runtime's send.
    @Published private(set) var switchHold: MobileMailRuntimeSwitchHold?
    @Published private(set) var notificationOpen: MobileNotificationOpenState?
    /// A replacement that was not the user's switch released a runtime whose
    /// send had failed, dropping its notice. Stays until dismissed, across
    /// later replacements.
    @Published private(set) var releasedFailedSend: MobileReleasedFailedSend?

    var showsReleasedFailedSendNotice: Bool { releasedFailedSend != nil }

    private let makeRuntime: MakeRuntime
    private let pollInterval: Duration
    /// Posts a VoiceOver announcement. Owned here, not by the notice view, so
    /// it is posted once when the notice becomes visible rather than on every
    /// rebuild of the view.
    private let announce: @MainActor (String) -> Void
    private var readOnly: Bool?
    /// The authority the current runtime was requested with.
    private var preparedRoute: MobilePreparedRoute?
    private let preparationFence = PlainpostRuntimePreparationFence()
    private var sendPendingObservation: AnyCancellable?
    private var unsavedComposerObservation: AnyCancellable?
    private var notificationOpenToken: UInt64 = 0

    init(
        makeRouteRuntime: @escaping MakeRuntime,
        pollInterval: Duration = .milliseconds(50),
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.makeRuntime = makeRouteRuntime
        self.pollInterval = pollInterval
        self.announce = announce
    }

    convenience init(
        makeRuntime: @escaping @MainActor (_ readOnly: Bool, _ mailAuthority: (any PlainpostMailAuthority)?) throws -> Runtime,
        pollInterval: Duration = .milliseconds(50),
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.init(makeRouteRuntime: { readOnly, route in
            switch route {
            case .node(let authority): return try makeRuntime(readOnly, authority)
            case .localSetup, .allDirect: return try makeRuntime(readOnly, nil)
            case .nodeUnavailable: throw PlainpostError.permissionDenied("Sync Node is unavailable.")
            }
        }, pollInterval: pollInterval, announce: announce)
    }

    /// A runtime replacement is waiting on the current runtime's send.
    var isDeferringForPendingSend: Bool { switchHold != nil }

    /// The notification message the current runtime may open, only when that
    /// runtime serves the authority the message was resolved for.
    var initialSelectedMessageID: String? {
        guard let notificationOpen,
              case let .message(messageID) = notificationOpen.destination,
              let runtime,
              notificationOpen.isBound(to: runtime.mailAuthority) else { return nil }
        return messageID
    }

    var initialDestination: PlainpostDestination? {
        switch notificationOpen?.destination {
        case .allInboxes?, .messageUnavailable?: .allInboxes
        default: nil
        }
    }

    /// Builds the runtime for `mailAuthority`, replacing the current one.
    /// `isUserAccountSwitch` is true only when the user chose this authority's
    /// account in the switcher; every other replacement (a read-only flip, a
    /// lost authority, a refreshed session, a notification owner) is not.
    /// Even then it is a user switch only if it moves to another account than
    /// the current runtime's: rebuilding the runtime of the account the user
    /// switched to is not.
    ///
    /// `isAccountListed` answers whether the Node still lists a provider
    /// account. It is read while a failed send holds the switch, so an account
    /// removed meanwhile releases the hold instead of keeping a writable
    /// runtime for an account that no longer exists. Authorities without a
    /// scoped provider account are never held on this ground.
    ///
    /// `beforeReplacing` runs right before the current runtime is released, after any wait on
    /// its send: the host commits grace-period mail actions there, including one the user
    /// started while the replacement waited.
    func prepare(
        readOnly: Bool,
        route: MobileMailRoute,
        isUserAccountSwitch: Bool = false,
        isAccountListed: @MainActor (LogicalMailboxID) -> Bool = { _ in true },
        beforeReplacing: @MainActor () async -> Void = {}
    ) async {
        let mailAuthority: (any PlainpostMailAuthority)?
        if case .node(let authority) = route { mailAuthority = authority } else { mailAuthority = nil }
        let routeIdentity = MobilePreparedRoute(route)
        let generation = preparationFence.begin()
        // Any older deferred preparation is superseded from here on.
        switchHold = nil
        if runtime != nil, self.readOnly == readOnly, preparedRoute == routeIdentity { return }
        let previousAuthority: MobileMailAuthorityReference
        if case .node(let reference) = preparedRoute { previousAuthority = reference }
        else { previousAuthority = MobileMailAuthorityReference(nil) }
        let userSwitch = isUserAccountSwitch && mailAuthority != nil && !previousAuthority.refersToAccount(of: mailAuthority)
        let preservesSetupComposer: Bool
        if case .some(.localSetup) = preparedRoute, case .allDirect = route {
            preservesSetupComposer = true
        } else {
            preservesSetupComposer = false
        }

        // An undoable send is delivered by the runtime that scheduled it, and
        // releasing that runtime cancels the delivery. Keep the runtime, and
        // its Undo, until the send is delivered or undone, whatever the
        // replacement. This also covers a foreground refresh or notification
        // tap that rebinds the authority.
        // A failed send's draft is already saved on the Node. Its notice holds
        // only the user's own account switch, until the user reopens the
        // draft or dismisses the failure. Any other replacement proceeds, so
        // a lost or refreshed session never keeps a writable runtime alive.
        // An account the Node no longer lists counts the same way: holding it
        // would keep a writable runtime for an account that is gone.
        // A newer preparation supersedes this wait.
        func heldFailureStillHolds(_ current: Runtime) -> Bool {
            guard userSwitch, current.hasFailedSend else { return false }
            guard let account = MobileMailAuthorityReference.scopedAccount(of: current.mailAuthority) else { return true }
            return isAccountListed(account.logicalMailboxID)
        }

        func holds(_ current: Runtime) -> Bool {
            current.isSendPending || (preservesSetupComposer && hasUnsavedComposer) || heldFailureStillHolds(current)
        }

        while let current = runtime {
            if holds(current) {
                defer { if preparationFence.isCurrent(generation) { switchHold = nil } }
                while true {
                    guard !Task.isCancelled, preparationFence.isCurrent(generation) else { return }
                    if current.isSendPending {
                        switchHold = .finishingSend
                    } else if preservesSetupComposer && hasUnsavedComposer {
                        switchHold = .unsavedComposer
                    } else if heldFailureStillHolds(current) {
                        switchHold = .sendFailed
                    } else {
                        break
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                guard !Task.isCancelled, preparationFence.isCurrent(generation), runtime === current else { return }
            }
            // The host commits grace-period mail actions here, after the wait, so an archive
            // the user started while the switch waited isn't lost with the runtime.
            await beforeReplacing()
            guard !Task.isCancelled, preparationFence.isCurrent(generation), runtime === current else { return }
            // A send started during the commit holds the replacement again.
            if !holds(current) { break }
        }

        let previousRuntime = runtime
        // A user switch waits until the failure is dismissed or its draft
        // reopened, so a failure still showing here is released by another
        // replacement, whether it failed before this preparation, while it
        // waited on the send, or because the account stopped being listed.
        // Its notice goes with the runtime, so the controller raises one that
        // names the account the draft is in.
        if previousRuntime?.hasFailedSend == true {
            publish(MobileReleasedFailedSend(
                providerIdentity: MobileMailAuthorityReference
                    .scopedAccount(of: previousRuntime?.mailAuthority)?.providerIdentity))
        }
        setRuntime(nil)
        failure = nil
        self.readOnly = readOnly
        preparedRoute = routeIdentity
        // A notification destination belongs to the runtime it was resolved for.
        notificationOpen = nil

        // Always retire the old runtime, including a failed authority
        // preparation. Otherwise a stale runtime can remain alive behind the
        // unavailable projection and continue serving local data.
        await previousRuntime?.shutdown()
        guard !Task.isCancelled, preparationFence.isCurrent(generation) else { return }

        // A production Node account is fail-closed: a missing or revoked
        // authority must never fall back to whatever local SQLite happens to
        // be present on the device. Development fixtures explicitly leave
        // requiresMailAuthority false.
        guard case .nodeUnavailable = route else {
            do {
                let nextRuntime = try makeRuntime(readOnly, route)
                guard !Task.isCancelled, preparationFence.isCurrent(generation) else {
                    await nextRuntime.shutdown()
                    return
                }
                setRuntime(nextRuntime)
            } catch {
                guard !Task.isCancelled, preparationFence.isCurrent(generation) else { return }
                failure = error.localizedDescription
            }
            return
        }
            failure = "Sync Node is unavailable or this session is no longer authorized."
    }

    func prepare(
        readOnly: Bool,
        mailAuthority: (any PlainpostMailAuthority)?,
        requiresMailAuthority: Bool,
        isUserAccountSwitch: Bool = false,
        isAccountListed: @MainActor (LogicalMailboxID) -> Bool = { _ in true },
        beforeReplacing: @MainActor () async -> Void = {}
    ) async {
        let route: MobileMailRoute = if let mailAuthority { .node(mailAuthority) }
            else if requiresMailAuthority { .nodeUnavailable(AccountID("unavailable")) }
            else { .localSetup }
        await prepare(readOnly: readOnly, route: route,
                      isUserAccountSwitch: isUserAccountSwitch, isAccountListed: isAccountListed,
                      beforeReplacing: beforeReplacing)
    }

    /// Acknowledges the current runtime's failed send so a waiting
    /// replacement can proceed. The draft stays saved on the Sync Node.
    func dismissFailedSend() {
        runtime?.dismissFailedSend()
    }

    /// Clears the notice left by a failed send a replacement released.
    func dismissReleasedFailedSendNotice() {
        releasedFailedSend = nil
    }

    /// Shows the notice a released failed send leaves behind, and announces
    /// it. The announcement belongs to the release, which happens once, not to
    /// the notice view, which SwiftUI rebuilds whenever the runtime it sits
    /// above changes.
    private func publish(_ notice: MobileReleasedFailedSend) {
        releasedFailedSend = notice
        announce(notice.statusText)
    }

    func shutdown() async {
        _ = preparationFence.begin()
        switchHold = nil
        let previousRuntime = runtime
        setRuntime(nil)
        notificationOpen = nil
        await previousRuntime?.shutdown()
    }

    /// Starts a notification open and returns its token; a later open supersedes it.
    func beginNotificationOpen() -> UInt64 {
        notificationOpenToken &+= 1
        notificationOpen = nil
        return notificationOpenToken
    }

    /// Publishes a destination resolved by `resolvedBy`, only while that runtime
    /// is still current and no newer open started.
    func finishNotificationOpen(_ destination: PlainpostNotificationOpenDestination, token: UInt64, resolvedBy resolver: Runtime?) {
        guard token == notificationOpenToken else { return }
        guard let resolver, resolver === runtime else {
            notificationOpen = MobileNotificationOpenState(destination: .allInboxes, authority: nil)
            return
        }
        notificationOpen = MobileNotificationOpenState(destination: destination, authority: resolver.mailAuthority)
    }

    private func setRuntime(_ next: Runtime?) {
        sendPendingObservation = nil
        unsavedComposerObservation = nil
        if runtime !== next { runtimeGeneration &+= 1 }
        runtime = next
        isSendPending = next?.isSendPending ?? false
        sendPendingObservation = next?.sendPendingPublisher.sink { [weak self] pending in
            MainActor.assumeIsolated { self?.isSendPending = pending }
        }
        hasUnsavedComposer = false
        unsavedComposerObservation = next?.unsavedOpenComposerPublisher.sink { [weak self] unsaved in
            MainActor.assumeIsolated { self?.hasUnsavedComposer = unsaved }
        }
    }
}
