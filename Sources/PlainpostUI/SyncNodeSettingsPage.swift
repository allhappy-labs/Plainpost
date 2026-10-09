import SwiftUI

/// The Settings "Sync Node" page on both platforms. It composes the overview, the setup steps
/// or the enrolled Node's sections over the account session and owns no connection state of
/// its own. A host that builds its own page (the iOS app) supplies it through
/// `PlainpostSettingsHost.syncNodePage`, composing the same `SyncNodePageContent`.
struct SyncNodeSettingsPage: View {
    let session: AccountSessionViewModel?
    let nodeSettings: SyncNodeSettingsViewModel?
    @Environment(\.plainpostSettingsHost) private var host

    var body: some View {
        if let page = host.syncNodePage {
            page(nodeSettings)
        } else if let session {
            SyncNodeSessionSettingsPage(session: session, nodeSettings: nodeSettings)
        } else if let nodeSettings {
            SettingsPage(.syncNode) { SyncNodeStatusOnlyContent(nodeSettings: nodeSettings) }
        } else {
            SettingsPage(.syncNode) {
                SyncNodePageContent(isSignedIn: false, awaitsOwner: false, enrollment: nil, load: .idle, importModel: nil, nodeSettings: nil)
            }
        }
    }
}

private struct SyncNodeSessionSettingsPage: View {
    @ObservedObject var session: AccountSessionViewModel
    let nodeSettings: SyncNodeSettingsViewModel?

    var body: some View {
        SettingsPage(.syncNode) {
            SyncNodePageContent(
                isSignedIn: session.presentation.allowsMailbox,
                isAccountUnavailable: session.presentation != .signInRequired,
                awaitsOwner: session.syncNodeEnrollmentAwaitsOwner,
                enrollment: session.presentableSyncNodeEnrollmentModel,
                load: session.syncNodeEnrollmentLoadPresentation,
                importModel: session.syncNodeSettingsImportModel,
                nodeSettings: nodeSettings,
                actions: SyncNodePageActions(
                    retryLoad: { session.retrySyncNodeEnrollment() },
                    completeFileImport: session.handleSyncNodeBootstrapFileImporter,
                    changeServerAddress: session.updateSyncNodeServerOrigin,
                    importProfile: session.importSyncNodeBootstrapProfile,
                    // Calendars depend on the Node connection; publish them now instead of
                    // waiting for the next session preparation.
                    didConnect: { Task { await session.prepareCalendarAuthority() } }
                )
            )
        }
        .syncNodeEnrollmentLifecycle(session.presentableSyncNodeEnrollmentModel)
        .task {
            session.refreshSyncNodeEnrollmentOwner()
            guard session.syncNodeEnrollmentModel == nil else { return }
            session.prepareSyncNodeEnrollment()
        }
    }
}

/// What a Sync Node page can do beyond its models. The Mac session and the iOS account
/// model each supply their own.
public struct SyncNodePageActions {
    public var retryLoad: (@MainActor () -> Void)?
    public var completeFileImport: ((Result<[URL], Error>) -> Void)?
    public var changeServerAddress: (@MainActor (String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate)?
    public var importProfile: (@MainActor (URL) -> Bool)?
    /// The enrollment reached Connected while the page was open.
    public var didConnect: (@MainActor () -> Void)?
    /// Appended to the setup steps' footer (the iOS AirDrop guidance).
    public var setupNote: String?

    public init(
        retryLoad: (@MainActor () -> Void)? = nil,
        completeFileImport: ((Result<[URL], Error>) -> Void)? = nil,
        changeServerAddress: (@MainActor (String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate)? = nil,
        importProfile: (@MainActor (URL) -> Bool)? = nil,
        didConnect: (@MainActor () -> Void)? = nil,
        setupNote: String? = nil
    ) {
        self.retryLoad = retryLoad
        self.completeFileImport = completeFileImport
        self.changeServerAddress = changeServerAddress
        self.importProfile = importProfile
        self.didConnect = didConnect
        self.setupNote = setupNote
    }
}

/// The Sync Node page's sections, never empty: the overview first, then the setup steps
/// before enrollment or the Node's details, server and Erase once enrolled. `enrollment` is
/// the model the session may present (the owner's own), never one awaiting its owner.
public struct SyncNodePageContent: View {
    private let isSignedIn: Bool
    private let isAccountUnavailable: Bool
    private let awaitsOwner: Bool
    private let enrollment: SyncNodeEnrollmentViewModel?
    private let load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation
    private let importModel: SyncNodeBootstrapImportViewModel?
    private let nodeSettings: SyncNodeSettingsViewModel?
    private let actions: SyncNodePageActions
    @Environment(\.plainpostSettingsHost) private var host

    /// `isAccountUnavailable`: not signed in, but an account exists that can't be used now
    /// (pending approval, suspended, deleted…), so signing in isn't the next step.
    public init(
        isSignedIn: Bool,
        isAccountUnavailable: Bool = false,
        awaitsOwner: Bool,
        enrollment: SyncNodeEnrollmentViewModel?,
        load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation,
        importModel: SyncNodeBootstrapImportViewModel?,
        nodeSettings: SyncNodeSettingsViewModel?,
        actions: SyncNodePageActions = SyncNodePageActions()
    ) {
        self.isSignedIn = isSignedIn
        self.isAccountUnavailable = isAccountUnavailable
        self.awaitsOwner = awaitsOwner
        self.enrollment = enrollment
        self.load = load
        self.importModel = importModel
        self.nodeSettings = nodeSettings
        self.actions = actions
    }

    public var body: some View {
        if awaitsOwner {
            // Another account's connection is kept in memory; nothing that identifies it,
            // including the Server Setup, is shown.
            SyncNodeOverviewSection(overview: SyncNodeOverview(.init(awaitsOwner: true)))
        } else if !isSignedIn {
            SyncNodeOverviewSection(overview: SyncNodeOverview(.init(
                isSignedIn: false,
                isAccountUnavailable: isAccountUnavailable,
                canConnectPlainpostAccount: host.connectPlainpostAccount != nil
            ))) { action in
                if action == .connectPlainpostAccount { host.connectPlainpostAccount?() }
            }
        } else if let enrollment {
            SyncNodeEnrollmentSettingsContent(
                enrollment: enrollment,
                importModel: importModel,
                nodeSettings: nodeSettings,
                actions: actions
            )
            .id(ObjectIdentifier(enrollment))
        } else if let nodeSettings {
            // No enrollment model (an offline lease, or a load that failed), but the Node
            // reports a status, so it is enrolled: its sections, never the setup steps.
            SyncNodeStatusOnlyContent(nodeSettings: nodeSettings, load: load, retryLoad: actions.retryLoad)
        } else if let importModel {
            SyncNodeSetupSettingsContent(importModel: importModel, load: load, actions: actions)
        } else {
            SyncNodeOverviewSection(overview: SyncNodeOverview(.init(load: load))) { action in
                if action == .tryAgain { actions.retryLoad?() }
            }
        }
    }
}

/// No enrollment model yet: the overview, then both setup steps with Connect disabled. A
/// failed load shows only the overview with Try Again: whether the account already has a
/// Node is unknown, so setting one up isn't offered. Only a load that found no Node and no
/// Server Setup (`.noSyncNode`) is known to need setup.
private struct SyncNodeSetupSettingsContent: View {
    @ObservedObject var importModel: SyncNodeBootstrapImportViewModel
    let load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation
    let actions: SyncNodePageActions

    private var loadFailed: Bool {
        if case .failed = load { return true }
        return false
    }

    var body: some View {
        SyncNodeOverviewSection(overview: SyncNodeOverview(.init(load: load))) { action in
            if action == .tryAgain { actions.retryLoad?() }
        }
        if !loadFailed {
            SyncNodeSetupSteps(importModel: importModel, enrollment: nil, actions: actions)
        }
    }
}

/// Not enrolled: the overview, then the numbered setup steps. Enrolled: the overview, the
/// Node's details, its server (with any replacement), then Erase.
private struct SyncNodeEnrollmentSettingsContent: View {
    @ObservedObject var enrollment: SyncNodeEnrollmentViewModel
    let importModel: SyncNodeBootstrapImportViewModel?
    let nodeSettings: SyncNodeSettingsViewModel?
    let actions: SyncNodePageActions

    private var isEnrolled: Bool { enrollment.activeNodeID != nil }

    var body: some View {
        SyncNodeEnrollmentOverviewSection(enrollment: enrollment, nodeSettings: nodeSettings)
            .onChange(of: enrollment.connectionPresentation) { _, presentation in
                guard presentation == .connected else { return }
                actions.didConnect?()
            }
        if isEnrolled {
            if let nodeSettings {
                SyncNodeStatusSection(model: nodeSettings)
            }
            SyncNodeConnectionSection(
                enrollment: enrollment,
                importModel: importModel,
                completeFileImport: actions.completeFileImport,
                changeServerAddress: actions.changeServerAddress,
                importProfile: actions.importProfile
            )
            .syncNodeSettingsGroup("settings.sync-node.enrollment")
            if let nodeSettings {
                SyncNodeEraseSection(model: nodeSettings)
            }
        } else if let importModel {
            SyncNodeSetupSteps(importModel: importModel, enrollment: enrollment, actions: actions)
        } else {
            SyncNodeConnectStepSection(enrollment: enrollment, note: actions.setupNote)
        }
    }
}

/// Step 1, Import Server Setup, then step 2, Connect with Apple.
private struct SyncNodeSetupSteps: View {
    let importModel: SyncNodeBootstrapImportViewModel
    let enrollment: SyncNodeEnrollmentViewModel?
    let actions: SyncNodePageActions

    /// The server Connect would use, when an enrollment model names one.
    private var target: SyncNodeServerSetupStep.Target? {
        guard let origin = enrollment?.targetOrigin, let fingerprint = enrollment?.targetFingerprint else { return nil }
        return .init(origin: origin, fingerprint: fingerprint)
    }

    var body: some View {
        SyncNodeServerSetupStep(model: importModel, target: target, completeFileImport: actions.completeFileImport)
            .syncNodeSettingsGroup("settings.sync-node.import")
        SyncNodeConnectStepSection(enrollment: enrollment, note: actions.setupNote)
    }
}

private struct SyncNodeConnectStepSection: View {
    let enrollment: SyncNodeEnrollmentViewModel?
    let note: String?

    var body: some View {
        Section {
            if let enrollment {
                SyncNodeEnrollmentView(model: enrollment, placement: .connectStep)
            } else {
                // Nothing to connect to until step 1 is done.
                SyncNodeEnrollmentView.unavailableConnectButton
            }
        } header: {
            Text("2. Connect with Apple")
        } footer: {
            Text(["Create the Server Setup file with your Sync Node’s setup tool, then import it here.", note].compactMap { $0 }.joined(separator: " "))
        }
        .syncNodeSettingsGroup(enrollment == nil ? "settings.sync-node.connect-step" : "settings.sync-node.enrollment")
    }
}

/// The overview for an enrollment, with the Node's status once enrolled.
private struct SyncNodeEnrollmentOverviewSection: View {
    @ObservedObject var enrollment: SyncNodeEnrollmentViewModel
    let nodeSettings: SyncNodeSettingsViewModel?

    var body: some View {
        if let nodeSettings {
            SyncNodeObserving(model: nodeSettings) { nodeSettings in
                section(nodeStatus: enrollment.activeNodeID == nil ? nil : SyncNodeOverview.NodeStatus(nodeSettings))
            }
        } else {
            section(nodeStatus: nil)
        }
    }

    private func section(nodeStatus: SyncNodeOverview.NodeStatus?) -> some View {
        SyncNodeOverviewSection(
            overview: SyncNodeOverview(.init(enrollment: SyncNodeOverview.Enrollment(enrollment), nodeStatus: nodeStatus))
        ) { action in
            SyncNodeOverviewSection.perform(action, enrollment: enrollment, nodeSettings: nodeSettings)
        }
    }
}

/// The Node's own status, details and Erase, for a host without an account session or an
/// enrolled Node whose enrollment model isn't loaded. A failed load still offers Try Again.
struct SyncNodeStatusOnlyContent: View {
    @ObservedObject var nodeSettings: SyncNodeSettingsViewModel
    var load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation = .idle
    var retryLoad: (@MainActor () -> Void)?

    var body: some View {
        SyncNodeOverviewSection(overview: SyncNodeOverview(.init(load: load, nodeStatus: SyncNodeOverview.NodeStatus(nodeSettings)))) { action in
            if action == .tryAgain {
                retryLoad?()
            } else {
                SyncNodeOverviewSection.perform(action, enrollment: nil, nodeSettings: nodeSettings)
            }
        }
        SyncNodeStatusSection(model: nodeSettings)
        SyncNodeEraseSection(model: nodeSettings)
    }
}

/// Re-renders `content` when an optional page model changes.
private struct SyncNodeObserving<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: (Model) -> Content

    var body: some View { content(model) }
}

/// The page's first section: an icon, a title, its detail lines and the actions. The title
/// keeps the status row's identifier, so it is the page's one connection status.
struct SyncNodeOverviewSection: View {
    let overview: SyncNodeOverview
    var perform: @MainActor (SyncNodeOverview.Action) -> Void = { _ in }

    var body: some View {
        Section {
            summary
            #if os(iOS)
            // iOS lists actions as their own rows, like the rest of the form.
            ForEach(overview.actions, id: \.self) { action in
                actionButton(action)
            }
            #endif
        }
    }

    private var summary: some View {
        // A title on its own centres on the icon; detail lines hang below it.
        HStack(alignment: overview.detail.isEmpty && overview.actions.isEmpty ? .center : .top, spacing: 12) {
            SettingsRowIcon(symbol: overview.symbol, tint: tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.title)
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("sync-node.settings.status")
                ForEach(overview.detail, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #if os(macOS)
                if !overview.actions.isEmpty {
                    HStack {
                        ForEach(overview.actions, id: \.self) { action in
                            actionButton(action)
                        }
                    }
                    .padding(.top, 4)
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if overview.showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-node.overview")
    }

    @ViewBuilder
    private func actionButton(_ action: SyncNodeOverview.Action) -> some View {
        let button = Button(action.title) { perform(action) }
            .disabled(overview.actionsDisabled)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        #if os(macOS)
        if action == .approve {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
        #else
        button
        #endif
    }

    private var tint: Color {
        switch overview.tint {
        case .positive: .green
        case .attention: .orange
        case .failure: .red
        case .neutral: MailDesign.secondaryText
        }
    }

    /// Runs an overview action on the page's models. The load retry and account sign-in
    /// actions are the page's own and handled where it builds the overview.
    @MainActor
    static func perform(
        _ action: SyncNodeOverview.Action,
        enrollment: SyncNodeEnrollmentViewModel?,
        nodeSettings: SyncNodeSettingsViewModel?
    ) {
        switch action {
        case .checkAgain:
            guard let nodeSettings else { return }
            Task { await nodeSettings.refresh() }
        case .retryConnection:
            guard let enrollment else { return }
            Task { await enrollment.retryConnection() }
        case .retry, .startOver:
            enrollment?.resetAfterFailure()
        case .retryInstallation:
            guard let enrollment else { return }
            Task { await enrollment.retryCommit() }
        case .stopAndStartOver:
            guard let enrollment else { return }
            Task { await enrollment.stopAndStartOver() }
        case .retryActivation:
            guard let enrollment else { return }
            Task { await enrollment.retryActivation() }
        case .retryVerification:
            guard let enrollment else { return }
            Task { await enrollment.retryCommitVerification() }
        case .approve:
            guard let enrollment else { return }
            Task { await enrollment.approvePinnedTarget() }
        case .cancelApproval:
            guard let enrollment else { return }
            Task { await enrollment.rejectPinnedTarget() }
        case .connectPlainpostAccount, .tryAgain:
            break
        }
    }
}

/// The enrolled Node's server: its host, the fingerprint behind Verify Fingerprint, the
/// Change Server Address and Replace Server Setup actions, then Replace Sync Node once a new
/// Server Setup is imported.
public struct SyncNodeConnectionSection: View {
    @ObservedObject private var enrollment: SyncNodeEnrollmentViewModel
    private let importModel: SyncNodeBootstrapImportViewModel?
    private let completeFileImport: ((Result<[URL], Error>) -> Void)?
    private let changeServerAddress: (@MainActor (String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate)?
    private let importProfile: (@MainActor (URL) -> Bool)?
    @State private var showsFingerprint = false
    @State private var showsServerEditor = false

    /// Without `changeServerAddress` (and `importProfile`) the page offers no address editor.
    public init(
        enrollment: SyncNodeEnrollmentViewModel,
        importModel: SyncNodeBootstrapImportViewModel?,
        completeFileImport: ((Result<[URL], Error>) -> Void)?,
        changeServerAddress: (@MainActor (String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate)? = nil,
        importProfile: (@MainActor (URL) -> Bool)? = nil
    ) {
        self.enrollment = enrollment
        self.importModel = importModel
        self.completeFileImport = completeFileImport
        self.changeServerAddress = changeServerAddress
        self.importProfile = importProfile
    }

    public var body: some View {
        Section {
            if let origin = enrollment.targetOrigin {
                LabeledContent("Address", value: AccountSecurityPresentation.host(origin) ?? origin)
            }
            if let fingerprint = enrollment.targetFingerprint {
                Button("Verify Fingerprint…") { showsFingerprint = true }
                    .accessibilityIdentifier("sync-node.settings.verify-fingerprint")
                    .sheet(isPresented: $showsFingerprint) {
                        SyncNodeFingerprintSheet(fingerprint: fingerprint)
                    }
            }
            if canChangeServerAddress {
                Button("Change Server Address…") { showsServerEditor = true }
                    .accessibilityIdentifier("sync-node.settings.change-server")
                    .sheet(isPresented: $showsServerEditor) {
                        if let origin = enrollment.targetOrigin,
                           let changeServerAddress,
                           let importProfile {
                            SyncNodeServerEditor(
                                currentOrigin: origin,
                                save: changeServerAddress,
                                importProfile: importProfile
                            )
                        }
                    }
            }
            if let importModel {
                SyncNodeReplaceServerSetupButton(importModel: importModel, completeFileImport: completeFileImport)
            }
            SyncNodeEnrollmentView(model: enrollment, placement: .replacement)
        } header: {
            Text("Server")
        } footer: {
            if canChangeServerAddress {
                Text("Change the address if your Sync Node moved. Import a new Server Setup file if you reinstalled it.")
            } else {
                Text("Import a new Server Setup file if you reinstalled your Sync Node.")
            }
        }
    }

    private var canChangeServerAddress: Bool {
        importModel != nil && changeServerAddress != nil && importProfile != nil
            && enrollment.targetOrigin != nil
    }
}

private struct SyncNodeReplaceServerSetupButton: View {
    @ObservedObject var importModel: SyncNodeBootstrapImportViewModel
    let completeFileImport: ((Result<[URL], Error>) -> Void)?

    var body: some View {
        Button("Replace Server Setup…") { importModel.presentFileImporter() }
            .accessibilityIdentifier("sync-node.settings.replace-server-setup")
            .fileImporter(
                isPresented: $importModel.isFileImporterPresented,
                allowedContentTypes: [.plainpostServerSetup],
                allowsMultipleSelection: false,
                onCompletion: completeFileImport ?? importModel.handleFileImporter
            )
    }
}

/// The pinned Node fingerprint, copyable, for comparing with the Sync Node's own.
struct SyncNodeFingerprintSheet: View {
    let fingerprint: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Fingerprint") {
                    Text(fingerprint)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sync-node.fingerprint")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Verify Fingerprint")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 180)
        #endif
    }
}

extension View {
    /// On the Mac page a section is a plain view in a stack; give it an accessibility
    /// container so the page's groups can be found.
    @ViewBuilder
    func syncNodeSettingsGroup(_ identifier: String) -> some View {
        #if os(macOS)
        frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        #else
        self
        #endif
    }
}

struct SyncNodeServerEditor: View {
    typealias Save = @MainActor (String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate
    typealias ImportProfile = @MainActor (URL) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var originText: String
    @State private var errorMessage: String?
    @State private var isFileImporterPresented = false
    private let save: Save
    private let importProfile: ImportProfile

    init(
        currentOrigin: String,
        save: @escaping Save,
        importProfile: @escaping ImportProfile
    ) {
        _originText = State(initialValue: currentOrigin)
        self.save = save
        self.importProfile = importProfile
    }

    var body: some View {
        Group {
            #if os(iOS)
            ScrollView {
                editorContent
            }
            .frame(maxWidth: .infinity)
            #else
            editorContent
                .frame(width: 540)
            #endif
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.plainpostServerSetup],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  urls.count == 1,
                  let url = urls.first,
                  importProfile(url)
            else {
                errorMessage = "Server setup couldn’t be imported. Check the file and try again."
                return
            }
            dismiss()
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            Text("Change Server Address")
                .font(.title2.bold())
            Text("Use this when the Sync Node moves to a new address.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Server address")
                    .font(.headline)
                TextField("https://sync.example.com:18443", text: $originText)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .accessibilityIdentifier("sync-node-server.origin")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sync-node-server.error")
            }

            Button("Import Different Server Setup…") {
                isFileImporterPresented = true
            }
#if os(macOS)
            .buttonStyle(.link)
#endif

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save Server") { saveServer() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sync-node-server.save")
            }
        }
        .padding(28)
    }

    private func saveServer() {
        switch save(originText) {
        case .saved:
            dismiss()
        case .invalidAddress:
            errorMessage = "Enter a valid HTTPS Sync Node address."
        case .unavailable:
            errorMessage = "Import a new Server Setup file to change this node."
        }
    }
}
