import Foundation

public enum NodeCalendarError: Error, Equatable, Sendable {
    case unsupported, conflict, unavailable, unauthorized, invalidResponse, deliveryUncertain
    /// The Node reports that this account never admitted the requested operation.
    case unknownOperation
    /// A response would create a new attendee copy while more than one writable
    /// calendar could hold it; the destination must be chosen first.
    case targetCalendarRequired
    /// A window's events changed between pages; restart from the first page.
    case snapshotChanged
    /// A calendar is still completing its first sync, so the Node can't tell
    /// whether the invitation's event exists yet. Nothing was admitted.
    case calendarIndexPending
}

public enum NodeCalendarStepState: String, Codable, Equatable, Sendable {
    case notNeeded = "not_needed", pending, inFlight = "in_flight", confirmed, failed, uncertain
}

public enum NodeCalendarDeliveryOwner: String, Codable, Equatable, Sendable {
    case google, caldavServer = "caldav_server", email
}

public enum NodeCalendarParticipation: String, Codable, Equatable, Sendable {
    case none = "", needsAction, accepted, tentative, declined
}

public enum NodeCalendarScope: String, Codable, Equatable, Sendable {
    case occurrence, series
}

public enum NodeCalendarProviderKind: String, Codable, Equatable, Sendable {
    case google, caldav
}

public enum NodeCalendarTimeKind: String, Codable, Equatable, Sendable {
    case date, dateTime = "date_time"
}

public enum NodeCalendarInvitationState: String, Codable, Equatable, Sendable {
    case actionable, superseded, cancelled, unresolved, informational
}

public struct NodeCalendarTime: Codable, Equatable, Sendable {
    public var kind: NodeCalendarTimeKind
    public var value: String
    public var timezone: String

    public init(kind: NodeCalendarTimeKind, value: String, timezone: String) {
        self.kind = kind
        self.value = value
        self.timezone = timezone
    }
}

public struct NodeCalendarWindow: Codable, Equatable, Sendable {
    public var start: String
    public var end: String
    public var timezone: String

    public init(start: String, end: String, timezone: String) {
        self.start = start
        self.end = end
        self.timezone = timezone
    }
}

public struct NodeCalendarEdit: Codable, Equatable, Sendable {
    public var title: String
    public var location: String
    public var notes: String
    public var start: NodeCalendarTime
    public var end: NodeCalendarTime

    public init(title: String, location: String, notes: String, start: NodeCalendarTime, end: NodeCalendarTime) {
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
    }
}

public struct NodeCalendarCommand: Codable, Equatable, Sendable {
    public var operationID: String
    public var connectionID: String
    public var generation: UInt64
    public var eventID: String
    public var invitationID: String
    public var revision: String
    public var scope: NodeCalendarScope
    public var edit: NodeCalendarEdit?
    public var response: NodeCalendarParticipation?
    /// Destination calendar of a new attendee copy; omitted when not chosen.
    public var targetCalendarID: String?

    public init(operationID: String, connectionID: String, generation: UInt64, eventID: String, invitationID: String, revision: String, scope: NodeCalendarScope, edit: NodeCalendarEdit? = nil, response: NodeCalendarParticipation? = nil, targetCalendarID: String? = nil) {
        self.operationID = operationID
        self.connectionID = connectionID
        self.generation = generation
        self.eventID = eventID
        self.invitationID = invitationID
        self.revision = revision
        self.scope = scope
        self.edit = edit
        self.response = response
        self.targetCalendarID = targetCalendarID
    }
}

public struct NodeCalendarReceipt: Codable, Equatable, Sendable {
    public var operationID: String
    public var owner: NodeCalendarDeliveryOwner
    public var calendar: NodeCalendarStepState
    public var delivery: NodeCalendarStepState
    public var code: String
    public var eventID: String
    public var revision: String

    public init(operationID: String, owner: NodeCalendarDeliveryOwner, calendar: NodeCalendarStepState, delivery: NodeCalendarStepState, code: String, eventID: String, revision: String) {
        self.operationID = operationID
        self.owner = owner
        self.calendar = calendar
        self.delivery = delivery
        self.code = code
        self.eventID = eventID
        self.revision = revision
    }
}

/// Native invitation projection. `eventID` is the invitation identity named by
/// response commands; `calendarEventID` is the Node-resolved projected event,
/// or nil when absent or ambiguous. Display fields come from the invitation.
public struct NodeCalendarInvitation: Codable, Equatable, Sendable {
    public var id: String
    public var eventID: String
    public var messageID: String
    public var uid: String
    public var organizer: String
    public var attendeeAddress: String
    public var recurrenceID: String
    public var method: String
    public var revision: String
    public var state: NodeCalendarInvitationState
    public var sequence: UInt64
    public var stamp: String
    public var title: String
    public var location: String
    public var start: NodeCalendarTime?
    public var end: NodeCalendarTime?
    public var meetingURL: String?
    public var calendarEventID: String?

    public init(id: String, eventID: String, messageID: String, uid: String, organizer: String, attendeeAddress: String, recurrenceID: String, method: String, revision: String, state: NodeCalendarInvitationState, sequence: UInt64, stamp: String, title: String = "", location: String = "", start: NodeCalendarTime? = nil, end: NodeCalendarTime? = nil, meetingURL: String? = nil, calendarEventID: String? = nil) {
        self.id = id
        self.eventID = eventID
        self.messageID = messageID
        self.uid = uid
        self.organizer = organizer
        self.attendeeAddress = attendeeAddress
        self.recurrenceID = recurrenceID
        self.method = method
        self.revision = revision
        self.state = state
        self.sequence = sequence
        self.stamp = stamp
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.meetingURL = meetingURL
        self.calendarEventID = calendarEventID
    }
    private enum CodingKeys: String, CodingKey { case id, eventID, messageID, uid, organizer, attendeeAddress, recurrenceID, method, revision, state, sequence, stamp, title, location, start, end, meetingURL, calendarEventID }
    /// Nullable members are always present on the closed wire.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(uid, forKey: .uid)
        try container.encode(organizer, forKey: .organizer)
        try container.encode(attendeeAddress, forKey: .attendeeAddress)
        try container.encode(recurrenceID, forKey: .recurrenceID)
        try container.encode(method, forKey: .method)
        try container.encode(revision, forKey: .revision)
        try container.encode(state, forKey: .state)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(stamp, forKey: .stamp)
        try container.encode(title, forKey: .title)
        try container.encode(location, forKey: .location)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(meetingURL, forKey: .meetingURL)
        try container.encode(calendarEventID, forKey: .calendarEventID)
    }
}

public struct NodeCalendarEvent: Codable, Equatable, Sendable {
    public var id: String
    public var connectionID: String
    public var calendarID: String
    public var recurrenceID: String
    public var organizer: String
    public var revision: String
    public var sequence: UInt64
    public var stamp: String
    public var title: String
    public var location: String
    public var notes: String
    public var start: NodeCalendarTime
    public var end: NodeCalendarTime
    public var recurring: Bool
    public var cancelled: Bool
    public var attendeeAddress: String
    public var response: NodeCalendarParticipation
    public var canEditOccurrence: Bool
    public var canEditSeries: Bool
    public var canRespond: Bool
    public var disabledReason: String
    public var threadID: String
    public var messageID: String
    public var providerLink: String

    public init(id: String, connectionID: String, calendarID: String, recurrenceID: String, organizer: String, revision: String, sequence: UInt64, stamp: String, title: String, location: String, notes: String, start: NodeCalendarTime, end: NodeCalendarTime, recurring: Bool, cancelled: Bool, attendeeAddress: String, response: NodeCalendarParticipation, canEditOccurrence: Bool, canEditSeries: Bool, canRespond: Bool, disabledReason: String, threadID: String, messageID: String, providerLink: String) {
        self.id = id
        self.connectionID = connectionID
        self.calendarID = calendarID
        self.recurrenceID = recurrenceID
        self.organizer = organizer
        self.revision = revision
        self.sequence = sequence
        self.stamp = stamp
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.recurring = recurring
        self.cancelled = cancelled
        self.attendeeAddress = attendeeAddress
        self.response = response
        self.canEditOccurrence = canEditOccurrence
        self.canEditSeries = canEditSeries
        self.canRespond = canRespond
        self.disabledReason = disabledReason
        self.threadID = threadID
        self.messageID = messageID
        self.providerLink = providerLink
    }
}

public struct NodeCalendarConnection: Codable, Equatable, Sendable {
    public var calendars: [NodeCalendarCollection]
    public var id: String
    public var generation: UInt64
    public var kind: NodeCalendarProviderKind
    public var sendingMailbox: String
    public var attendeeAddress: String
    public var delivery: NodeCalendarDeliveryOwner
    public var enabled: Bool

    public init(id: String, generation: UInt64, kind: NodeCalendarProviderKind, sendingMailbox: String, attendeeAddress: String, delivery: NodeCalendarDeliveryOwner, enabled: Bool, calendars: [NodeCalendarCollection] = []) {
        self.calendars = calendars
        self.id = id
        self.generation = generation
        self.kind = kind
        self.sendingMailbox = sendingMailbox
        self.attendeeAddress = attendeeAddress
        self.delivery = delivery
        self.enabled = enabled
    }
}

public struct NodeCalendarCapabilities: Codable, Equatable, Sendable {
    public var version: UInt64
    public var providers: [NodeCalendarProviderKind]
    public var enabled: Bool
    public var google: NodeCalendarGoogleAvailability

    public init(version: UInt64, providers: [NodeCalendarProviderKind], enabled: Bool, google: NodeCalendarGoogleAvailability = .unconfigured) {
        self.version = version
        self.providers = providers
        self.enabled = enabled
        self.google = google
    }
}

/// The Sync Node's Google "Desktop app" calendar client. The client ID is not
/// secret and is present exactly when the Node has a configured client.
public struct NodeCalendarGoogleAvailability: Codable, Equatable, Sendable {
    public var configured: Bool
    public var clientID: String?

    public static let unconfigured = NodeCalendarGoogleAvailability(clientID: nil)

    public init(clientID: String?) {
        self.configured = clientID != nil
        self.clientID = clientID
    }

    private enum CodingKeys: String, CodingKey { case configured, clientID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decode(Bool.self, forKey: .configured)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        guard configured == (clientID != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .clientID, in: container, debugDescription: "client ID is present exactly when Google is configured")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configured, forKey: .configured)
        try container.encode(clientID, forKey: .clientID)
    }
}

public struct NodeCalendarConnectionsResult: Codable, Equatable, Sendable {
    public var connections: [NodeCalendarConnection]

    public init(connections: [NodeCalendarConnection]) {
        self.connections = connections
    }
}

public struct NodeCalendarGoogleConfiguration: Codable, Equatable, Sendable {
    public var authorizationCode: String
    public var codeVerifier: String
    public var clientID: String
    public var redirectURI: String
    public init(authorizationCode: String, codeVerifier: String, clientID: String, redirectURI: String) {
        self.authorizationCode = authorizationCode
        self.codeVerifier = codeVerifier
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}

public struct NodeCalendarCalDAVConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var username: String
    public var password: String
    public var approvedRedirectOrigins: [String]
    public init(endpoint: String, username: String, password: String, approvedRedirectOrigins: [String]) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.approvedRedirectOrigins = approvedRedirectOrigins
    }
}

public struct NodeCalendarConfiguration: Codable, Equatable, Sendable {
    public var google: NodeCalendarGoogleConfiguration?
    public var caldav: NodeCalendarCalDAVConfiguration?
    public init(google: NodeCalendarGoogleConfiguration? = nil, caldav: NodeCalendarCalDAVConfiguration? = nil) {
        self.google = google
        self.caldav = caldav
    }
}

public struct NodeCalendarConnectionCommand: Codable, Equatable, Sendable {
    public var operationID: String
    public var connectionID: String?
    public var expectedGeneration: UInt64
    public var kind: NodeCalendarProviderKind
    public var configuration: NodeCalendarConfiguration
    public var sendingMailboxID: String?
    public var attendeeAddress: String?
    public init(operationID: String, connectionID: String? = nil, expectedGeneration: UInt64, kind: NodeCalendarProviderKind, configuration: NodeCalendarConfiguration, sendingMailboxID: String? = nil, attendeeAddress: String? = nil) {
        self.operationID = operationID
        self.connectionID = connectionID
        self.expectedGeneration = expectedGeneration
        self.kind = kind
        self.configuration = configuration
        self.sendingMailboxID = sendingMailboxID
        self.attendeeAddress = attendeeAddress
    }
    private enum CodingKeys: String, CodingKey { case operationID, connectionID, expectedGeneration, kind, configuration, sendingMailboxID, attendeeAddress }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encodeIfPresent(connectionID, forKey: .connectionID)
        try container.encode(expectedGeneration, forKey: .expectedGeneration)
        try container.encode(kind, forKey: .kind)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(sendingMailboxID, forKey: .sendingMailboxID)
        try container.encode(attendeeAddress, forKey: .attendeeAddress)
    }
}

public struct NodeCalendarDisconnectCommand: Codable, Equatable, Sendable {
    public var operationID: String
    public var connectionID: String
    public var expectedGeneration: UInt64
    public init(operationID: String, connectionID: String, expectedGeneration: UInt64) {
        self.operationID = operationID
        self.connectionID = connectionID
        self.expectedGeneration = expectedGeneration
    }
}

public struct NodeCalendarConnectionRequest: Codable, Equatable, Sendable {
    public var command: NodeCalendarConnectionCommand
    public init(command: NodeCalendarConnectionCommand) {
        self.command = command
    }
}

public struct NodeCalendarConnectionsRequest: Codable, Equatable, Sendable {
    public init() {
    }
}

/// Bounded setup outcome codes carried by `connection-result`.
public enum NodeCalendarConnectionCode: String, Codable, Equatable, Sendable {
    case none = ""
    /// Discovery found more calendars than one connection may carry (200).
    case calendarLimit = "calendar_limit"
    /// The discovered calendar details (names, links) are too large to journal
    /// for setup, although the count is within bounds.
    case calendarMetadataLimit = "calendar_metadata_limit"
}

public struct NodeCalendarConnectionResult: Codable, Equatable, Sendable {
    public var connection: NodeCalendarConnection
    public var operationID: String
    public var state: NodeCalendarStepState
    public var code: NodeCalendarConnectionCode

    public init(connection: NodeCalendarConnection, operationID: String, state: NodeCalendarStepState, code: NodeCalendarConnectionCode = .none) {
        self.connection = connection
        self.operationID = operationID
        self.state = state
        self.code = code
    }
}

public struct NodeCalendarWindowRequest: Codable, Equatable, Sendable {
    public var window: NodeCalendarWindow
    public var cursor: String
    /// A first page asks the Node to refresh stale connections first; the wire
    /// member is present only as true. Prefetches and later pages read.
    public var refresh: Bool

    public init(window: NodeCalendarWindow, cursor: String, refresh: Bool = false) {
        self.window = window
        self.cursor = cursor
        self.refresh = refresh
    }
    private enum CodingKeys: String, CodingKey { case window, cursor, refresh }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        window = try container.decode(NodeCalendarWindow.self, forKey: .window)
        cursor = try container.decode(String.self, forKey: .cursor)
        refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(window, forKey: .window)
        try container.encode(cursor, forKey: .cursor)
        if refresh { try container.encode(true, forKey: .refresh) }
    }
}

public struct NodeCalendarWindowSnapshot: Codable, Equatable, Sendable {
    public var events: [NodeCalendarEvent]
    public var window: NodeCalendarWindow
    public var coverage: String
    public var refreshedAt: String
    public var failures: [String: String]
    public var nextCursor: String

    public init(events: [NodeCalendarEvent], window: NodeCalendarWindow, coverage: String, refreshedAt: String, failures: [String: String], nextCursor: String) {
        self.events = events
        self.window = window
        self.coverage = coverage
        self.refreshedAt = refreshedAt
        self.failures = failures
        self.nextCursor = nextCursor
    }
}

public struct NodeCalendarEventRequest: Codable, Equatable, Sendable {
    public var eventID: String

    public init(eventID: String) {
        self.eventID = eventID
    }
}

public struct NodeCalendarEventResult: Codable, Equatable, Sendable {
    public var event: NodeCalendarEvent

    public init(event: NodeCalendarEvent) {
        self.event = event
    }
}

public struct NodeCalendarCommandRequest: Codable, Equatable, Sendable {
    public var command: NodeCalendarCommand

    public init(command: NodeCalendarCommand) {
        self.command = command
    }
}

public struct NodeCalendarCommandResult: Codable, Equatable, Sendable {
    public var receipt: NodeCalendarReceipt

    public init(receipt: NodeCalendarReceipt) {
        self.receipt = receipt
    }
}

public struct NodeCalendarInvitationReadRequest: Codable, Equatable, Sendable {
    public var messageIDs: [String]

    public init(messageIDs: [String]) {
        self.messageIDs = messageIDs
    }
}

public struct NodeCalendarInvitationReadResult: Codable, Equatable, Sendable {
    public var invitations: [NodeCalendarInvitation]

    public init(invitations: [NodeCalendarInvitation]) {
        self.invitations = invitations
    }
}

public struct NodeCalendarOperationReadRequest: Codable, Equatable, Sendable {
    public var operationIDs: [String]

    public init(operationIDs: [String]) {
        self.operationIDs = operationIDs
    }
}

public struct NodeCalendarOperationReadResult: Codable, Equatable, Sendable {
    public var receipts: [NodeCalendarReceipt]
    /// Requested operations this account never admitted: the only definitive
    /// signal that an intent was not received.
    public var unknownOperationIDs: [String]

    public init(receipts: [NodeCalendarReceipt], unknownOperationIDs: [String] = []) {
        self.receipts = receipts
        self.unknownOperationIDs = unknownOperationIDs
    }
}


public struct NodeCalendarCollection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var timezone: String
    public var writable: Bool
    public var scheduling: Bool
    public init(id: String, name: String, color: String, timezone: String, writable: Bool, scheduling: Bool) {
        self.id = id; self.name = name; self.color = color; self.timezone = timezone; self.writable = writable; self.scheduling = scheduling
    }
}
