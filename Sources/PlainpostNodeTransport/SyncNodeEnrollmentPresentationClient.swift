import Foundation

public struct SyncNodeEnrollmentPresentationRequest: Sendable {
    public let endpoint: NodeEndpointURL
    let capabilityID: Data
    let capability: Data

    public init(endpoint: NodeEndpointURL, capabilityID: Data, capability: Data) throws {
        guard capabilityID.count == 16, !capabilityID.allSatisfy({ $0 == 0 }), capability.count == 32, !capability.allSatisfy({ $0 == 0 }) else {
            throw NodeSessionError.invalidValue
        }
        self.endpoint = endpoint
        self.capabilityID = capabilityID
        self.capability = capability
    }
}

public struct SyncNodeEnrollmentPresentation: Sendable {
    public let setupCode: String
    public let expiresAt: Date
    public let claimProofSignature: Data
    public let claimFingerprint: String

    public init(setupCode: String, expiresAt: Date, claimProofSignature: Data, claimFingerprint: String) throws {
        var setup = try NodeSessionWire.decodeBase64URL(setupCode)
        defer { setup.resetBytes(in: setup.startIndex ..< setup.endIndex) }
        guard setup.count == 32, !setup.allSatisfy({ $0 == 0 }), claimProofSignature.count == 64,
              claimFingerprint.utf8.count == 6, claimFingerprint.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else { throw NodeSessionError.invalidValue }
        self.setupCode = setupCode
        self.expiresAt = expiresAt
        self.claimProofSignature = claimProofSignature
        self.claimFingerprint = claimFingerprint
    }
}

public struct SyncNodeEnrollmentPresentationClient: Sendable {
    public static let maximumResponseBytes = 1024
    public static let path = "/v1/bootstrap/enrollment-presentation"

    private let client: NodeTLSClient
    private let clock: @Sendable () -> Date
    private let sensitiveBufferCleared: @Sendable (Data) -> Void

    public init(client: NodeTLSClient = NodeTLSClient(), clock: @escaping @Sendable () -> Date = Date.init) {
        self.init(client: client, clock: clock, sensitiveBufferCleared: { _ in })
    }

    init(client: NodeTLSClient, clock: @escaping @Sendable () -> Date, sensitiveBufferCleared: @escaping @Sendable (Data) -> Void) {
        self.client = client
        self.clock = clock
        self.sensitiveBufferCleared = sensitiveBufferCleared
    }

    public func fetch(_ request: SyncNodeEnrollmentPresentationRequest) async throws -> SyncNodeEnrollmentPresentation {
        var capabilityID = request.capabilityID
        var capability = request.capability
        defer {
            capabilityID.resetBytes(in: capabilityID.startIndex ..< capabilityID.endIndex)
            capability.resetBytes(in: capability.startIndex ..< capability.endIndex)
            sensitiveBufferCleared(capabilityID)
            sensitiveBufferCleared(capability)
        }
        let authorization = "Plainpost-Bootstrap-v1 \(NodeSessionWire.encodeBase64URL(capabilityID)).\(NodeSessionWire.encodeBase64URL(capability))"
        let response = try await client.send(
            NodeHTTPRequest(endpoint: request.endpoint, method: "POST", path: Self.path, body: Data(), additionalHeaders: ["Authorization": authorization]),
            maximumResponseBytes: Self.maximumResponseBytes
        )
        var body = response.body
        defer {
            body.resetBytes(in: body.startIndex ..< body.endIndex)
            sensitiveBufferCleared(body)
        }
        switch response.statusCode {
        case 200:
            break
        case 404:
            throw NodeSessionError.authenticationRejected
        case 500 ... 599:
            throw NodeSessionError.transportFailure
        default:
            throw NodeSessionError.invalidValue
        }
        guard header(response.headers, named: "content-type") == "application/json",
              header(response.headers, named: "cache-control") == "no-store"
        else { throw NodeSessionError.invalidValue }
        return try decodePresentation(body, now: clock())
    }
}

private func decodePresentation(_ document: Data, now: Date) throws -> SyncNodeEnrollmentPresentation {
    guard !document.isEmpty, document.count <= SyncNodeEnrollmentPresentationClient.maximumResponseBytes else { throw NodeSessionError.invalidValue }
    var canonicalInput = document
    defer { canonicalInput.resetBytes(in: canonicalInput.startIndex ..< canonicalInput.endIndex) }
    if canonicalInput.last == 0x0a { canonicalInput.removeLast() }
    guard !canonicalInput.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: canonicalInput),
          let values = object as? [String: String],
          Set(values.keys) == Set(["claimFingerprint", "claimProofSignature", "expiresAt", "kind", "setupCode"]),
          values["kind"] == "sync-node.enrollment-presentation.v1",
          let setupCode = values["setupCode"],
          let expiresText = values["expiresAt"],
          let expiresAt = NodeSessionWire.parseWholeSecondTimestamp(expiresText),
          now < expiresAt,
          let signatureText = values["claimProofSignature"],
          let fingerprint = values["claimFingerprint"]
    else { throw NodeSessionError.invalidValue }
    guard var canonical = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes]) else { throw NodeSessionError.invalidValue }
    defer { canonical.resetBytes(in: canonical.startIndex ..< canonical.endIndex) }
    guard canonical == canonicalInput else { throw NodeSessionError.invalidValue }
    return try SyncNodeEnrollmentPresentation(setupCode: setupCode, expiresAt: expiresAt, claimProofSignature: NodeSessionWire.decodeBase64URL(signatureText), claimFingerprint: fingerprint)
}

private func header(_ headers: [String: String], named name: String) -> String? {
    headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
}
