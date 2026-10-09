import Darwin
import Dispatch
import Foundation
import PlainpostCore

public struct LocalIMAPAppendedMessage: Equatable, Sendable {
    public let mailbox: String
    public let flags: [String]
    public let data: String
    public let uid: Int

    public init(mailbox: String, flags: [String], data: String, uid: Int) {
        self.mailbox = mailbox
        self.flags = flags
        self.data = data
        self.uid = uid
    }
}

public struct LocalIMAPLoginAttempt: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum LocalIMAPLoginArgumentParser {
    public static func parse(_ arguments: String) -> LocalIMAPLoginAttempt? {
        guard !arguments.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }

        var index = arguments.startIndex
        guard let username = parseArgument(arguments, index: &index),
              index < arguments.endIndex,
              arguments[index] == " "
        else {
            return nil
        }
        index = arguments.index(after: index)
        guard let password = parseArgument(arguments, index: &index),
              index == arguments.endIndex
        else {
            return nil
        }
        return LocalIMAPLoginAttempt(username: username, password: password)
    }

    private static func parseArgument(_ arguments: String, index: inout String.Index) -> String? {
        guard index < arguments.endIndex else { return nil }

        if arguments[index] != "\"" {
            let start = index
            let atomSpecials: Set<Character> = ["(", ")", "{", "%", "*", "\"", "\\", "]", " "]
            while index < arguments.endIndex, !atomSpecials.contains(arguments[index]) {
                index = arguments.index(after: index)
            }
            guard start != index else { return nil }
            return String(arguments[start..<index])
        }

        index = arguments.index(after: index)
        var value = ""
        while index < arguments.endIndex {
            let character = arguments[index]
            index = arguments.index(after: index)
            if character == "\\" {
                guard index < arguments.endIndex else { return nil }
                let escaped = arguments[index]
                guard escaped == "\\" || escaped == "\"" else { return nil }
                value.append(escaped)
                index = arguments.index(after: index)
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }
}

public struct LocalIMAPCopyAttempt: Equatable, Sendable {
    public let uid: Int
    public let mailbox: String

    public init(uid: Int, mailbox: String) {
        self.uid = uid
        self.mailbox = mailbox
    }
}

/// Typed server-side stimulus for semantic IMAP fixtures. It models only
/// bytes that the loopback peer emits; callers cannot use it to synthesize a
/// normalized result. The production client remains the sole observer.
public struct LocalIMAPPeerResponse: Equatable, Sendable {
    public struct Mailbox: Equatable, Sendable {
        public let path: String
        public let specialUse: String?
        public let selectable: Bool

        public init(path: String, specialUse: String? = nil, selectable: Bool = true) {
            self.path = path
            self.specialUse = specialUse
            self.selectable = selectable
        }
    }

    public struct ProviderMetadata: Equatable, Sendable {
        public let stableID: String
        public let threadID: String
        public let labels: [String]

        public init(stableID: String, threadID: String, labels: [String]) {
            self.stableID = stableID
            self.threadID = threadID
            self.labels = labels
        }
    }

    public enum CatalogBehavior: Equatable, Sendable {
        case normal
        case oversized
    }

    public enum MetadataBehavior: Equatable, Sendable {
        case normal
        case gmailLabelsLiteral(bytes: Int)
    }

    public let capabilities: [String]
    public let mailboxes: [Mailbox]
    public let uidValidity: Int
    public let messageUID: Int
    public let messageData: Data
    public let initialFlags: Set<String>
    public let sendsIdleChange: Bool
    public let appendUIDResponses: [Int?]
    public let providerMetadata: ProviderMetadata?
    public let catalogBehavior: CatalogBehavior
    public let metadataBehavior: MetadataBehavior

    public init(
        capabilities: [String],
        mailboxes: [Mailbox],
        uidValidity: Int,
        messageUID: Int,
        messageData: Data,
        initialFlags: Set<String> = ["\\Seen"],
        sendsIdleChange: Bool = false,
        appendUIDResponses: [Int?] = [1_001],
        providerMetadata: ProviderMetadata? = nil,
        catalogBehavior: CatalogBehavior = .normal,
        metadataBehavior: MetadataBehavior = .normal
    ) {
        self.capabilities = capabilities
        self.mailboxes = mailboxes
        self.uidValidity = uidValidity
        self.messageUID = messageUID
        self.messageData = messageData
        self.initialFlags = initialFlags
        self.sendsIdleChange = sendsIdleChange
        self.appendUIDResponses = appendUIDResponses
        self.providerMetadata = providerMetadata
        self.catalogBehavior = catalogBehavior
        self.metadataBehavior = metadataBehavior
    }
}

public final class LocalIMAPServer: @unchecked Sendable {
    private let username: String
    private let password: String
    private let forcedLoginFailure: String?
    private let forcedLoginResponse: String?
    private let uidValidity: Int
    private let messageUID: Int
    private let capabilities: [String]
    private let mailboxes: [LocalIMAPPeerResponse.Mailbox]
    private let messageData: Data
    private let providerMetadata: LocalIMAPPeerResponse.ProviderMetadata?
    private let catalogBehavior: LocalIMAPPeerResponse.CatalogBehavior
    private let metadataBehavior: LocalIMAPPeerResponse.MetadataBehavior
    private let supportsIdle: Bool
    private let sendsIdleChange: Bool
    private let appendUIDResponses: [Int?]
    private let onSessionStart: @Sendable () -> Void
    private let onSessionEnd: @Sendable () -> Void
    private let stateLock = NSLock()
    private var flags: Set<String>
    private var labels: Set<String>
    private var archived: [Int] = []
    private var copyAttemptsStorage: [LocalIMAPCopyAttempt] = []
    private var movesStorage: [LocalIMAPCopyAttempt] = []
    private var uidCommandsStorage: [String] = []
    private var nextMoveUID = 501
    private var deleted: [Int] = []
    /// Mailboxes the fixture message was expunged from. Like a real server,
    /// such a mailbox no longer reports, searches or fetches the message.
    /// A COPY alone leaves the source mailbox unchanged.
    private var expungedMailboxes: Set<String> = []
    private var selectedMailboxesStorage: [String] = []
    private var appended: [LocalIMAPAppendedMessage] = []
    private var nextAppendUID = 1001
    private var appendResponseIndex = 0
    private var loginAttemptsStorage: [LocalIMAPLoginAttempt] = []
    private var loginCommandCountStorage = 0
    private var messageStateFetches = 0
    private var expunges = 0
    private var broadExpunges = 0
    private var storeCommandsStorage: [String] = []
    // Internal test visibility proves a disconnected peer write is converted
    // into a normal socket error rather than a process-level SIGPIPE.
    private var socketWriteFailuresStorage = 0
    private var activeClientFDs: Set<Int32> = []
    private var listenFD: Int32 = -1
    private var implicitTLSProxy: LocalImplicitTLSProxy?
    private var activeGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private enum LifecycleState: Equatable {
        case stopped
        case starting(UInt64)
        case running(UInt64)
    }
    private var lifecycleState: LifecycleState = .stopped
    private static let acceptQueueThreadMarker = "Plainpost.LocalIMAPServer.acceptQueue"
    private let acceptQueueIdentity = UUID().uuidString
    private let queue = DispatchQueue(label: "Plainpost.LocalIMAPServer")
    private let acceptLoopGroup = DispatchGroup()

    public private(set) var port: UInt16 = 0

    public func startImplicitTLS(certificateName: String = "localhost") throws -> LocalImplicitTLSProxy {
        let proxy = try LocalImplicitTLSProxy(forwardingTo: Int(port), certificateName: certificateName)
        implicitTLSProxy = proxy
        return proxy
    }

    public var archivedUIDs: [Int] {
        stateLock.withLock { archived }
    }

    public var deletedUIDs: [Int] {
        stateLock.withLock { deleted }
    }

    public var copyAttempts: [LocalIMAPCopyAttempt] {
        stateLock.withLock { copyAttemptsStorage }
    }

    /// Every `UID` command's arguments as sent, in order (so quoting and
    /// copy-before-expunge are visible). Searches and fetches are left out.
    public var uidCommands: [String] {
        stateLock.withLock { uidCommandsStorage }
    }

    /// Every accepted `UID MOVE`, with its unquoted destination.
    public var moves: [LocalIMAPCopyAttempt] {
        stateLock.withLock { movesStorage }
    }

    public var selectedMailboxes: [String] {
        stateLock.withLock { selectedMailboxesStorage }
    }

    public var expungeCount: Int {
        stateLock.withLock { expunges }
    }

    /// Test-only visibility of a dangerous bare EXPUNGE. Consumers should use
    /// UID EXPUNGE after marking their exact target as deleted.
    public var broadExpungeCount: Int {
        stateLock.withLock { broadExpunges }
    }

    public var appendedMessages: [LocalIMAPAppendedMessage] {
        stateLock.withLock { appended }
    }

    public var loginAttempts: [LocalIMAPLoginAttempt] {
        stateLock.withLock { loginAttemptsStorage }
    }

    public var loginCommandCount: Int {
        stateLock.withLock { loginCommandCountStorage }
    }

    public var messageStateFetchCount: Int {
        stateLock.withLock { messageStateFetches }
    }

    /// Observed state after a public client mutation. The semantic harness
    /// reads this only after the peer processed STORE; it is never fixture
    /// expectation input.
    public var observedLabels: Set<String> {
        stateLock.withLock { labels }
    }

    public var storeCommands: [String] {
        stateLock.withLock { storeCommandsStorage }
    }

    var socketWriteFailureCount: Int {
        stateLock.withLock { socketWriteFailuresStorage }
    }

    public init(
        username: String,
        password: String,
        message: MessageSummary,
        forcedLoginFailure: String? = nil,
        forcedLoginResponse: String? = nil,
        uidValidity: Int = 1,
        messageUID: Int = 1,
        supportsIdle: Bool = false,
        sendsIdleChange: Bool = false,
        appendUIDResponses: [Int?] = [1_001],
        extraMailboxes: [LocalIMAPPeerResponse.Mailbox] = [],
        peer: LocalIMAPPeerResponse? = nil,
        onSessionStart: @escaping @Sendable () -> Void = {},
        onSessionEnd: @escaping @Sendable () -> Void = {}
    ) {
        let response = peer ?? Self.defaultPeerResponse(
            message: message,
            uidValidity: uidValidity,
            messageUID: messageUID,
            supportsIdle: supportsIdle,
            sendsIdleChange: sendsIdleChange,
            appendUIDResponses: appendUIDResponses,
            extraMailboxes: extraMailboxes
        )
        self.username = username
        self.password = password
        self.forcedLoginFailure = forcedLoginFailure
        self.forcedLoginResponse = forcedLoginResponse
        self.uidValidity = response.uidValidity
        self.messageUID = response.messageUID
        self.capabilities = response.capabilities
        self.mailboxes = response.mailboxes
        self.messageData = response.messageData
        self.providerMetadata = response.providerMetadata
        self.catalogBehavior = response.catalogBehavior
        self.metadataBehavior = response.metadataBehavior
        self.supportsIdle = response.capabilities.contains { $0.caseInsensitiveCompare("IDLE") == .orderedSame }
        self.sendsIdleChange = response.sendsIdleChange
        self.appendUIDResponses = response.appendUIDResponses.isEmpty ? [1_001] : response.appendUIDResponses
        self.flags = response.initialFlags
        self.labels = Set(response.providerMetadata?.labels ?? [])
        self.onSessionStart = onSessionStart
        self.onSessionEnd = onSessionEnd
    }

    deinit {
        stop()
    }

    public func start() async throws {
        let generation = try stateLock.withLock { () throws -> UInt64 in
            guard lifecycleState == .stopped else {
                throw IMAPClientError.connectionFailed
            }
            nextGeneration &+= 1
            lifecycleState = .starting(nextGeneration)
            return nextGeneration
        }

        // A prior accept loop may still be unwinding after stop() was called
        // by a session callback. Wait for that loop before opening a new
        // listener, while allowing a later stop() to cancel this start.
        do {
            try waitForPreviousAcceptLoop(generation: generation)
        } catch {
            stateLock.withLock {
                if lifecycleState == .starting(generation) {
                    lifecycleState = .stopped
                }
            }
            throw error
        }

        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            stateLock.withLock {
                if lifecycleState == .starting(generation) {
                    lifecycleState = .stopped
                }
            }
            throw IMAPClientError.connectionFailed
        }

        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(serverFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(serverFD, 4) == 0 else {
            stateLock.withLock {
                if lifecycleState == .starting(generation) {
                    lifecycleState = .stopped
                }
            }
            Darwin.shutdown(serverFD, SHUT_RDWR)
            Darwin.close(serverFD)
            throw IMAPClientError.connectionFailed
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(serverFD, sockaddrPointer, &boundLength)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddress.sin_port)

        // Enter before publishing the running generation. stop() can race
        // this handoff; in that case the token check closes this descriptor
        // without ever making it reachable.
        acceptLoopGroup.enter()
        let published = stateLock.withLock { () -> Bool in
            guard lifecycleState == .starting(generation) else { return false }
            lifecycleState = .running(generation)
            activeGeneration = generation
            listenFD = serverFD
            port = boundPort
            return true
        }
        guard published else {
            acceptLoopGroup.leave()
            Darwin.shutdown(serverFD, SHUT_RDWR)
            Darwin.close(serverFD)
            throw IMAPClientError.connectionFailed
        }

        let acceptLoopGroup = self.acceptLoopGroup
        let acceptQueueIdentity = self.acceptQueueIdentity
        queue.async { [weak self] in
            Thread.current.threadDictionary[Self.acceptQueueThreadMarker] = acceptQueueIdentity
            defer {
                Thread.current.threadDictionary.removeObject(forKey: Self.acceptQueueThreadMarker)
                acceptLoopGroup.leave()
            }
            self?.acceptLoop(fd: serverFD, generation: generation)
        }
    }

    public func stop() {
        implicitTLSProxy?.stop()
        implicitTLSProxy = nil
        let listener = stateLock.withLock { () -> Int32 in
            let descriptor = listenFD
            listenFD = -1
            activeGeneration = nil
            lifecycleState = .stopped
            return descriptor
        }
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        let clientFDs = stateLock.withLock { Array(activeClientFDs) }
        for clientFD in clientFDs {
            Darwin.shutdown(clientFD, SHUT_RDWR)
        }
        let currentQueueIdentity = Thread.current.threadDictionary[Self.acceptQueueThreadMarker] as? String
        if currentQueueIdentity != acceptQueueIdentity {
            queue.sync {}
        }
    }

    private func waitForPreviousAcceptLoop(generation: UInt64) throws {
        while acceptLoopGroup.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            let isCurrentStart = stateLock.withLock {
                lifecycleState == .starting(generation)
            }
            guard isCurrentStart else {
                throw IMAPClientError.connectionFailed
            }
        }
        let isCurrentStart = stateLock.withLock {
            lifecycleState == .starting(generation)
        }
        guard isCurrentStart else {
            throw IMAPClientError.connectionFailed
        }
    }

    private func acceptLoop(fd: Int32, generation: UInt64) {
        while true {
            let isCurrent = stateLock.withLock {
                activeGeneration == generation && listenFD == fd
            }
            guard isCurrent else { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                return
            }

            // The peer intentionally exercises disconnect and overflow
            // paths. A client close must make a later fixture write fail
            // normally, never terminate the shared XCTest process.
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                Darwin.close(clientFD)
                continue
            }
            let claimed = stateLock.withLock {
                guard activeGeneration == generation, listenFD == fd else { return false }
                activeClientFDs.insert(clientFD)
                return true
            }
            guard claimed else {
                Darwin.shutdown(clientFD, SHUT_RDWR)
                Darwin.close(clientFD)
                return
            }
            handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        let socket = TestLineSocket(fd: fd) { [weak self] in
            self?.stateLock.withLock {
                self?.socketWriteFailuresStorage += 1
            }
        }
        onSessionStart()
        defer {
            _ = stateLock.withLock {
                activeClientFDs.remove(fd)
            }
            socket.close()
            onSessionEnd()
        }

        try? socket.writeLine("* OK Plainpost test IMAP ready")
        var selectedMailbox: String?
        func messageIsListed() -> Bool {
            guard let selectedMailbox else { return true }
            return stateLock.withLock { !expungedMailboxes.contains(selectedMailbox) }
        }

        while let line = try? socket.readLine() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                continue
            }
            let tag = String(parts[0])
            let command = parts[1].uppercased()
            let arguments = parts.count == 3 ? String(parts[2]) : ""

            switch command {
            case "CAPABILITY":
                try? socket.writeLine("* CAPABILITY \(capabilities.joined(separator: " "))")
                try? socket.writeLine("\(tag) OK CAPABILITY completed")
            case "LOGIN":
                stateLock.withLock {
                    loginCommandCountStorage += 1
                }
                let loginParts = LocalIMAPLoginArgumentParser.parse(arguments)
                if let loginParts {
                    stateLock.withLock {
                        loginAttemptsStorage.append(loginParts)
                    }
                }
                if let forcedLoginResponse {
                    try? socket.writeLine("\(tag) \(forcedLoginResponse)")
                } else if let forcedLoginFailure {
                    try? socket.writeLine("\(tag) NO \(forcedLoginFailure)")
                } else if loginParts?.username == username, loginParts?.password == password {
                    try? socket.writeLine("\(tag) OK LOGIN completed")
                } else {
                    try? socket.writeLine("\(tag) NO authentication failed")
                }
            case "LIST":
                for mailbox in listedMailboxes() {
                    try? socket.writeLine(listResponse(for: mailbox))
                }
                try? socket.writeLine("\(tag) OK LIST completed")
            case "SELECT":
                let selected = Self.unquotedMailbox(arguments)
                stateLock.withLock {
                    selectedMailboxesStorage.append(selected)
                }
                guard mailboxes.contains(where: { $0.path == selected && $0.selectable }) else {
                    try? socket.writeLine("\(tag) NO mailbox is not selectable")
                    continue
                }
                selectedMailbox = selected
                let visibleAppendedCount = stateLock.withLock { appended.filter { $0.mailbox == selected }.count }
                try? socket.writeLine("* \((messageIsListed() ? 1 : 0) + visibleAppendedCount) EXISTS")
                try? socket.writeLine(
                    "* OK [UIDVALIDITY \(uidValidity)] UIDs valid"
                )
                try? socket.writeLine("\(tag) OK [READ-WRITE] SELECT completed")
            case "UID":
                let uppercasedArguments = arguments.uppercased()
                if !uppercasedArguments.hasPrefix("SEARCH "), !uppercasedArguments.hasPrefix("FETCH ") {
                    stateLock.withLock { uidCommandsStorage.append(arguments) }
                }
                if uppercasedArguments == "FETCH 1:* (UID FLAGS)" {
                    stateLock.withLock {
                        messageStateFetches += 1
                    }
                }
                if uppercasedArguments.contains(" STORE ") || uppercasedArguments.hasPrefix("STORE ") {
                    stateLock.withLock { storeCommandsStorage.append(arguments) }
                    handleUIDStore(arguments: arguments)
                    try? socket.writeLine("\(tag) OK UID STORE completed")
                    continue
                } else if uppercasedArguments.hasPrefix("SEARCH ") {
                    let minimumUID: Int
                    if let range = uppercasedArguments.range(of: "UID "),
                       let number = Int(uppercasedArguments[range.upperBound...].prefix(while: \.isNumber)) {
                        minimumUID = number
                    } else {
                        minimumUID = 0
                    }
                    var found = messageIsListed() && messageUID >= minimumUID ? [messageUID] : []
                    found += stateLock.withLock {
                        appended.filter { $0.mailbox == selectedMailbox && $0.uid >= minimumUID }.map(\.uid)
                    }
                    try? socket.writeLine("* SEARCH \(found.map(String.init).joined(separator: " "))")
                    try? socket.writeLine("\(tag) OK UID SEARCH completed")
                    continue
                } else if uppercasedArguments.hasPrefix("MOVE ") {
                    handleUIDMove(arguments: arguments, tag: tag, selectedMailbox: selectedMailbox, socket: socket)
                    continue
                } else if uppercasedArguments.contains(" COPY ") || uppercasedArguments.hasPrefix("COPY ") {
                    handleUIDCopy(arguments: arguments)
                    try? socket.writeLine("\(tag) OK UID COPY completed")
                    continue
                } else if uppercasedArguments.hasPrefix("EXPUNGE ") {
					if let uid = Int(arguments.split(separator: " ").dropFirst().first ?? "") {
						stateLock.withLock {
							if !deleted.contains(uid) { deleted.append(uid) }
							expunges += 1
							if uid == messageUID, let selectedMailbox {
								expungedMailboxes.insert(selectedMailbox)
							}
						}
						try? socket.writeLine("* 1 EXPUNGE")
						try? socket.writeLine("\(tag) OK UID EXPUNGE completed")
					} else {
						try? socket.writeLine("\(tag) BAD invalid UID EXPUNGE")
					}
					continue
                } else if uppercasedArguments.hasPrefix("FETCH "), !messageIsListed() {
                    // The message is gone from this mailbox: no FETCH rows.
                } else if uppercasedArguments.hasPrefix("FETCH "),
                          let requestedUID = Int(arguments.dropFirst("FETCH ".count).prefix(while: \.isNumber)),
                          let injected = stateLock.withLock({ appended.first { $0.mailbox == selectedMailbox && $0.uid == requestedUID } }) {
                    let data = Data(injected.data.utf8)
                    if uppercasedArguments.contains("INTERNALDATE") && !uppercasedArguments.contains("BODY") {
                        try? socket.writeLine("* 1 FETCH (UID \(injected.uid) INTERNALDATE \"08-Jul-2026 00:00:00 +0000\")")
                    } else if uppercasedArguments.contains("BODY.PEEK[]") {
                        try? socket.writeLine("* 1 FETCH (UID \(injected.uid) BODY[] {\(data.count)}")
                        try? socket.writeData(data)
                        try? socket.writeLine(")")
                    } else {
                        try? socket.writeLine("* 1 FETCH (UID \(injected.uid) FLAGS () BODY[HEADER]")
                        try? socket.writeData(Self.headerData(from: data))
                        try? socket.writeLine(")")
                    }
                } else if uppercasedArguments.contains("INTERNALDATE") && !uppercasedArguments.contains("BODY") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
                    let internalDate = formatter.string(from: Date())
                    try? socket.writeLine("* 1 FETCH (UID \(messageUID) INTERNALDATE \"\(internalDate)\")")
                } else if uppercasedArguments.contains("BODY.PEEK[]") {
                    try? socket.writeLine(
                        "* 1 FETCH (UID \(messageUID) BODY[] {\(messageData.count)}"
                    )
                    try? socket.writeData(messageData)
                    try? socket.writeLine(")")
                } else {
                    if case let .gmailLabelsLiteral(bytes) = metadataBehavior,
                       let providerMetadata,
                       bytes >= 0 {
                        // This is a real IMAP command literal: the production
                        // client must bound it from the marker before allocating
                        // it, then reconstruct the response only at the exact
                        // limit. It intentionally sits on the Gmail labels
                        // metadata path rather than a test-only command.
                        try? socket.writeLine(
                            "* 1 FETCH (UID \(messageUID) X-GM-MSGID \(providerMetadata.stableID) X-GM-THRID \(providerMetadata.threadID) X-GM-LABELS ({\(bytes)}"
                        )
                        try? socket.writeData(Data(repeating: 76, count: bytes))
                        try? socket.writeLine(")")
                        try? socket.writeLine("\(tag) OK UID FETCH completed")
                        continue
                    }
                    let currentFlags = stateLock.withLock { flags.sorted().joined(separator: " ") }
                    let metadata = imapProviderMetadataResponse()
                    try? socket.writeLine("* 1 FETCH (UID \(messageUID) FLAGS (\(currentFlags))\(metadata) BODY[HEADER]")
                    try? socket.writeData(headerData())
                    try? socket.writeLine(")")
                }
                if uppercasedArguments == "FETCH 1:* (UID FLAGS)" {
                    let visible = stateLock.withLock { appended.filter { $0.mailbox == selectedMailbox } }
                    for (index, message) in visible.enumerated() {
                        try? socket.writeLine("* \(index + 2) FETCH (UID \(message.uid) FLAGS ())")
                    }
                }
                try? socket.writeLine("\(tag) OK UID FETCH completed")
            case "EXPUNGE":
                stateLock.withLock {
                    expunges += 1
					broadExpunges += 1
                    if flags.contains("\\Deleted"), let selectedMailbox {
                        expungedMailboxes.insert(selectedMailbox)
                    }
                }
                try? socket.writeLine("* 1 EXPUNGE")
                try? socket.writeLine("\(tag) OK EXPUNGE completed")
            case "APPEND":
                handleAppend(arguments: arguments, tag: tag, socket: socket)
            case "IDLE" where supportsIdle:
                try? socket.writeLine("+ idling")
                if sendsIdleChange { try? socket.writeLine("* 2 EXISTS") }
                if let done = try? socket.readLine(), done.uppercased() == "DONE" {
                    try? socket.writeLine("\(tag) OK IDLE completed")
                }
            case "LOGOUT":
                try? socket.writeLine("* BYE logging out")
                try? socket.writeLine("\(tag) OK LOGOUT completed")
                return
            default:
                try? socket.writeLine("\(tag) BAD unsupported command")
            }
        }
    }

    private func handleAppend(arguments: String, tag: String, socket: TestLineSocket) {
        guard let request = parseAppendRequest(arguments) else {
            try? socket.writeLine("\(tag) BAD invalid APPEND")
            return
        }

        do {
            try socket.writeLine("+ Ready for literal data")
            let data = try socket.readBytes(count: request.literalByteCount)
            _ = try socket.readLine()
            let (uid, responseUID) = stateLock.withLock {
                let assigned = nextAppendUID
                nextAppendUID += 1
                let response = appendUIDResponses[min(appendResponseIndex, appendUIDResponses.count - 1)]
                appendResponseIndex += 1
                return (assigned, response)
            }
            stateLock.withLock {
                appended.append(
                    LocalIMAPAppendedMessage(
                        mailbox: request.mailbox,
                        flags: request.flags,
                        data: String(decoding: data, as: UTF8.self),
                        uid: uid
                    )
                )
            }
            if let responseUID {
                try socket.writeLine("\(tag) OK [APPENDUID 1 \(responseUID)] APPEND completed")
            } else {
                try socket.writeLine("\(tag) OK APPEND completed")
            }
        } catch {
            try? socket.writeLine("\(tag) BAD APPEND failed")
        }
    }

    private static func defaultPeerResponse(
        message: MessageSummary,
        uidValidity: Int,
        messageUID: Int,
        supportsIdle: Bool,
        sendsIdleChange: Bool,
        appendUIDResponses: [Int?],
        extraMailboxes: [LocalIMAPPeerResponse.Mailbox]
    ) -> LocalIMAPPeerResponse {
        var capabilities = ["IMAP4rev1", "UIDPLUS"]
        if supportsIdle { capabilities.append("IDLE") }
        let source = """
        From: \(message.from.rawValue)\r
        Date: Wed, 8 Jul 2026 00:00:00 +0000\r
        Subject: \(message.subject)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        \(message.body)
        """
        return .init(
            capabilities: capabilities,
            mailboxes: [.init(
                path: message.mailboxPath,
                specialUse: message.mailboxPath == "INBOX" ? "\\Inbox" : nil
            )] + extraMailboxes,
            uidValidity: uidValidity,
            messageUID: messageUID,
            messageData: Data(source.utf8),
            sendsIdleChange: sendsIdleChange,
            appendUIDResponses: appendUIDResponses
        )
    }

    private func listedMailboxes() -> [LocalIMAPPeerResponse.Mailbox] {
        guard catalogBehavior == .oversized, let first = mailboxes.first else { return mailboxes }
        // Keep this in the actual LIST wire response, rather than merely
        // returning an oversized array after parsing. The client must reject
        // the physical response line before a catalog projection exists.
        return [.init(
            path: String(repeating: "x", count: 64 << 10),
            specialUse: first.specialUse,
            selectable: first.selectable
        )]
    }

    private func listResponse(for mailbox: LocalIMAPPeerResponse.Mailbox) -> String {
        var attributes = [mailbox.selectable ? "\\HasNoChildren" : "\\Noselect"]
        if let specialUse = mailbox.specialUse, !specialUse.isEmpty {
            attributes.append(specialUse)
        }
        return "* LIST (\(attributes.joined(separator: " "))) \"/\" \(Self.quotedMailbox(mailbox.path))"
    }

    private func headerData() -> Data {
        Self.headerData(from: messageData)
    }

    private static func headerData(from data: Data) -> Data {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8))
                ?? data.range(of: Data("\n\n".utf8)) else {
            return data
        }
        // The literal needs its own terminating CRLF before the enclosing
        // FETCH list closes; otherwise a final MIME header and `)` share one
        // protocol line and the peer no longer faithfully frames its input.
        return Data(data[..<boundary.lowerBound]) + Data("\r\n".utf8)
    }

    private func imapProviderMetadataResponse() -> String {
        guard let providerMetadata else { return "" }
        let observedLabels = stateLock.withLock { labels.sorted() }
        let encodedLabels = observedLabels.map(Self.quotedMailbox).joined(separator: " ")
        return " X-GM-MSGID \(providerMetadata.stableID) X-GM-THRID \(providerMetadata.threadID) X-GM-LABELS (\(encodedLabels))"
    }

    private func parseAppendRequest(_ arguments: String) -> LocalIMAPAppendRequest? {
        guard let parsedMailbox = parseMailboxName(from: arguments),
              let flagsStart = parsedMailbox.remainder.firstIndex(of: "("),
              let flagsEnd = parsedMailbox.remainder.firstIndex(of: ")"),
              let literalStart = parsedMailbox.remainder.firstIndex(of: "{"),
              let literalEnd = parsedMailbox.remainder.firstIndex(of: "}")
        else {
            return nil
        }

        let flagsText = parsedMailbox.remainder[parsedMailbox.remainder.index(after: flagsStart)..<flagsEnd]
        let flags = flagsText.split(separator: " ").map(String.init)
        let byteCountText = parsedMailbox.remainder[parsedMailbox.remainder.index(after: literalStart)..<literalEnd]
        guard let byteCount = Int(byteCountText) else {
            return nil
        }
        return LocalIMAPAppendRequest(mailbox: parsedMailbox.mailbox, flags: flags, literalByteCount: byteCount)
    }

    private func parseMailboxName(from arguments: String) -> (mailbox: String, remainder: String)? {
        guard let argument = Self.parseIMAPArgument(arguments) else { return nil }
        return (argument.value, argument.remainder)
    }

    private static func parseIMAPArgument(_ arguments: String) -> (value: String, remainder: String)? {
        var remaining = arguments.trimmingCharacters(in: .whitespaces)
        guard !remaining.isEmpty else { return nil }

        if remaining.first != "\"" {
            let value = String(remaining.prefix { !$0.isWhitespace })
            remaining.removeFirst(value.count)
            return (value, remaining.trimmingCharacters(in: .whitespaces))
        }

        remaining.removeFirst()
        var mailbox = ""
        var isEscaped = false
        var endIndex: String.Index?

        for index in remaining.indices {
            let character = remaining[index]
            if isEscaped {
                mailbox.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                endIndex = index
                break
            } else {
                mailbox.append(character)
            }
        }

        guard let endIndex else { return nil }
        let remainderStart = remaining.index(after: endIndex)
        let remainder = String(remaining[remainderStart...]).trimmingCharacters(in: .whitespaces)
        return (mailbox, remainder)
    }

    private func handleUIDStore(arguments: String) {
        let parts = arguments.split(separator: " ").map(String.init)
        guard parts.count >= 4, let uid = Int(parts[1]) else { return }
        var operationIndex = 2
        if parts[operationIndex].uppercased() == "(UNCHANGEDSINCE" {
            operationIndex += 2
        }
        guard parts.indices.contains(operationIndex) else { return }
        let operation = parts[operationIndex].uppercased()
        let flagExpression = parts.dropFirst(operationIndex + 1).joined(separator: " ")
        let atoms = Self.storeAtoms(flagExpression)

        stateLock.withLock {
            if operation.hasPrefix("+FLAGS"), flagExpression.contains("\\Seen") {
                flags.insert("\\Seen")
            }
            if operation.hasPrefix("-FLAGS"), flagExpression.contains("\\Seen") {
                flags.remove("\\Seen")
            }
            if operation.hasPrefix("+FLAGS"), flagExpression.contains("\\Deleted") {
                flags.insert("\\Deleted")
                if !deleted.contains(uid) {
                    deleted.append(uid)
                }
            }
            if operation.hasPrefix("FLAGS") {
                flags = Set(atoms.filter { $0.hasPrefix("\\") })
            }
            if operation.hasPrefix("+X-GM-LABELS") {
                labels.formUnion(atoms)
            }
            if operation.hasPrefix("-X-GM-LABELS") {
                labels.subtract(atoms)
            }
        }
    }

    private static func storeAtoms(_ value: String) -> [String] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map(unquotedMailbox)
    }

    private func handleUIDCopy(arguments: String) {
        let parts = arguments.split(separator: " ").map(String.init)
        guard parts.count >= 3, let uid = Int(parts[1]) else { return }
        let mailbox = parts.dropFirst(2).joined(separator: " ")
        stateLock.withLock {
            copyAttemptsStorage.append(
                LocalIMAPCopyAttempt(
                    uid: uid,
                    mailbox: Self.unquotedMailbox(mailbox)
                )
            )
            if !archived.contains(uid) {
                archived.append(uid)
            }
        }
    }

    /// RFC 6851 UID MOVE, offered only when the peer advertises MOVE. The
    /// destination must be listed (else `NO [TRYCREATE]`, nothing moves); on
    /// success the message leaves the selected mailbox and COPYUID names its
    /// new UID, like a UIDPLUS server.
    private func handleUIDMove(arguments: String, tag: String, selectedMailbox: String?, socket: TestLineSocket) {
        guard capabilities.contains(where: { $0.caseInsensitiveCompare("MOVE") == .orderedSame }) else {
            try? socket.writeLine("\(tag) BAD MOVE is not supported")
            return
        }
        let parts = arguments.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let uid = Int(parts[1]) else {
            try? socket.writeLine("\(tag) BAD invalid UID MOVE")
            return
        }
        let destination = Self.unquotedMailbox(parts[2])
        guard mailboxes.contains(where: { $0.path == destination && $0.selectable }) else {
            try? socket.writeLine("\(tag) NO [TRYCREATE] no such mailbox")
            return
        }
        let destinationUID = stateLock.withLock { () -> Int in
            movesStorage.append(LocalIMAPCopyAttempt(uid: uid, mailbox: destination))
            if uid == messageUID, let selectedMailbox {
                expungedMailboxes.insert(selectedMailbox)
            }
            defer { nextMoveUID += 1 }
            return nextMoveUID
        }
        try? socket.writeLine("* OK [COPYUID \(uidValidity) \(uid) \(destinationUID)] moved")
        try? socket.writeLine("* 1 EXPUNGE")
        try? socket.writeLine("\(tag) OK UID MOVE completed")
    }

    private static func unquotedMailbox(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\""
        else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func quotedMailbox(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\\\""))\""
    }
}

private struct LocalIMAPAppendRequest {
    let mailbox: String
    let flags: [String]
    let literalByteCount: Int
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private final class TestLineSocket {
    private let fd: Int32
    private let onWriteFailure: @Sendable () -> Void

    init(fd: Int32, onWriteFailure: @escaping @Sendable () -> Void = {}) {
        self.fd = fd
        self.onWriteFailure = onWriteFailure
    }

    func writeLine(_ line: String) throws {
        let bytes = Array((line + "\r\n").utf8)
        try writeData(Data(bytes))
    }

    func writeData(_ data: Data) throws {
        let bytes = [UInt8](data)
        try bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard result > 0 else {
                    onWriteFailure()
                    throw IMAPClientError.connectionFailed
                }
                sent += result
            }
        }
    }

    func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.recv(fd, &byte, 1, 0)
            guard count == 1 else {
                throw IMAPClientError.connectionFailed
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

    func readBytes(count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var byte: UInt8 = 0
            let readCount = Darwin.recv(fd, &byte, 1, 0)
            guard readCount == 1 else {
                throw IMAPClientError.connectionFailed
            }
            bytes.append(byte)
        }
        return bytes
    }

    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
