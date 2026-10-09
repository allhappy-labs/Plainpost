#if os(macOS)
import AppKit
#endif
import SwiftUI
import PlainpostAccountRuntime
import PlainpostNodeTransport

@MainActor
final class CalendarSettingsModel: ObservableObject {
    @Published var endpoint = ""
    @Published var username = ""
    @Published var password = ""
    @Published var sendingMailboxID = ""
    @Published var attendeeAddress = ""
    @Published private(set) var connections: [NodeCalendarConnection] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var reconnectingConnection: NodeCalendarConnection?
    /// A disabled or outdated Node offers no calendar setup.
    @Published private(set) var availability: CalendarAvailability = .unknown
    /// The Node's Google Desktop-app client, read from its capability.
    @Published private(set) var googleSetup: CalendarGoogleSetup = .unknown
    private var offersSetup: Bool { availability == .enabled || availability == .unknown }
    @Published private(set) var sendingMailboxes: [CalendarSendingMailbox]
    private let service: any CalendarServing
    private var oauth: CalendarOAuthSession?
    private let openBrowser: @MainActor (URL) -> Bool
    /// Re-reads the sending-mailbox list (the list is captured once, at
    /// authority construction, so a stale empty list needs an explicit
    /// re-fetch). Non-destructive: it must not invalidate or replace the
    /// live calendar authority, which other calendar surfaces (week view,
    /// thread invitations) may still be using concurrently. `nil` where no
    /// such path is wired, e.g. design previews and tests.
    private let refreshSendingMailboxes: (@MainActor @Sendable () async -> [CalendarSendingMailbox])?
    init(service: any CalendarServing, openBrowser: @escaping @MainActor (URL) -> Bool = CalendarSettingsModel.openInDefaultBrowser, refreshSendingMailboxes: (@MainActor @Sendable () async -> [CalendarSendingMailbox])? = nil) {
        self.service = service
        self.refreshSendingMailboxes = refreshSendingMailboxes
        self.openBrowser = openBrowser
        self.sendingMailboxes = (service as? PlainpostCalendarAuthority)?.sendingMailboxes ?? []
    }
    /// The escape hatch for an empty mailbox list. Guarded like every other
    /// control here (`isBusy`) so a second tap while a retry is in flight is
    /// a no-op, not a second concurrent fetch.
    func retryMailboxDiscovery() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        if let refreshSendingMailboxes { sendingMailboxes = await refreshSendingMailboxes() }
        await load()
    }
    /// Google refuses embedded web views for loopback clients; consent opens in
    /// the user's default browser.
    static func openInDefaultBrowser(_ url: URL) -> Bool {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        false
        #endif
    }
    /// A listed connection that is not enabled is a setup that didn't finish;
    /// it is never shown as connected.
    nonisolated static func connectionStatus(_ connection: NodeCalendarConnection) -> String {
        connection.enabled ? "Connected" : "Setup didn’t finish — connect again to retry"
    }
    /// The attendee address the user entered when connecting, never the
    /// listed mailbox's display name: a `CalendarSendingMailbox.name` is a
    /// Node display label (e.g. "Drafts"), not necessarily an email, so it
    /// is never a safe stand-in for the identity shown on sent invitations.
    nonisolated static func sendsAsLabel(_ connection: NodeCalendarConnection) -> String {
        "Sends as " + connection.attendeeAddress
    }
    var canConnectGoogle: Bool {
        offersSetup && !isBusy && googleSetup.clientID != nil && (reconnectingConnection == nil || reconnectingConnection?.kind == .google)
    }
    var canConnectCalDAV: Bool {
        guard let url = URLComponents(string: endpoint), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              !username.isEmpty, !password.isEmpty, !sendingMailboxID.isEmpty,
              attendeeAddress.contains("@"), !attendeeAddress.contains(where: { $0.isWhitespace }) else { return false }
        return offersSetup && !isBusy && (reconnectingConnection == nil || reconnectingConnection?.kind == .caldav) && (sendingMailboxes.isEmpty || sendingMailboxes.contains { $0.id == sendingMailboxID })
    }
    func beginReconnect(_ connection: NodeCalendarConnection) {
        guard !isBusy else { return }
        reconnectingConnection = connection
        if connection.kind == .caldav { endpoint = ""; username = "" }
        sendingMailboxID = connection.sendingMailbox; attendeeAddress = connection.attendeeAddress
        password = ""; errorMessage = nil; statusMessage = "Reconnect " + (connection.kind == .google ? "Google Calendar" : "CalDAV") + " using its current credentials."
    }
    func cancelReconnect() {
        guard !isBusy else { return }
        reconnectingConnection = nil
        password = ""; statusMessage = nil; errorMessage = nil
    }
    func load() async {
        (availability, googleSetup) = await CalendarAvailability.probeSetup(service, lastKnownEnabled: availability == .enabled ? true : nil)
        guard offersSetup else { connections = []; errorMessage = nil; return }
        do { connections = try await service.connections() }
        catch { errorMessage = CalendarWeekViewModel.message(error) }
    }
    func connectCalDAV() async {
        guard canConnectCalDAV else { return }
        let command = NodeCalendarConnectionCommand(operationID: UUID().uuidString, connectionID: reconnectingConnection?.id, expectedGeneration: reconnectingConnection?.generation ?? 0, kind: .caldav, configuration: .init(caldav: .init(endpoint: endpoint, username: username, password: password, approvedRedirectOrigins: [])), sendingMailboxID: sendingMailboxID, attendeeAddress: attendeeAddress)
        password = ""
        await configure(command)
    }
    func connectGoogle() async {
        guard canConnectGoogle, let clientID = googleSetup.clientID else { return }
        isBusy = true; errorMessage = nil
        statusMessage = "Continue in your browser."
        let session = CalendarOAuthSession(clientID: clientID, openBrowser: openBrowser)
        oauth = session
        do {
            let configuration = try await session.authorize()
            if oauth === session { oauth = nil }
            isBusy = false; statusMessage = nil
            await configure(.init(operationID: UUID().uuidString, connectionID: reconnectingConnection?.id, expectedGeneration: reconnectingConnection?.generation ?? 0, kind: .google, configuration: .init(google: configuration)))
        } catch {
            if oauth === session { oauth = nil }
            statusMessage = nil
            errorMessage = Self.authorizationMessage(error)
            isBusy = false
        }
    }
    nonisolated static func authorizationMessage(_ error: any Error) -> String {
        switch error as? CalendarOAuthSession.Error {
        case .denied?: "Google Calendar access was not allowed."
        case .timedOut?: "Google Calendar authorization timed out. Try connecting again."
        case .cannotStart?: "Couldn’t open your browser for Google Calendar authorization."
        default: "Google Calendar authorization was not completed."
        }
    }
    func disconnect(_ connection: NodeCalendarConnection) async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        do { _ = try await service.disconnect(.init(operationID: UUID().uuidString, connectionID: connection.id, expectedGeneration: connection.generation)); await load() }
        catch { errorMessage = CalendarWeekViewModel.message(error) }
    }
    func stop() { oauth?.cancel(); oauth = nil; password = "" }
    static func setupMessage(_ result: NodeCalendarConnectionResult) -> String {
        switch (result.state, result.code) {
        case (.confirmed, _): "Calendar connected."
        case (.failed, .calendarLimit): "Calendar setup failed: this account has more than 200 calendars."
        case (.failed, .calendarMetadataLimit): "Calendar setup failed: the discovered calendar details are too large."
        case (.failed, _): "Calendar setup failed. Try connecting again."
        default: "Finishing setup… Refresh to check."
        }
    }
    private func configure(_ command: NodeCalendarConnectionCommand) async {
        isBusy = true; errorMessage = nil; defer { isBusy = false }
        do {
            let result = try await service.configure(command)
            statusMessage = Self.setupMessage(result)
            if result.state == .confirmed { reconnectingConnection = nil }
            await load()
        } catch { errorMessage = CalendarWeekViewModel.message(error) }
    }
}

#if os(macOS)
struct CalendarSettingsView: View {
    @StateObject private var model: CalendarSettingsModel
    init(service: any CalendarServing, refreshSendingMailboxes: (@MainActor @Sendable () async -> [CalendarSendingMailbox])? = nil) {
        _model = StateObject(wrappedValue: CalendarSettingsModel(service: service, refreshSendingMailboxes: refreshSendingMailboxes))
    }
    init(model: CalendarSettingsModel) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Calendars", detail: "", systemImage: "calendar", tint: MailDesign.accentBlue)
            if let message = model.availability.settingsMessage {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary).accessibilityIdentifier("calendar.availability")
            } else {
            if model.googleSetup != .unknown {
            GroupBox("Google Calendar") {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = model.googleSetup.settingsMessage {
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("calendar.google.unconfigured")
                    } else {
                        Text("Authorize Calendar access in your browser. Your Sync Node exchanges the authorization code.").font(.callout).foregroundStyle(.secondary)
                        Button("Connect Google Calendar", systemImage: "link") { Task { await model.connectGoogle() } }.disabled(!model.canConnectGoogle).accessibilityIdentifier("calendar.google.connect")
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            GroupBox("CalDAV") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("HTTPS server or explicit calendar URL", text: $model.endpoint)
                    TextField("CalDAV username", text: $model.username)
                    SecureField("Password or app password", text: $model.password)
                    Divider()
                    Text("Email scheduling identity").font(.headline)
                    if model.sendingMailboxes.isEmpty {
                        HStack {
                            Text("Connect mail on your Sync Node, then refresh.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry") { Task { await model.retryMailboxDiscovery() } }.disabled(model.isBusy)
                        }
                    } else {
                        Picker("Sending mailbox", selection: $model.sendingMailboxID) {
                            Text("Choose a sending mailbox").tag("")
                            ForEach(model.sendingMailboxes) { mailbox in Text(mailbox.name).tag(mailbox.id) }
                        }
                    }
                    TextField("Attendee email address", text: $model.attendeeAddress)
                    Text("Choose the connected mailbox and attendee address explicitly. The CalDAV login is not used as your email identity.").font(.caption).foregroundStyle(.secondary)
                    Button("Connect and discover calendars", systemImage: "link") { Task { await model.connectCalDAV() } }.disabled(!model.canConnectCalDAV)
                }.textFieldStyle(.roundedBorder).padding(8)
            }
            if let connection = model.reconnectingConnection {
                HStack {
                    Text("Reconnecting " + (connection.kind == .google ? "Google Calendar" : "CalDAV")).font(.callout)
                    Spacer()
                    Button("Cancel reconnect") { model.cancelReconnect() }.disabled(model.isBusy).accessibilityIdentifier("calendar.cancelReconnect")
                }
            }
            if model.isBusy { ProgressView("Connecting calendar…") }
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let status = model.statusMessage { Label(status, systemImage: "info.circle") }
            HStack { Text("Connected calendars").font(.headline); Spacer(); Button("Refresh") { Task { await model.load() } } }
            ForEach(model.connections, id: \.id) { connection in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(connection.kind == .google ? "Google Calendar" : "CalDAV", systemImage: "calendar"); Spacer()
                            Text(CalendarSettingsModel.connectionStatus(connection)).font(.caption)
                            // Only an established connection can be reconnected or disconnected;
                            // a setup that didn't finish is retried by connecting again.
                            if connection.enabled {
                                Button("Reconnect") { model.beginReconnect(connection) }
                                Button("Disconnect", role: .destructive) { Task { await model.disconnect(connection) } }
                            }
                        }
                        ForEach(connection.calendars, id: \.id) { calendar in
                            HStack { Circle().fill(CalendarWeekView.color(calendar.color)).frame(width: 8, height: 8); Text(calendar.name); Spacer(); Text(calendar.writable ? "Writable" : "Read-only").font(.caption).foregroundStyle(.secondary) }
                        }
                        if connection.kind == .caldav {
                            Text(CalendarSettingsModel.sendsAsLabel(connection)).font(.caption).textSelection(.enabled)
                        }
                    }.padding(8)
                }
            }
            }
        }.task { await model.load() }.onDisappear { model.stop() }.accessibilityIdentifier("calendar.settings")
    }
}
#endif


private struct CalendarAuthorityEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlainpostCalendarAuthority? = nil
}
public extension EnvironmentValues {
    var plainpostCalendarAuthority: PlainpostCalendarAuthority? {
        get { self[CalendarAuthorityEnvironmentKey.self] }
        set { self[CalendarAuthorityEnvironmentKey.self] = newValue }
    }
}
