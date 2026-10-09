import Foundation

private struct LocalAPIVersionHeader: Decodable {
    let apiVersion: Int
    let requestID: String
}

public struct LocalAPICaller: Sendable {
    public let id: String
    public let allowedMethods: Set<LocalAPIMethod>

    public static let browserExtension = LocalAPICaller(
        id: "browser-extension-user",
        allowedMethods: Set(LocalAPIMethod.allCases)
    )
}

public protocol LocalAPIRoute: Sendable {
    var method: LocalAPIMethod { get }
    func handle(requestData: Data, requestID: String) async throws -> Data
}

public struct LocalAPIRouteError: Error, Sendable {
    public let code: LocalAPIErrorCode
    public let safeMessage: String

    public init(code: LocalAPIErrorCode, safeMessage: String) {
        self.code = code
        self.safeMessage = safeMessage
    }
}

public actor LocalAPIRouter {
    private let routes: [LocalAPIMethod: any LocalAPIRoute]

    public init(routes: [any LocalAPIRoute]) {
        self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.method, $0) })
    }

    public func handle(_ data: Data, caller: LocalAPICaller) async -> Data {
        guard data.count <= LocalAPIProtocol.maximumFrameSize,
              let versionHeader = try? JSONDecoder().decode(LocalAPIVersionHeader.self, from: data) else {
            return failure(requestID: nil, code: .invalidRequest, message: "The request is invalid.")
        }
        guard versionHeader.apiVersion == LocalAPIProtocol.version else {
            let code: LocalAPIErrorCode = versionHeader.apiVersion > LocalAPIProtocol.version
                ? .serverUpdateRequired : .clientUpdateRequired
            return failure(requestID: versionHeader.requestID, code: code, message: "Plainpost and the extension must be updated together.")
        }
        guard let header = try? JSONDecoder().decode(LocalAPIRequestHeader.self, from: data) else {
            return failure(requestID: nil, code: .invalidRequest, message: "The request is invalid.")
        }
        guard caller.allowedMethods.contains(header.method) else {
            return failure(requestID: header.requestID, code: .permissionDenied, message: "This client cannot perform that action.")
        }
        guard let route = routes[header.method] else {
            return failure(requestID: header.requestID, code: .invalidRequest, message: "The requested method is unavailable.")
        }
        do {
            return try await route.handle(requestData: data, requestID: header.requestID)
        } catch let error as LocalAPIRouteError {
            return failure(requestID: header.requestID, code: error.code, message: error.safeMessage)
        } catch {
            return failure(requestID: header.requestID, code: .operationFailed, message: "The local operation failed.")
        }
    }

    private func failure(requestID: String?, code: LocalAPIErrorCode, message: String) -> Data {
        let response = LocalAPIFailure(
            apiVersion: LocalAPIProtocol.version,
            requestID: requestID,
            ok: false,
            error: .init(code: code, message: message)
        )
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}
