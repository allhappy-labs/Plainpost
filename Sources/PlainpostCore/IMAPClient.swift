import Darwin
import CFNetwork
import Foundation

public enum IMAPClientError: Error, Equatable, Sendable {
    case authenticationFailed
    case connectionLimit
    case throttled
    case connectionFailed
    case tlsFailed
    case timedOut
    case resourceLimit
    case protocolError(String)
    /// The mail server could not be reached, or it dropped or stalled the
    /// connection, before any command that could change mail was sent:
    /// while connecting (and STARTTLS), reading the greeting, or signing in
    /// (LOGIN or AUTHENTICATE and their CAPABILITY exchanges). Nothing
    /// changed on the server. A failure after sign-in stays
    /// `connectionFailed` or `timedOut`: a command may have acted.
    case unreachableBeforeCommand
}

/// Runs the sign-in phase of a session: a network failure or time-out there
/// is `unreachableBeforeCommand` (no command that changes mail was sent
/// yet). Everything else passes through.
func imapBeforeCommand<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch IMAPClientError.connectionFailed, IMAPClientError.timedOut {
        throw IMAPClientError.unreachableBeforeCommand
    }
}

public enum IMAPIdleOutcome: Equatable, Sendable {
    case mailboxChanged
    case renewalDue
    case serverClosing
    case unsupported
}

public struct IMAPRemoteMessageState: Equatable, Sendable {
    public let uid: Int
    public let flags: Set<String>

    public init(uid: Int, flags: Set<String>) {
        self.uid = uid
        self.flags = flags
    }
}

public struct IMAPAppendResult: Equatable, Sendable {
    public let mailbox: String
    public let uid: Int?

    public init(mailbox: String, uid: Int?) {
        self.mailbox = mailbox
        self.uid = uid
    }
}

/// Where a move put the message. `uidValidity` and `uid` come from the
/// server's `COPYUID` response code (UIDPLUS) and are nil without one.
public struct IMAPMoveResult: Equatable, Sendable {
    public let mailbox: String
    public let uidValidity: Int?
    public let uid: Int?

    public init(mailbox: String, uidValidity: Int?, uid: Int?) {
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

extension IMAPMoveResult {
    /// Reads `[COPYUID <uidvalidity> <source> <destination>]` for exactly the
    /// moved UID, untagged or on the tagged OK. Anything else (no code, a set
    /// or range, another UID, a zero) leaves the destination UID unknown.
    static func parsingCopyUID(mailbox: String, sourceUID: Int, lines: [String]) -> IMAPMoveResult {
        for line in lines {
            guard let marker = line.range(of: "[COPYUID ", options: .caseInsensitive),
                  let close = line[marker.upperBound...].firstIndex(of: "]") else { continue }
            let fields = line[marker.upperBound..<close].split(separator: " ")
            guard fields.count == 3,
                  let uidValidity = Int(fields[0]), uidValidity > 0,
                  Int(fields[1]) == sourceUID,
                  let destinationUID = Int(fields[2]), destinationUID > 0 else { continue }
            return IMAPMoveResult(mailbox: mailbox, uidValidity: uidValidity, uid: destinationUID)
        }
        return IMAPMoveResult(mailbox: mailbox, uidValidity: nil, uid: nil)
    }
}

public protocol IMAPClientProtocol {
    func login(username: String, password: String) async throws
    /// Authenticates with a password (`LOGIN`) or an OAuth access token
    /// (`AUTHENTICATE XOAUTH2`). XOAUTH2 failures surface as
    /// `MailAuthenticationError`.
    func authenticate(username: String, authentication: MailAuthentication) async throws
    func listMailboxes() async throws -> [Mailbox]
    func selectMailbox(_ path: String) async throws -> String
    func allMessageUIDs() async throws -> [Int]
    func messageUIDs(after uid: Int?) async throws -> [Int]
    func capabilities() async throws -> Set<String>
    func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome
    func messageStates() async throws -> [IMAPRemoteMessageState]?
    func disconnect() async
    func fetchHeader(uid: Int) async throws -> String
    /// Returns the server supplied INTERNALDATE. A missing value is an
    /// intentional fail-closed result for notification eligibility.
    func fetchInternalDate(uid: Int) async throws -> Date?
    func fetchBody(uid: Int) async throws -> String
    func fetchBodyData(uid: Int) async throws -> Data
    func markRead(uid: Int) async throws
    func markUnread(uid: Int) async throws
    func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws
    func setLabels(uid: Int, add: [String], remove: [String]) async throws
    func archive(uid: Int, archiveMailbox: String) async throws
    /// Moves one message out of the selected mailbox into `mailbox`: `UID MOVE`
    /// when the server has MOVE, otherwise `UID COPY` then `UID EXPUNGE` of that
    /// UID only. Fails before any change when the server has neither MOVE nor
    /// UIDPLUS, so a failed move never erases the message.
    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult
    /// Erases one message: `\Deleted` then `UID EXPUNGE` of that UID only.
    func delete(uid: Int) async throws
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult
}

public extension IMAPClientProtocol {
    /// Password-only default for test doubles: XOAUTH2 is unavailable.
    func authenticate(username: String, authentication: MailAuthentication) async throws {
        switch authentication {
        case .password(let password):
            try await login(username: username, password: password)
        case .xoauth2:
            throw MailAuthenticationError.mechanismUnavailable
        }
    }

    func fetchInternalDate(uid: Int) async throws -> Date? {
        IMAPInternalDateParser.date(from: try await fetchHeader(uid: uid))
    }

    func messageUIDs(after uid: Int?) async throws -> [Int] {
        let values = try await allMessageUIDs()
        guard let uid else { return values }
        return values.filter { $0 > uid }
    }

    func fetchBodyData(uid: Int) async throws -> Data {
        Data(try await fetchBody(uid: uid).utf8)
    }

    func capabilities() async throws -> Set<String> { [] }

    func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome { .unsupported }

    func disconnect() async {}

    func messageStates() async throws -> [IMAPRemoteMessageState]? { nil }

    func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws {
        throw IMAPClientError.protocolError("Typed flag mutation is unavailable for this client.")
    }

    func setLabels(uid: Int, add: [String], remove: [String]) async throws {
        throw IMAPClientError.protocolError("Gmail label mutation is unavailable for this client.")
    }

    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        throw IMAPClientError.protocolError("Moving messages is unavailable for this client.")
    }
}

public extension IMAPClientProtocol {
    /// Moves the duplicate UIDs of a copy just moved, in the selected mailbox,
    /// and returns those the server moved; a refused one stays. Some servers
    /// (Purelymail) deliver one message twice: two UIDs under one Message-ID,
    /// shown as one row, so an action on the row acts on every copy.
    func moveDuplicates(_ uids: [Int], to mailbox: String) async -> [Int] {
        var moved: [Int] = []
        for uid in uids where (try? await move(uid: uid, to: mailbox)) != nil {
            moved.append(uid)
        }
        return moved
    }

    /// Erases the duplicate UIDs of a copy just erased, like `moveDuplicates`.
    func deleteDuplicates(_ uids: [Int]) async -> [Int] {
        var erased: [Int] = []
        for uid in uids where (try? await delete(uid: uid)) != nil {
            erased.append(uid)
        }
        return erased
    }
}

public extension MailTransportClientFactory {
    static func imapClient(host: String, port: UInt16) -> IMAPClientProtocol {
        if MailTransportSecurityPolicy.isLoopback(host) {
            return PlaintextIMAPClient(host: host, port: port)
        }
        if port == 993 {
            return SecureIMAPClient(host: host, port: port)
        }
        if port == 143 {
            return StartTLSIMAPClient(host: host, port: port)
        }
        return UnsupportedIMAPSecurityClient()
    }
}

public struct UnsupportedIMAPSecurityClient: IMAPClientProtocol {
    public init() {}

    public func login(username: String, password: String) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func authenticate(username: String, authentication: MailAuthentication) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func listMailboxes() async throws -> [Mailbox] {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func selectMailbox(_ path: String) async throws -> String {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func allMessageUIDs() async throws -> [Int] {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func fetchHeader(uid: Int) async throws -> String {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func fetchInternalDate(uid: Int) async throws -> Date? {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func fetchBody(uid: Int) async throws -> String {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func markRead(uid: Int) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func markUnread(uid: Int) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func archive(uid: Int, archiveMailbox: String) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func delete(uid: Int) async throws {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }

    public func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        throw PlainpostError.validationFailed("Secure IMAP transport is not implemented for this port.")
    }
}

public final class PlaintextIMAPClient: IMAPClientProtocol {
    private let session: IMAPProtocolSession

    public init(host: String, port: UInt16) {
        session = IMAPProtocolSession(socketProvider: PlaintextIMAPSocketProvider(host: host, port: port))
    }

    /// Tests only: a shorter read timeout than production's.
    init(host: String, port: UInt16, commandTimeout: TimeInterval) {
        session = IMAPProtocolSession(socketProvider: PlaintextIMAPSocketProvider(host: host, port: port),
                                      commandTimeout: commandTimeout)
    }

    public func login(username: String, password: String) async throws {
        try session.login(username: username, password: password)
    }

    public func authenticate(username: String, authentication: MailAuthentication) async throws {
        try session.authenticate(username: username, authentication: authentication)
    }

    public func listMailboxes() async throws -> [Mailbox] {
        try session.listMailboxes()
    }

    public func selectMailbox(_ path: String) async throws -> String {
        try session.selectMailbox(path)
    }

    public func allMessageUIDs() async throws -> [Int] {
        try session.allMessageUIDs()
    }

    public func messageUIDs(after uid: Int?) async throws -> [Int] {
        try session.messageUIDs(after: uid)
    }

    public func capabilities() async throws -> Set<String> {
        try session.capabilities()
    }

    public func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome {
        let session = self.session
        return try await withTaskCancellationHandler {
            try session.idle(maxDuration: maxDuration)
        } onCancel: {
            session.interrupt()
        }
    }

    public func disconnect() async {
        session.disconnect()
    }

    public func messageStates() async throws -> [IMAPRemoteMessageState]? {
        try session.messageStates()
    }

    public func fetchHeader(uid: Int) async throws -> String {
        try session.fetchHeader(uid: uid)
    }

    public func fetchInternalDate(uid: Int) async throws -> Date? {
        try session.fetchInternalDate(uid: uid)
    }

    public func fetchBody(uid: Int) async throws -> String {
        try session.fetchBody(uid: uid)
    }

    public func fetchBodyData(uid: Int) async throws -> Data {
        try session.fetchBodyData(uid: uid)
    }

    public func markRead(uid: Int) async throws {
        try session.markRead(uid: uid)
    }

    public func markUnread(uid: Int) async throws {
        try session.markUnread(uid: uid)
    }

    public func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws {
        try session.setFlags(uid: uid, add: add, remove: remove, expectedModSequence: expectedModSequence)
    }

    public func setLabels(uid: Int, add: [String], remove: [String]) async throws {
        try session.setLabels(uid: uid, add: add, remove: remove)
    }

    public func archive(uid: Int, archiveMailbox: String) async throws {
        try session.archive(uid: uid, archiveMailbox: archiveMailbox)
    }

    public func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        try session.move(uid: uid, to: mailbox)
    }

    public func delete(uid: Int) async throws {
        try session.delete(uid: uid)
    }

    public func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        try session.appendMessage(to: mailbox, flags: flags, data: data)
    }
}

public final class SecureIMAPClient: IMAPClientProtocol {
    public enum CertificateValidation: Sendable {
        case systemTrust
        case disabledForLocalTesting
        /// Explicit fixture trust; the hostname is still validated.
        case testAnchor(Data)
    }

    private let session: IMAPProtocolSession

    public init(
        host: String,
        port: UInt16,
        certificateValidation: CertificateValidation = .systemTrust
    ) {
        session = IMAPProtocolSession(
            socketProvider: TLSIMAPSocketProvider(
                host: host,
                port: port,
                certificateValidation: certificateValidation
            )
        )
    }

    /// Tests only: a shorter read timeout than production's.
    init(host: String, port: UInt16, certificateValidation: CertificateValidation, commandTimeout: TimeInterval) {
        session = IMAPProtocolSession(
            socketProvider: TLSIMAPSocketProvider(host: host, port: port, certificateValidation: certificateValidation),
            commandTimeout: commandTimeout
        )
    }

    public func login(username: String, password: String) async throws {
        try session.login(username: username, password: password)
    }

    public func authenticate(username: String, authentication: MailAuthentication) async throws {
        try session.authenticate(username: username, authentication: authentication)
    }

    public func listMailboxes() async throws -> [Mailbox] {
        try session.listMailboxes()
    }

    public func selectMailbox(_ path: String) async throws -> String {
        try session.selectMailbox(path)
    }

    public func allMessageUIDs() async throws -> [Int] {
        try session.allMessageUIDs()
    }

    public func messageUIDs(after uid: Int?) async throws -> [Int] {
        try session.messageUIDs(after: uid)
    }

    public func capabilities() async throws -> Set<String> {
        try session.capabilities()
    }

    public func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome {
        let session = self.session
        return try await withTaskCancellationHandler {
            try session.idle(maxDuration: maxDuration)
        } onCancel: {
            session.interrupt()
        }
    }

    public func disconnect() async {
        session.disconnect()
    }

    public func messageStates() async throws -> [IMAPRemoteMessageState]? {
        try session.messageStates()
    }

    public func fetchHeader(uid: Int) async throws -> String {
        try session.fetchHeader(uid: uid)
    }

    public func fetchInternalDate(uid: Int) async throws -> Date? {
        try session.fetchInternalDate(uid: uid)
    }

    public func fetchBody(uid: Int) async throws -> String {
        try session.fetchBody(uid: uid)
    }

    public func fetchBodyData(uid: Int) async throws -> Data {
        try session.fetchBodyData(uid: uid)
    }

    public func markRead(uid: Int) async throws {
        try session.markRead(uid: uid)
    }

    public func markUnread(uid: Int) async throws {
        try session.markUnread(uid: uid)
    }

    public func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws {
        try session.setFlags(uid: uid, add: add, remove: remove, expectedModSequence: expectedModSequence)
    }

    public func setLabels(uid: Int, add: [String], remove: [String]) async throws {
        try session.setLabels(uid: uid, add: add, remove: remove)
    }

    public func archive(uid: Int, archiveMailbox: String) async throws {
        try session.archive(uid: uid, archiveMailbox: archiveMailbox)
    }

    public func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        try session.move(uid: uid, to: mailbox)
    }

    public func delete(uid: Int) async throws {
        try session.delete(uid: uid)
    }

    public func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        try session.appendMessage(to: mailbox, flags: flags, data: data)
    }
}

public final class StartTLSIMAPClient: IMAPClientProtocol {
    private let session: IMAPProtocolSession

    public init(
        host: String,
        port: UInt16,
        certificateValidation: SecureIMAPClient.CertificateValidation = .systemTrust
    ) {
        session = IMAPProtocolSession(
            socketProvider: StartTLSIMAPSocketProvider(
                host: host,
                port: port,
                certificateValidation: certificateValidation
            )
        )
    }

    /// Tests only: a shorter read timeout than production's.
    init(
        host: String, port: UInt16, certificateValidation: SecureIMAPClient.CertificateValidation, commandTimeout: TimeInterval
    ) {
        session = IMAPProtocolSession(
            socketProvider: StartTLSIMAPSocketProvider(host: host, port: port, certificateValidation: certificateValidation),
            commandTimeout: commandTimeout
        )
    }

    public func login(username: String, password: String) async throws {
        try session.login(username: username, password: password)
    }

    public func authenticate(username: String, authentication: MailAuthentication) async throws {
        try session.authenticate(username: username, authentication: authentication)
    }

    public func listMailboxes() async throws -> [Mailbox] {
        try session.listMailboxes()
    }

    public func selectMailbox(_ path: String) async throws -> String {
        try session.selectMailbox(path)
    }

    public func allMessageUIDs() async throws -> [Int] {
        try session.allMessageUIDs()
    }

    public func messageUIDs(after uid: Int?) async throws -> [Int] {
        try session.messageUIDs(after: uid)
    }

    public func capabilities() async throws -> Set<String> {
        try session.capabilities()
    }

    public func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome {
        let session = self.session
        return try await withTaskCancellationHandler {
            try session.idle(maxDuration: maxDuration)
        } onCancel: {
            session.interrupt()
        }
    }

    public func disconnect() async {
        session.disconnect()
    }

    public func messageStates() async throws -> [IMAPRemoteMessageState]? {
        try session.messageStates()
    }

    public func fetchHeader(uid: Int) async throws -> String {
        try session.fetchHeader(uid: uid)
    }

    public func fetchInternalDate(uid: Int) async throws -> Date? {
        try session.fetchInternalDate(uid: uid)
    }

    public func fetchBody(uid: Int) async throws -> String {
        try session.fetchBody(uid: uid)
    }

    public func fetchBodyData(uid: Int) async throws -> Data {
        try session.fetchBodyData(uid: uid)
    }

    public func markRead(uid: Int) async throws {
        try session.markRead(uid: uid)
    }

    public func markUnread(uid: Int) async throws {
        try session.markUnread(uid: uid)
    }

    public func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws {
        try session.setFlags(uid: uid, add: add, remove: remove, expectedModSequence: expectedModSequence)
    }

    public func setLabels(uid: Int, add: [String], remove: [String]) async throws {
        try session.setLabels(uid: uid, add: add, remove: remove)
    }

    public func archive(uid: Int, archiveMailbox: String) async throws {
        try session.archive(uid: uid, archiveMailbox: archiveMailbox)
    }

    public func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        try session.move(uid: uid, to: mailbox)
    }

    public func delete(uid: Int) async throws {
        try session.delete(uid: uid)
    }

    public func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        try session.appendMessage(to: mailbox, flags: flags, data: data)
    }
}

private final class IMAPProtocolSession: @unchecked Sendable {
    private let socketProvider: IMAPSocketProvider
    private var socket: IMAPLineSocket?
    private let socketStateLock = NSLock()
    private var nextTag = 1

    // These are protocol framing limits, separate from MIME's decoded body
    // limits. Command literals are reconstructed before metadata parsing, so
    // the limit must be checked from the marker before allocating the payload.
    private static let maximumResponseLineBytes = 64 << 10
    private static let maximumResponseLines = 65_536
    private static let maximumNonliteralResponseBytes = 8 << 20
    private static let maximumCommandLiteralBytes = 8 << 20

    /// How long any read may wait for the server, from the greeting on.
    private let commandTimeout: TimeInterval

    init(socketProvider: IMAPSocketProvider, commandTimeout: TimeInterval = 30) {
        self.socketProvider = socketProvider
        self.commandTimeout = commandTimeout
    }

    deinit {
        socketStateLock.lock()
        let socket = self.socket
        self.socket = nil
        socketStateLock.unlock()
        socket?.close()
    }

    func authenticate(username: String, authentication: MailAuthentication) throws {
        switch authentication {
        case .password(let password):
            try login(username: username, password: password)
        case .xoauth2(let accessToken):
            try authenticateXOAUTH2(username: username, accessToken: accessToken)
        }
    }

    /// SASL XOAUTH2 (RFC 7628 framing as used by Google). The token is sent
    /// only after the server advertises `AUTH=XOAUTH2`. With `SASL-IR` the
    /// initial response rides on the command; otherwise it follows the first
    /// continuation. A second continuation is the server's error challenge:
    /// the client answers with an empty line and the tagged `NO` follows.
    func authenticateXOAUTH2(username: String, accessToken: String) throws {
        let payload = try XOAUTH2.initialClientResponse(username: username, accessToken: accessToken)
        try imapBeforeCommand { try authenticateXOAUTH2(payload: payload) }
    }

    private func authenticateXOAUTH2(payload: String) throws {
        let socket = try connectIfNeeded()
        let greeting = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
        guard greeting.hasPrefix("* OK") else {
            throw IMAPClientError.protocolError(greeting)
        }

        let capabilities = try Self.capabilities(from: command("CAPABILITY"))
        guard capabilities.contains("AUTH=XOAUTH2") else {
            throw MailAuthenticationError.mechanismUnavailable
        }

        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        var payloadSent = capabilities.contains("SASL-IR")
        var challenged = false
        let taggedLine: String
        do {
            try socket.writeLine(payloadSent ? "\(tag) AUTHENTICATE XOAUTH2 \(payload)" : "\(tag) AUTHENTICATE XOAUTH2")
            var responseLines = 0
            while true {
                let line = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
                responseLines += 1
                guard responseLines <= Self.maximumAuthenticationResponseLines else {
                    throw IMAPClientError.resourceLimit
                }
                if line.hasPrefix("\(tag) ") {
                    taggedLine = line
                    break
                }
                guard line.hasPrefix("+") else { continue }
                if !payloadSent {
                    payloadSent = true
                    try socket.writeLine(payload)
                } else if !challenged {
                    challenged = true
                    try socket.writeLine("")
                } else {
                    throw IMAPClientError.protocolError("Unexpected IMAP XOAUTH2 continuation.")
                }
            }
        } catch {
            socket.close()
            clearSocket(ifIdenticalTo: socket)
            throw error
        }

        switch Self.loginStatus(from: IMAPTaggedResponse(tag: tag, untaggedLines: [], taggedLine: taggedLine)) {
        case "OK":
            _ = try command("CAPABILITY")
        case "NO":
            throw Self.xoauth2Refusal(taggedLine: taggedLine, tag: tag, challenged: challenged)
        default:
            throw IMAPClientError.protocolError("Malformed IMAP AUTHENTICATE response.")
        }
    }

    /// Only a credential refusal may drive token refresh and reauthorization.
    ///
    /// A `[LIMIT]`/`[INUSE]` code always means a connection-limit refusal,
    /// even when Google's SASL error challenge came first: a challenge is
    /// Google's generic "authentication did not complete" signal and does
    /// not, by itself, distinguish a credential refusal from a limit refusal
    /// reached while authenticating. Otherwise a `NO` is a credential refusal
    /// when the challenge came first, or when it carries an RFC 5530
    /// credential code (`AUTHENTICATIONFAILED`, `AUTHORIZATIONFAILED`,
    /// `EXPIRED`). Gmail also refuses a grant it wants re-approved in a
    /// browser without a challenge, as `NO [WEBALERT <url>] ...` or
    /// `NO [ALERT] Please log in via your web browser ...`; that refusal never
    /// clears by itself, so it is a credential refusal too. Gmail sends its
    /// load refusals as `NO [ALERT] ...` as well, so every other code, every
    /// other `[ALERT]` and a bare `NO` stay temporary.
    static func xoauth2Refusal(taggedLine: String, tag: String, challenged: Bool) -> Error {
        let text = taggedLine.dropFirst(tag.count + 1).dropFirst("NO".count).drop(while: { $0 == " " })
        let code: String?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            code = text[text.index(after: text.startIndex)..<close]
                .split(separator: " ").first.map { $0.uppercased() }
        } else {
            code = nil
        }
        if code == "LIMIT" || code == "INUSE" {
            return IMAPClientError.connectionLimit
        }
        if code == "WEBALERT" || Self.requiresWebLogin(text) {
            return MailAuthenticationError.rejected
        }
        if challenged { return MailAuthenticationError.rejected }
        switch code {
        case "AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED":
            return MailAuthenticationError.rejected
        default:
            return IMAPClientError.throttled
        }
    }

    /// Gmail's durable "the user must re-approve this grant in a browser"
    /// wording, which it sends as free text beside `[ALERT]` or `[WEBALERT]`.
    static let webLoginRefusalText = "log in via your web browser"

    private static func requiresWebLogin(_ text: Substring) -> Bool {
        text.range(of: Self.webLoginRefusalText, options: .caseInsensitive) != nil
    }

    private static let maximumAuthenticationResponseLines = 64

    func login(username: String, password: String) throws {
        let encodedUsername = try Self.quotedLoginString(username)
        let encodedPassword = try Self.quotedLoginString(password)
        try imapBeforeCommand { try login(encodedUsername: encodedUsername, encodedPassword: encodedPassword) }
    }

    private func login(encodedUsername: String, encodedPassword: String) throws {
        let socket = try connectIfNeeded()
        let greeting = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
        guard greeting.hasPrefix("* OK") else {
            throw IMAPClientError.protocolError(greeting)
        }

        // Capability discovery is deliberately performed both before and after
        // credentials. The pre-auth response constrains the available auth
        // exchange while the post-auth response is the authenticated snapshot.
        _ = try command("CAPABILITY")

        let response = try command("LOGIN \(encodedUsername) \(encodedPassword)")
        switch Self.loginStatus(from: response) {
        case "OK":
            _ = try command("CAPABILITY")
            return
        case "NO":
            throw IMAPClientError.authenticationFailed
        default:
            throw IMAPClientError.protocolError("Malformed IMAP LOGIN response.")
        }
    }

    private static func loginStatus(from response: IMAPTaggedResponse) -> String? {
        let parts = response.taggedLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count >= 2,
              parts[0] == Substring(response.tag),
              !parts[1].isEmpty
        else {
            return nil
        }
        return parts[1].uppercased()
    }

    private static func quotedLoginString(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw IMAPClientError.protocolError("IMAP login credentials cannot contain control characters.")
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func listMailboxes() throws -> [Mailbox] {
        let response = try command(#"LIST "" "*""#)
        return response.untaggedLines.compactMap { line -> Mailbox? in
            guard let parsed = Self.parseListResponse(line) else { return nil }
            return Mailbox(
                id: MailboxID("mbx_\(Self.stableMailboxID(parsed.path))"),
                accountID: AccountID("acc_personal"),
                name: parsed.path.split(separator: parsed.delimiter?.first ?? "/").last.map(String.init) ?? parsed.path,
                path: parsed.path,
                specialUse: parsed.attributes.first(where: { Self.specialUseAttributes.contains($0.lowercased()) })
            )
        }
    }

    func selectMailbox(_ path: String) throws -> String {
        let response = try command("SELECT \(Self.quoted(path))")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return response.untaggedLines.joined(separator: "\n")
    }

    func allMessageUIDs() throws -> [Int] {
        try messageUIDs(after: nil)
    }

    func messageUIDs(after uid: Int?) throws -> [Int] {
        let criteria = uid.map { "UID \($0 + 1):*" } ?? "ALL"
        let response = try command("UID SEARCH \(criteria)")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return response.untaggedLines
            .filter { $0.uppercased().hasPrefix("* SEARCH") }
            .flatMap { line in
                line.split(separator: " ").dropFirst(2).compactMap { Int($0) }
            }
            .sorted()
    }

    func capabilities() throws -> Set<String> {
        try Self.capabilities(from: command("CAPABILITY"))
    }

    private static func capabilities(from response: IMAPTaggedResponse) throws -> Set<String> {
        guard response.taggedLine.localizedCaseInsensitiveContains(" OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return Set(response.untaggedLines
            .filter { $0.uppercased().hasPrefix("* CAPABILITY ") }
            .flatMap { $0.split(separator: " ").dropFirst(2).map { String($0).uppercased() } })
    }

    func messageStates() throws -> [IMAPRemoteMessageState] {
        let response = try command("UID FETCH 1:* (UID FLAGS)")
        guard response.taggedLine.localizedCaseInsensitiveContains(" OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        let uidExpression = try NSRegularExpression(pattern: #"\bUID\s+(\d+)"#, options: .caseInsensitive)
        let flagsExpression = try NSRegularExpression(pattern: #"\bFLAGS\s+\(([^)]*)\)"#, options: .caseInsensitive)
        return try response.untaggedLines.filter { $0.uppercased().contains(" FETCH ") }.map { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let flagsMatch = flagsExpression.firstMatch(in: line, range: range),
                  let flagsRange = Range(flagsMatch.range(at: 1), in: line) else {
                throw IMAPClientError.protocolError("Malformed UID FLAGS response.")
            }
            var topLevelAttributes = line
            if let entireFlagsRange = Range(flagsMatch.range(at: 0), in: topLevelAttributes) {
                topLevelAttributes.replaceSubrange(
                    entireFlagsRange,
                    with: String(repeating: " ", count: topLevelAttributes[entireFlagsRange].utf8.count)
                )
            }
            let topLevelRange = NSRange(topLevelAttributes.startIndex..., in: topLevelAttributes)
            guard let uidMatch = uidExpression.firstMatch(in: topLevelAttributes, range: topLevelRange),
                  let uidRange = Range(uidMatch.range(at: 1), in: topLevelAttributes),
                  let uid = Int(topLevelAttributes[uidRange]) else {
                throw IMAPClientError.protocolError("Malformed UID FLAGS response.")
            }
            return IMAPRemoteMessageState(
                uid: uid,
                flags: Set(line[flagsRange].split(whereSeparator: \.isWhitespace).map(String.init))
            )
        }
    }

    func idle(maxDuration: TimeInterval) throws -> IMAPIdleOutcome {
        guard try capabilities().contains("IDLE") else { return .unsupported }
        let socket = try connectIfNeeded()
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try socket.writeLine("\(tag) IDLE")
        let continuation = try socket.readLine()
        guard continuation.hasPrefix("+") else {
            throw IMAPClientError.protocolError(continuation)
        }

        try socket.setReadTimeout(max(1, maxDuration))
        defer { try? socket.setReadTimeout(self.commandTimeout) }
        do {
            while true {
                let line = try socket.readLine()
                let uppercased = line.uppercased()
                if uppercased.hasPrefix("* BYE") {
                    socket.close()
                    clearSocket(ifIdenticalTo: socket)
                    return .serverClosing
                }
                if Self.isMailboxChange(line: uppercased) {
                    try finishIdle(tag: tag, socket: socket)
                    return .mailboxChanged
                }
            }
        } catch IMAPClientError.timedOut {
            try finishIdle(tag: tag, socket: socket)
            return .renewalDue
        } catch {
            socket.close()
            clearSocket(ifIdenticalTo: socket)
            throw error
        }
    }

    func disconnect() {
        socketStateLock.lock()
        let socket = self.socket
        self.socket = nil
        socketStateLock.unlock()
        socket?.close()
    }

    func interrupt() {
        socketStateLock.lock()
        let socket = self.socket
        socketStateLock.unlock()
        socket?.interrupt()
    }

    private func finishIdle(tag: String, socket: IMAPLineSocket) throws {
        try socket.setReadTimeout(5)
        try socket.writeLine("DONE")
        while true {
            let line = try socket.readLine()
            if line.hasPrefix("\(tag) ") {
                guard line.localizedCaseInsensitiveContains(" OK") else {
                    throw IMAPClientError.protocolError(line)
                }
                return
            }
        }
    }

    private static func isMailboxChange(line: String) -> Bool {
        guard line.hasPrefix("*") else { return false }
        return line.contains(" EXISTS") || line.contains(" RECENT") || line.contains(" FETCH")
            || line.contains(" EXPUNGE") || line.contains(" VANISHED")
    }

    func fetchHeader(uid: Int) throws -> String {
        let response = try command("UID FETCH \(uid) (FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM REPLY-TO TO CC BCC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE CONTENT-DISPOSITION X-PLAINPOST-ACCOUNT-VERIFICATION)] RFC822.SIZE)")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return response.untaggedLines.joined(separator: "\n")
    }

    func fetchInternalDate(uid: Int) throws -> Date? {
        let response = try command("UID FETCH \(uid) (INTERNALDATE)")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return IMAPInternalDateParser.date(from: response.untaggedLines.joined(separator: "\n"))
    }

    func fetchBody(uid: Int) throws -> String {
        let response = try command("UID FETCH \(uid) BODY.PEEK[]")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return response.untaggedLines.joined(separator: "\n")
    }

    func fetchBodyData(uid: Int) throws -> Data {
        let socket = try connectIfNeeded()
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try socket.writeLine("\(tag) UID FETCH \(uid) BODY.PEEK[]")

        var fallbackLines: [String] = []
        var literal: Data?
        while true {
            let line = try socket.readLine()
            if line.hasPrefix("\(tag) ") {
                guard line.localizedCaseInsensitiveContains(" OK") else {
                    throw IMAPClientError.protocolError(line)
                }
                return literal ?? Data(fallbackLines.joined(separator: "\n").utf8)
            }
            if let byteCount = Self.literalByteCount(from: line) {
                literal = try socket.readBytes(count: byteCount)
            } else {
                fallbackLines.append(line)
            }
        }
    }

    private static func literalByteCount(from responseLine: String) -> Int? {
        guard responseLine.last == "}",
              let openingBrace = responseLine.lastIndex(of: "{") else {
            return nil
        }
        return Int(responseLine[responseLine.index(after: openingBrace)..<responseLine.index(before: responseLine.endIndex)])
    }

    private static let specialUseAttributes: Set<String> = [
        "\\inbox", "\\sent", "\\drafts", "\\trash", "\\junk", "\\archive", "\\all"
    ]

    private static func parseListResponse(_ line: String) -> (attributes: [String], delimiter: String?, path: String)? {
        let pattern = #"^\*\s+LIST\s+\(([^)]*)\)\s+(NIL|\"(?:[^\"\\]|\\.)*\")\s+(\"(?:[^\"\\]|\\.)*\"|\S+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let attributesRange = Range(match.range(at: 1), in: line),
              let delimiterRange = Range(match.range(at: 2), in: line),
              let pathRange = Range(match.range(at: 3), in: line) else { return nil }
        let attributes = line[attributesRange].split(whereSeparator: \.isWhitespace).map(String.init)
        let delimiterToken = String(line[delimiterRange])
        let path = unquoted(String(line[pathRange]))
        let delimiter = delimiterToken.uppercased() == "NIL" ? nil : unquoted(delimiterToken)
        return (attributes, delimiter, path)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func unquoted(_ value: String) -> String {
        guard value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func stableMailboxID(_ path: String) -> String {
        String(path.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    func markRead(uid: Int) throws {
        try store(uid: uid, operation: "+FLAGS.SILENT", flags: "(\\Seen)")
    }

    func markUnread(uid: Int) throws {
        try store(uid: uid, operation: "-FLAGS.SILENT", flags: "(\\Seen)")
    }

    // The semantic fixture seam exercises the same public client surface used
    // by callers that need an exact desired flag state. A conditional
    // add/remove pair is resolved to one FLAGS STORE so a MODSEQ race cannot
    // partially apply one half of the requested mutation.
    func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) throws {
        let addAtoms = try Self.flagAtoms(add)
        let removeAtoms = try Self.flagAtoms(remove)
        guard !addAtoms.isEmpty || !removeAtoms.isEmpty,
              Set(addAtoms).isDisjoint(with: Set(removeAtoms))
        else { throw IMAPClientError.protocolError("Invalid flag mutation.") }
        if let expectedModSequence {
            guard expectedModSequence > 0, try capabilities().contains("CONDSTORE") else {
                throw IMAPClientError.protocolError("Conditional STORE is unavailable.")
            }
        }
        if expectedModSequence != nil, !addAtoms.isEmpty, !removeAtoms.isEmpty {
            guard let current = try messageStates().first(where: { $0.uid == uid }) else {
                throw IMAPClientError.protocolError("Flag state is unavailable for conditional STORE.")
            }
            let desired = current.flags.union(addAtoms).subtracting(removeAtoms).sorted()
            try store(uid: uid, operation: "FLAGS.SILENT", flags: "(\(desired.joined(separator: " ")))", expectedModSequence: expectedModSequence)
            return
        }
        if !addAtoms.isEmpty {
            try store(uid: uid, operation: "+FLAGS.SILENT", flags: "(\(addAtoms.joined(separator: " ")))", expectedModSequence: expectedModSequence)
        }
        if !removeAtoms.isEmpty {
            try store(uid: uid, operation: "-FLAGS.SILENT", flags: "(\(removeAtoms.joined(separator: " ")))", expectedModSequence: expectedModSequence)
        }
    }

    func setLabels(uid: Int, add: [String], remove: [String]) throws {
        let addLabels = try Self.labelAtoms(add)
        let removeLabels = try Self.labelAtoms(remove)
        guard !addLabels.isEmpty || !removeLabels.isEmpty,
              Set(addLabels).isDisjoint(with: Set(removeLabels)),
              try capabilities().contains("X-GM-EXT-1")
        else { throw IMAPClientError.protocolError("Gmail label mutation is unavailable.") }
        if !addLabels.isEmpty {
            try store(uid: uid, operation: "+X-GM-LABELS.SILENT", flags: "(\(addLabels.map(Self.quoted).joined(separator: " ")))")
        }
        if !removeLabels.isEmpty {
            try store(uid: uid, operation: "-X-GM-LABELS.SILENT", flags: "(\(removeLabels.map(Self.quoted).joined(separator: " ")))")
        }
    }

    func archive(uid: Int, archiveMailbox: String) throws {
        let copyResponse = try command("UID COPY \(uid) \(archiveMailbox)")
        guard copyResponse.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(copyResponse.taggedLine)
        }
        try delete(uid: uid)
    }

    func move(uid: Int, to mailbox: String) throws -> IMAPMoveResult {
        try Self.validateMailboxName(mailbox)
        let serverCapabilities = try capabilities()
        let destination = Self.quotedMailbox(mailbox)
        if serverCapabilities.contains("MOVE") {
            // RFC 6851: one atomic command; COPYUID comes untagged before the
            // EXPUNGE responses (or on the tagged OK).
            let response = try command("UID MOVE \(uid) \(destination)")
            guard Self.isTaggedOK(response.taggedLine) else {
                throw IMAPClientError.protocolError(response.taggedLine)
            }
            return Self.moveResult(mailbox: mailbox, sourceUID: uid, lines: response.untaggedLines + [response.taggedLine])
        }
        // Without MOVE the copy must be followed by an exact UID EXPUNGE.
        // Refuse before copying when UIDPLUS is missing, so no half-done move.
        guard serverCapabilities.contains("UIDPLUS") else {
            throw IMAPClientError.protocolError("UID MOVE and UID EXPUNGE are unavailable.")
        }
        let copy = try command("UID COPY \(uid) \(destination)")
        guard Self.isTaggedOK(copy.taggedLine) else {
            throw IMAPClientError.protocolError(copy.taggedLine)
        }
        try delete(uid: uid)
        return Self.moveResult(mailbox: mailbox, sourceUID: uid, lines: copy.untaggedLines + [copy.taggedLine])
    }

    private static func isTaggedOK(_ taggedLine: String) -> Bool {
        let parts = taggedLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        return parts.count >= 2 && parts[1].uppercased() == "OK"
    }

    private static func moveResult(mailbox: String, sourceUID: Int, lines: [String]) -> IMAPMoveResult {
        IMAPMoveResult.parsingCopyUID(mailbox: mailbox, sourceUID: sourceUID, lines: lines)
    }

    func delete(uid: Int) throws {
        try store(uid: uid, operation: "+FLAGS.SILENT", flags: "(\\Deleted)")
        // A bare EXPUNGE removes every message already marked \Deleted in
        // the selected mailbox. Require UIDPLUS and expunge exactly the UID
        // we just marked so another client's deletion can never be widened.
        guard try capabilities().contains("UIDPLUS") else {
            throw IMAPClientError.protocolError("UID EXPUNGE is unavailable.")
        }
        let expungeResponse = try command("UID EXPUNGE \(uid)")
        guard expungeResponse.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(expungeResponse.taggedLine)
        }
    }

    func appendMessage(to mailbox: String, flags: [String], data: String) throws -> IMAPAppendResult {
        try Self.validateMailboxName(mailbox)
        let flagsExpression = "(\(flags.joined(separator: " ")))"
        let byteCount = data.utf8.count
        let command = "APPEND \(Self.quotedMailbox(mailbox)) \(flagsExpression) {\(byteCount)}"
        let response = try appendCommand(command, data: data)
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
        return IMAPAppendResult(mailbox: mailbox, uid: Self.appendUID(from: response.taggedLine))
    }

    private static func appendUID(from taggedLine: String) -> Int? {
        guard let markerRange = taggedLine.range(of: "[APPENDUID ", options: .caseInsensitive),
              let close = taggedLine[markerRange.upperBound...].firstIndex(of: "]")
        else {
            return nil
        }
        let content = taggedLine[markerRange.upperBound..<close]
        let parts = content.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        return Int(parts[1])
    }

    private static func validateMailboxName(_ mailbox: String) throws {
        if mailbox.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw IMAPClientError.protocolError("Mailbox names cannot contain control characters.")
        }
    }

    private static func quotedMailbox(_ mailbox: String) -> String {
        let escaped = mailbox
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static let mutableFlagAtoms: Set<String> = ["\\Seen", "\\Answered", "\\Flagged", "\\Draft", "\\Deleted"]

    private static func flagAtoms(_ values: [String]) throws -> [String] {
        let atoms = values.sorted()
        guard Set(atoms).count == atoms.count, Set(atoms).isSubset(of: mutableFlagAtoms) else {
            throw IMAPClientError.protocolError("Invalid flags.")
        }
        return atoms
    }

    private static func labelAtoms(_ values: [String]) throws -> [String] {
        let labels = values.sorted()
        guard Set(labels).count == labels.count,
              labels.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) })
        else { throw IMAPClientError.protocolError("Invalid Gmail labels.") }
        return labels
    }

    private func store(uid: Int, operation: String, flags: String, expectedModSequence: Int? = nil) throws {
        let condition = expectedModSequence.map { " (UNCHANGEDSINCE \($0))" } ?? ""
        let response = try command("UID STORE \(uid)\(condition) \(operation) \(flags)")
        guard response.taggedLine.contains("OK") else {
            throw IMAPClientError.protocolError(response.taggedLine)
        }
    }

    private func command(_ command: String) throws -> IMAPTaggedResponse {
        let socket = try connectIfNeeded()
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try socket.writeLine("\(tag) \(command)")
        return try readTaggedResponse(socket, tag: tag)
    }

    private func appendCommand(_ command: String, data: String) throws -> IMAPTaggedResponse {
        let socket = try connectIfNeeded()
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try socket.writeLine("\(tag) \(command)")

        let continuation = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
        guard continuation.hasPrefix("+") else {
            throw IMAPClientError.protocolError(continuation)
        }
        try socket.writeRaw(data + "\r\n")

        return try readTaggedResponse(socket, tag: tag)
    }

    private func readTaggedResponse(_ socket: IMAPLineSocket, tag: String) throws -> IMAPTaggedResponse {
        var untagged: [String] = []
        var responseLines = 0
        var nonliteralBytes = 0
        do {
            while true {
                let response = try readCommandResponseLine(socket)
                responseLines += response.physicalLines
                nonliteralBytes += response.nonliteralBytes
                guard responseLines <= Self.maximumResponseLines,
                      nonliteralBytes <= Self.maximumNonliteralResponseBytes
                else { throw IMAPClientError.resourceLimit }
                if response.line.hasPrefix("\(tag) ") {
                    return IMAPTaggedResponse(tag: tag, untaggedLines: untagged, taggedLine: response.line)
                }
                untagged.append(response.line)
            }
        } catch {
            socket.close()
            clearSocket(ifIdenticalTo: socket)
            throw error
        }
    }

    private func readCommandResponseLine(
        _ socket: IMAPLineSocket
    ) throws -> (line: String, nonliteralBytes: Int, physicalLines: Int) {
        let line = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
        guard let literalBytes = Self.literalByteCount(from: line) else {
            return (line, line.utf8.count + 2, 1)
        }
        guard literalBytes <= Self.maximumCommandLiteralBytes else {
            throw IMAPClientError.resourceLimit
        }
        let literal = try socket.readBytes(count: literalBytes)
        let tail = try socket.readLine(maximumBytes: Self.maximumResponseLineBytes)
        let nonliteralBytes = line.utf8.count + tail.utf8.count + 4
        guard nonliteralBytes <= Self.maximumNonliteralResponseBytes else {
            throw IMAPClientError.resourceLimit
        }
        let prefix = String(line[..<line.index(line.endIndex, offsetBy: -1)])
        let openingBrace = prefix.lastIndex(of: "{")!
        return (
            String(prefix[..<openingBrace]) + String(decoding: literal, as: UTF8.self) + tail,
            nonliteralBytes,
            2
        )
    }

    private func connectIfNeeded() throws -> IMAPLineSocket {
        socketStateLock.lock()
        if let socket = self.socket {
            socketStateLock.unlock()
            return socket
        }
        socketStateLock.unlock()

        // The provider applies the read timeout before its first read (a
        // STARTTLS provider reads the greeting and the STARTTLS reply).
        let connectedSocket = try socketProvider.connect(readTimeout: commandTimeout)
        socketStateLock.lock()
        if let existing = self.socket {
            socketStateLock.unlock()
            connectedSocket.close()
            return existing
        }
        self.socket = connectedSocket
        socketStateLock.unlock()
        return connectedSocket
    }

    private func clearSocket(ifIdenticalTo candidate: IMAPLineSocket) {
        socketStateLock.lock()
        if let socket = self.socket, socket === candidate { self.socket = nil }
        socketStateLock.unlock()
    }

}

private protocol IMAPSocketProvider {
    /// Connects with `readTimeout` applied before any read, and uses it to
    /// bound the wait for the streams to open.
    func connect(readTimeout: TimeInterval) throws -> IMAPLineSocket
}

private struct PlaintextIMAPSocketProvider: IMAPSocketProvider {
    let host: String
    let port: UInt16

    func connect(readTimeout: TimeInterval) throws -> IMAPLineSocket {
        try MailTransportSecurityPolicy.validateCleartextHarnessHost(host)
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IMAPClientError.connectionFailed
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw IMAPClientError.connectionFailed
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw IMAPClientError.connectionFailed
        }

        let socket = LineSocket(fd: fd)
        do {
            try socket.setReadTimeout(readTimeout)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }
}

private struct TLSIMAPSocketProvider: IMAPSocketProvider {
    let host: String
    let port: UInt16
    let certificateValidation: SecureIMAPClient.CertificateValidation

    func connect(readTimeout: TimeInterval) throws -> IMAPLineSocket {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw IMAPClientError.connectionFailed
        }

        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

        let sslSettingsKey = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        let sslSettings = MailTLSSettings.sslSettings(
            host: host,
            certificateValidation: certificateValidation.mailTLSValidation
        )
        input.setProperty(sslSettings, forKey: sslSettingsKey)
        output.setProperty(sslSettings, forKey: sslSettingsKey)

        input.open()
        output.open()
        // A read issued while an SSL stream is still opening can block
        // forever when the connection fails (a refused or unreachable
        // port): wait, bounded, until the streams have opened or failed.
        do {
            try imapAwaitStreamsOpened(input, output, tlsActive: true, timeout: readTimeout)
        } catch {
            input.close()
            output.close()
            throw error
        }

        let socket = TLSLineSocket(input: input, output: output, tlsActive: true, host: host, certificateValidation: certificateValidation)
        try socket.setReadTimeout(readTimeout)
        return socket
    }
}

private struct StartTLSIMAPSocketProvider: IMAPSocketProvider {
    let host: String
    let port: UInt16
    let certificateValidation: SecureIMAPClient.CertificateValidation

    func connect(readTimeout: TimeInterval) throws -> IMAPLineSocket {
        if case .testAnchor = certificateValidation { throw IMAPClientError.tlsFailed }
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw IMAPClientError.connectionFailed
        }

        input.open()
        output.open()
        // The plaintext leg can block on its first read too while a refused
        // connection is still opening: the same bounded wait.
        do {
            try imapAwaitStreamsOpened(input, output, tlsActive: false, timeout: readTimeout)
        } catch {
            input.close()
            output.close()
            throw error
        }

        let socket = TLSLineSocket(input: input, output: output, tlsActive: false)
        do {
            // Before the first read: a server that accepts and then stays
            // silent must time out, not hang on the greeting or the STARTTLS
            // reply.
            try socket.setReadTimeout(readTimeout)
            let greeting = try socket.readLine()
            guard greeting.hasPrefix("* OK") else {
                throw IMAPClientError.protocolError(greeting)
            }

            try socket.writeLine("A000 STARTTLS")
            let response = try socket.readLine()
            guard response.hasPrefix("A000 OK") else {
                throw IMAPClientError.protocolError(response)
            }

            try upgrade(input: input, output: output, socket: socket)
            return QueuedIMAPLineSocket(firstLine: greeting, socket: socket)
        } catch {
            socket.close()
            throw error
        }
    }

    private func upgrade(input: InputStream, output: OutputStream, socket: TLSLineSocket) throws {
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

        let sslSettingsKey = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        let sslSettings = MailTLSSettings.sslSettings(
            host: host,
            certificateValidation: certificateValidation.mailTLSValidation
        )
        input.setProperty(sslSettings, forKey: sslSettingsKey)
        output.setProperty(sslSettings, forKey: sslSettingsKey)

        socket.tlsActive = true
        for stream in [input as Stream, output as Stream] where stream.streamStatus == .error {
            throw imapStreamFailure(stream, tlsActive: true)
        }
    }
}

private struct IMAPTaggedResponse {
    let tag: String
    let untaggedLines: [String]
    let taggedLine: String
}

private protocol IMAPLineSocket: AnyObject {
    func writeLine(_ line: String) throws
    func writeRaw(_ string: String) throws
    func readLine(maximumBytes: Int?) throws -> String
    func readBytes(count: Int) throws -> Data
    func setReadTimeout(_ seconds: TimeInterval?) throws
    func interrupt()
    func close()
}

private extension IMAPLineSocket {
    func readLine() throws -> String {
        try readLine(maximumBytes: nil)
    }
}

private final class LineSocket: IMAPLineSocket {
    private var fd: Int32
    private let closeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    func writeLine(_ line: String) throws {
        try writeRaw(line + "\r\n")
    }

    func writeRaw(_ string: String) throws {
        let bytes = Array(string.utf8)
        try bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard result > 0 else {
                    throw IMAPClientError.connectionFailed
                }
                sent += result
            }
        }
    }

    func readLine(maximumBytes: Int?) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var bytesRead = 0
        while true {
            let count = Darwin.recv(fd, &byte, 1, 0)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw IMAPClientError.timedOut
            }
            guard count == 1 else {
                throw IMAPClientError.connectionFailed
            }
            bytesRead += 1
            if let maximumBytes, bytesRead > maximumBytes {
                throw IMAPClientError.resourceLimit
            }
            if byte == 10 {
                if bytes.last == 13 {
                    bytes.removeLast()
                }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
    }

    func readBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress!.advanced(by: received), count - received, 0)
            }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw IMAPClientError.timedOut
            }
            guard result > 0 else {
                throw IMAPClientError.connectionFailed
            }
            received += result
        }
        return Data(bytes)
    }

    func setReadTimeout(_ seconds: TimeInterval?) throws {
        try Self.setReadTimeout(seconds, fileDescriptor: fd)
    }

    fileprivate static func setReadTimeout(_ seconds: TimeInterval?, fileDescriptor: Int32) throws {
        let value = max(0, seconds ?? 0)
        var timeout = timeval(
            tv_sec: Int(value.rounded(.down)),
            tv_usec: Int32((value - value.rounded(.down)) * 1_000_000)
        )
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw IMAPClientError.connectionFailed
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }

    func interrupt() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}

private final class TLSLineSocket: IMAPLineSocket {
    private let input: InputStream
    private let output: OutputStream
    private let testAnchor: (host: String, certificate: Data)?
    private var didValidateTestAnchor = false
    private let closeLock = NSLock()
    private let readTimeoutLock = NSLock()
    private var isClosed = false
    private var pendingReadTimeout: TimeInterval?
    private var activeReadID = 0
    private var timedOutReadID: Int?
    /// False on a STARTTLS socket's plaintext leg: any failure there is the
    /// network. Once TLS is in play the stream's error decides.
    var tlsActive: Bool
    /// True once a byte was read through TLS: the handshake completed.
    private var handshakeCompleted = false

    init(input: InputStream, output: OutputStream, tlsActive: Bool, host: String? = nil, certificateValidation: SecureIMAPClient.CertificateValidation = .systemTrust) {
        self.input = input
        self.output = output
        self.tlsActive = tlsActive
        if case .testAnchor(let certificate) = certificateValidation, let host {
            testAnchor = (host, certificate)
        } else {
            testAnchor = nil
        }
    }

    private func failure(_ stream: Stream) -> IMAPClientError {
        imapStreamFailure(stream, tlsActive: tlsActive, handshakeCompleted: handshakeCompleted)
    }

    func writeLine(_ line: String) throws {
        try writeRaw(line + "\r\n")
    }

    func writeRaw(_ string: String) throws {
        let bytes = Array(string.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                output.write(
                    buffer.baseAddress!.advanced(by: sent).assumingMemoryBound(to: UInt8.self),
                    maxLength: bytes.count - sent
                )
            }
            if count < 0 {
                throw failure(output)
            }
            guard count > 0 else {
                throw IMAPClientError.connectionFailed
            }
            sent += count
        }
    }

    func readLine(maximumBytes: Int?) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var bytesRead = 0
        while true {
            applyPendingReadTimeoutIfPossible()
            let count = try read(&byte, maxLength: 1)
            if count < 0 {
                if Self.isTimeout(input.streamError) { throw IMAPClientError.timedOut }
                throw failure(input)
            }
            guard count == 1 else {
                throw IMAPClientError.connectionFailed
            }
            if tlsActive { handshakeCompleted = true }
            if !didValidateTestAnchor {
                if let testAnchor, !MailTLSSettings.validateTestAnchor(testAnchor.certificate, host: testAnchor.host, input: input) {
                    throw IMAPClientError.tlsFailed
                }
                didValidateTestAnchor = true
            }
            bytesRead += 1
            if let maximumBytes, bytesRead > maximumBytes {
                throw IMAPClientError.resourceLimit
            }
            if byte == 10 {
                if bytes.last == 13 {
                    bytes.removeLast()
                }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
    }

    func readBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            applyPendingReadTimeoutIfPossible()
            let result = try bytes.withUnsafeMutableBytes { buffer in
                try read(
                    buffer.baseAddress!.advanced(by: received).assumingMemoryBound(to: UInt8.self),
                    maxLength: count - received
                )
            }
            if result < 0 {
                if Self.isTimeout(input.streamError) { throw IMAPClientError.timedOut }
                throw failure(input)
            }
            guard result > 0 else {
                throw IMAPClientError.connectionFailed
            }
            if tlsActive { handshakeCompleted = true }
            received += result
        }
        return Data(bytes)
    }

    private func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        guard let timeout = pendingReadTimeout, timeout > 0 else {
            return input.read(buffer, maxLength: maxLength)
        }

        let readID = beginTimedRead()
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.interruptTimedRead(id: readID)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let count = input.read(buffer, maxLength: maxLength)
        timeoutWork.cancel()
        if endTimedRead(id: readID) {
            throw IMAPClientError.timedOut
        }
        return count
    }

    private func beginTimedRead() -> Int {
        readTimeoutLock.lock()
        defer { readTimeoutLock.unlock() }
        activeReadID += 1
        timedOutReadID = nil
        return activeReadID
    }

    private func interruptTimedRead(id: Int) {
        readTimeoutLock.lock()
        guard activeReadID == id else {
            readTimeoutLock.unlock()
            return
        }
        timedOutReadID = id
        readTimeoutLock.unlock()
        interrupt()
    }

    private func endTimedRead(id: Int) -> Bool {
        readTimeoutLock.lock()
        defer { readTimeoutLock.unlock() }
        let didTimeOut = timedOutReadID == id
        if activeReadID == id {
            activeReadID = 0
        }
        return didTimeOut
    }

    func setReadTimeout(_ seconds: TimeInterval?) throws {
        pendingReadTimeout = seconds
        applyPendingReadTimeoutIfPossible()
    }

    private func applyPendingReadTimeoutIfPossible() {
        let key = Stream.PropertyKey(rawValue: CFStreamPropertyKey.socketNativeHandle.rawValue as String)
        guard let data = input.property(forKey: key) as? Data,
              data.count >= MemoryLayout<Int32>.size else {
            return
        }
        var fileDescriptor: Int32 = -1
        _ = withUnsafeMutableBytes(of: &fileDescriptor) { data.copyBytes(to: $0) }
        try? LineSocket.setReadTimeout(pendingReadTimeout, fileDescriptor: fileDescriptor)
    }

    private static func isTimeout(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return errno == EAGAIN || errno == EWOULDBLOCK }
        return error.domain == NSPOSIXErrorDomain && (error.code == Int(EAGAIN) || error.code == Int(EWOULDBLOCK))
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        input.close()
        output.close()
    }

    func interrupt() {
        let key = Stream.PropertyKey(rawValue: CFStreamPropertyKey.socketNativeHandle.rawValue as String)
        guard let data = input.property(forKey: key) as? Data,
              data.count >= MemoryLayout<Int32>.size else {
            input.close()
            output.close()
            return
        }
        var fileDescriptor: Int32 = -1
        _ = withUnsafeMutableBytes(of: &fileDescriptor) { data.copyBytes(to: $0) }
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }
}

private final class QueuedIMAPLineSocket: IMAPLineSocket {
    private var queuedLines: [String]
    private let socket: IMAPLineSocket

    init(firstLine: String, socket: IMAPLineSocket) {
        queuedLines = [firstLine]
        self.socket = socket
    }

    func writeLine(_ line: String) throws {
        try socket.writeLine(line)
    }

    func writeRaw(_ string: String) throws {
        try socket.writeRaw(string)
    }

    func readLine(maximumBytes: Int?) throws -> String {
        if !queuedLines.isEmpty {
            let line = queuedLines.removeFirst()
            if let maximumBytes, line.utf8.count + 2 > maximumBytes {
                throw IMAPClientError.resourceLimit
            }
            return line
        }
        return try socket.readLine(maximumBytes: maximumBytes)
    }

    func readBytes(count: Int) throws -> Data {
        try socket.readBytes(count: count)
    }

    func setReadTimeout(_ seconds: TimeInterval?) throws {
        try socket.setReadTimeout(seconds)
    }

    func interrupt() {
        socket.interrupt()
    }

    func close() {
        socket.close()
    }
}

/// What a failed IMAP stream read, write or open means, by the stream
/// error's domain (the rule the SMTP TLS sockets use): a POSIX, CFNetwork
/// host/connect or URL error (refused, unreachable, DNS) is the network,
/// and an SSL or other OSStatus (trust, unknown) is TLS. After the handshake
/// completed, an abortive close of the TLS session is the network too.
func imapStreamErrorClass(domain: String, code: Int, handshakeCompleted: Bool = false) -> IMAPClientError {
    switch smtpStreamErrorClass(domain: domain, code: code, handshakeCompleted: handshakeCompleted) {
    case .connectionFailed: return .connectionFailed
    default: return .tlsFailed
    }
}

/// A failed IMAP stream: before TLS is in play any failure is the network;
/// once it is, the stream's error domain decides (`imapStreamErrorClass`).
func imapStreamFailure(_ stream: Stream, tlsActive: Bool, handshakeCompleted: Bool = false) -> IMAPClientError {
    guard tlsActive else { return .connectionFailed }
    guard let error = stream.streamError as NSError? else { return .tlsFailed }
    return imapStreamErrorClass(domain: error.domain, code: error.code, handshakeCompleted: handshakeCompleted)
}

/// Waits until both streams have left `.opening`, for at most `timeout`.
/// A stream that failed to open throws its classified failure; one still
/// opening at the deadline is a connection failure.
func imapAwaitStreamsOpened(
    _ input: InputStream, _ output: OutputStream, tlsActive: Bool, timeout: TimeInterval = 30
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        for stream in [input as Stream, output as Stream] where stream.streamStatus == .error {
            throw imapStreamFailure(stream, tlsActive: tlsActive)
        }
        let opening = [input.streamStatus, output.streamStatus].contains { $0 == .opening || $0 == .notOpen }
        guard opening else { return }
        guard Date() < deadline else { throw IMAPClientError.connectionFailed }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
