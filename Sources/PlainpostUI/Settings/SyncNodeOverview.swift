import Foundation
import PlainpostAccountRuntime

/// What the Sync Node page says first, on both platforms: an icon, a title, a few lines of
/// detail and the actions that move the state on. A pure value read from the existing
/// models, so every state the page can be in is unit tested; the enrollment transitions and
/// guards stay in `SyncNodeEnrollmentViewModel`.
struct SyncNodeOverview: Equatable {
    enum State: Equatable {
        case signedOut
        case accountUnavailable
        case loading
        case loadFailed
        case ownerRequired
        case notSetUp
        case readyToConnect
        case connecting
        case connected
        case unreachable
        case notReady
        case failed
        case finishing
        case approveServer
        case recoveryRequired
    }

    enum Tint: Equatable {
        case positive
        case attention
        case failure
        case neutral
    }

    /// Each action keeps the accessibility identifier its button had before the overview.
    enum Action: Hashable {
        case connectPlainpostAccount
        case tryAgain
        case checkAgain
        case retryConnection
        case retry
        case startOver
        case retryInstallation
        case stopAndStartOver
        case retryActivation
        case retryVerification
        case approve
        case cancelApproval

        var title: String {
            switch self {
            case .connectPlainpostAccount: "Connect Plainpost Account"
            case .tryAgain: "Try Again"
            case .checkAgain: "Check Again"
            case .retryConnection: "Retry Connection"
            case .retry: "Retry"
            case .startOver: "Start Over"
            case .retryInstallation: "Retry Installation"
            case .stopAndStartOver: "Stop and Start Over"
            case .retryActivation: "Retry Activation"
            case .retryVerification: "Retry Verification"
            case .approve: "Approve"
            case .cancelApproval: "Cancel"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .connectPlainpostAccount: "sync-node.overview.connect-account"
            case .tryAgain: "sync-node.overview.try-again"
            case .checkAgain: "sync-node.overview.check-again"
            case .retryConnection: "sync-node-retry-connection"
            case .retry: "sync-node-retry"
            case .startOver: "sync-node-start-over"
            case .retryInstallation: "sync-node-retry-installation"
            case .stopAndStartOver: "sync-node-stop-and-start-over"
            case .retryActivation: "sync-node-retry-activation"
            case .retryVerification: "sync-node-retry-verification"
            case .approve: "sync-node-approve-pinned-target"
            case .cancelApproval: "sync-node-reject-pinned-target"
            }
        }
    }

    /// The enrollment model's state, copied so the overview stays a pure function.
    struct Enrollment: Equatable {
        var state: SyncNodeEnrollmentCoordinator.State = .enterCode
        var presentation: SyncNodeEnrollmentViewModel.ConnectionPresentation = .ready
        var isEnrolled = false
        var hasProvisionedTarget = true
        var targetHost: String?
        var failureMessage: String?
        var isProfileOutdated = false
        var needsNewServerSetup = false
        var retainedAdmissionGuidance: String?
        var canStopAndStartOver = false
        var isStoppingAndStartingOver = false
        var startOverFailureMessage: String?
        var isReplacementReady = false
    }

    /// The Node's own status report, when the page has one.
    struct NodeStatus: Equatable {
        var hasStatus: Bool
        var reachability: String
        var syncLag: String
    }

    struct Input: Equatable {
        var isSignedIn = true
        /// Not signed in, but an account exists that can't be used right now (pending
        /// approval, suspended, deleted, being erased or needing recovery). The Plainpost
        /// Account page explains which.
        var isAccountUnavailable = false
        /// The host can open Plainpost account sign-in from here.
        var canConnectPlainpostAccount = false
        /// A connection started by another account is kept in memory.
        var awaitsOwner = false
        var load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation = .idle
        var enrollment: Enrollment?
        var nodeStatus: NodeStatus?
    }

    var state: State
    var title: String
    var detail: [String] = []
    var tint: Tint = .neutral
    var symbol: String
    var actions: [Action] = []
    var showsProgress = false
    /// A Stop and Start Over is waiting for the server, so its actions wait too.
    var actionsDisabled = false

    static let explanation = "A Sync Node is your own server that keeps mail synced while your devices are off."
    static let unreachableDetail = "Make sure it’s running and online."
    static let notReadyDetail = "The Sync Node is installed but isn’t answering yet."
    static let recoveryDetail = "Your account has a Sync Node, but this device isn’t connected to it."
    /// Recovery with a Server Setup already imported: Replace Sync Node reconnects.
    static let recoveryReplaceDetail = "Choose Replace Sync Node to connect this device to it again."
    /// Recovery without a Server Setup: one has to be imported before Replace Sync Node shows.
    static let recoveryImportDetail = "To connect this device again, create a new Server Setup file with your Sync Node’s setup tool, import it with Replace Server Setup, then choose Replace Sync Node."
    static let accountUnavailableDetail = "Open Plainpost Account in Settings to see why."
    /// Before enrollment, a new Server Setup file comes in through step 1.
    #if os(macOS)
    static let differentFileHint = "Then choose Use a Different File on this page to import it."
    #else
    static let differentFileHint = "Then choose Use a Different File on this screen to import it."
    #endif

    init(
        state: State,
        title: String,
        detail: [String] = [],
        tint: Tint = .neutral,
        symbol: String,
        actions: [Action] = [],
        showsProgress: Bool = false,
        actionsDisabled: Bool = false
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.tint = tint
        self.symbol = symbol
        self.actions = actions
        self.showsProgress = showsProgress
        self.actionsDisabled = actionsDisabled
    }

    @MainActor
    init(_ input: Input) {
        if input.awaitsOwner {
            // Names no server, Node or account.
            self.init(
                state: .ownerRequired,
                title: AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage,
                symbol: "person.crop.circle.badge.exclamationmark"
            )
        } else if !input.isSignedIn, input.isAccountUnavailable {
            self.init(
                state: .accountUnavailable,
                title: "Plainpost account unavailable",
                detail: [Self.accountUnavailableDetail],
                tint: .attention,
                symbol: "person.crop.circle.badge.exclamationmark"
            )
        } else if !input.isSignedIn {
            self.init(
                state: .signedOut,
                title: "Sign in to Plainpost",
                detail: ["\(Self.explanation) Sign in to set one up."],
                symbol: "person.crop.circle",
                actions: input.canConnectPlainpostAccount ? [.connectPlainpostAccount] : []
            )
        } else if let enrollment = input.enrollment {
            self = Self.enrollment(enrollment, nodeStatus: input.nodeStatus)
            // While the server waits for approval, Cancel stays available, an approval in
            // flight included (`rejectPinnedTarget` stops it).
            if case .matchingStringConfirmation = enrollment.state, !actions.contains(.cancelApproval) {
                actions.append(.cancelApproval)
            }
        } else if input.load == .loading {
            self = Self.loading
        } else if case .failed(let message) = input.load {
            // A real failure (session, trust state, network) never means "No Sync Node": the
            // account may well have one. Only `.noSyncNode` below proves there is none.
            self.init(
                state: .loadFailed,
                title: "Sync Node unavailable",
                detail: [message],
                tint: .failure,
                symbol: "exclamationmark.triangle.fill",
                actions: [.tryAgain]
            )
        } else if let nodeStatus = input.nodeStatus {
            self = Self.node(nodeStatus, host: nil)
        } else {
            // `.noSyncNode` (the load found no Node and no Server Setup), or nothing loaded yet.
            self.init(state: .notSetUp, title: "No Sync Node", detail: [Self.explanation], symbol: "server.rack")
        }
    }

    private static let loading = SyncNodeOverview(
        state: .loading,
        title: "Checking your Sync Node…",
        symbol: "server.rack",
        showsProgress: true
    )

    @MainActor
    private static func enrollment(_ enrollment: Enrollment, nodeStatus: NodeStatus?) -> SyncNodeOverview {
        let hint = enrollment.isEnrolled ? SyncNodeEnrollmentViewModel.serverSetupImportHint : differentFileHint
        // A possibly committed admission: only its own retry finishes it.
        switch enrollment.state {
        case .commitResponseUncertain:
            return finishing(
                [SyncNodeEnrollmentViewModel.commitUncertainMessage, enrollment.retainedAdmissionGuidance, enrollment.startOverFailureMessage],
                actions: [.retryInstallation] + (enrollment.canStopAndStartOver ? [.stopAndStartOver] : []),
                disabled: enrollment.isStoppingAndStartingOver
            )
        case .activationResponseUncertain:
            return finishing([SyncNodeEnrollmentViewModel.activationUncertainMessage, enrollment.retainedAdmissionGuidance], actions: [.retryActivation])
        case .commitVerificationFailed:
            return finishing([enrollment.failureMessage ?? SyncNodeEnrollmentViewModel.verificationFailureMessage, enrollment.retainedAdmissionGuidance], actions: [.retryVerification])
        case .matchingStringConfirmation where enrollment.presentation == .ready:
            let server = enrollment.targetHost ?? "this server"
            return SyncNodeOverview(
                state: .approveServer,
                title: "Approve this server",
                detail: ["Approve \(server) for your Plainpost account."],
                tint: .attention,
                symbol: "checkmark.shield",
                actions: [.approve, .cancelApproval]
            )
        default:
            break
        }

        // An outdated Server Setup is explained in every state it can appear in.
        let outdated = enrollment.isProfileOutdated ? [SyncNodeEnrollmentViewModel.outdatedProfileMessage, hint] : []
        if let message = enrollment.failureMessage,
           enrollment.presentation == .failed || (enrollment.isProfileOutdated && !enrollment.isEnrolled) {
            let actions: [Action]
            if enrollment.state == .serverAudienceMismatch {
                // The same Server Setup will mismatch again; this only returns to Connect.
                actions = [.startOver]
            } else if enrollment.isProfileOutdated {
                actions = []
            } else {
                actions = [.retry]
            }
            return SyncNodeOverview(
                state: .failed,
                title: "Couldn’t connect",
                detail: [message] + (enrollment.needsNewServerSetup ? [hint] : []),
                tint: .failure,
                symbol: "xmark.octagon.fill",
                actions: actions
            )
        }

        switch enrollment.presentation {
        case .authorizing:
            return connecting("Waiting for Sign in with Apple…")
        case .connecting:
            return connecting(connectingStep(enrollment.state))
        case .checking:
            return connecting("Checking the connection…")
        case .connectionFailed:
            return SyncNodeOverview(
                state: .notReady,
                title: "Not ready yet",
                detail: [notReadyDetail] + outdated,
                tint: .attention,
                symbol: "exclamationmark.circle.fill",
                actions: [.retryConnection]
            )
        case .recoveryRequired:
            return SyncNodeOverview(
                state: .recoveryRequired,
                title: "This device needs to reconnect",
                detail: [recoveryDetail, enrollment.hasProvisionedTarget && !enrollment.isProfileOutdated ? recoveryReplaceDetail : recoveryImportDetail] + outdated,
                tint: .attention,
                symbol: "arrow.triangle.2.circlepath"
            )
        case .connected:
            var overview = node(nodeStatus, host: enrollment.targetHost)
            overview.detail += outdated
            return overview
        case .ready where enrollment.hasProvisionedTarget:
            return SyncNodeOverview(
                state: .readyToConnect,
                title: "Ready to connect",
                detail: enrollment.targetHost.map { [$0] } ?? [],
                symbol: "server.rack"
            )
        case .ready where enrollment.isEnrolled:
            return node(nodeStatus, host: enrollment.targetHost)
        case .ready, .failed:
            return SyncNodeOverview(state: .notSetUp, title: "No Sync Node", detail: [explanation], symbol: "server.rack")
        }
    }

    /// Fails closed: only a status that says "reachable" counts as connected.
    private static func node(_ status: NodeStatus?, host: String?) -> SyncNodeOverview {
        if let status, !status.hasStatus { return loading }
        if let status, !SyncNodeStatusText.isReachable(status.reachability) {
            return SyncNodeOverview(
                state: .unreachable,
                title: "Can’t reach your Sync Node",
                detail: [unreachableDetail],
                tint: .attention,
                symbol: "wifi.exclamationmark",
                actions: [.checkAgain]
            )
        }
        let delayed = status.map { SyncNodeStatusText.isDelayed($0.syncLag) } ?? false
        let line = [host, delayed ? "Sync delayed" : nil].compactMap { $0 }.joined(separator: " · ")
        return SyncNodeOverview(
            state: .connected,
            title: "Connected",
            detail: line.isEmpty ? [] : [line],
            tint: .positive,
            symbol: "checkmark.circle.fill"
        )
    }

    private static func connecting(_ step: String) -> SyncNodeOverview {
        SyncNodeOverview(state: .connecting, title: "Connecting…", detail: [step], symbol: "server.rack", showsProgress: true)
    }

    private static func finishing(_ lines: [String?], actions: [Action], disabled: Bool = false) -> SyncNodeOverview {
        SyncNodeOverview(
            state: .finishing,
            title: "Finishing connection",
            detail: lines.compactMap { $0 },
            tint: .attention,
            symbol: "hourglass",
            actions: actions,
            actionsDisabled: disabled
        )
    }

    private static func connectingStep(_ state: SyncNodeEnrollmentCoordinator.State) -> String {
        switch state {
        case .fetching: "Preparing the server connection…"
        case .localAuthentication: "Confirming on this device…"
        case .centralStepUp: "Confirming account access…"
        case .signing: "Signing approval…"
        case .committing: "Installing Sync Node…"
        case .installed: "Checking the connection…"
        default: "Connecting to your Sync Node…"
        }
    }
}

extension SyncNodeOverview.Enrollment {
    @MainActor
    init(_ model: SyncNodeEnrollmentViewModel) {
        self.init(
            state: model.state,
            presentation: model.connectionPresentation,
            isEnrolled: model.activeNodeID != nil,
            hasProvisionedTarget: model.hasProvisionedTarget,
            targetHost: model.targetOrigin.map { AccountSecurityPresentation.host($0) ?? $0 },
            failureMessage: model.presentedFailureMessage,
            isProfileOutdated: model.isProfileOutdated,
            needsNewServerSetup: model.needsNewServerSetup,
            retainedAdmissionGuidance: model.retainedAdmissionGuidance,
            canStopAndStartOver: model.canStopAndStartOver,
            isStoppingAndStartingOver: model.isStoppingAndStartingOver,
            startOverFailureMessage: model.startOverFailureMessage,
            isReplacementReady: model.isReplacementReady
        )
    }
}

extension SyncNodeOverview.NodeStatus {
    @MainActor
    init(_ model: SyncNodeSettingsViewModel) {
        self.init(hasStatus: model.hasStatus, reachability: model.snapshot.reachability, syncLag: model.snapshot.syncLag)
    }
}
