import Foundation

public enum NodeActivationError: Error, Equatable, Sendable { case uncertain, rejected }

/// Serializes one exact V3 activation request. Only an ambiguous transport or
/// 5xx outcome retains the original bytes for replay; success, cancellation,
/// and every definitive 4xx response overwrite the mutable copy.
public actor NodeActivationClient {
    private let endpoint: NodeEndpointURL
    private let client: NodeTLSClient
    private var replayBody: [UInt8] = []
    // A 2xx only proves the Node accepted V3.  Metadata publication and the
    // device-only session save are separate recoverable stages, so keep the
    // exact body until their owner explicitly completes them.
    private var nodeAccepted = false

    public init(endpoint: NodeEndpointURL, client: NodeTLSClient = NodeTLSClient()) {
        self.endpoint = endpoint; self.client = client
    }

    public var hasPendingActivationReplay: Bool { !replayBody.isEmpty }

    public var hasAcceptedActivation: Bool { nodeAccepted }

    public func activate(_ request: ActivationRequestV3) async throws {
        guard replayBody.isEmpty else { throw NodeSessionError.invalidValue }
        replayBody = Array(try canonicalWire(request))
        try await submitRetainedBody()
    }

    public func retryUncertainActivation() async throws {
        guard !replayBody.isEmpty else { throw NodeSessionError.invalidValue }
        if !nodeAccepted { try await submitRetainedBody() }
    }

    /// A local cancel after dispatch cannot revoke an already accepted Node
    /// activation.  Retain its sole recovery material; callers may only wipe
    /// it after all local completion stages have durably succeeded.
    public func cancelPendingActivation() {}

    public func completeActivation() { wipeReplay(); nodeAccepted = false }

    private func submitRetainedBody() async throws {
        do { try Task.checkCancellation() }
        catch { throw NodeActivationError.uncertain }
        let response: NodeHTTPResponse
        do { response = try await client.send(NodeHTTPRequest(endpoint: endpoint, method: "POST", path: "/v1/activate", body: Data(replayBody))) }
        catch is CancellationError { throw NodeActivationError.uncertain }
        catch NodeSessionError.invalidValue { wipeReplay(); throw NodeActivationError.rejected }
        catch { throw NodeActivationError.uncertain }
        if (200...299).contains(response.statusCode) { nodeAccepted = true; return }
        if (400...499).contains(response.statusCode) { wipeReplay(); throw NodeActivationError.rejected }
        throw NodeActivationError.uncertain
    }

    private func canonicalWire(_ request: ActivationRequestV3) throws -> Data {
        let object: [String: String] = [
            "kind": "node.activation.v3",
            "resultWire": NodeSessionWire.encodeBase64URL(request.resultWire),
            "refreshWire": NodeSessionWire.encodeBase64URL(request.refreshWire),
            "leaseWire": NodeSessionWire.encodeBase64URL(request.leaseWire),
            "trustCommitWire": NodeSessionWire.encodeBase64URL(request.trustCommitWire),
            "admissionEvidenceWire": NodeSessionWire.encodeBase64URL(request.admissionEvidenceWire),
            "cleanupCapabilityWire": NodeSessionWire.encodeBase64URL(request.cleanupCapabilityWire),
            "claimProofSignature": NodeSessionWire.encodeBase64URL(request.claimProofSignature),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func wipeReplay() { replayBody.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; replayBody.removeAll(keepingCapacity: false) }
}
