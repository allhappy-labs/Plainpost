import Foundation

/// Test-only TLS front end for the protocol-faithful loopback mail servers.
/// The generated certificate is returned to the caller, never installed in
/// the system trust store.
public final class LocalImplicitTLSProxy: @unchecked Sendable {
    private let directory: URL
    private let process: Process
    private let stopLock = NSLock()
    private var stopped = false
    public let port: UInt16
    public let certificate: Data

    public init(forwardingTo backendPort: Int, certificateName: String = "localhost") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authorityURL = directory.appendingPathComponent("authority.pem")
        let authorityKeyURL = directory.appendingPathComponent("authority.key")
        let authorityDERURL = directory.appendingPathComponent("authority.der")
        let certificateURL = directory.appendingPathComponent("certificate.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        let requestURL = directory.appendingPathComponent("certificate.csr")
        let extensionsURL = directory.appendingPathComponent("server.ext")
        let portURL = directory.appendingPathComponent("port.txt")
        try Self.run("/opt/homebrew/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", authorityKeyURL.path, "-out", authorityURL.path,
            "-subj", "/CN=Plainpost Fixture CA",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign"
        ])
        try Self.run("/opt/homebrew/bin/openssl", [
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path, "-out", requestURL.path,
            "-subj", "/CN=\(certificateName)"
        ])
        let subjectAltName = certificateName == "localhost"
            ? "IP:127.0.0.1,DNS:localhost" : "DNS:\(certificateName)"
        try "basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=\(subjectAltName)\n"
            .write(to: extensionsURL, atomically: true, encoding: .utf8)
        try Self.run("/opt/homebrew/bin/openssl", [
            "x509", "-req", "-in", requestURL.path,
            "-CA", authorityURL.path, "-CAkey", authorityKeyURL.path, "-CAcreateserial",
            "-out", certificateURL.path, "-days", "1", "-extfile", extensionsURL.path
        ])
        try Self.run("/opt/homebrew/bin/openssl", [
            "x509", "-in", authorityURL.path, "-outform", "der", "-out", authorityDERURL.path
        ])
        certificate = try Data(contentsOf: authorityDERURL)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = ["-u", "-c", Self.proxyScript, certificateURL.path, keyURL.path, portURL.path, String(backendPort)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        var listeningPort: UInt16?
        while Date() < deadline {
            if let value = try? String(contentsOf: portURL, encoding: .utf8),
               let parsed = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                listeningPort = parsed
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let listeningPort else {
            process.terminate()
            process.waitUntilExit()
            throw LocalImplicitTLSProxyError.cannotStart
        }
        port = listeningPort
    }

    deinit { stop() }

    public func stop() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LocalImplicitTLSProxyError.cannotStart }
    }

    private static let proxyScript = #"""
import select
import socket
import ssl
import sys
import threading

cert, key, port_file, backend_port = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(cert, key)
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 0))
listener.listen(16)
with open(port_file, 'w', encoding='utf-8') as output:
    output.write(str(listener.getsockname()[1]))

def relay(client):
    try:
        with context.wrap_socket(client, server_side=True) as secure:
            with socket.create_connection(('127.0.0.1', int(backend_port))) as backend:
                sockets = [secure, backend]
                while True:
                    ready, _, _ = select.select(sockets, [], [], 30)
                    if not ready:
                        return
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        (backend if source is secure else secure).sendall(data)
    except (OSError, ssl.SSLError):
        pass

while True:
    connection, _ = listener.accept()
    threading.Thread(target=relay, args=(connection,), daemon=True).start()
"""#
}

public enum LocalImplicitTLSProxyError: Error {
    case cannotStart
}
