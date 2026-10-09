import Foundation
import XCTest
@testable import PlainpostCore

final class TLSSMTPHarnessTests: XCTestCase {
    func testSecureSMTPClientRejectsSelfSignedCertificateByDefault() throws {
        let server = try LocalImplicitTLSSMTPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = SecureSMTPClient(host: "127.0.0.1", port: server.port)

        do {
            try awaitSend(
                client: client,
                password: "secret",
                subject: "Should fail certificate validation"
            )
            XCTFail("Expected self-signed certificate rejection.")
        } catch {
            XCTAssertEqual(error as? SMTPClientError, .tlsFailed)
        }
    }

    func testSecureSMTPClientSendsThroughImplicitTLSHarnessWithExplicitTestTrustOverride() throws {
        let server = try LocalImplicitTLSSMTPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = SecureSMTPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try awaitSend(client: client, password: "secret", subject: "TLS delivery")

        let captured = try server.capturedMessage()
        XCTAssertTrue(captured.contains("Subject: TLS delivery"), captured)
        XCTAssertTrue(captured.contains("Body over TLS."), captured)
        XCTAssertFalse(captured.contains("secret"))
    }

    func testSecureSMTPClientRejectsTLS11OnlyServerEvenWithLocalTrustOverride() throws {
        let server = try LocalImplicitTLSSMTPServer(
            username: "me@example.com",
            password: "secret",
            tlsMode: .legacyTLS11Only
        )
        try server.start()
        defer { server.stop() }

        let client = SecureSMTPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        do {
            try awaitSend(client: client, password: "secret", subject: "Legacy TLS should fail")
            XCTFail("Expected TLS 1.0/1.1-only server rejection.")
        } catch {
            XCTAssertTrue(error is SMTPClientError, "Expected SMTP transport failure, got \(error).")
        }
        XCTAssertThrowsError(try server.capturedMessage())
    }

    func testStartTLSClientUpgradesBeforeAuthenticationAndSendsThroughHarness() throws {
        let server = try LocalSTARTTLSSMTPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = StartTLSSMTPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try awaitSend(client: client, password: "secret", subject: "STARTTLS delivery")

        let captured = try server.capturedMessage()
        XCTAssertTrue(captured.contains("Subject: STARTTLS delivery"), captured)
        XCTAssertTrue(captured.contains("Body over TLS."), captured)
        XCTAssertFalse(captured.contains("secret"))
    }

    private func awaitSend(client: SMTPClientProtocol, password: String, subject: String) throws {
        let done = XCTestExpectation(description: "send completes")
        let result = LockedSendResult()
        Task {
            do {
                try await client.send(
                    username: "me@example.com",
                    password: password,
                    from: EmailAddress("me@example.com"),
                    to: [EmailAddress("alice@example.com")],
                    data: "Subject: \(subject)\r\n\r\nBody over TLS."
                )
                result.store(.success(()))
            } catch {
                result.store(.failure(error))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        try result.load()?.get()
    }
}

private final class LockedSendResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class LocalImplicitTLSSMTPServer {
    enum TLSMode: String {
        case modern
        case legacyTLS11Only = "legacy_tls_11_only"
    }

    private let username: String
    private let password: String
    private let tlsMode: TLSMode
    private let tempDirectory: URL
    private let portFile: URL
    private let messageFile: URL
    private let certificateFile: URL
    private let keyFile: URL
    private var process: Process?

    private(set) var port: Int = 0

    init(username: String, password: String, tlsMode: TLSMode = .modern) throws {
        self.username = username
        self.password = password
        self.tlsMode = tlsMode
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-tls-smtp-\(UUID().uuidString)", isDirectory: true)
        portFile = tempDirectory.appendingPathComponent("port.txt")
        messageFile = tempDirectory.appendingPathComponent("message.txt")
        certificateFile = tempDirectory.appendingPathComponent("cert.pem")
        keyFile = tempDirectory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try generateCertificate()
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.pythonServerScript,
            certificateFile.path,
            keyFile.path,
            portFile.path,
            messageFile.path,
            username,
            password,
            tlsMode.rawValue
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let portText = try? String(contentsOf: portFile, encoding: .utf8),
               let parsedPort = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = parsedPort
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw SMTPClientError.connectionFailed
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func capturedMessage() throws -> String {
        try String(contentsOf: messageFile, encoding: .utf8)
    }

    private func generateCertificate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyFile.path,
            "-out", certificateFile.path,
            "-days", "1",
            "-subj", "/CN=localhost"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SMTPClientError.connectionFailed
        }
    }

    private static let pythonServerScript = #"""
import base64
import os
import socket
import ssl
import sys

cert_path, key_path, port_path, message_path, username, password, tls_mode = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
if tls_mode == "legacy_tls_11_only":
    context.minimum_version = ssl.TLSVersion.TLSv1
    context.maximum_version = ssl.TLSVersion.TLSv1_1
    context.set_ciphers("ALL:@SECLEVEL=0")
context.load_cert_chain(certfile=cert_path, keyfile=key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_path, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.getsockname()[1]))
    port_file.flush()

conn, _ = server.accept()
try:
    with context.wrap_socket(conn, server_side=True) as tls:
        stream = tls.makefile("rwb", buffering=0)

        def write_line(line):
            stream.write((line + "\r\n").encode("utf-8"))

        def read_line():
            data = stream.readline()
            if not data:
                raise SystemExit(20)
            return data.decode("utf-8").rstrip("\r\n")

        write_line("220 localhost ESMTP TLS ready")
        line = read_line()
        if not line.upper().startswith("EHLO"):
            write_line("500 EHLO required")
            raise SystemExit(21)
        write_line("250-localhost")
        write_line("250 AUTH PLAIN")

        line = read_line()
        if not line.upper().startswith("AUTH PLAIN "):
            write_line("530 AUTH required")
            raise SystemExit(22)
        decoded = base64.b64decode(line.split(" ", 2)[2]).decode("utf-8")
        if decoded != "\0" + username + "\0" + password:
            write_line("535 Authentication failed")
            raise SystemExit(23)
        write_line("235 Authentication successful")

        read_line()
        write_line("250 Sender OK")
        read_line()
        write_line("250 Recipient OK")
        read_line()
        write_line("354 End data with <CR><LF>.<CR><LF>")

        lines = []
        while True:
            line = read_line()
            if line == ".":
                break
            if line.startswith(".."):
                line = line[1:]
            lines.append(line)
        with open(message_path, "w", encoding="utf-8") as message_file:
            message_file.write("\n".join(lines))
        write_line("250 Message accepted")
        read_line()
        write_line("221 Bye")
finally:
    server.close()
"""#
}

private final class LocalSTARTTLSSMTPServer {
    private let username: String
    private let password: String
    private let tempDirectory: URL
    private let portFile: URL
    private let messageFile: URL
    private let certificateFile: URL
    private let keyFile: URL
    private var process: Process?

    private(set) var port: Int = 0

    init(username: String, password: String) throws {
        self.username = username
        self.password = password
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-starttls-smtp-\(UUID().uuidString)", isDirectory: true)
        portFile = tempDirectory.appendingPathComponent("port.txt")
        messageFile = tempDirectory.appendingPathComponent("message.txt")
        certificateFile = tempDirectory.appendingPathComponent("cert.pem")
        keyFile = tempDirectory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try generateCertificate()
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.pythonServerScript,
            certificateFile.path,
            keyFile.path,
            portFile.path,
            messageFile.path,
            username,
            password
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let portText = try? String(contentsOf: portFile, encoding: .utf8),
               let parsedPort = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = parsedPort
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw SMTPClientError.connectionFailed
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func capturedMessage() throws -> String {
        try String(contentsOf: messageFile, encoding: .utf8)
    }

    private func generateCertificate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyFile.path,
            "-out", certificateFile.path,
            "-days", "1",
            "-subj", "/CN=localhost"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SMTPClientError.connectionFailed
        }
    }

    private static let pythonServerScript = #"""
import base64
import socket
import ssl
import sys

cert_path, key_path, port_path, message_path, username, password = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile=cert_path, keyfile=key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_path, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.getsockname()[1]))
    port_file.flush()

conn, _ = server.accept()
try:
    stream = conn.makefile("rwb", buffering=0)

    def write_line(line):
        stream.write((line + "\r\n").encode("utf-8"))

    def read_line():
        data = stream.readline()
        if not data:
            raise SystemExit(20)
        return data.decode("utf-8").rstrip("\r\n")

    write_line("220 localhost ESMTP STARTTLS ready")
    line = read_line()
    if not line.upper().startswith("EHLO"):
        write_line("500 EHLO required")
        raise SystemExit(21)
    write_line("250-localhost")
    write_line("250-STARTTLS")
    write_line("250 AUTH PLAIN")

    line = read_line()
    if line.upper() != "STARTTLS":
        write_line("530 Must issue STARTTLS first")
        raise SystemExit(22)
    write_line("220 Ready to start TLS")

    with context.wrap_socket(conn, server_side=True) as tls:
        stream = tls.makefile("rwb", buffering=0)

        line = read_line()
        if not line.upper().startswith("EHLO"):
            write_line("500 EHLO required after STARTTLS")
            raise SystemExit(23)
        write_line("250-localhost")
        write_line("250 AUTH PLAIN")

        line = read_line()
        if not line.upper().startswith("AUTH PLAIN "):
            write_line("530 AUTH required")
            raise SystemExit(24)
        decoded = base64.b64decode(line.split(" ", 2)[2]).decode("utf-8")
        if decoded != "\0" + username + "\0" + password:
            write_line("535 Authentication failed")
            raise SystemExit(25)
        write_line("235 Authentication successful")

        read_line()
        write_line("250 Sender OK")
        read_line()
        write_line("250 Recipient OK")
        read_line()
        write_line("354 End data with <CR><LF>.<CR><LF>")

        lines = []
        while True:
            line = read_line()
            if line == ".":
                break
            if line.startswith(".."):
                line = line[1:]
            lines.append(line)
        with open(message_path, "w", encoding="utf-8") as message_file:
            message_file.write("\n".join(lines))
        write_line("250 Message accepted")
        read_line()
        write_line("221 Bye")
finally:
    server.close()
"""#
}
