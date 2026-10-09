import CryptoKit
import Foundation
import OSLog
import PlainpostAccountProtocol
#if canImport(Security)
import Security
#endif

private let accountTrustSyncLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "account-security"
)

public struct AccountHTTPResponse: Sendable { public let statusCode: Int; public let headers: [String: String]; public let body: Data; public init(statusCode: Int, headers: [String: String], body: Data) { self.statusCode = statusCode; self.headers = headers; self.body = body } }
/// The authenticated request path exposes only the HTTP status for a
/// rejected response. Response bodies from failures are intentionally never
/// surfaced to callers, while endpoint adapters can still distinguish a
/// permanent rejection from an uncertain retryable transport failure.
public enum AccountAPIRequestResult: Sendable {
    case success(Data)
    case httpFailure(statusCode: Int)
}
public protocol AccountHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse
}
public extension AccountHTTPTransport {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
        return response
    }
}
public protocol AccountTrustHistoryApplying: Sendable {
    func currentTrustCommit() async throws -> TrustStateCommitV1?
    func acceptHistory(_ entries: [AccountTrustHistoryEntryV1]) async throws
}

public actor AccountAPIClient {
    public static let productionBaseURL = URL(string: "https://plainpost-api.olhapi.com")!
    public static let maximumTransportResponseBytes = AccountWireCodec.maxTrustStatePageBodyBytes
    private let transport: any AccountHTTPTransport
    private let credentialStore: any AccountCredentialStoring
    private let manifestStore: BootstrapKeyManifestStore
    private let baseURL: URL
    private let random: @Sendable (Int) throws -> Data
    /// The app a Sign in with Apple token must be issued to; see `AppleSignInIssuedForAnotherApp`.
    private let appleAudience: String?

    public init(transport: any AccountHTTPTransport, credentialStore: any AccountCredentialStoring, manifestStore: BootstrapKeyManifestStore, baseURL: URL = AccountAPIClient.productionBaseURL, random: @escaping @Sendable (Int) throws -> Data = AccountAPIClient.secureRandom, appleAudience: String? = AppleIdentityTokenAudience.runningApp) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw AccountRuntimeError.transportFailure }
        self.transport = transport; self.credentialStore = credentialStore; self.manifestStore = manifestStore; self.baseURL = baseURL; self.random = random
        self.appleAudience = appleAudience
    }
    public init(credentialStore: any AccountCredentialStoring, manifestStore: BootstrapKeyManifestStore, baseURL: URL) throws {
        try self.init(transport: URLSessionAccountHTTPTransport(), credentialStore: credentialStore, manifestStore: manifestStore, baseURL: baseURL)
    }

    public func bootstrapAppleCredential(identityToken: String, nonce: Data, device: AccountDeviceIdentity) async throws -> AccountActivation {
        try Task.checkCancellation()
        try AppleIdentityTokenAudience.requireIssued(to: appleAudience, identityToken: identityToken)
        guard nonce.count == 32 else { throw AccountRuntimeError.untrustedResponse }
        let tokenDigest = Data(SHA256.hash(data: Data(identityToken.utf8)))
        let proof = try device.signature(for: AccountTranscript.exchangeProof(tokenDigest: tokenDigest, nonce: nonce, bundle: device.publicBundle))
        let exchange = try AccountExchangeRequest(appleIdentityToken: identityToken, nonce: nonce, deviceBundle: device.publicBundle, deviceProof: proof)
        let exchangeDigest = Data(SHA256.hash(data: AccountTranscript.exchangeRequest(tokenDigest: tokenDigest, nonce: nonce, bundle: device.publicBundle, proof: proof)))
        let begin = try request(path: "/v1/account/bootstrap/apple/begin", body: try AccountWireCodec.encodeExchangeRequest(exchange))
        let beginResponse = try checkedResponse(try await transport.send(begin))
        try Task.checkCancellation()
        let challenge = try AccountWireCodec.decodeBootstrapChallenge(beginResponse.body)
        guard challenge.exchangeRequestDigest == exchangeDigest, challenge.publicBundle == device.publicBundle else { throw AccountRuntimeError.untrustedResponse }
        try manifestStore.verifyBootstrapChallenge(challenge)
        let challengeDigest = Data(SHA256.hash(data: AccountTranscript.bootstrapChallenge(challenge) + AccountTranscript.part(challenge.serverSignature)))

        let material: Data?
        let commit: AccountTrustStateCommit?
        if challenge.mode == .genesis {
            let constructed = try genesisCommit(challenge: challenge, device: device)
            material = constructed.material; commit = constructed.commit
        } else { material = nil; commit = nil }
        let commitDigest = try commit.map { try digest($0) }
        let unsigned = try AccountBootstrapFinalize(challenge: challenge, challengeDigest: challengeDigest, exchangeRequestDigest: exchangeDigest, genesisCommit: commit, deviceSignature: Data(repeating: 1, count: 64))
        let signature = try device.signature(for: AccountTranscript.finalize(unsigned, commitDigest: commitDigest))
        let finalize = try AccountBootstrapFinalize(challenge: challenge, challengeDigest: challengeDigest, exchangeRequestDigest: exchangeDigest, genesisCommit: commit, deviceSignature: signature)
        let finalizeRequest = try request(path: "/v1/account/bootstrap/apple/finalize", body: try AccountWireCodec.encodeFinalize(finalize))
        let activationResponse = try checkedResponse(try await transport.send(finalizeRequest))
        try Task.checkCancellation()
        let decodedActivation = try AccountWireCodec.encodeActivation(activationResponse.body)
        guard decodedActivation.accountID == challenge.accountID, decodedActivation.deviceID == challenge.deviceID,
              (commit == nil || decodedActivation.currentTrustCommit.map(AccountTranscript.trustCommitDigest) == commit.map(AccountTranscript.trustCommitDigest))
        else { throw AccountRuntimeError.untrustedResponse }
        let activation = AccountActivation(accountID: decodedActivation.accountID, deviceID: decodedActivation.deviceID, mode: challenge.mode, accessToken: decodedActivation.accessToken, accessExpiresAt: decodedActivation.accessExpiresAt, refreshCredential: decodedActivation.refreshCredential, offlineLease: decodedActivation.offlineLease, currentTrustCommit: decodedActivation.currentTrustCommit)
        if let access = activation.accessToken, let accessExpiry = activation.accessExpiresAt, let refresh = activation.refreshCredential, let lease = activation.offlineLease {
            let credentials = try AccountSessionCredentials(accountID: activation.accountID, deviceID: activation.deviceID, accessToken: access, accessExpiresAt: accessExpiry, refreshCredential: refresh, offlineLease: lease)
            if activation.mode == .pending { try credentialStore.commitPendingActivation(activation, credentials: credentials) }
            else { try credentialStore.commitActivation(activation, credentials: credentials, genesisMaterial: material) }
        } else {
            try credentialStore.commitProvisionalActivation(activation, genesisMaterial: material)
        }
        return activation
    }

    public func refreshSession(_ credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date()) async throws -> AccountSessionCredentials {
        let bodyObject: [String: String] = ["accountID": credentials.accountID.rawValue, "deviceID": credentials.deviceID.rawValue, "refreshCredential": AccountWireCodec.encodeBase64URL(credentials.refreshCredential)]
        let body = try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let nonce = try random(32); guard nonce.count == 32 else { throw AccountRuntimeError.cryptographicFailure }
        let digest = Data(SHA256.hash(data: body))
        let seconds = UInt64(max(0, now.timeIntervalSince1970.rounded(.towardZero)))
        let signature = try device.signature(for: AccountTranscript.sessionProof(accountID: credentials.accountID, deviceID: credentials.deviceID, method: "POST", path: "/v1/sessions/refresh", bodyDigest: digest, timestamp: seconds, nonce: nonce))
        let proof: [String: String] = ["method": "POST", "path": "/v1/sessions/refresh", "bodyDigest": AccountWireCodec.encodeBase64URL(digest), "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))), "nonce": AccountWireCodec.encodeBase64URL(nonce), "signature": AccountWireCodec.encodeBase64URL(signature)]
        var request = try self.request(path: "/v1/sessions/refresh", body: body)
        request.setValue(AccountWireCodec.encodeBase64URL(try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .withoutEscapingSlashes])), forHTTPHeaderField: "DPoP")
        let response: AccountHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AccountSessionRefreshFailure.network }
        if response.statusCode == 423 { throw AccountSessionRefreshFailure.suspended }
        guard response.statusCode == 200 else { throw AccountSessionRefreshFailure.rejected }
        guard response.body.count > 0, response.body.count <= AccountWireCodec.maxBodyBytes, response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased().hasPrefix("application/json") == true, let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], Set(root.keys) == Set(["kind", "accessToken", "accessExpiresAt", "refreshCredential", "refreshCredentialID", "refreshExpiresAt", "offlineLease", "offlineLeaseExpiresAt"]), root["kind"] as? String == "account.session-refresh.v1", let access = root["accessToken"] as? String, let accessExpires = root["accessExpiresAt"] as? String, let refresh = root["refreshCredential"] as? String, let refreshID = root["refreshCredentialID"] as? String, (try? PlainpostAccountID(refreshID)) != nil, let refreshExpires = root["refreshExpiresAt"] as? String, let lease = root["offlineLease"] as? String, let leaseExpires = root["offlineLeaseExpiresAt"] as? String, let accessDate = AccountWireCodec.parseTimestamp(accessExpires), let refreshDate = AccountWireCodec.parseTimestamp(refreshExpires), let leaseDate = AccountWireCodec.parseTimestamp(leaseExpires), refreshDate > now, leaseDate > now else { throw AccountSessionRefreshFailure.rejected }
        return try AccountSessionCredentials(accountID: credentials.accountID, deviceID: credentials.deviceID, accessToken: access, accessExpiresAt: accessDate, refreshCredential: try AccountWireCodec.decodeBase64URL(refresh, exactBytes: 32), offlineLease: lease)
    }

    public func sendAccountRequest(method: String, path: String, queryItems: [URLQueryItem] = [], body: Data? = nil, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date(), maximumRequestBytes: Int = 512 * 1024, maximumResponseBytes: Int = AccountAPIClient.maximumTransportResponseBytes, expectedStatusCodes: Set<Int> = [200]) async throws -> Data {
        try Task.checkCancellation()
        let accessToken = credentials.accessToken
        guard ["GET", "POST", "PUT", "DELETE"].contains(method), path.hasPrefix("/v1/"), !path.contains("?"), !accessToken.isEmpty, !accessToken.contains(where: { $0.isWhitespace }), maximumRequestBytes > 0, maximumResponseBytes > 0, maximumResponseBytes <= Self.maximumTransportResponseBytes, !expectedStatusCodes.isEmpty, expectedStatusCodes.allSatisfy({ (200...299).contains($0) }), (body?.count ?? 0) <= maximumRequestBytes else { throw AccountRuntimeError.transportFailure }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw AccountRuntimeError.transportFailure }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else { throw AccountRuntimeError.transportFailure }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let requestBody = body ?? Data()
        let bodyDigest = Data(SHA256.hash(data: requestBody))
        let tokenDigest = Data(SHA256.hash(data: Data(accessToken.utf8)))
        let nonce = try random(32)
        guard nonce.count == 32 else { throw AccountRuntimeError.cryptographicFailure }
        let seconds = UInt64(max(0, now.timeIntervalSince1970.rounded(.towardZero)))
        let target = url.path + (url.query.map { "?\($0)" } ?? "")
        let signature = try device.signature(for: AccountTranscript.accountRequestProof(accountID: credentials.accountID, deviceID: credentials.deviceID, method: method, target: target, bodyDigest: bodyDigest, accessTokenDigest: tokenDigest, timestamp: seconds, nonce: nonce))
        let proof: [String: String] = ["method": method, "target": target, "bodyDigest": AccountWireCodec.encodeBase64URL(bodyDigest), "accessTokenDigest": AccountWireCodec.encodeBase64URL(tokenDigest), "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))), "nonce": AccountWireCodec.encodeBase64URL(nonce), "signature": AccountWireCodec.encodeBase64URL(signature)]
        request.setValue(AccountWireCodec.encodeBase64URL(try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .withoutEscapingSlashes])), forHTTPHeaderField: "DPoP")
        request.timeoutInterval = 20
        let response = try await transport.send(request, maximumResponseBytes: maximumResponseBytes)
        try Task.checkCancellation()
        // A server-side failure cannot establish whether an idempotent account
        // mutation committed before the response path failed. Surface it with
        // the existing uncertain transport taxonomy so callers can replay the
        // same signed request; 4xx responses remain definite rejections.
        if (500 ... 599).contains(response.statusCode) { throw AccountRuntimeError.transportFailure }
        guard expectedStatusCodes.contains(response.statusCode), response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.untrustedResponse }
        if response.statusCode != 204 {
            guard !response.body.isEmpty, response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased().hasPrefix("application/json") == true else { throw AccountRuntimeError.untrustedResponse }
        } else if !response.body.isEmpty { throw AccountRuntimeError.untrustedResponse }
        return response.body
    }

    /// Authenticated request seam for adapters whose retry policy depends on
    /// the HTTP status. It deliberately returns no failure body. Transport
    /// failures still throw `AccountRuntimeError.transportFailure`; a server
    /// response outside `expectedStatusCodes` is a status-only result.
    public func sendAccountRequestResult(method: String, path: String, queryItems: [URLQueryItem] = [], body: Data? = nil, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date(), maximumRequestBytes: Int = 512 * 1024, maximumResponseBytes: Int = AccountAPIClient.maximumTransportResponseBytes, expectedStatusCodes: Set<Int> = [200]) async throws -> AccountAPIRequestResult {
        try Task.checkCancellation()
        let accessToken = credentials.accessToken
        guard ["GET", "POST", "PUT", "DELETE"].contains(method), path.hasPrefix("/v1/"), !path.contains("?"), !accessToken.isEmpty, !accessToken.contains(where: { $0.isWhitespace }), maximumRequestBytes > 0, maximumResponseBytes > 0, maximumResponseBytes <= Self.maximumTransportResponseBytes, !expectedStatusCodes.isEmpty, expectedStatusCodes.allSatisfy({ (200...299).contains($0) }), (body?.count ?? 0) <= maximumRequestBytes else { throw AccountRuntimeError.transportFailure }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw AccountRuntimeError.transportFailure }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else { throw AccountRuntimeError.transportFailure }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let requestBody = body ?? Data()
        let bodyDigest = Data(SHA256.hash(data: requestBody))
        let tokenDigest = Data(SHA256.hash(data: Data(accessToken.utf8)))
        let nonce = try random(32)
        guard nonce.count == 32 else { throw AccountRuntimeError.cryptographicFailure }
        let seconds = UInt64(max(0, now.timeIntervalSince1970.rounded(.towardZero)))
        let target = url.path + (url.query.map { "?\($0)" } ?? "")
        let signature = try device.signature(for: AccountTranscript.accountRequestProof(accountID: credentials.accountID, deviceID: credentials.deviceID, method: method, target: target, bodyDigest: bodyDigest, accessTokenDigest: tokenDigest, timestamp: seconds, nonce: nonce))
        let proof: [String: String] = ["method": method, "target": target, "bodyDigest": AccountWireCodec.encodeBase64URL(bodyDigest), "accessTokenDigest": AccountWireCodec.encodeBase64URL(tokenDigest), "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))), "nonce": AccountWireCodec.encodeBase64URL(nonce), "signature": AccountWireCodec.encodeBase64URL(signature)]
        request.setValue(AccountWireCodec.encodeBase64URL(try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .withoutEscapingSlashes])), forHTTPHeaderField: "DPoP")
        request.timeoutInterval = 20
        let response = try await transport.send(request, maximumResponseBytes: maximumResponseBytes)
        try Task.checkCancellation()
        guard expectedStatusCodes.contains(response.statusCode) else {
            return .httpFailure(statusCode: response.statusCode)
        }
        guard response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
        if response.statusCode != 204 {
            guard !response.body.isEmpty, response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased().hasPrefix("application/json") == true else { throw AccountRuntimeError.untrustedResponse }
        } else if !response.body.isEmpty { throw AccountRuntimeError.untrustedResponse }
        return .success(response.body)
    }

    public func issueStepUp(
        action: AccountLifecycleAction,
        targetDeviceID: AccountDeviceID?,
        currentCommitDigest: Data,
        identityToken: String,
        appleNonce: Data,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date = Date()
    ) async throws -> AccountStepUpAuthorizationV1 {
        try AppleIdentityTokenAudience.requireIssued(to: appleAudience, identityToken: identityToken)
        let request = try AccountStepUpRequestV1(
            accountID: credentials.accountID, actorDeviceID: credentials.deviceID,
            targetDeviceID: targetDeviceID, action: action, currentCommitDigest: currentCommitDigest,
            requestNonce: try exactRandom(32), appleNonce: appleNonce, identityToken: identityToken
        )
        let body = try AccountWireCodec.encodeStepUpRequest(request)
        let response = try await sendAccountRequest(method: "POST", path: "/v1/account/lifecycle/step-up", body: body, credentials: credentials, device: device, now: now)
        let authorization = try AccountWireCodec.decodeStepUpAuthorization(response)
        guard authorization.accountID == credentials.accountID,
              authorization.actorDeviceID == credentials.deviceID,
              authorization.targetDeviceID == targetDeviceID,
              authorization.action == action,
              authorization.currentCommitDigest == currentCommitDigest,
              authorization.requestDigest == Data(SHA256.hash(data: AccountTranscript.stepUpRequest(request)))
        else { throw AccountRuntimeError.untrustedResponse }
        try manifestStore.verifyStepUpAuthorization(authorization)
        return authorization
    }

    public func submitLifecycle(
        authorization: AccountStepUpAuthorizationV1,
        candidate: AccountTrustHistoryEntryV1,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date = Date()
    ) async throws -> AccountTrustHistoryEntryV1 {
        let body = try AccountWireCodec.encodeLifecycleSubmission(AccountLifecycleSubmissionV1(authorization: authorization, entry: candidate))
        let response = try await sendAccountRequest(method: "PUT", path: "/v1/account/lifecycle", body: body, credentials: credentials, device: device, now: now)
        let accepted = try AccountWireCodec.decodeTrustHistoryEntry(response)
        guard accepted == candidate else { throw AccountRuntimeError.untrustedResponse }
        return accepted
    }

    public func securityEvents(
        cursor: String? = nil,
        limit: Int = 32,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date = Date()
    ) async throws -> AccountSecurityEventPageV1 {
        guard (1...32).contains(limit) else { throw AccountRuntimeError.transportFailure }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.insert(URLQueryItem(name: "cursor", value: cursor), at: 0) }
        let body = try await sendAccountRequest(method: "GET", path: "/v1/account/security-events", queryItems: query, credentials: credentials, device: device, now: now)
        return try AccountWireCodec.decodeSecurityEventPage(body)
    }

    public func deleteAccount(
        authorization: AccountStepUpAuthorizationV1,
        currentCommitDigest: Data,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date = Date()
    ) async throws -> AccountDeletionResultV1 {
        let request = try AccountDeletionRequestV1(accountID: credentials.accountID, headCommitDigest: currentCommitDigest, authorization: authorization)
        let requestBody = try AccountWireCodec.encodeDeletionRequest(request)
        let body: Data
        do {
            body = try await sendAccountRequest(method: "POST", path: "/v1/account/delete", body: requestBody, credentials: credentials, device: device, now: now)
        } catch AccountRuntimeError.transportFailure {
            try Task.checkCancellation()
            body = try await sendAccountRequest(method: "POST", path: "/v1/account/delete", body: requestBody, credentials: credentials, device: device, now: now)
        }
        let result = try AccountWireCodec.decodeDeletionResult(body)
        guard result.accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        return result
    }

    public func registerCleanup(
        _ registration: AccountCleanupRegistrationV1,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date = Date()
    ) async throws -> AccountCleanupRegistrationReceiptV1 {
        let body = try AccountWireCodec.encodeCleanupRegistration(registration)
        let response = try await sendAccountRequest(method: "PUT", path: "/v1/account/cleanup-registration", body: body, credentials: credentials, device: device, now: now, maximumRequestBytes: 512, maximumResponseBytes: 512)
        let receipt = try AccountWireCodec.decodeCleanupRegistrationReceipt(response)
        guard receipt.targetHandle == registration.targetHandle else { throw AccountRuntimeError.untrustedResponse }
        return receipt
    }

    public func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 {
        guard (43...64).contains(setupCode.utf8.count) else { throw AccountRuntimeError.untrustedResponse }
        let body = try nodeEnrollmentDocument(["setupCode": setupCode])
        return try AccountWireCodec.decodeNodeEnrollmentPublicClaim(try await sendPublicLifecycleRequest(path: "/v1/sync-nodes/claims/lookup", body: body, maximumResponseBytes: 2048))
    }

    public func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        let body = try nodeEnrollmentDocument(["setupCode": setupCode, "claimID": claimID.rawValue])
        _ = try await sendPublicLifecycleRequest(path: "/v1/sync-nodes/claims/cancel", body: body, maximumResponseBytes: 1, expectedStatus: 204)
    }

    public func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date = Date()) async throws -> AccountStepUpAuthorizationV1 {
        let lifecycleAction: AccountLifecycleAction = action == .enroll ? .enrollSyncNode : .replaceSyncNode
        let target = action == .enroll ? claim.nodeDeviceID : replacedNodeID
        guard (action == .enroll) == (replacedNodeID == nil), let target else { throw AccountRuntimeError.untrustedResponse }
        let stepUp = try AccountStepUpRequestV1(accountID: credentials.accountID, actorDeviceID: credentials.deviceID, targetDeviceID: target, action: lifecycleAction, currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit), requestNonce: try exactRandom(32), appleNonce: authorization.nonce, identityToken: authorization.identityToken)
        let encodedStepUp = try AccountWireCodec.encodeStepUpRequest(stepUp)
        let stepUpObject = try JSONSerialization.jsonObject(with: encodedStepUp)
        let body = try nodeEnrollmentDocument(["kind": "account.sync-node-step-up-request.v1", "stepUp": stepUpObject, "claimID": claim.claimID.rawValue, "proposedNodeDeviceID": claim.nodeDeviceID.rawValue])
        let response = try await sendAccountRequest(method: "POST", path: "/v1/sync-nodes/step-up", body: body, credentials: credentials, device: device, now: now, maximumRequestBytes: 32 * 1024, maximumResponseBytes: 32 * 1024)
        let issued = try AccountWireCodec.decodeStepUpAuthorization(response)
        guard issued.accountID == credentials.accountID, issued.actorDeviceID == credentials.deviceID, issued.targetDeviceID == target, issued.action == lifecycleAction, issued.currentCommitDigest == stepUp.currentCommitDigest else { throw AccountRuntimeError.untrustedResponse }
        // The authorization is issued after this request crosses the network.
        // Verify freshness at receipt rather than against the request timestamp.
        try manifestStore.verifyStepUpAuthorization(issued)
        return issued
    }

    public func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date()) async throws -> SyncNodeEnrollmentAdmissionResponse {
        let body = try Self.syncNodeAdmissionBody(request)
        let path = request.evidence.action == .enroll ? "/v1/sync-nodes/enrollment/approve" : "/v1/sync-nodes/replacement"
        let result: AccountAPIRequestResult
        do {
            result = try await sendAccountRequestResult(method: "POST", path: path, body: body, credentials: credentials, device: device, now: now, maximumRequestBytes: 768 * 1024, maximumResponseBytes: 768 * 1024)
        } catch AccountRuntimeError.untrustedResponse {
            // Only a 2xx with a missing body or a non-JSON content type
            // reaches this error here. Central may have committed it.
            throw SyncNodeEnrollmentCommitError.undecodableSuccess
        }
        return try Self.classifySyncNodeAdmission(result)
    }

    static func syncNodeAdmissionBody(_ request: SyncNodeEnrollmentAdmissionRequest) throws -> Data {
        var object: [String: Any] = [
            "kind": "account.sync-node-admission-request.v1",
            "evidence": try JSONSerialization.jsonObject(with: AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence)),
            "claimProofSignature": AccountWireCodec.encodeBase64URL(request.claimProofSignature),
            "matchingConfirmationSignature": AccountWireCodec.encodeBase64URL(request.matchingConfirmationSignature),
            "admissionApprovalSignature": AccountWireCodec.encodeBase64URL(request.admissionApprovalSignature),
            "idempotencyKey": AccountWireCodec.encodeBase64URL(request.idempotencyKey),
            "trustCommit": try JSONSerialization.jsonObject(with: AccountWireCodec.encodeTrustCommit(request.trustCommit)),
        ]
        if let audience = request.expectedCentralAudience { object["expectedCentralAudience"] = audience }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func classifySyncNodeAdmission(_ result: AccountAPIRequestResult) throws -> SyncNodeEnrollmentAdmissionResponse {
        switch result {
        case .httpFailure(statusCode: let status) where (500 ... 599).contains(status):
            throw AccountRuntimeError.transportFailure
        case .httpFailure(statusCode: 422):
            throw SyncNodeEnrollmentCommitError.audienceMismatch
        case .httpFailure(statusCode: let status) where (200 ... 299).contains(status):
            // A success status other than the expected 200: possibly committed.
            throw SyncNodeEnrollmentCommitError.undecodableSuccess
        case .httpFailure:
            throw AccountRuntimeError.untrustedResponse
        case .success(let document):
            do { return try decodeSyncNodeAdmissionResponse(document) }
            catch { throw SyncNodeEnrollmentCommitError.undecodableSuccess }
        }
    }

    private static func decodeSyncNodeAdmissionResponse(_ document: Data) throws -> SyncNodeEnrollmentAdmissionResponse {
        guard let root = try JSONSerialization.jsonObject(with: document) as? [String: Any], let kind = root["kind"] as? String else { throw AccountRuntimeError.untrustedResponse }
        if kind == "account.sync-node-admission-response.v2" { return try SyncNodeEnrollmentAdmissionResponse(v2: AccountWireCodec.decodeNodeEnrollmentAdmissionResponseV2(document)) }
        guard Set(root.keys) == Set(["kind", "result", "refreshCredential", "offlineLease"]), kind == "account.sync-node-admission-response.v1", let result = root["result"], let refresh = root["refreshCredential"], let lease = root["offlineLease"] else { throw AccountRuntimeError.untrustedResponse }
        return try SyncNodeEnrollmentAdmissionResponse(result: AccountWireCodec.decodeNodeEnrollmentResult(JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])), refreshCredential: AccountWireCodec.decodeNodeRefreshCredential(JSONSerialization.data(withJSONObject: refresh, options: [.sortedKeys, .withoutEscapingSlashes])), offlineLease: AccountWireCodec.decodeNodeOfflineLease(JSONSerialization.data(withJSONObject: lease, options: [.sortedKeys, .withoutEscapingSlashes])))
    }

    public func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data) {
        guard appleNonce.count == 32 else { throw AccountRecoveryFailure.requestPreparation }
        try AppleIdentityTokenAudience.requireIssued(to: appleAudience, identityToken: identityToken)
        let exchangeDigest: Data
        let requestBody: Data
        do {
            let tokenDigest = Data(SHA256.hash(data: Data(identityToken.utf8)))
            let proof = try device.signature(for: AccountTranscript.exchangeProof(tokenDigest: tokenDigest, nonce: appleNonce, bundle: device.publicBundle))
            let request = try AccountRecoveryRequestV1(identityToken: identityToken, appleNonce: appleNonce, publicBundle: device.publicBundle, deviceProof: proof)
            exchangeDigest = Data(SHA256.hash(data: AccountTranscript.exchangeRequest(tokenDigest: tokenDigest, nonce: appleNonce, bundle: device.publicBundle, proof: proof)))
            requestBody = try AccountWireCodec.encodeRecoveryRequest(request)
        } catch {
            throw AccountRecoveryFailure.requestPreparation
        }
        let body: Data
        do {
            body = try await sendPublicLifecycleRequest(path: "/v1/account/recovery/prepare", body: requestBody, maximumResponseBytes: 16 * 1024 * 1024)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountRecoveryFailure.serverPreparation
        }
        let preparation: AccountRecoveryPreparationV1
        do {
            preparation = try AccountWireCodec.decodeRecoveryPreparation(body)
        } catch {
            throw AccountRecoveryFailure.responseDecoding
        }
        guard preparation.authorization.publicBundle == device.publicBundle,
              preparation.authorization.exchangeRequestDigest == exchangeDigest,
              preparation.priorHistory.last.map({ AccountTranscript.trustCommitDigest($0.commit) }) == preparation.authorization.priorCommitDigest,
              preparation.authorization.platform != AccountPlatform.syncNode
        else { throw AccountRecoveryFailure.responseBinding }
        do {
            try manifestStore.verifyHistoricalRecoveryAuthorization(preparation.authorization, historicalManifest: preparation.historicalManifest, expectedAccountID: preparation.authorization.accountID, expectedEpoch: preparation.authorization.epoch, expectedDeviceID: preparation.authorization.deviceID, expectedPlatform: preparation.authorization.platform, expectedPublicBundle: device.publicBundle, expectedPriorCommitDigest: preparation.authorization.priorCommitDigest, expectedExchangeRequestDigest: exchangeDigest)
        } catch {
            throw AccountRecoveryFailure.authorizationVerification
        }
        return (preparation, exchangeDigest)
    }

    public func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1 {
        let nonce = try exactRandom(32)
        let unsigned = try AccountRecoveryCommitRequestV1(authorizationID: authorizationID, requestNonce: nonce, entry: candidate, deviceProof: Data(repeating: 1, count: 64))
        let proof = try device.signature(for: AccountTranscript.recoveryCommitProof(unsigned))
        let request = try AccountRecoveryCommitRequestV1(authorizationID: authorizationID, requestNonce: nonce, entry: candidate, deviceProof: proof)
        let requestBody = try AccountWireCodec.encodeRecoveryCommitRequest(request)
        let body: Data
        do {
            body = try await sendPublicLifecycleRequest(path: "/v1/account/recovery/commit", body: requestBody, maximumResponseBytes: 640 * 1024)
        } catch AccountRuntimeError.transportFailure {
            try Task.checkCancellation()
            body = try await sendPublicLifecycleRequest(path: "/v1/account/recovery/commit", body: requestBody, maximumResponseBytes: 640 * 1024)
        }
        let activation = try AccountWireCodec.decodeRecoveryActivation(body)
        guard activation.acceptedEntry == candidate else { throw AccountRuntimeError.untrustedResponse }
        return activation
    }

    public func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1 {
        let body = try await sendPublicLifecycleRequest(path: "/v1/account/cleanup/check", body: AccountWireCodec.encodeCleanupCheck(check), maximumResponseBytes: AccountWireCodec.maxBodyBytes)
        return try AccountWireCodec.decodeCleanupDirective(body)
    }

    public func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws {
        guard cleanupCredential.count == 32 else { throw AccountRuntimeError.untrustedResponse }
        _ = try await sendPublicLifecycleRequest(path: "/v1/account/cleanup/ack", body: AccountWireCodec.encodeCleanupAcknowledgement(acknowledgement), maximumResponseBytes: 1, authorization: "Cleanup \(AccountWireCodec.encodeBase64URL(cleanupCredential))", expectedStatus: 204)
    }

    private func sendPublicLifecycleRequest(path: String, body: Data, maximumResponseBytes: Int, authorization: String? = nil, expectedStatus: Int = 200) async throws -> Data {
        guard body.count <= 640 * 1024, let url = URL(string: path, relativeTo: baseURL) else { throw AccountRuntimeError.transportFailure }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20
        let response = try await transport.send(request, maximumResponseBytes: maximumResponseBytes)
        try Task.checkCancellation()
        guard response.statusCode == expectedStatus else { throw AccountRuntimeError.untrustedResponse }
        if expectedStatus == 204 { guard response.body.isEmpty else { throw AccountRuntimeError.untrustedResponse }; return Data() }
        guard !response.body.isEmpty, response.body.count <= maximumResponseBytes,
              response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased().hasPrefix("application/json") == true
        else { throw AccountRuntimeError.untrustedResponse }
        return response.body
    }

    private func nodeEnrollmentDocument(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func exactRandom(_ count: Int) throws -> Data {
        let value = try random(count)
        guard value.count == count, !value.allSatisfy({ $0 == 0 }) else { throw AccountRuntimeError.cryptographicFailure }
        return value
    }

    public func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date = Date()) async throws -> TrustStateCommitV1? {
        var cursor: AccountTrustCursorV1?
        var restarted = false
        while true {
            try Task.checkCancellation()
            let current = try await applying.currentTrustCommit()
            let expectedAfter: AccountTrustAfterV1
            let query: [URLQueryItem]
            if let cursor {
                expectedAfter = cursor.after
                query = [URLQueryItem(name: "cursor", value: AccountWireCodec.encodeBase64URL(try AccountWireCodec.encodeTrustCursor(cursor))), URLQueryItem(name: "limit", value: "32")]
            } else if let current {
                let checkpoint = try AccountTrustPageCheckpointV1(epoch: current.state.epoch, revision: current.state.revision, commitDigest: AccountTranscript.trustCommitDigest(current))
                expectedAfter = .checkpoint(checkpoint)
                query = [URLQueryItem(name: "afterEpoch", value: current.state.epoch.wireValue), URLQueryItem(name: "afterRevision", value: current.state.revision.wireValue), URLQueryItem(name: "afterCommitDigest", value: AccountWireCodec.encodeBase64URL(checkpoint.commitDigest)), URLQueryItem(name: "limit", value: "32")]
            } else {
                expectedAfter = .genesis
                query = [URLQueryItem(name: "after", value: "genesis"), URLQueryItem(name: "limit", value: "32")]
            }
            do {
                let body: Data
                do {
                    body = try await sendAccountRequest(method: "GET", path: "/v1/trust/chain", queryItems: query, credentials: credentials, device: device, now: now, maximumResponseBytes: AccountWireCodec.maxTrustStatePageBodyBytes)
                } catch {
                    accountTrustSyncLogger.error("trust_sync_failed step=request error_type=\(String(reflecting: type(of: error)), privacy: .public)")
                    throw error
                }
                let page: AccountTrustStatePageV1
                do {
                    page = try AccountWireCodec.decodeTrustStatePage(body)
                } catch {
                    let reason = trustStatePageDecodeFailureReason(body)
                    accountTrustSyncLogger.error(
                        "trust_sync_failed step=decode reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    throw error
                }
                do {
                    try manifestStore.verifyTrustStatePage(page, expectedAccountID: credentials.accountID, expectedAfter: expectedAfter, expectedCursor: cursor)
                } catch {
                    accountTrustSyncLogger.error("trust_sync_failed step=verify_page error_type=\(String(reflecting: type(of: error)), privacy: .public)")
                    throw error
                }
                try Task.checkCancellation()
                if !page.entries.isEmpty {
                    do {
                        try await applying.acceptHistory(page.entries)
                    } catch {
                        accountTrustSyncLogger.error("trust_sync_failed step=apply_history error_type=\(String(reflecting: type(of: error)), privacy: .public)")
                        throw error
                    }
                }
                if page.terminal {
                    do {
                        return try await applying.currentTrustCommit()
                    } catch {
                        accountTrustSyncLogger.error("trust_sync_failed step=read_head error_type=\(String(reflecting: type(of: error)), privacy: .public)")
                        throw error
                    }
                }
                cursor = page.nextCursor
            } catch is CancellationError { throw CancellationError() }
            catch where cursor != nil && !restarted {
                restarted = true
                cursor = nil
            }
        }
    }

    private func trustStatePageDecodeFailureReason(_ body: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return "document" }
        let expectedFields = Set([
            "kind", "requestCursor", "accountID", "snapshotHead", "entries",
            "nextCursor", "terminal", "issuedAt", "expiresAt", "serverKeyID",
            "serverSignature"
        ])
        guard Set(root.keys) == expectedFields else { return "root_fields" }
        guard root["kind"] as? String == "account.trust-state-page.v1" else { return "kind" }
        guard let requestCursor = root["requestCursor"],
              let requestCursorWire = try? JSONSerialization.data(
                  withJSONObject: requestCursor,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { return "request_cursor_document" }
        do {
            _ = try AccountWireCodec.decodeTrustCursor(requestCursorWire)
        } catch {
            return "request_cursor_\(String(describing: error))"
        }
        guard let entries = root["entries"] as? [Any], entries.count <= 32
        else { return "entries_container" }
        for entry in entries {
            guard let entryWire = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else { return "history_entry_document" }
            do {
                _ = try AccountWireCodec.decodeTrustHistoryEntry(entryWire)
            } catch {
                return "history_entry_\(String(describing: error))"
            }
        }
        if let nextCursor = root["nextCursor"], !(nextCursor is NSNull) {
            guard let nextCursorWire = try? JSONSerialization.data(
                withJSONObject: nextCursor,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else { return "next_cursor_document" }
            do {
                _ = try AccountWireCodec.decodeTrustCursor(nextCursorWire)
            } catch {
                return "next_cursor_\(String(describing: error))"
            }
        }
        guard let signature = root["serverSignature"] as? String,
              (try? AccountWireCodec.decodeBase64URL(signature, exactBytes: 64)) != nil
        else { return "server_signature" }
        return "page_invariants"
    }

    private func genesisCommit(challenge: AccountBootstrapChallenge, device: AccountDeviceIdentity) throws -> (commit: AccountTrustStateCommit, material: Data) {
        let material = try random(64)
        guard material.count == 64 else { throw AccountRuntimeError.cryptographicFailure }
        let commitment = Data(SHA256.hash(data: material))
        let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(1))
        let revision = try PositiveUInt64(1)
        let keyGeneration = try PositiveUInt64(1)
        let transition = try AccountTrustTransition(kind: .genesis, targetDeviceIDs: [challenge.deviceID], priorRecordDigests: [])
        let unsignedRecord = try AccountDeviceTrustRecord(accountID: challenge.accountID, epoch: epoch, revision: revision, deviceID: challenge.deviceID, platform: challenge.platform, publicBundle: device.publicBundle, signerDeviceID: challenge.deviceID, signature: Data(repeating: 1, count: 64))
        let record = try AccountDeviceTrustRecord(accountID: unsignedRecord.accountID, epoch: unsignedRecord.epoch, revision: unsignedRecord.revision, deviceID: unsignedRecord.deviceID, platform: unsignedRecord.platform, publicBundle: unsignedRecord.publicBundle, signerDeviceID: unsignedRecord.signerDeviceID, signature: device.signature(for: AccountTranscript.trustRecord(unsignedRecord)))
        let unsignedState = try AccountTrustState(accountID: challenge.accountID, epoch: epoch, revision: revision, previousCommitDigest: nil, transition: transition, keyGeneration: keyGeneration, keyCommitment: commitment, members: [record], signerDeviceID: challenge.deviceID, signature: Data(repeating: 1, count: 64))
        let state = try AccountTrustState(accountID: unsignedState.accountID, epoch: unsignedState.epoch, revision: unsignedState.revision, previousCommitDigest: nil, transition: unsignedState.transition, keyGeneration: unsignedState.keyGeneration, keyCommitment: unsignedState.keyCommitment, members: unsignedState.members, signerDeviceID: unsignedState.signerDeviceID, signature: device.signature(for: AccountTranscript.trustState(unsignedState)))
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try device.sharedSecret(with: ephemeral.publicKey.x963Representation)
        let info = AccountTranscript.parts([Data("Plainpost.AccountGroupKeyPackage.KDF.v1".utf8), AccountTranscript.uuid(challenge.accountID.rawValue), AccountTranscript.u64(epoch.value), AccountTranscript.u64(revision.value), AccountTranscript.u64(keyGeneration.value), stateDigest, AccountTranscript.uuid(challenge.deviceID.rawValue), AccountTranscript.uuid(challenge.deviceID.rawValue)])
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: stateDigest, sharedInfo: info, outputByteCount: 32)
        let nonce = try random(12)
        let aad = AccountTranscript.parts([Data("Plainpost.AccountGroupKeyPackage.AAD.v1".utf8), AccountTranscript.u16(1), AccountTranscript.uuid(challenge.accountID.rawValue), AccountTranscript.u64(epoch.value), AccountTranscript.u64(revision.value), AccountTranscript.u64(keyGeneration.value), stateDigest, commitment, AccountTranscript.uuid(challenge.deviceID.rawValue), AccountTranscript.uuid(challenge.deviceID.rawValue), ephemeral.publicKey.x963Representation])
        let sealed = try AES.GCM.seal(material, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        guard sealed.ciphertext.count == 64, sealed.tag.count == 16 else { throw AccountRuntimeError.cryptographicFailure }
        let encrypted = sealed.ciphertext + sealed.tag
        let unsignedPackage = try AccountGroupKeyPackage(accountID: challenge.accountID, epoch: epoch, stateRevision: revision, keyGeneration: keyGeneration, stateDigest: stateDigest, keyCommitment: commitment, recipientDeviceID: challenge.deviceID, senderDeviceID: challenge.deviceID, senderEphemeralPublicKey: ephemeral.publicKey.x963Representation, nonce: nonce, encryptedKeyMaterial: encrypted, signature: Data(repeating: 1, count: 64))
        let encryptedDigest = Data(SHA256.hash(data: nonce + encrypted))
        let package = try AccountGroupKeyPackage(accountID: unsignedPackage.accountID, epoch: unsignedPackage.epoch, stateRevision: unsignedPackage.stateRevision, keyGeneration: unsignedPackage.keyGeneration, stateDigest: unsignedPackage.stateDigest, keyCommitment: unsignedPackage.keyCommitment, recipientDeviceID: unsignedPackage.recipientDeviceID, senderDeviceID: unsignedPackage.senderDeviceID, senderEphemeralPublicKey: unsignedPackage.senderEphemeralPublicKey, nonce: unsignedPackage.nonce, encryptedKeyMaterial: unsignedPackage.encryptedKeyMaterial, signature: device.signature(for: AccountTranscript.groupKeyPackage(unsignedPackage, encryptedDigest: encryptedDigest)))
        return (try AccountTrustStateCommit(state: state, keyPackages: [package]), material)
    }

    private func digest(_ commit: AccountTrustStateCommit) throws -> Data {
        AccountTranscript.trustCommitDigest(commit)
    }
    private func request(path: String, body: Data) throws -> URLRequest {
        guard body.count <= AccountWireCodec.maxBodyBytes, let url = URL(string: path, relativeTo: baseURL) else { throw AccountRuntimeError.transportFailure }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.timeoutInterval = 20; return request
    }
    private func checkedResponse(_ response: AccountHTTPResponse) throws -> AccountHTTPResponse {
        guard response.statusCode == 200, response.body.count > 0, response.body.count <= AccountWireCodec.maxBodyBytes, let contentType = response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value, contentType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else { throw AccountRuntimeError.untrustedResponse }
        return response
    }
    public static func secureRandom(_ count: Int) throws -> Data { var data = Data(count: count); let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }; guard status == errSecSuccess else { throw AccountRuntimeError.cryptographicFailure }; return data }
}

extension AccountAPIClient: AccountSessionRefreshing {
    public func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials { try await refreshSession(credentials, device: identity) }
}

extension AccountAPIClient: SyncNodeEnrollmentRemote {}

/// Opaque account-record access for the private Node endpoint. Central only
/// observes `EncryptedAccountRecordV1` envelopes and revision conflicts.
public protocol SyncNodeEndpointMetadataRemote: Sendable {
    func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> EncryptedAccountRecordV1?
    func putSyncNodeEndpointRecord(_ record: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws
}

extension AccountAPIClient: SyncNodeEndpointMetadataRemote {
    public func syncNodeEndpointRecord(accountID: PlainpostAccountID, recordID: AccountRecordID, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date()) async throws -> EncryptedAccountRecordV1? {
        guard accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        var cursor: Data?
        for _ in 0..<64 {
            var query = [URLQueryItem(name: "limit", value: "32")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: AccountWireCodec.encodeBase64URL(cursor))) }
            let wire = try await sendAccountRequest(method: "GET", path: "/v1/account-records", queryItems: query, credentials: credentials, device: device, now: now, maximumResponseBytes: AccountWireCodec.maxTrustStatePageBodyBytes)
            let page = try AccountWireCodec.decodeEncryptedAccountRecordPage(wire)
            if let match = page.records.first(where: { $0.recordID == recordID }) { return match }
            guard !page.terminal, let next = page.nextCursor else { return nil }
            cursor = next
        }
        throw AccountRuntimeError.untrustedResponse
    }

    public func putSyncNodeEndpointRecord(_ record: EncryptedAccountRecordV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date = Date()) async throws {
        guard record.accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        _ = try await sendAccountRequest(method: "PUT", path: "/v1/account-records/\(record.recordID.rawValue)", body: try AccountWireCodec.encodeEncryptedAccountRecord(record), credentials: credentials, device: device, now: now, maximumRequestBytes: 128 * 1024, maximumResponseBytes: 128 * 1024)
    }
}
