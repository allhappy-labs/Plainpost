import Darwin
import Foundation
import PlainpostCore
import PlainpostTestSupport

/// Mac-host process. The simulator reaches its control and TLS mail ports on
/// loopback; no test-support code is linked into the iOS app or UI test runner.
@main
struct PlainpostIOSMailFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureError.arguments }
        let fixture = Fixture()
        try await fixture.start(readinessPath: CommandLine.arguments[1])
        fixture.serve()
    }
}

private enum FixtureError: Error { case arguments, listener, command }

private final class Fixture: @unchecked Sendable {
    /// An Archive and a Trash, so Archive and Delete have somewhere to move to.
    private let imap = LocalIMAPServer(
        username: "reader@example.test", password: "incoming",
        message: PlainpostFixtures.aliceMessage,
        extraMailboxes: [.init(path: "Archive", specialUse: "\\Archive"), .init(path: "Trash", specialUse: "\\Trash")]
    )
    private let smtp = LocalSMTPServer(username: "reader@example.test", password: "outgoing")
    private var imapTLS: LocalImplicitTLSProxy?
    private var smtpTLS: LocalImplicitTLSProxy?
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var injected = false
    private var offline = false
    private var shuttingDown = false

    func start(readinessPath: String) async throws {
        try await imap.start()
        try await smtp.start()
        let incoming = try imap.startImplicitTLS()
        let outgoing = try smtp.startImplicitTLS()
        imapTLS = incoming
        smtpTLS = outgoing
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw FixtureError.listener }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw FixtureError.listener }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }) == 0 else { throw FixtureError.listener }
        let readiness: [String: Any] = [
            "controlPort": Int(UInt16(bigEndian: address.sin_port)),
            "imapPort": Int(incoming.port), "smtpPort": Int(outgoing.port),
            "anchor": incoming.certificate.base64EncodedString(),
            "smtpAnchor": outgoing.certificate.base64EncodedString(),
            "tlsMode": "implicit TLS 1.2+ with explicit test CA"
        ]
        let bytes = try JSONSerialization.data(withJSONObject: readiness, options: [.sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: readinessPath), options: .atomic)
    }

    func serve() {
        let controlListener = listener
        while true {
            let client = accept(controlListener, nil, nil)
            if client < 0 {
                if lock.withLock({ shuttingDown }) { return }
                continue
            }
            DispatchQueue.global().async { [self] in handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { Darwin.shutdown(client, SHUT_RDWR); Darwin.close(client) }
        var bytes = [UInt8](repeating: 0, count: 2048)
        let count = recv(client, &bytes, bytes.count, 0)
        guard count > 0, let line = String(bytes: bytes[..<count], encoding: .utf8)?.components(separatedBy: "\r\n").first else { return }
        let command = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let response: [String: Any]
        let shouldShutDown: Bool
        switch command {
        case "/state":
            response = state()
            shouldShutDown = false
        case "/inject":
            response = inject()
            shouldShutDown = false
        case "/ambiguous":
            smtp.setDisconnectAfterData(true)
            response = state()
            shouldShutDown = false
        case "/offline":
            lock.lock(); offline = true; lock.unlock()
            imap.stop(); smtp.stop()
            response = state()
            shouldShutDown = false
        case "/shutdown":
            response = ["status": "stopping"]
            shouldShutDown = true
        default:
            response = ["error": "unknown-command"]
            shouldShutDown = false
        }
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        _ = Array(header.utf8).withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        if shouldShutDown { stop() }
    }

    private func stop() {
        lock.withLock { shuttingDown = true }
        imap.stop()
        smtp.stop()
        imapTLS?.stop()
        smtpTLS?.stop()
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            listener = -1
        }
    }

    private func state() -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        let count = LockedValue(0)
        Task {
            count.set(await smtp.acceptedMessages().count)
            semaphore.signal()
        }
        semaphore.wait()
        return lock.withLock {
            ["smtpDataCount": count.get(), "injected": injected, "offline": offline,
             "imapLoginCount": imap.loginCommandCount, "archivedCount": imap.archivedUIDs.count,
             "deletedCount": imap.deletedUIDs.count]
        }
    }

    private func inject() -> [String: Any] {
        if lock.withLock({ injected || offline }) { return state() }
        guard let imapTLS else { return ["error": "imap-unavailable"] }
        let semaphore = DispatchSemaphore(value: 0)
        let succeeded = LockedValue(false)
        Task {
            let client = SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port,
                                          certificateValidation: .testAnchor(imapTLS.certificate))
            do {
                try await client.login(username: "reader@example.test", password: "incoming")
                _ = try await client.appendMessage(to: "INBOX", flags: [], data:
                    "From: Sender <post@example.test>\r\nTo: reader@example.test\r\nSubject: Incremental fixture\r\nMessage-ID: <incremental@example.test>\r\n\r\nIncremental body")
                succeeded.set(true)
            } catch {}
            await client.disconnect()
            semaphore.signal()
        }
        semaphore.wait()
        if succeeded.get() { lock.withLock { injected = true } }
        return state()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value { lock.withLock { value } }
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T { lock(); defer { unlock() }; return action() }
}
