import Darwin
import Foundation

public struct LocalOllamaHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: String

    public init(method: String, path: String, body: String) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public final class LocalOllamaServer: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "LocalOllamaServer.state")
    private var listenerFileDescriptor: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private var requests: [LocalOllamaHTTPRequest] = []

    public var generateResponseText = "Local Ollama summary."
    public var modelNames = ["qwen3:8b", "mxbai-embed-large"]
    public private(set) var port: Int = 0

    public init() {}

    deinit {
        stop()
    }

    public func start() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalOllamaServerError.cannotStart
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
        guard bindResult == 0, listen(fd, SOMAXCONN) == 0 else {
            Darwin.close(fd)
            throw LocalOllamaServerError.cannotStart
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let portResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &boundAddressLength)
            }
        }
        guard portResult == 0 else {
            Darwin.close(fd)
            throw LocalOllamaServerError.cannotStart
        }

        listenerFileDescriptor = fd
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
        serverTask = Task.detached { [weak self] in
            self?.acceptConnections(fileDescriptor: fd)
        }
    }

    public func stop() {
        serverTask?.cancel()
        serverTask = nil

        if listenerFileDescriptor >= 0 {
            Darwin.shutdown(listenerFileDescriptor, SHUT_RDWR)
            Darwin.close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }
    }

    public func request(at index: Int) async throws -> LocalOllamaHTTPRequest {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let request = stateQueue.sync(execute: { requests.indices.contains(index) ? requests[index] : nil }) {
                return request
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LocalOllamaServerError.requestNotReceived
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
        defer { Darwin.close(fileDescriptor) }
        guard let request = readRequest(fileDescriptor: fileDescriptor) else {
            return
        }
        stateQueue.sync {
            requests.append(request)
        }

        let payload: String
        if request.method == "GET", request.path == "/api/tags" {
            let models = modelNames
                .map { #"{"name":"\#($0)"}"# }
                .joined(separator: ",")
            payload = #"{"models":[\#(models)]}"#
        } else if request.path == "/api/embeddings" {
            payload = #"{"embedding":[0.25,0.5,0.75]}"#
        } else {
            let escaped = generateResponseText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            payload = #"{"model":"qwen3:8b","response":"\#(escaped)","done":true}"#
        }

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(Data(payload.utf8).count)\r
        Connection: close\r
        \r
        \(payload)
        """
        _ = response.withCString { pointer in
            Darwin.write(fileDescriptor, pointer, strlen(pointer))
        }
    }

    private func readRequest(fileDescriptor: Int32) -> LocalOllamaHTTPRequest? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, 1)
            guard count == 1 else {
                return nil
            }
            bytes.append(buffer[0])
            if bytes.suffix(4) == [13, 10, 13, 10] {
                break
            }
        }

        let headerText = String(decoding: bytes, as: UTF8.self)
        let requestLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first ?? ""
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return nil
        }
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) } ?? 0

        var bodyBytes: [UInt8] = []
        while bodyBytes.count < contentLength {
            let count = Darwin.read(fileDescriptor, &buffer, 1)
            guard count == 1 else {
                return nil
            }
            bodyBytes.append(buffer[0])
        }

        return LocalOllamaHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            body: String(decoding: bodyBytes, as: UTF8.self)
        )
    }
}

public enum LocalOllamaServerError: Error, Equatable, Sendable {
    case cannotStart
    case requestNotReceived
}
