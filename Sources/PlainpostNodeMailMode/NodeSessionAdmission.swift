import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime

/// How far the service may use the Node session right now. It mirrors the
/// app's account presentation: an unexpired access token is `.active`
/// (read-write); an expired token with a verified offline lease is
/// `.offlineLease` (read-only, mutations dropped); anything else, including a
/// suspended or deleted account, is not admitted.
public enum NodeSessionAdmission: Equatable, Sendable {
    case readWrite
    case readOnly(expiresAt: Date)
}

/// The admission and the trusted-Node binding read locally before every
/// broker lane operation. A binding change (another trusted Node or epoch,
/// or another account session) forces the broker to resolve again.
public struct NodeSessionCheck: Equatable, Sendable {
    public let admission: NodeSessionAdmission
    public let binding: String?

    public init(admission: NodeSessionAdmission, binding: String?) {
        self.admission = admission
        self.binding = binding
    }
}

/// A definite Central refusal of the current access token.
public enum NodeSessionCentralRefusal: Error, Equatable, Sendable {
    case unauthorized
    case suspended
}

public enum NodeSessionAdmissionPolicy {
    public typealias LeaseVerifier = @Sendable (_ credentials: AccountSessionCredentials, _ now: Date) -> Date?

    /// Only a cryptographically verified lease permits an expired token to read.
    public static func admission(accessExpiresAt: Date, verifiedLeaseExpiresAt: Date?, now: Date, suspended: Bool = false) throws -> NodeSessionAdmission {
        guard !suspended else { throw NodeSessionBrokerError.notAdmitted }
        if accessExpiresAt > now { return .readWrite }
        guard let verifiedLeaseExpiresAt, verifiedLeaseExpiresAt > now else { throw NodeSessionBrokerError.notAdmitted }
        return .readOnly(expiresAt: verifiedLeaseExpiresAt)
    }

    /// The app's classification, without the refresh the app performs: the
    /// service never refreshes Central credentials, it reads what the app wrote.
    public static func admission(
        for credentials: AccountSessionCredentials,
        now: Date,
        suspended: Bool,
        leaseVerifier: LeaseVerifier
    ) throws -> NodeSessionAdmission {
        guard !suspended else { throw NodeSessionBrokerError.notAdmitted }
        if now < credentials.accessExpiresAt { return .readWrite }
        guard let expiry = leaseVerifier(credentials, now), expiry > now else { throw NodeSessionBrokerError.notAdmitted }
        return .readOnly(expiresAt: expiry)
    }

    /// The Node routes a read-only (lease-only) session may use: every GET and
    /// the POST-bodied read families. Everything else changes Node or provider
    /// state and is refused, like the app's read-only mail authority.
    public static func permitsReadOnly(method: String, path: String) -> Bool {
        if method == "GET" { return true }
        guard method == "POST" else { return false }
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return readOnlyPostRoutes.contains(route)
    }

    static let readOnlyPostRoutes: Set<String> = [
        "/v1/snapshot",
        "/v1/deltas",
        "/v1/search",
        "/v1/mail/snapshot",
        "/v1/mail/deltas",
        "/v1/mail/mirror/coordinates",
        "/v1/notifications/policy/read",
        "/v1/calendar/connections/read",
        "/v1/calendar/window",
        "/v1/calendar/event",
        "/v1/calendar/invitations",
        "/v1/calendar/operations/read",
    ]

    /// Verifies the lease with the persisted, root-authenticated session-key
    /// manifest (the same high-water store the app maintains).
    public static func persistedLeaseVerifier(secretStore: any AccountSecretStoring = KeychainAccountSecretStore()) -> LeaseVerifier {
        { credentials, now in
            guard let manifests = try? SessionKeyManifestStore(
                bundledDocument: SessionKeyManifestStore.bundledManifest,
                offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
                offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
                secretStore: secretStore
            ), let verifier = try? manifests.verifier() else { return nil }
            return verifier.offlineLeaseVerifier(accountID: credentials.accountID, deviceID: credentials.deviceID)(credentials.offlineLease, now)
        }
    }
}

/// The endpoint-record read of `AccountAPIClient`, keeping Central's status:
/// 401/403 is a definite refusal of the access token, 423 a suspended
/// account, 5xx or a transport failure a reachability problem.
struct StatusClassifyingEndpointRemote: SyncNodeEndpointMetadataRemote {
    let api: AccountAPIClient

    func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> EncryptedAccountRecordV1? {
        guard accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        var cursor: Data?
        for _ in 0..<64 {
            var query = [URLQueryItem(name: "limit", value: "32")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: AccountWireCodec.encodeBase64URL(cursor))) }
            let result = try await api.sendAccountRequestResult(method: "GET", path: "/v1/account-records", queryItems: query, credentials: credentials, device: device, now: now, maximumResponseBytes: AccountWireCodec.maxTrustStatePageBodyBytes)
            let wire: Data
            switch result {
            case .success(let body): wire = body
            case .httpFailure(let status): throw Self.failure(status: status)
            }
            let page = try AccountWireCodec.decodeEncryptedAccountRecordPage(wire)
            if let match = page.records.first(where: { $0.recordID == recordID }) { return match }
            guard !page.terminal, let next = page.nextCursor else { return nil }
            cursor = next
        }
        throw AccountRuntimeError.untrustedResponse
    }

    func putSyncNodeEndpointRecord(_ record: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws {
        // Publishing belongs to enrollment in the app; the service never writes Central records.
        throw AccountRuntimeError.untrustedResponse
    }

    static func failure(status: Int) -> Error {
        switch status {
        case 401, 403: return NodeSessionCentralRefusal.unauthorized
        case 423: return NodeSessionCentralRefusal.suspended
        case 500...599: return AccountRuntimeError.transportFailure
        default: return AccountRuntimeError.untrustedResponse
        }
    }
}
