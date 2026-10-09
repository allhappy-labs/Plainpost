import Darwin
import Foundation

public protocol SMTPClientProtocol: Sendable {
    func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws

    /// Sends with a password (`AUTH PLAIN`) or an OAuth access token
    /// (`AUTH XOAUTH2`). XOAUTH2 failures surface as `MailAuthenticationError`.
    func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws
}

public extension SMTPClientProtocol {
    /// Password-only default for test doubles: XOAUTH2 is unavailable.
    func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        switch authentication {
        case .password(let password):
            try await send(username: username, password: password, from: from, to: recipients, data: data)
        case .xoauth2:
            throw MailAuthenticationError.mechanismUnavailable
        }
    }
}

public enum SMTPClientError: Error, Equatable, Sendable {
    case connectionFailed
    case tlsFailed
    case authenticationFailed
    /// A server response exceeded the bounded SMTP framing budget.
    case resourceLimit
    /// An address or header requires SMTPUTF8 but the authenticated server
    /// capability snapshot did not advertise it. No envelope bytes were sent.
    case smtpUTF8Unavailable
    /// The server may have accepted DATA, but the final reply was lost. This
    /// is deliberately not retryable by the client because resubmission can
    /// duplicate a delivered message.
    case deliveryUncertain
    case recipientRejected(EmailAddress, code: Int, message: String)
    /// An unexpected server reply. Out of `send`, the SMTP clients report it
    /// only for the final reply after the message content was transmitted
    /// (every earlier reply becomes `.refusedBeforeData`), so the server may
    /// have accepted the message.
    case unexpectedResponse(String)
    /// The server refused (greeting, EHLO, STARTTLS, AUTH, MAIL FROM, RCPT
    /// or the DATA command) before any message content was on the wire:
    /// nothing can have been delivered.
    case refusedBeforeData(String)
    /// The connection could not be made or dropped before any message
    /// content was on the wire: nothing can have been delivered.
    case unreachableBeforeData
}

/// Runs a step that happens before the message content is on the wire. A
/// dropped connection or an unexpected reply there is a definite refusal:
/// the server never received the message.
func smtpBeforeData<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as SMTPClientError {
        switch error {
        case .connectionFailed:
            throw SMTPClientError.unreachableBeforeData
        case .unexpectedResponse(let raw):
            throw SMTPClientError.refusedBeforeData(raw)
        case .tlsFailed, .authenticationFailed, .resourceLimit, .smtpUTF8Unavailable, .deliveryUncertain,
             .recipientRejected, .refusedBeforeData, .unreachableBeforeData:
            throw error
        }
    }
}

public enum MailTransportClientFactory {
    public static func smtpClient(host: String, port: Int) -> SMTPClientProtocol {
        if MailTransportSecurityPolicy.isLoopback(host) {
            return PlaintextSMTPClient(host: host, port: port)
        }
        if port == 465 {
            return SecureSMTPClient(host: host, port: port)
        }
        if port == 587 {
            return StartTLSSMTPClient(host: host, port: port)
        }
        return UnsupportedSMTPSecurityClient()
    }
}

public struct UnsupportedSMTPSecurityClient: SMTPClientProtocol {
    public init() {}

    public func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        throw PlainpostError.validationFailed("Secure SMTP transport is not implemented for this port.")
    }

    public func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        throw PlainpostError.validationFailed("Secure SMTP transport is not implemented for this port.")
    }
}

public struct SecureSMTPClient: SMTPClientProtocol {
    public enum CertificateValidation: Sendable {
        case systemTrust
        case disabledForLocalTesting
        /// Explicit fixture trust; the hostname is still validated.
        case testAnchor(Data)
    }

    public let host: String
    public let port: Int
    public let certificateValidation: CertificateValidation
    /// How long any reply may take, from the greeting on (the final reply
    /// to the message content gets at least `smtpFinalReplyTimeout`).
    public var readTimeout: TimeInterval = smtpReadTimeout

    public init(
        host: String,
        port: Int,
        certificateValidation: CertificateValidation = .systemTrust
    ) {
        self.host = host
        self.port = port
        self.certificateValidation = certificateValidation
    }

    public func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await send(username: username, authentication: .password(password), from: from, to: recipients, data: data)
    }

    public func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await Task.detached {
            let connection = try smtpBeforeData {
                try TLSSMTPSocket.connect(
                    host: host,
                    port: port,
                    certificateValidation: certificateValidation,
                    readTimeout: readTimeout
                )
            }
            defer { connection.close() }

            let capabilityResponse = try smtpBeforeData { () throws -> SMTPResponse in
                try connection.expectResponse(code: 220)
                try connection.writeLine("EHLO plainpost.local")
                let capabilityResponse = try connection.readResponse()
                guard capabilityResponse.code == 250 else {
                    throw SMTPClientError.unexpectedResponse(capabilityResponse.raw)
                }
                return capabilityResponse
            }
            try performSMTPSubmission(
                connection: connection,
                capabilities: capabilityResponse,
                username: username,
                authentication: authentication,
                from: from,
                recipients: recipients,
                data: data
            )
        }.value
    }
}

public struct StartTLSSMTPClient: SMTPClientProtocol {
    public let host: String
    public let port: Int
    public let certificateValidation: SecureSMTPClient.CertificateValidation
    /// How long any reply may take, from the greeting on (the final reply
    /// to the message content gets at least `smtpFinalReplyTimeout`).
    public var readTimeout: TimeInterval = smtpReadTimeout

    public init(
        host: String,
        port: Int,
        certificateValidation: SecureSMTPClient.CertificateValidation = .systemTrust
    ) {
        self.host = host
        self.port = port
        self.certificateValidation = certificateValidation
    }

    public func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await send(username: username, authentication: .password(password), from: from, to: recipients, data: data)
    }

    public func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        if case .testAnchor = certificateValidation { throw SMTPClientError.tlsFailed }
        try await Task.detached {
            let connection = try smtpBeforeData { try StartTLSSMTPSocket.connect(host: host, port: port, readTimeout: readTimeout) }
            defer { connection.close() }

            let capabilityResponse = try smtpBeforeData { () throws -> SMTPResponse in
                try connection.expectResponse(code: 220)
                try connection.writeLine("EHLO plainpost.local")
                try connection.expectResponse(code: 250)
                try connection.writeLine("STARTTLS")
                try connection.expectResponse(code: 220)
                try connection.startTLS(host: host, certificateValidation: certificateValidation)
                try connection.writeLine("EHLO plainpost.local")
                let capabilityResponse = try connection.readResponse()
                guard capabilityResponse.code == 250 else {
                    throw SMTPClientError.unexpectedResponse(capabilityResponse.raw)
                }
                return capabilityResponse
            }
            try performSMTPSubmission(
                connection: connection,
                capabilities: capabilityResponse,
                username: username,
                authentication: authentication,
                from: from,
                recipients: recipients,
                data: data
            )
        }.value
    }
}

public struct PlaintextSMTPClient: SMTPClientProtocol {
    public let host: String
    public let port: Int
    /// How long any reply may take, from the greeting on (the final reply
    /// to the message content gets at least `smtpFinalReplyTimeout`).
    public var readTimeout: TimeInterval = smtpReadTimeout

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await send(username: username, authentication: .password(password), from: from, to: recipients, data: data)
    }

    public func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await Task.detached {
            try MailTransportSecurityPolicy.validateCleartextHarnessHost(host)
            let connection = try smtpBeforeData { try PlaintextSMTPSocket.connect(host: host, port: port, readTimeout: readTimeout) }
            defer { connection.close() }

            let capabilityResponse = try smtpBeforeData { () throws -> SMTPResponse in
                try connection.expectResponse(code: 220)
                try connection.writeLine("EHLO plainpost.local")
                let capabilityResponse = try connection.readResponse()
                guard capabilityResponse.code == 250 else {
                    throw SMTPClientError.unexpectedResponse(capabilityResponse.raw)
                }
                return capabilityResponse
            }
            try performSMTPSubmission(
                connection: connection,
                capabilities: capabilityResponse,
                username: username,
                authentication: authentication,
                from: from,
                recipients: recipients,
                data: data
            )
        }.value
    }
}

/// A reply that takes longer is a network failure: before DATA nothing was
/// sent (`unreachableBeforeData`), after it the delivery is uncertain.
/// RFC 5321 (4.5.3.2) suggests 5 minutes for the greeting and commands.
public let smtpReadTimeout: TimeInterval = 300
/// RFC 5321 suggests 10 minutes for the reply to the message content.
public let smtpFinalReplyTimeout: TimeInterval = 600

private protocol SMTPLineConnection: AnyObject {
    var readTimeout: TimeInterval { get set }
    func readResponse() throws -> SMTPResponse
    func expectResponse(code expectedCode: Int) throws
    func writeLine(_ line: String) throws
    func writeDataBlock(_ data: String) throws
}

extension PlaintextSMTPSocket: SMTPLineConnection {}
extension TLSSMTPSocket: SMTPLineConnection {}
extension StartTLSSMTPSocket: SMTPLineConnection {}

/// Authenticates and submits one message on an established, post-EHLO
/// connection. Delivery is final at the DATA 250 reply; QUIT is cleanup only.
private func performSMTPSubmission(
    connection: SMTPLineConnection,
    capabilities capabilityResponse: SMTPResponse,
    username: String,
    authentication: MailAuthentication,
    from: EmailAddress,
    recipients: [EmailAddress],
    data: String
) throws {
    let smtpUTF8 = supportsSMTPUTF8(capabilityResponse)

    try smtpBeforeData {
    switch authentication {
    case .password(let password):
        let authValue = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
        try connection.writeLine("AUTH PLAIN \(authValue)")
        // A failure to read the reply (the connection dropped, a TLS error)
        // is not a credential refusal; before DATA it is reported as such.
        let reply = try connection.readResponse()
        if reply.code != 235 {
            try? connection.writeLine("QUIT")
            // A 4xx reply (for example `454 4.7.0` login throttling) is
            // temporary; any other refusal is the credential.
            if (400..<500).contains(reply.code) { throw MailAuthenticationError.temporarilyRefused }
            throw SMTPClientError.authenticationFailed
        }
    case .xoauth2(let accessToken):
        try authenticateXOAUTH2(
            connection: connection,
            capabilities: capabilityResponse,
            username: username,
            accessToken: accessToken
        )
    }
    }

    do {
        // Everything up to the DATA command's 354 happens before the
        // message content is on the wire: a failure there is a refusal.
        try smtpBeforeData {
        let needsSMTPUTF8 = requiresSMTPUTF8(from: from, recipients: recipients, data: data)
        guard !needsSMTPUTF8 || smtpUTF8 else { throw SMTPClientError.smtpUTF8Unavailable }
        try connection.writeLine("MAIL FROM:<\(from.rawValue)>\(needsSMTPUTF8 ? " SMTPUTF8" : "")")
        try connection.expectResponse(code: 250)

        for recipient in recipients {
            try connection.writeLine("RCPT TO:<\(recipient.rawValue)>")
            let response = try connection.readResponse()
            if response.code == 550 {
                try? connection.writeLine("RSET")
                try? connection.expectResponse(code: 250)
                throw SMTPClientError.recipientRejected(
                    recipient,
                    code: response.code,
                    message: response.message
                )
            }
            guard response.code == 250 else {
                try? connection.writeLine("RSET")
                try? connection.expectResponse(code: 250)
                throw SMTPClientError.unexpectedResponse(response.raw)
            }
        }

        try connection.writeLine("DATA")
        try connection.expectResponse(code: 354)
        }
        do {
            try connection.writeDataBlock(data)
        } catch {
            throw SMTPClientError.deliveryUncertain
        }
        let finalResponse: SMTPResponse
        connection.readTimeout = max(connection.readTimeout, smtpFinalReplyTimeout)
        do {
            finalResponse = try connection.readResponse()
        } catch {
            throw SMTPClientError.deliveryUncertain
        }
        guard finalResponse.code == 250 else {
            throw SMTPClientError.unexpectedResponse(finalResponse.raw)
        }
        // Delivery is final at the 250 response. QUIT is cleanup
        // only: a dropped cleanup reply must never downgrade it.
        try? connection.writeLine("QUIT")
        try? connection.expectResponse(code: 221)
    } catch {
        try? connection.writeLine("QUIT")
        throw error
    }
}

/// SASL XOAUTH2 over SMTP. The token is sent only when EHLO advertises the
/// mechanism. A `334` reply is Google's base64 JSON error challenge: the
/// client answers with an empty line and the server finishes with `535`.
private func authenticateXOAUTH2(
    connection: SMTPLineConnection,
    capabilities: SMTPResponse,
    username: String,
    accessToken: String
) throws {
    let payload = try XOAUTH2.initialClientResponse(username: username, accessToken: accessToken)
    guard smtpAuthMechanisms(capabilities).contains("XOAUTH2") else {
        try? connection.writeLine("QUIT")
        throw MailAuthenticationError.mechanismUnavailable
    }
    try connection.writeLine("AUTH XOAUTH2 \(payload)")
    var response = try connection.readResponse()
    var challenged = false
    if response.code == 334 {
        challenged = true
        try connection.writeLine("")
        response = try connection.readResponse()
    }
    if response.code == 235 { return }
    try? connection.writeLine("QUIT")
    throw smtpXOAUTH2Refusal(code: response.code, raw: response.raw, challenged: challenged)
}

/// Only a credential refusal may drive token refresh and reauthorization: a
/// `530`/`534`/`535` after Google's `334` error challenge, `535 5.7.8`, or
/// `534 5.7.14`, Gmail's "log in via your web browser" refusal, which arrives
/// without a challenge and never clears by itself. Every 4xx reply (for
/// example `454 4.7.0` login throttling) is temporary.
func smtpXOAUTH2Refusal(code: Int, raw: String, challenged: Bool) -> Error {
    if (400..<500).contains(code) {
        return MailAuthenticationError.temporarilyRefused
    }
    if challenged, [530, 534, 535].contains(code) {
        return MailAuthenticationError.rejected
    }
    if code == 535, smtpReplyCarriesStatus(raw, "5.7.8") {
        return MailAuthenticationError.rejected
    }
    if code == 534, smtpReplyCarriesStatus(raw, "5.7.14") {
        return MailAuthenticationError.rejected
    }
    return SMTPClientError.unexpectedResponse(raw)
}

/// Whether any line of a multi-line reply carries `status` as its RFC 3463
/// enhanced status code, right after the three-digit reply code.
private func smtpReplyCarriesStatus(_ raw: String, _ status: String) -> Bool {
    raw.split(whereSeparator: \.isNewline).contains {
        $0.dropFirst(4).drop(while: { $0 == " " }).hasPrefix(status)
    }
}

private func smtpAuthMechanisms(_ response: SMTPResponse) -> Set<String> {
    var mechanisms = Set<String>()
    for line in response.raw.split(whereSeparator: \.isNewline) {
        let value = line.dropFirst(min(4, line.count))
        let words = value.split(whereSeparator: { $0 == " " || $0 == "=" })
        guard let keyword = words.first, keyword.caseInsensitiveCompare("AUTH") == .orderedSame else { continue }
        words.dropFirst().forEach { mechanisms.insert($0.uppercased()) }
    }
    return mechanisms
}

private struct SMTPResponse {
    let code: Int
    let message: String
    let raw: String
}

private let maximumSMTPResponseLineBytes = 64 * 1024
private let maximumSMTPResponseLines = 65_536
private let maximumSMTPResponseBytes = 8 * 1024 * 1024

private func appendSMTPResponseLine(
    _ line: String,
    lines: inout [String],
    byteCount: inout Int
) throws {
    let nextByteCount = byteCount + line.utf8.count + 2
    guard lines.count < maximumSMTPResponseLines,
          nextByteCount <= maximumSMTPResponseBytes
    else { throw SMTPClientError.resourceLimit }
    lines.append(line)
    byteCount = nextByteCount
}

private func makeSMTPResponse(_ lines: [String]) throws -> SMTPResponse {
    let raw = lines.joined(separator: "\n")
    guard let firstLine = lines.first, firstLine.count >= 3 else {
        throw SMTPClientError.unexpectedResponse(raw)
    }

    let codeText = String(firstLine.prefix(3))
    guard let code = Int(codeText) else {
        throw SMTPClientError.unexpectedResponse(raw)
    }

    let message = lines
        .compactMap { line -> String? in
            guard line.count > 4 else { return nil }
            let start = line.index(line.startIndex, offsetBy: 4)
            return String(line[start...])
        }
        .joined(separator: "\n")

    return SMTPResponse(code: code, message: message, raw: raw)
}

private func supportsSMTPUTF8(_ response: SMTPResponse) -> Bool {
    response.raw
        .split(whereSeparator: \.isNewline)
        .contains { line in
            let value = line.dropFirst(min(4, line.count)).trimmingCharacters(in: .whitespaces)
            return value.caseInsensitiveCompare("SMTPUTF8") == .orderedSame
        }
}

private func requiresSMTPUTF8(from: EmailAddress, recipients: [EmailAddress], data: String) -> Bool {
    let header = data.components(separatedBy: "\r\n\r\n").first ?? data
    return ([from.rawValue] + recipients.map(\.rawValue) + [header])
        .joined()
        .unicodeScalars
        .contains { $0.value > 0x7F }
}

private final class PlaintextSMTPSocket {
    private let fileDescriptor: Int32
    private var isClosed = false
    /// Applied to the socket (`SO_RCVTIMEO`): a stalled read fails.
    var readTimeout: TimeInterval {
        didSet { smtpSetReceiveTimeout(readTimeout, fileDescriptor: fileDescriptor) }
    }

    private init(fileDescriptor: Int32, readTimeout: TimeInterval) {
        self.fileDescriptor = fileDescriptor
        self.readTimeout = readTimeout
        smtpSetReceiveTimeout(readTimeout, fileDescriptor: fileDescriptor)
    }

    static func connect(host: String, port: Int, readTimeout: TimeInterval) throws -> PlaintextSMTPSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SMTPClientError.connectionFailed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw SMTPClientError.connectionFailed
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            throw SMTPClientError.connectionFailed
        }

        return PlaintextSMTPSocket(fileDescriptor: fd, readTimeout: readTimeout)
    }

    func readResponse() throws -> SMTPResponse {
        var lines: [String] = []
        var byteCount = 0

        while true {
            let line = try readLine()
            try appendSMTPResponseLine(line, lines: &lines, byteCount: &byteCount)

            if line.count >= 4 {
                let separatorIndex = line.index(line.startIndex, offsetBy: 3)
                if line[separatorIndex] == " " {
                    break
                }
            }
        }

        return try makeSMTPResponse(lines)
    }

    func expectResponse(code expectedCode: Int) throws {
        let response = try readResponse()
        guard response.code == expectedCode else {
            throw SMTPClientError.unexpectedResponse(response.raw)
        }
    }

    func writeLine(_ line: String) throws {
        try writeBytes(Array("\(line)\r\n".utf8))
    }

    func writeDataBlock(_ data: String) throws {
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let text = line.hasPrefix(".") ? ".\(line)" : String(line)
            try writeLine(text)
        }
        try writeLine(".")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0

        while true {
            let count = recv(fileDescriptor, &byte, 1, 0)
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }

            if byte == UInt8(ascii: "\n") {
                break
            }
            if byte != UInt8(ascii: "\r") {
                bytes.append(byte)
                guard bytes.count <= maximumSMTPResponseLineBytes else {
                    throw SMTPClientError.resourceLimit
                }
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeBytes(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                send(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
            }
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }
            sent += count
        }
    }
}

private final class TLSSMTPSocket {
    private let input: InputStream
    private let output: OutputStream
    private let host: String
    private let certificateValidation: SecureSMTPClient.CertificateValidation
    private var didValidateTestAnchor = false
    private var isClosed = false
    var readTimeout: TimeInterval

    private init(input: InputStream, output: OutputStream, readTimeout: TimeInterval, host: String, certificateValidation: SecureSMTPClient.CertificateValidation) {
        self.input = input
        self.output = output
        self.readTimeout = readTimeout
        self.host = host
        self.certificateValidation = certificateValidation
    }

    static func connect(
        host: String,
        port: Int,
        certificateValidation: SecureSMTPClient.CertificateValidation,
        readTimeout: TimeInterval
    ) throws -> TLSSMTPSocket {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw SMTPClientError.connectionFailed
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
            try smtpAwaitStreamsOpened(input, output, tlsActive: true)
        } catch {
            input.close()
            output.close()
            throw error
        }

        return TLSSMTPSocket(input: input, output: output, readTimeout: readTimeout, host: host, certificateValidation: certificateValidation)
    }

    /// True once a byte was read through TLS: the handshake completed.
    private var handshakeCompleted = false

    func readResponse() throws -> SMTPResponse {
        var lines: [String] = []
        var byteCount = 0

        while true {
            let line = try readLine()
            try appendSMTPResponseLine(line, lines: &lines, byteCount: &byteCount)

            if line.count >= 4 {
                let separatorIndex = line.index(line.startIndex, offsetBy: 3)
                if line[separatorIndex] == " " {
                    break
                }
            }
        }

        return try makeSMTPResponse(lines)
    }

    func expectResponse(code expectedCode: Int) throws {
        let response = try readResponse()
        guard response.code == expectedCode else {
            throw SMTPClientError.unexpectedResponse(response.raw)
        }
    }

    func writeLine(_ line: String) throws {
        try writeBytes(Array("\(line)\r\n".utf8))
    }

    func writeDataBlock(_ data: String) throws {
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let text = line.hasPrefix(".") ? ".\(line)" : String(line)
            try writeLine(text)
        }
        try writeLine(".")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        input.close()
        output.close()
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0

        while true {
            let count = try smtpTimedRead(input, timeout: readTimeout) { input.read(&byte, maxLength: 1) }
            if count < 0 {
                throw smtpStreamFailure(input, tlsActive: true, handshakeCompleted: handshakeCompleted)
            }
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }
            handshakeCompleted = true
            if !didValidateTestAnchor {
                if case .testAnchor(let certificate) = certificateValidation {
                    guard MailTLSSettings.validateTestAnchor(certificate, host: host, input: input) else {
                        throw SMTPClientError.tlsFailed
                    }
                }
                didValidateTestAnchor = true
            }

            if byte == UInt8(ascii: "\n") {
                break
            }
            if byte != UInt8(ascii: "\r") {
                bytes.append(byte)
                guard bytes.count <= maximumSMTPResponseLineBytes else {
                    throw SMTPClientError.resourceLimit
                }
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeBytes(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                output.write(
                    buffer.baseAddress!.advanced(by: sent).assumingMemoryBound(to: UInt8.self),
                    maxLength: bytes.count - sent
                )
            }
            if count < 0 {
                throw smtpStreamFailure(output, tlsActive: true, handshakeCompleted: handshakeCompleted)
            }
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }
            sent += count
        }
    }
}

private final class StartTLSSMTPSocket {
    private let input: InputStream
    private let output: OutputStream
    private var isClosed = false
    /// False until STARTTLS: a stream error on the plaintext leg is a
    /// network failure, never a TLS one.
    private var tlsStarted = false
    /// True once a byte was read after STARTTLS: the handshake completed.
    private var handshakeCompleted = false

    var readTimeout: TimeInterval

    private init(input: InputStream, output: OutputStream, readTimeout: TimeInterval) {
        self.input = input
        self.output = output
        self.readTimeout = readTimeout
    }

    static func connect(host: String, port: Int, readTimeout: TimeInterval) throws -> StartTLSSMTPSocket {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            throw SMTPClientError.connectionFailed
        }

        input.open()
        output.open()
        do {
            try smtpAwaitStreamsOpened(input, output, tlsActive: false)
        } catch {
            input.close()
            output.close()
            throw error
        }

        return StartTLSSMTPSocket(input: input, output: output, readTimeout: readTimeout)
    }

    func startTLS(
        host: String,
        certificateValidation: SecureSMTPClient.CertificateValidation
    ) throws {
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

        let sslSettingsKey = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        let sslSettings = MailTLSSettings.sslSettings(
            host: host,
            certificateValidation: certificateValidation.mailTLSValidation
        )
        input.setProperty(sslSettings, forKey: sslSettingsKey)
        output.setProperty(sslSettings, forKey: sslSettingsKey)
        tlsStarted = true

        guard input.streamStatus != .error, output.streamStatus != .error else {
            throw SMTPClientError.tlsFailed
        }
    }

    func readResponse() throws -> SMTPResponse {
        var lines: [String] = []
        var byteCount = 0

        while true {
            let line = try readLine()
            try appendSMTPResponseLine(line, lines: &lines, byteCount: &byteCount)

            if line.count >= 4 {
                let separatorIndex = line.index(line.startIndex, offsetBy: 3)
                if line[separatorIndex] == " " {
                    break
                }
            }
        }

        return try makeSMTPResponse(lines)
    }

    func expectResponse(code expectedCode: Int) throws {
        let response = try readResponse()
        guard response.code == expectedCode else {
            throw SMTPClientError.unexpectedResponse(response.raw)
        }
    }

    func writeLine(_ line: String) throws {
        try writeBytes(Array("\(line)\r\n".utf8))
    }

    func writeDataBlock(_ data: String) throws {
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let text = line.hasPrefix(".") ? ".\(line)" : String(line)
            try writeLine(text)
        }
        try writeLine(".")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        input.close()
        output.close()
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0

        while true {
            let count = try smtpTimedRead(input, timeout: readTimeout) { input.read(&byte, maxLength: 1) }
            if count < 0 {
                throw smtpStreamFailure(input, tlsActive: tlsStarted, handshakeCompleted: handshakeCompleted)
            }
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }
            if tlsStarted { handshakeCompleted = true }

            if byte == UInt8(ascii: "\n") {
                break
            }
            if byte != UInt8(ascii: "\r") {
                bytes.append(byte)
                guard bytes.count <= maximumSMTPResponseLineBytes else {
                    throw SMTPClientError.resourceLimit
                }
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeBytes(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                output.write(
                    buffer.baseAddress!.advanced(by: sent).assumingMemoryBound(to: UInt8.self),
                    maxLength: bytes.count - sent
                )
            }
            if count < 0 {
                throw smtpStreamFailure(output, tlsActive: tlsStarted, handshakeCompleted: handshakeCompleted)
            }
            guard count > 0 else {
                throw SMTPClientError.connectionFailed
            }
            sent += count
        }
    }
}

/// What a failed SMTP stream read or write means. Before TLS is in play any
/// failure is the network. Once it is, the stream's error decides: a POSIX
/// or CFNetwork host/connect error (refused, unreachable, DNS) is the
/// network, and an SSL error (or anything unknown) is TLS. After the
/// handshake completed, an abortive close of the TLS session is the network
/// too: the peer or a middlebox dropped an established connection.
func smtpStreamFailure(_ stream: Stream, tlsActive: Bool, handshakeCompleted: Bool = false) -> SMTPClientError {
    guard tlsActive else { return .connectionFailed }
    guard let error = stream.streamError as NSError? else { return .tlsFailed }
    return smtpStreamErrorClass(domain: error.domain, code: error.code, handshakeCompleted: handshakeCompleted)
}

/// `errSSLClosedGraceful`, `errSSLClosedAbort` and `errSSLClosedNoNotify`.
private let smtpTLSClosedStatuses: Set<Int> = [-9805, -9806, -9816]

func smtpStreamErrorClass(domain: String, code: Int, handshakeCompleted: Bool = false) -> SMTPClientError {
    let sslStatus = (-9899)...(-9800)
    if handshakeCompleted, smtpTLSClosedStatuses.contains(code),
       domain == NSOSStatusErrorDomain || domain == (kCFErrorDomainCFNetwork as String) {
        // Certificate and handshake failures cannot happen here any more.
        return .connectionFailed
    }
    if domain == NSPOSIXErrorDomain {
        return .connectionFailed
    }
    if domain == (kCFErrorDomainCFNetwork as String) || domain == NSURLErrorDomain {
        // CFNetwork host lookup and socket errors; its TLS errors are the
        // secure-connection range (-1206 … -1200) or SSL statuses.
        if sslStatus.contains(code) || (-1206...(-1200)).contains(code) { return .tlsFailed }
        return .connectionFailed
    }
    if domain == NSOSStatusErrorDomain {
        // SSL and trust statuses (and any unknown OSStatus) are TLS.
        return .tlsFailed
    }
    return .tlsFailed
}

/// Waits until both streams have left `.opening`, for at most `timeout`.
/// A stream that failed to open throws its classified failure; one that is
/// still opening at the deadline is a connection failure.
func smtpAwaitStreamsOpened(
    _ input: InputStream, _ output: OutputStream, tlsActive: Bool, timeout: TimeInterval = 30
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        for stream in [input as Stream, output as Stream] where stream.streamStatus == .error {
            throw smtpStreamFailure(stream, tlsActive: tlsActive)
        }
        let opening = [input.streamStatus, output.streamStatus].contains { $0 == .opening || $0 == .notOpen }
        guard opening else { return }
        guard Date() < deadline else { throw SMTPClientError.connectionFailed }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

/// Applies `SO_RCVTIMEO` to a plaintext socket.
private func smtpSetReceiveTimeout(_ seconds: TimeInterval, fileDescriptor: Int32) {
    let value = max(0, seconds)
    var timeout = timeval(tv_sec: Int(value.rounded(.down)), tv_usec: Int32((value - value.rounded(.down)) * 1_000_000))
    setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

/// One blocking stream read bounded by `timeout`: when it passes, the
/// stream's socket is shut down so the read returns, and the read is a
/// network failure (`connectionFailed`), even if the shutdown surfaced as a
/// TLS error mid-handshake. A stream without a native socket reads
/// unbounded.
private func smtpTimedRead(_ input: InputStream, timeout: TimeInterval, _ read: () -> Int) throws -> Int {
    let key = Stream.PropertyKey(rawValue: CFStreamPropertyKey.socketNativeHandle.rawValue as String)
    guard timeout > 0, let handle = input.property(forKey: key) as? Data, handle.count >= MemoryLayout<Int32>.size else {
        return read()
    }
    var fileDescriptor: Int32 = -1
    _ = withUnsafeMutableBytes(of: &fileDescriptor) { handle.copyBytes(to: $0) }
    let fired = SMTPWatchdogFlag()
    let watchdog = DispatchWorkItem { [fileDescriptor] in
        fired.set()
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let count = read()
    watchdog.cancel()
    if fired.value { throw SMTPClientError.connectionFailed }
    return count
}

private final class SMTPWatchdogFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool { lock.withLock { fired } }
    func set() { lock.withLock { fired = true } }
}
