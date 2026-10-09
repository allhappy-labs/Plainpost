import Foundation
import Network

/// In-process loopback IMAP and SMTP servers that accept only SASL XOAUTH2.
///
/// The fixture accepts exactly one configured bearer token for one username.
/// A wrong token receives Google's shape of refusal: a continuation carrying a
/// base64 JSON error, then a tagged `NO` (IMAP) or `535` (SMTP) after the
/// client's empty response. The transcript records client lines with every
/// XOAUTH2 payload replaced by `<xoauth2>` once it has been verified, so no
/// token text is retained.
final class XOAUTH2MailFixture: @unchecked Sendable {
    /// Scripted refusals that replace the default Google refusal shape.
    struct Refusals: Sendable {
        /// IMAP tagged text (for example `NO [ALERT] ...`) sent in place of
        /// any error challenge.
        var imapWithoutChallenge: String?
        /// IMAP tagged text sent after the error challenge.
        var imapAfterChallenge: String?
        /// SMTP reply lines sent in place of the `334` error challenge.
        var smtpWithoutChallenge: [String]?
        /// SMTP reply lines sent after the `334` error challenge.
        var smtpAfterChallenge: [String]?
    }

    let imapPort: UInt16
    let smtpPort: Int

    private let state: FixtureState
    private let imapListener: NWListener
    private let smtpListener: NWListener

    private init(state: FixtureState, imapListener: NWListener, smtpListener: NWListener) {
        self.state = state
        self.imapListener = imapListener
        self.smtpListener = smtpListener
        imapPort = imapListener.port?.rawValue ?? 0
        smtpPort = Int(smtpListener.port?.rawValue ?? 0)
    }

    static func start(
        username: String,
        acceptedToken: String,
        advertisesXOAUTH2: Bool = true,
        advertisesSASLIR: Bool = true,
        imapRefusalResponseCode: String? = nil,
        refusals: Refusals = Refusals()
    ) async throws -> XOAUTH2MailFixture {
        let state = FixtureState(
            username: username,
            acceptedToken: acceptedToken,
            advertisesXOAUTH2: advertisesXOAUTH2,
            advertisesSASLIR: advertisesSASLIR,
            imapRefusalResponseCode: imapRefusalResponseCode,
            refusals: refusals
        )
        let imap = try await startListener(queueLabel: "XOAUTH2MailFixture.imap") { connection in
            await IMAPFixtureSession(connection: connection, state: state).run()
        }
        let smtp: NWListener
        do {
            smtp = try await startListener(queueLabel: "XOAUTH2MailFixture.smtp") { connection in
                await SMTPFixtureSession(connection: connection, state: state).run()
            }
        } catch {
            imap.cancel()
            throw error
        }
        return XOAUTH2MailFixture(state: state, imapListener: imap, smtpListener: smtp)
    }

    func stop() {
        imapListener.cancel()
        smtpListener.cancel()
        state.cancelConnections()
    }

    /// Client lines joined by `\n`, with XOAUTH2 payloads redacted.
    var transcript: String { state.transcript }

    var acceptedAuthenticationCount: Int { state.acceptedAuthenticationCount }

    var acceptedMessageCount: Int { state.acceptedMessageCount }

    private static func startListener(
        queueLabel: String,
        session: @escaping @Sendable (FixtureLineConnection) async -> Void
    ) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: queueLabel)
        listener.newConnectionHandler = { connection in
            let line = FixtureLineConnection(connection: connection, queue: queue)
            Task.detached { await session(line) }
        }
        let resume = OnceResume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    resume.run { continuation.resume() }
                case .failed(let error):
                    resume.run { continuation.resume(throwing: error) }
                case .cancelled:
                    resume.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

private final class FixtureState: @unchecked Sendable {
    let username: String
    let acceptedToken: String
    let advertisesXOAUTH2: Bool
    let advertisesSASLIR: Bool
    let imapRefusalResponseCode: String?
    let refusals: XOAUTH2MailFixture.Refusals

    private let lock = NSLock()
    private var lines: [String] = []
    private var accepted = 0
    private var messages = 0
    private var connections: [FixtureLineConnection] = []

    init(username: String, acceptedToken: String, advertisesXOAUTH2: Bool, advertisesSASLIR: Bool,
         imapRefusalResponseCode: String?, refusals: XOAUTH2MailFixture.Refusals) {
        self.username = username
        self.acceptedToken = acceptedToken
        self.advertisesXOAUTH2 = advertisesXOAUTH2
        self.advertisesSASLIR = advertisesSASLIR
        self.imapRefusalResponseCode = imapRefusalResponseCode
        self.refusals = refusals
    }

    var transcript: String { lock.withLock { lines.joined(separator: "\n") } }
    var acceptedAuthenticationCount: Int { lock.withLock { accepted } }
    var acceptedMessageCount: Int { lock.withLock { messages } }

    func record(_ line: String) { lock.withLock { lines.append(line) } }
    func recordAcceptedMessage() { lock.withLock { messages += 1 } }
    func track(_ connection: FixtureLineConnection) { lock.withLock { connections.append(connection) } }

    func cancelConnections() {
        let current = lock.withLock { connections }
        current.forEach { $0.cancel() }
    }

    /// Verifies a base64 SASL XOAUTH2 initial response. The payload is never
    /// stored; callers record `<xoauth2>` in its place.
    func verify(payload: String) -> Bool {
        let expected = Data("user=\(username)\u{01}auth=Bearer \(acceptedToken)\u{01}\u{01}".utf8)
        guard let decoded = Data(base64Encoded: payload), decoded == expected else { return false }
        lock.withLock { accepted += 1 }
        return true
    }

    /// Google's XOAUTH2 error challenge body.
    static let errorChallenge = Data(#"{"status":"401","schemes":"bearer","scope":"https://mail.google.com/"}"#.utf8)
        .base64EncodedString()
}

final class FixtureLineConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
    }

    func cancel() { connection.cancel() }

    func readLine() async -> String? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var lineData = buffer[buffer.startIndex..<newline]
                if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
                let line = String(decoding: lineData, as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard let chunk = await receive() else { return nil }
            buffer.append(chunk)
        }
    }

    func write(_ line: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data("\(line)\r\n".utf8), completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

private struct IMAPFixtureSession {
    let connection: FixtureLineConnection
    let state: FixtureState

    func run() async {
        state.track(connection)
        defer { connection.cancel() }
        var authenticated = false
        await connection.write("* OK XOAUTH2 fixture ready")
        while let line = await connection.readLine() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else {
                state.record(line)
                await connection.write("* BAD missing tag")
                continue
            }
            let tag = parts[0]
            let command = parts[1].uppercased()
            let arguments = parts.count > 2 ? parts[2] : ""
            switch command {
            case "CAPABILITY":
                state.record(line)
                var capabilities = ["IMAP4rev1"]
                if state.advertisesSASLIR { capabilities.append("SASL-IR") }
                if state.advertisesXOAUTH2 { capabilities.append("AUTH=XOAUTH2") }
                await connection.write("* CAPABILITY \(capabilities.joined(separator: " "))")
                await connection.write("\(tag) OK CAPABILITY completed")
            case "AUTHENTICATE":
                guard await authenticate(tag: tag, arguments: arguments) else { continue }
                authenticated = true
            case "SELECT":
                state.record(line)
                guard authenticated else {
                    await connection.write("\(tag) NO not authenticated")
                    continue
                }
                await connection.write("* 0 EXISTS")
                await connection.write("* OK [UIDVALIDITY 1] UIDs valid")
                await connection.write("\(tag) OK [READ-WRITE] SELECT completed")
            case "LIST":
                state.record(line)
                guard authenticated else {
                    await connection.write("\(tag) NO not authenticated")
                    continue
                }
                await connection.write(#"* LIST (\HasNoChildren) "/" "INBOX""#)
                await connection.write("\(tag) OK LIST completed")
            case "UID" where arguments.uppercased().hasPrefix("SEARCH"):
                state.record(line)
                guard authenticated else {
                    await connection.write("\(tag) NO not authenticated")
                    continue
                }
                await connection.write("* SEARCH")
                await connection.write("\(tag) OK SEARCH completed")
            case "NOOP":
                state.record(line)
                await connection.write("\(tag) OK NOOP completed")
            case "LOGOUT":
                state.record(line)
                await connection.write("* BYE logging out")
                await connection.write("\(tag) OK LOGOUT completed")
                return
            case "LOGIN":
                state.record("\(tag) LOGIN <redacted>")
                await connection.write("\(tag) NO LOGIN is disabled")
            default:
                state.record(line)
                await connection.write("\(tag) BAD unsupported command")
            }
        }
    }

    private func authenticate(tag: String, arguments: String) async -> Bool {
        let argumentParts = arguments.split(separator: " ", maxSplits: 1).map(String.init)
        guard state.advertisesXOAUTH2, argumentParts.first?.uppercased() == "XOAUTH2" else {
            state.record("\(tag) AUTHENTICATE \(argumentParts.first ?? "") <redacted>")
            await connection.write("\(tag) NO unsupported mechanism")
            return false
        }
        let payload: String
        if argumentParts.count == 2 {
            guard state.advertisesSASLIR else {
                state.record("\(tag) AUTHENTICATE XOAUTH2 <redacted>")
                await connection.write("\(tag) BAD SASL-IR not advertised")
                return false
            }
            payload = argumentParts[1]
            state.record("\(tag) AUTHENTICATE XOAUTH2 <xoauth2>")
        } else {
            state.record("\(tag) AUTHENTICATE XOAUTH2")
            await connection.write("+ ")
            guard let line = await connection.readLine() else { return false }
            payload = line
            state.record("<xoauth2>")
        }
        if let code = state.imapRefusalResponseCode {
            await connection.write("\(tag) NO [\(code)] temporarily unavailable")
            return false
        }
        if state.verify(payload: payload) {
            await connection.write("\(tag) OK AUTHENTICATE completed")
            return true
        }
        if let refusal = state.refusals.imapWithoutChallenge {
            await connection.write("\(tag) \(refusal)")
            return false
        }
        await connection.write("+ \(FixtureState.errorChallenge)")
        guard let response = await connection.readLine() else { return false }
        guard response.isEmpty else {
            state.record("<unexpected-client-response>")
            await connection.write("\(tag) BAD expected an empty response to the error challenge")
            return false
        }
        state.record("")
        await connection.write("\(tag) \(state.refusals.imapAfterChallenge ?? "NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)")")
        return false
    }
}

private struct SMTPFixtureSession {
    let connection: FixtureLineConnection
    let state: FixtureState

    func run() async {
        state.track(connection)
        defer { connection.cancel() }
        var authenticated = false
        var inEnvelope = false
        await connection.write("220 XOAUTH2 fixture ESMTP")
        while let line = await connection.readLine() {
            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") {
                state.record(line)
                await connection.write("250-xoauth2.fixture")
                if state.advertisesXOAUTH2 {
                    await connection.write("250-AUTH XOAUTH2")
                }
                await connection.write("250 8BITMIME")
            } else if upper.hasPrefix("AUTH XOAUTH2 ") {
                state.record("AUTH XOAUTH2 <xoauth2>")
                guard state.advertisesXOAUTH2 else {
                    await connection.write("504 5.7.4 Unrecognized authentication type")
                    continue
                }
                let payload = String(line.dropFirst("AUTH XOAUTH2 ".count))
                if state.verify(payload: payload) {
                    authenticated = true
                    await connection.write("235 2.7.0 Accepted")
                } else if let refusal = state.refusals.smtpWithoutChallenge {
                    for replyLine in refusal { await connection.write(replyLine) }
                } else {
                    await connection.write("334 \(FixtureState.errorChallenge)")
                    guard let response = await connection.readLine() else { return }
                    guard response.isEmpty else {
                        state.record("<unexpected-client-response>")
                        await connection.write("501 5.5.2 Cannot Decode response")
                        continue
                    }
                    state.record("")
                    for replyLine in state.refusals.smtpAfterChallenge ?? [
                        "535-5.7.8 Username and Password not accepted.",
                        "535 5.7.8 https://support.google.com/mail/?p=BadCredentials",
                    ] {
                        await connection.write(replyLine)
                    }
                }
            } else if upper.hasPrefix("AUTH ") {
                state.record("\(line.split(separator: " ").prefix(2).joined(separator: " ")) <redacted>")
                await connection.write("504 5.7.4 Unrecognized authentication type")
            } else if upper.hasPrefix("MAIL FROM:") {
                state.record(line)
                guard authenticated else {
                    await connection.write("530 5.7.0 Authentication Required")
                    continue
                }
                inEnvelope = true
                await connection.write("250 2.1.0 OK")
            } else if upper.hasPrefix("RCPT TO:") {
                state.record(line)
                await connection.write(inEnvelope ? "250 2.1.5 OK" : "503 5.5.1 MAIL first")
            } else if upper == "DATA" {
                state.record(line)
                guard inEnvelope else {
                    await connection.write("503 5.5.1 MAIL first")
                    continue
                }
                await connection.write("354 Go ahead")
                while let dataLine = await connection.readLine(), dataLine != "." {}
                state.record("<data>")
                state.recordAcceptedMessage()
                inEnvelope = false
                await connection.write("250 2.0.0 OK")
            } else if upper == "RSET" {
                state.record(line)
                inEnvelope = false
                await connection.write("250 2.0.0 OK")
            } else if upper == "QUIT" {
                state.record(line)
                await connection.write("221 2.0.0 closing connection")
                return
            } else {
                state.record(line)
                await connection.write("502 5.5.2 Command not recognized")
            }
        }
    }
}
