import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// One imported, installation-pinned owner-bootstrap profile. Capability
/// bytes remain internal to the account runtime and its transport adapter.
public struct SyncNodeBootstrapProfile: Sendable, Equatable {
    public static let maximumDocumentBytes = 4096
    static let legacyKind = "sync-node.bootstrap-profile.v1"
    static let currentKind = "sync-node.bootstrap-profile.v2"
    private static let legacyKeys: Set<String> = ["capability", "capabilityID", "canonicalOrigin", "kind", "nodeDeviceID", "signingKeyDigest"]

    public let canonicalOrigin: NodeEndpointURL
    public let nodeDeviceID: AccountDeviceID
    public let signingKeyDigest: Data
    public let capabilityID: Data
    let capability: Data
    /// The Central audience the Node was provisioned for. `nil` means a
    /// legacy v1 profile that carries no audience.
    public let centralAudience: String?

    public init(canonicalOrigin: NodeEndpointURL, nodeDeviceID: AccountDeviceID, signingKeyDigest: Data, capabilityID: Data, capability: Data, centralAudience: String?) throws {
        guard signingKeyDigest.count == 32, !signingKeyDigest.allSatisfy({ $0 == 0 }),
              capabilityID.count == 16, !capabilityID.allSatisfy({ $0 == 0 }),
              capability.count == 32, !capability.allSatisfy({ $0 == 0 }),
              centralAudience.map(AccountCentralAudience.isPortableLabel) ?? true
        else { throw AccountRuntimeError.untrustedResponse }
        self.canonicalOrigin = canonicalOrigin
        self.nodeDeviceID = nodeDeviceID
        self.signingKeyDigest = signingKeyDigest
        self.capabilityID = capabilityID
        self.capability = capability
        self.centralAudience = centralAudience
    }

    public func replacingOrigin(with origin: NodeEndpointURL) throws -> SyncNodeBootstrapProfile {
        try SyncNodeBootstrapProfile(
            canonicalOrigin: origin,
            nodeDeviceID: nodeDeviceID,
            signingKeyDigest: signingKeyDigest,
            capabilityID: capabilityID,
            capability: capability,
            centralAudience: centralAudience
        )
    }

    /// Accepts compact canonical JSON with either no suffix or exactly one
    /// terminal newline. Arbitrary whitespace and trailing data are rejected.
    public static func decode(_ document: Data) throws -> SyncNodeBootstrapProfile {
        guard !document.isEmpty, document.count <= maximumDocumentBytes else { throw AccountRuntimeError.untrustedResponse }
        var owned = document
        defer { owned.resetBytes(in: owned.startIndex ..< owned.endIndex) }
        if owned.last == 0x0a { owned.removeLast() }
        guard !owned.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: owned),
              let values = object as? [String: String],
              let kind = values["kind"]
        else { throw AccountRuntimeError.untrustedResponse }
        let audience: String?
        switch kind {
        case Self.legacyKind:
            guard Set(values.keys) == Self.legacyKeys else { throw AccountRuntimeError.untrustedResponse }
            audience = nil
        case Self.currentKind:
            guard Set(values.keys) == Self.legacyKeys.union(["centralAudience"]),
                  let value = values["centralAudience"], AccountCentralAudience.isPortableLabel(value)
            else { throw AccountRuntimeError.untrustedResponse }
            audience = value
        default:
            throw AccountRuntimeError.untrustedResponse
        }
        guard let originText = values["canonicalOrigin"], let nodeText = values["nodeDeviceID"],
              let digestText = values["signingKeyDigest"], let idText = values["capabilityID"],
              let capabilityText = values["capability"]
        else { throw AccountRuntimeError.untrustedResponse }
        guard var canonical = canonicalDocument(values) else { throw AccountRuntimeError.untrustedResponse }
        defer { canonical.resetBytes(in: canonical.startIndex ..< canonical.endIndex) }
        guard canonical == owned else { throw AccountRuntimeError.untrustedResponse }
        do {
            return try SyncNodeBootstrapProfile(
                canonicalOrigin: NodeEndpointURL(originText),
                nodeDeviceID: AccountDeviceID(nodeText),
                signingKeyDigest: NodeSessionWire.decodeBase64URL(digestText),
                capabilityID: NodeSessionWire.decodeBase64URL(idText),
                capability: NodeSessionWire.decodeBase64URL(capabilityText),
                centralAudience: audience
            )
        } catch {
            throw AccountRuntimeError.untrustedResponse
        }
    }

    /// Canonical Keychain-ready representation. Task 3 owns durable storage;
    /// this method deliberately remains internal to the runtime module.
    func encodedForStorage() throws -> Data {
        var values: [String: String] = [
            "capability": NodeSessionWire.encodeBase64URL(capability),
            "capabilityID": NodeSessionWire.encodeBase64URL(capabilityID),
            "canonicalOrigin": canonicalOrigin.url.absoluteString,
            "kind": centralAudience == nil ? Self.legacyKind : Self.currentKind,
            "nodeDeviceID": nodeDeviceID.rawValue,
            "signingKeyDigest": NodeSessionWire.encodeBase64URL(signingKeyDigest),
        ]
        if let centralAudience { values["centralAudience"] = centralAudience }
        guard var wire = Self.canonicalDocument(values), wire.count < Self.maximumDocumentBytes else {
            throw AccountRuntimeError.untrustedResponse
        }
        wire.append(0x0a)
        return wire
    }

    private static func canonicalDocument(_ values: [String: String]) -> Data? {
        guard let capability = values["capability"], let capabilityID = values["capabilityID"],
              let canonicalOrigin = values["canonicalOrigin"], let kind = values["kind"],
              let nodeDeviceID = values["nodeDeviceID"], let signingKeyDigest = values["signingKeyDigest"]
        else { return nil }
        let audience = values["centralAudience"].map { #","centralAudience":"\#($0)""# } ?? ""
        return Data(#"{"capability":"\#(capability)","capabilityID":"\#(capabilityID)","canonicalOrigin":"\#(canonicalOrigin)"\#(audience),"kind":"\#(kind)","nodeDeviceID":"\#(nodeDeviceID)","signingKeyDigest":"\#(signingKeyDigest)"}"#.utf8)
    }
}

public protocol SyncNodeBootstrapProfileStoring: Sendable {
    func load() throws -> SyncNodeBootstrapProfile?
    func importProfile(_ profile: SyncNodeBootstrapProfile) throws
    func replaceOrigin(
        _ origin: NodeEndpointURL,
        expectedCapabilityID: Data
    ) throws -> SyncNodeBootstrapProfile
    func retire(expectedCapabilityID: Data) throws
}

public extension SyncNodeBootstrapProfileStoring {
    func replaceOrigin(
        _: NodeEndpointURL,
        expectedCapabilityID _: Data
    ) throws -> SyncNodeBootstrapProfile {
        throw AccountRuntimeError.secretUnavailable
    }
}

/// Owns the one discoverable, device-only bootstrap profile slot. All writes
/// use the complete prior value as a Keychain CAS fence so another import can
/// never be erased by a stale enrollment completion.
public final class SyncNodeBootstrapProfileStore: SyncNodeBootstrapProfileStoring, @unchecked Sendable {
    static let storageKey = AccountSecretKey(
        service: "com.marynavdovenko.Plainpost.SyncNodeBootstrapProfile.v1",
        account: "current",
        accessGroup: PlainpostAccountSharedKeychain.accessGroup
    )

    private static let retiredKind = "sync-node.bootstrap-profile-retired.v1"
    private let secretStore: any AccountSecretStoring
    private let key: AccountSecretKey

    /// The Keychain access group every load and write of this store uses.
    public var accessGroup: String? { key.accessGroup }

    public convenience init() {
        self.init(secretStore: KeychainAccountSecretStore())
    }

    /// iOS passes `PlainpostIOSAppKeychain.accessGroup`: its entitlements have
    /// no AccountShared group, and the notifications group is shared with the
    /// Notification Service extension.
    public convenience init(accessGroup: String) {
        self.init(secretStore: KeychainAccountSecretStore(), accessGroup: accessGroup)
    }

    init(secretStore: any AccountSecretStoring, accessGroup: String? = PlainpostAccountSharedKeychain.accessGroup) {
        self.secretStore = secretStore
        key = AccountSecretKey(service: Self.storageKey.service, account: Self.storageKey.account, accessGroup: accessGroup)
    }

    public func load() throws -> SyncNodeBootstrapProfile? {
        guard let record = try secretStore.load(key) else { return nil }
        guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        switch try decodeSlot(record.value) {
        case .profile(let profile): return profile
        case .retired: return nil
        }
    }

    public func importProfile(_ profile: SyncNodeBootstrapProfile) throws {
        var replacement = try profile.encodedForStorage()
        defer { replacement.resetBytes(in: replacement.startIndex ..< replacement.endIndex) }
        let current = try secretStore.load(key)
        if let current {
            guard current.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            switch try decodeSlot(current.value) {
            case .profile(let existing) where existing.capabilityID == profile.capabilityID:
                guard current.value == replacement else { throw AccountRuntimeError.corruptSecret }
                return
            case .retired(let capabilityID) where capabilityID == profile.capabilityID:
                throw AccountRuntimeError.corruptSecret
            case .profile, .retired:
                break
            }
        }
        let changed = try secretStore.compareAndSwap(
            expected: current?.value,
            replacement: replacement,
            key: key,
            attributes: .deviceOnly
        )
        guard changed else { throw AccountRuntimeError.secretUnavailable }
    }

    public func replaceOrigin(
        _ origin: NodeEndpointURL,
        expectedCapabilityID: Data
    ) throws -> SyncNodeBootstrapProfile {
        guard let current = try secretStore.load(key),
              current.attributes == .deviceOnly
        else { throw AccountRuntimeError.corruptSecret }
        guard case .profile(let profile) = try decodeSlot(current.value),
              profile.capabilityID == expectedCapabilityID
        else { throw AccountRuntimeError.corruptSecret }
        guard profile.canonicalOrigin != origin else { return profile }
        let replacement = try profile.replacingOrigin(with: origin)
        var replacementData = try replacement.encodedForStorage()
        defer { replacementData.resetBytes(in: replacementData.startIndex ..< replacementData.endIndex) }
        let changed = try secretStore.compareAndSwap(
            expected: current.value,
            replacement: replacementData,
            key: key,
            attributes: .deviceOnly
        )
        guard changed else { throw AccountRuntimeError.secretUnavailable }
        return replacement
    }

    public func retire(expectedCapabilityID: Data) throws {
        guard expectedCapabilityID.count == 16,
              !expectedCapabilityID.allSatisfy({ $0 == 0 }) else {
            throw AccountRuntimeError.corruptSecret
        }
        guard let current = try secretStore.load(key) else { return }
        guard current.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        switch try decodeSlot(current.value) {
        case .retired:
            return
        case .profile(let profile):
            guard profile.capabilityID == expectedCapabilityID else { return }
        }
        var tombstone = Self.retiredDocument(capabilityID: expectedCapabilityID)
        defer { tombstone.resetBytes(in: tombstone.startIndex ..< tombstone.endIndex) }
        _ = try secretStore.compareAndSwap(
            expected: current.value,
            replacement: tombstone,
            key: key,
            attributes: .deviceOnly
        )
    }

    private enum Slot {
        case profile(SyncNodeBootstrapProfile)
        case retired(capabilityID: Data)
    }

    private func decodeSlot(_ document: Data) throws -> Slot {
        if let profile = try? SyncNodeBootstrapProfile.decode(document) {
            return .profile(profile)
        }
        guard !document.isEmpty, document.count <= SyncNodeBootstrapProfile.maximumDocumentBytes,
              document.last == 0x0a else { throw AccountRuntimeError.corruptSecret }
        var body = document
        defer { body.resetBytes(in: body.startIndex ..< body.endIndex) }
        body.removeLast()
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let values = object as? [String: String],
              Set(values.keys) == Set(["capabilityID", "kind"]),
              values["kind"] == Self.retiredKind,
              let encodedID = values["capabilityID"],
              let capabilityID = try? NodeSessionWire.decodeBase64URL(encodedID),
              capabilityID.count == 16,
              !capabilityID.allSatisfy({ $0 == 0 }),
              NodeSessionWire.encodeBase64URL(capabilityID) == encodedID,
              document == Self.retiredDocument(capabilityID: capabilityID) else {
            throw AccountRuntimeError.corruptSecret
        }
        return .retired(capabilityID: capabilityID)
    }

    private static func retiredDocument(capabilityID: Data) -> Data {
        Data(
            #"{"capabilityID":"\#(NodeSessionWire.encodeBase64URL(capabilityID))","kind":"\#(retiredKind)"}"#.utf8
        ) + Data([0x0a])
    }
}

public protocol SyncNodeEnrollmentPresenting: Sendable {
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation
}

/// Keeps profile parsing and capability custody in AccountRuntime while the
/// dependency-neutral HTTPS client remains in PlainpostNodeTransport.
public struct NodeTransportSyncNodeEnrollmentPresenter: SyncNodeEnrollmentPresenting {
    private let client: SyncNodeEnrollmentPresentationClient

    public init(client: SyncNodeEnrollmentPresentationClient = SyncNodeEnrollmentPresentationClient()) {
        self.client = client
    }

    public func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation {
        var capability = profile.capability
        defer { capability.resetBytes(in: capability.startIndex ..< capability.endIndex) }
        let request = try SyncNodeEnrollmentPresentationRequest(endpoint: profile.canonicalOrigin, capabilityID: profile.capabilityID, capability: capability)
        return try await client.fetch(request)
    }
}
