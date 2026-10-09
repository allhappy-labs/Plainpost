import Foundation

/// Bounds of the app-to-service Node session proxy. The request body cap is
/// the Node session transport's own cap (`NodeSessionLimits`), repeated here so
/// the IPC module does not depend on the Node transport; a test pins both.
public enum PlainpostNodeSessionLimits {
    public static let maximumMethodBytes = 16
    public static let maximumPathBytes = 2_048
    public static let maximumRequestBodyBytes = 1_048_576
    /// The largest buffered Node response (the calendar window class).
    public static let maximumResponseBodyBytes = 8 * 1_048_576
    public static let maximumResponseHeaderCount = 64
    public static let maximumResponseHeaderFieldBytes = 8_192
}

/// One Node session request the app asks the service broker to send. The body
/// may carry secrets on their way into the service (for example a CalDAV
/// setup password), so no description ever formats it.
public struct PlainpostNodeSessionRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let method: String
    public let path: String
    public let body: Data

    public init(method: String, path: String, body: Data) throws {
        guard Self.validMethod(method),
              Self.validPath(path),
              body.count <= PlainpostNodeSessionLimits.maximumRequestBodyBytes
        else { throw PlainpostServiceClientError.invalidRequest }
        self.method = method
        self.path = path
        self.body = body
    }

    public init(dto: PlainpostNodeSessionRequestDTO) throws {
        guard dto.schemaVersion == 1 else { throw PlainpostServiceClientError.invalidRequest }
        try self.init(method: dto.method, path: dto.path, body: dto.body)
    }

    public func dto() throws -> PlainpostNodeSessionRequestDTO {
        guard let dto = PlainpostNodeSessionRequestDTO(schemaVersion: 1, method: method, path: path, body: body) else {
            throw PlainpostServiceClientError.invalidRequest
        }
        return dto
    }

    public var description: String { "PlainpostNodeSessionRequest(method: \(method), path: \(path), body: <\(body.count) bytes redacted>)" }
    public var debugDescription: String { description }

    static func validMethod(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= PlainpostNodeSessionLimits.maximumMethodBytes && bytes.allSatisfy { (65...90).contains($0) }
    }

    static func validPath(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty
            && bytes.count <= PlainpostNodeSessionLimits.maximumPathBytes
            && bytes[0] == 47
            && bytes.allSatisfy { $0 > 32 && $0 < 127 }
    }
}

/// The Node's response bytes relayed to the app. The body is never formatted.
public struct PlainpostNodeSessionResponse: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) throws {
        guard (100...599).contains(statusCode),
              headers.count <= PlainpostNodeSessionLimits.maximumResponseHeaderCount,
              headers.allSatisfy({ Self.validHeaderField($0.key, allowEmpty: false) && Self.validHeaderField($0.value, allowEmpty: true) }),
              body.count <= PlainpostNodeSessionLimits.maximumResponseBodyBytes
        else { throw PlainpostServiceClientError.operationFailed }
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public init(dto: PlainpostNodeSessionResponseDTO) throws {
        guard dto.schemaVersion == 1 else { throw PlainpostServiceClientError.serviceUnavailable }
        do {
            try self.init(statusCode: dto.statusCode, headers: dto.headers, body: dto.body)
        } catch {
            throw PlainpostServiceClientError.serviceUnavailable
        }
    }

    public func dto() throws -> PlainpostNodeSessionResponseDTO {
        guard let dto = PlainpostNodeSessionResponseDTO(schemaVersion: 1, statusCode: statusCode, headers: headers, body: body) else {
            throw PlainpostServiceClientError.operationFailed
        }
        return dto
    }

    public var description: String { "PlainpostNodeSessionResponse(statusCode: \(statusCode), body: <\(body.count) bytes redacted>)" }
    public var debugDescription: String { description }

    private static func validHeaderField(_ value: String, allowEmpty: Bool) -> Bool {
        let count = value.utf8.count
        return (allowEmpty || count > 0) && count <= PlainpostNodeSessionLimits.maximumResponseHeaderFieldBytes
    }
}

/// Whether the service can read this Mac's account session and device
/// identity from the shared Keychain group. Branch S (Task 1 `KEY_OUTCOME=shared`)
/// only produces `ready` and `noSession`; the other values stay in the wire
/// contract for the migration and re-enrollment branches.
public enum PlainpostNodeSessionIdentityReadiness: String, Codable, Sendable, CaseIterable {
    case ready
    case noSession = "no_session"
    case needsMigration = "needs_migration"
    case needsReenrollment = "needs_reenrollment"

    /// Decodes the XPC reply string; an unknown value is a service failure.
    public init(dtoString: String) throws {
        guard let value = Self(rawValue: dtoString) else { throw PlainpostServiceClientError.operationFailed }
        self = value
    }
}

/// A Node session failure carried across XPC as `PlainpostXPCErrorCodeNodeSessionFailed`
/// with this raw value as its detail. The broker failures come first; the
/// transport failures mirror `NodeSessionError` so an app-side sender can
/// keep the dispatch/uncertainty distinction the Node clients rely on.
public enum PlainpostNodeSessionFailure: Int, Equatable, Sendable, CaseIterable {
    case noActiveSession = 1
    case noEnrolledNode = 2
    case pathNotAllowed = 3
    case unavailable = 4
    case invalidValue = 5
    case authenticationRejected = 6
    case transportFailure = 7
    case transportFailureAfterDispatch = 8
    case transportCancellationAfterDispatch = 9
    case applicationResultUncertain = 10
    /// The session is not admitted (expired token without a verified lease,
    /// Central refusal, suspension or deletion).
    case notAdmitted = 11
    /// Lease-only admission is read-only; the request would change state.
    case readOnly = 12
}

/// The service methods whose callers the validator restricts beyond the
/// connection-level identity check.
public enum PlainpostServiceMethod: String, CaseIterable, Equatable, Sendable {
    case performNodeSessionRequest
    case invalidateNodeSession
    case nodeSessionIdentityReadiness
    case nodeMailModeStatus
    case serviceIdentity
    /// "Start Over with Saved Sign-ins" after the vault key is lost for good.
    case startOverAfterVaultKeyLoss
}

extension PlainpostNodeSessionRequestDTO: @retroactive @unchecked Sendable {}
extension PlainpostNodeSessionResponseDTO: @retroactive @unchecked Sendable {}
