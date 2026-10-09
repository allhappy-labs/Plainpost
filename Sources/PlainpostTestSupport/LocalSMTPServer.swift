import Darwin
import Foundation
import PlainpostCore

public struct AcceptedSMTPMessage: Equatable, Sendable {
    public let mailFrom: EmailAddress
    public let recipients: [EmailAddress]
    public let data: String

    public init(mailFrom: EmailAddress, recipients: [EmailAddress], data: String) {
        self.mailFrom = mailFrom
        self.recipients = recipients
        self.data = data
    }
}

public final class LocalSMTPServer: @unchecked Sendable {
    private let username: String
    private let password: String
    private let rejectedRecipients: Set<EmailAddress>
    private var disconnectAfterData: Bool
    private let mailFromReply: String?
    private let recipientReplies: [EmailAddress: String]
    private let disconnectAtMailFrom: Bool
    private let disconnectAtAuth: Bool
    private let authReply: String?
    private let onDataReceived: (@Sendable () -> Void)?
    private let disconnectOnQuit: Bool
    private let stateQueue = DispatchQueue(label: "LocalSMTPServer.state")
    private var listenerFileDescriptor: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private var messages: [AcceptedSMTPMessage] = []
    private var implicitTLSProxy: LocalImplicitTLSProxy?

    public private(set) var port: Int = 0

    public func startImplicitTLS(certificateName: String = "localhost") throws -> LocalImplicitTLSProxy {
        let proxy = try LocalImplicitTLSProxy(forwardingTo: port, certificateName: certificateName)
        implicitTLSProxy = proxy
        return proxy
    }

    public init(
        username: String,
        password: String,
        rejectedRecipients: [EmailAddress] = [],
        disconnectAfterData: Bool = false,
        onDataReceived: (@Sendable () -> Void)? = nil,
        disconnectOnQuit: Bool = false,
        mailFromReply: String? = nil,
        recipientReplies: [EmailAddress: String] = [:],
        disconnectAtMailFrom: Bool = false,
        disconnectAtAuth: Bool = false,
        authReply: String? = nil
    ) {
        self.disconnectAtAuth = disconnectAtAuth
        self.authReply = authReply
        self.mailFromReply = mailFromReply
        self.recipientReplies = recipientReplies
        self.disconnectAtMailFrom = disconnectAtMailFrom
        self.username = username
        self.password = password
        self.rejectedRecipients = Set(rejectedRecipients)
        self.disconnectAfterData = disconnectAfterData
        self.onDataReceived = onDataReceived
        self.disconnectOnQuit = disconnectOnQuit
    }

    deinit {
        stop()
    }

    public func start() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalSMTPServerError.cannotStart
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw LocalSMTPServerError.cannotStart
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw LocalSMTPServerError.cannotStart
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let portResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &boundAddressLength)
            }
        }
        guard portResult == 0 else {
            close(fd)
            throw LocalSMTPServerError.cannotStart
        }

        listenerFileDescriptor = fd
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
        serverTask = Task.detached { [weak self] in
            self?.acceptConnections(fileDescriptor: fd)
        }
    }

    public func stop() {
        implicitTLSProxy?.stop()
        implicitTLSProxy = nil
        serverTask?.cancel()
        serverTask = nil

        if listenerFileDescriptor >= 0 {
            Darwin.shutdown(listenerFileDescriptor, SHUT_RDWR)
            Darwin.close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }
    }

    public func acceptedMessages() async -> [AcceptedSMTPMessage] {
        stateQueue.sync { messages }
    }

    /// Host fixture can make a later DATA acknowledgement ambiguous without
    /// affecting the verification message sent during account setup.
    public func setDisconnectAfterData(_ enabled: Bool) {
        stateQueue.sync { disconnectAfterData = enabled }
    }

    private func acceptConnections(fileDescriptor: Int32) {
        while !Task.isCancelled {
            let client = accept(fileDescriptor, nil, nil)
            if client < 0 {
                break
            }

            Task.detached { [weak self] in
                self?.handleConnection(fileDescriptor: client)
            }
        }
    }

    private func handleConnection(fileDescriptor: Int32) {
        let connection = LocalSMTPSocket(fileDescriptor: fileDescriptor)
        defer { connection.close() }

        var authenticated = false
        var mailFrom: EmailAddress?
        var recipients: [EmailAddress] = []

        do {
            try connection.writeLine("220 Plainpost test SMTP ready")

            while true {
                let line = try connection.readLine()
                let uppercased = line.uppercased()

                if uppercased.hasPrefix("EHLO") {
                    try connection.writeRaw("250-localhost\r\n250 AUTH PLAIN\r\n")
                } else if uppercased.hasPrefix("AUTH PLAIN ") {
                    if disconnectAtAuth { return }
                    if let authReply {
                        try connection.writeLine(authReply)
                        continue
                    }
                    if validateAuthPlain(String(line.dropFirst("AUTH PLAIN ".count))) {
                        authenticated = true
                        try connection.writeLine("235 Authentication successful")
                    } else {
                        try connection.writeLine("535 Authentication failed")
                    }
                } else if uppercased.hasPrefix("MAIL FROM:") {
                    guard authenticated, let parsedAddress = parseSMTPAddress(line) else {
                        try connection.writeLine("503 Bad command sequence")
                        continue
                    }
                    if disconnectAtMailFrom { return }
                    if let mailFromReply {
                        try connection.writeLine(mailFromReply)
                        continue
                    }
                    mailFrom = EmailAddress(parsedAddress)
                    recipients = []
                    try connection.writeLine("250 Sender accepted")
                } else if uppercased.hasPrefix("RCPT TO:") {
                    guard authenticated, parseSMTPAddress(line) != nil else {
                        try connection.writeLine("503 Bad command sequence")
                        continue
                    }

                    let recipient = EmailAddress(parseSMTPAddress(line)!)
                    if let reply = recipientReplies[recipient] {
                        try connection.writeLine(reply)
                    } else if rejectedRecipients.contains(recipient) {
                        try connection.writeLine("550 Recipient rejected")
                    } else {
                        recipients.append(recipient)
                        try connection.writeLine("250 Recipient accepted")
                    }
                } else if uppercased == "DATA" {
                    guard let sender = mailFrom, !recipients.isEmpty else {
                        try connection.writeLine("503 Bad command sequence")
                        continue
                    }

                    try connection.writeLine("354 End data with <CR><LF>.<CR><LF>")
                    let data = try connection.readDataBlock()
                    appendAcceptedMessage(
                        AcceptedSMTPMessage(mailFrom: sender, recipients: recipients, data: data)
                    )
					onDataReceived?()
                    if stateQueue.sync(execute: { disconnectAfterData }) {
                        return
                    }
                    try connection.writeLine("250 Message accepted")
                    mailFrom = nil
                    recipients = []
                } else if uppercased == "QUIT" {
					if disconnectOnQuit { return }
                    try connection.writeLine("221 Bye")
                    break
                } else {
                    try connection.writeLine("500 Command not recognized")
                }
            }
        } catch {
            return
        }
    }

    private func validateAuthPlain(_ value: String) -> Bool {
        guard
            let data = Data(base64Encoded: value),
            let decoded = String(data: data, encoding: .utf8)
        else {
            return false
        }

        return decoded == "\u{0}\(username)\u{0}\(password)"
    }

    private func parseSMTPAddress(_ line: String) -> String? {
        guard
            let start = line.firstIndex(of: "<"),
            let end = line[start...].firstIndex(of: ">"),
            start < end
        else {
            return nil
        }

        let addressStart = line.index(after: start)
        return String(line[addressStart..<end])
    }

    private func appendAcceptedMessage(_ message: AcceptedSMTPMessage) {
        stateQueue.sync {
            messages.append(message)
        }
    }
}

public enum LocalSMTPServerError: Error, Equatable, Sendable {
    case cannotStart
}

private final class LocalSMTPSocket {
    private let fileDescriptor: Int32
    private var isClosed = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0

        while true {
            let count = recv(fileDescriptor, &byte, 1, 0)
            guard count > 0 else {
                throw LocalSMTPServerError.cannotStart
            }

            if byte == UInt8(ascii: "\n") {
                break
            }
            if byte != UInt8(ascii: "\r") {
                bytes.append(byte)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    func readDataBlock() throws -> String {
        var lines: [String] = []

        while true {
            let line = try readLine()
            if line == "." {
                break
            }
            if line.hasPrefix("..") {
                lines.append(String(line.dropFirst()))
            } else {
                lines.append(line)
            }
        }

        return lines.joined(separator: "\r\n")
    }

    func writeLine(_ line: String) throws {
        try writeRaw("\(line)\r\n")
    }

    func writeRaw(_ text: String) throws {
        let bytes = Array(text.utf8)
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
                throw LocalSMTPServerError.cannotStart
            }
            sent += count
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }
}
