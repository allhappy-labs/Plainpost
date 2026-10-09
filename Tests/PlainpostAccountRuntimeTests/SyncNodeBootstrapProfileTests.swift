import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport
import XCTest
@testable import PlainpostAccountRuntime

final class SyncNodeBootstrapProfileTests: XCTestCase {
    private let canonical = #"{"capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU","capabilityID":"AQIDBAUGBwgJCgsMDQ4PEA","canonicalOrigin":"https://node.tail1234.ts.net:18443","kind":"sync-node.bootstrap-profile.v1","nodeDeviceID":"11111111-1111-4111-8111-111111111111","signingKeyDigest":"ERERERERERERERERERERERERERERERERERERERERERE"}"#

    private let canonicalV2 = #"{"capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU","capabilityID":"AQIDBAUGBwgJCgsMDQ4PEA","canonicalOrigin":"https://node.tail1234.ts.net:18443","centralAudience":"plainpost-central-private-beta","kind":"sync-node.bootstrap-profile.v2","nodeDeviceID":"11111111-1111-4111-8111-111111111111","signingKeyDigest":"ERERERERERERERERERERERERERERERERERERERERERE"}"#

    func testProfileV2DecodesAudienceAndRoundTripsCanonicalBytes() throws {
        for suffix in ["", "\n"] {
            let profile = try SyncNodeBootstrapProfile.decode(Data((canonicalV2 + suffix).utf8))
            XCTAssertEqual(profile.centralAudience, "plainpost-central-private-beta")
            XCTAssertEqual(try profile.encodedForStorage(), Data((canonicalV2 + "\n").utf8))
        }
        let legacy = try SyncNodeBootstrapProfile.decode(Data(canonical.utf8))
        XCTAssertNil(legacy.centralAudience)
        XCTAssertEqual(try legacy.encodedForStorage(), Data((canonical + "\n").utf8))
        let moved = try SyncNodeBootstrapProfile.decode(Data(canonicalV2.utf8)).replacingOrigin(with: NodeEndpointURL("https://other.tail1234.ts.net:18443"))
        XCTAssertEqual(moved.centralAudience, "plainpost-central-private-beta")
    }

    func testProfileV2RejectsMissingNonPortableAndMisversionedAudience() {
        let audience = #""centralAudience":"plainpost-central-private-beta","#
        let invalid: [String: String] = [
            "v2 without audience": canonicalV2.replacingOccurrences(of: audience, with: ""),
            "v1 with audience": canonicalV2.replacingOccurrences(of: "sync-node.bootstrap-profile.v2", with: "sync-node.bootstrap-profile.v1"),
            "empty audience": canonicalV2.replacingOccurrences(of: "plainpost-central-private-beta", with: ""),
            "space": canonicalV2.replacingOccurrences(of: "plainpost-central-private-beta", with: "plainpost central"),
            "leading dash": canonicalV2.replacingOccurrences(of: "plainpost-central-private-beta", with: "-plainpost"),
            "escaped angle": canonicalV2.replacingOccurrences(of: "plainpost-central-private-beta", with: #"plain<post"#),
            "oversized": canonicalV2.replacingOccurrences(of: "plainpost-central-private-beta", with: String(repeating: "a", count: 256)),
            "key order": canonicalV2.replacingOccurrences(of: #""canonicalOrigin":"https://node.tail1234.ts.net:18443","centralAudience":"plainpost-central-private-beta","#, with: #""centralAudience":"plainpost-central-private-beta","canonicalOrigin":"https://node.tail1234.ts.net:18443","#),
        ]
        for (name, document) in invalid {
            XCTAssertThrowsError(try SyncNodeBootstrapProfile.decode(Data(document.utf8)), name)
        }
    }

    func testAudienceRulesSeparateWireFromPortableLabel() {
        XCTAssertTrue(AccountCentralAudience.isValid("plainpost central"))
        XCTAssertFalse(AccountCentralAudience.isValid("a\nb"))
        XCTAssertFalse(AccountCentralAudience.isValid(""))
        XCTAssertTrue(AccountCentralAudience.isPortableLabel("plainpost-central-private-beta"))
        XCTAssertTrue(AccountCentralAudience.isPortableLabel("acceptance.plainpost.central"))
        XCTAssertTrue(AccountCentralAudience.isPortableLabel(String(repeating: "a", count: 255)))
        for value in ["", "plainpost central", "_lead", "a<b", "é", String(repeating: "a", count: 256)] {
            XCTAssertFalse(AccountCentralAudience.isPortableLabel(value), value)
        }
    }

    func testProfileDecodesFrozenCanonicalRecoveryDocumentWithOneOptionalNewline() throws {
        for suffix in ["", "\n"] {
            let profile = try SyncNodeBootstrapProfile.decode(Data((canonical + suffix).utf8))
            XCTAssertEqual(profile.canonicalOrigin.url.absoluteString, "https://node.tail1234.ts.net:18443")
            XCTAssertEqual(profile.nodeDeviceID.rawValue, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(profile.signingKeyDigest, Data(repeating: 0x11, count: 32))
            XCTAssertEqual(profile.capabilityID, Data((1 ... 16).map(UInt8.init)))
            XCTAssertEqual(profile.capability, Data(repeating: 0xa5, count: 32))
            XCTAssertEqual(try profile.encodedForStorage(), Data((canonical + "\n").utf8))
        }
    }

    func testProfileRejectsOpenNoncanonicalOversizedAndInvalidDocuments() throws {
        let zero16 = NodeSessionWire.encodeBase64URL(Data(repeating: 0, count: 16))
        let zero32 = NodeSessionWire.encodeBase64URL(Data(repeating: 0, count: 32))
        let invalid: [String: Data] = [
            "leading whitespace": Data((" " + canonical).utf8),
            "two newlines": Data((canonical + "\n\n").utf8),
            "trailing space": Data((canonical + " ").utf8),
            "unknown field": Data(canonical.replacingOccurrences(of: #"{"capability"#, with: #"{"additional":true,"capability"#).utf8),
            "duplicate field": Data(canonical.replacingOccurrences(of: #"{"capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU"#, with: #"{"capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU","capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU"#).utf8),
            "padded capability": Data(canonical.replacingOccurrences(of: "paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU", with: "paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU=").utf8),
            "zero capability ID": Data(canonical.replacingOccurrences(of: "AQIDBAUGBwgJCgsMDQ4PEA", with: zero16).utf8),
            "zero capability": Data(canonical.replacingOccurrences(of: "paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU", with: zero32).utf8),
            "zero signing digest": Data(canonical.replacingOccurrences(of: "ERERERERERERERERERERERERERERERERERERERERERE", with: zero32).utf8),
            "origin path": Data(canonical.replacingOccurrences(of: "https://node.tail1234.ts.net:18443", with: "https://node.tail1234.ts.net:18443/").utf8),
            "unknown kind": Data(canonical.replacingOccurrences(of: "sync-node.bootstrap-profile.v1", with: "sync-node.bootstrap-profile.v3").utf8),
            "oversized": Data(repeating: 0x78, count: 4097),
        ]
        for (name, wire) in invalid {
            XCTAssertThrowsError(try SyncNodeBootstrapProfile.decode(wire), name)
        }
    }

    func testProfileInitializerRequiresExactNonzeroBinaryPins() throws {
        let origin = try NodeEndpointURL("https://node.tail1234.ts.net:18443")
        let node = try AccountDeviceID("11111111-1111-4111-8111-111111111111")
        XCTAssertNoThrow(try SyncNodeBootstrapProfile(canonicalOrigin: origin, nodeDeviceID: node, signingKeyDigest: Data(repeating: 1, count: 32), capabilityID: Data(repeating: 2, count: 16), capability: Data(repeating: 3, count: 32), centralAudience: "central.test"))
        let invalid: [(String, Data, Data, Data)] = [
            ("short digest", Data(repeating: 1, count: 31), Data(repeating: 2, count: 16), Data(repeating: 3, count: 32)),
            ("zero digest", Data(repeating: 0, count: 32), Data(repeating: 2, count: 16), Data(repeating: 3, count: 32)),
            ("short ID", Data(repeating: 1, count: 32), Data(repeating: 2, count: 15), Data(repeating: 3, count: 32)),
            ("zero ID", Data(repeating: 1, count: 32), Data(repeating: 0, count: 16), Data(repeating: 3, count: 32)),
            ("short capability", Data(repeating: 1, count: 32), Data(repeating: 2, count: 16), Data(repeating: 3, count: 31)),
            ("zero capability", Data(repeating: 1, count: 32), Data(repeating: 2, count: 16), Data(repeating: 0, count: 32)),
        ]
        for (name, digest, id, capability) in invalid {
            XCTAssertThrowsError(try SyncNodeBootstrapProfile(canonicalOrigin: origin, nodeDeviceID: node, signingKeyDigest: digest, capabilityID: id, capability: capability, centralAudience: "central.test"), name)
        }
    }

    func testProductionDecoderAcceptsRealProvisionerOutput() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provisioner = root.appendingPathComponent("Deploy/sync-node/scripts/provision-owner-bootstrap.py")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-swift-provisioner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let identity = temporary.appendingPathComponent("installation-identity.json")
        let output = temporary.appendingPathComponent("owner-bootstrap", isDirectory: true)
        let identityWire = #"{"kind":"sync-node.installation-identity.v1","nodeDeviceID":"11111111-1111-4111-8111-111111111111","signingPublicKey":"BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU","signingKeyDigest":"aYvqY9xEo0RmP_FCmuoQhC3ye2uZHvJYZrLGwCzcxb4"}"# + "\n"
        try Data(identityWire.utf8).write(to: identity, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)

        let process = Process()
        let receipt = Pipe()
        process.executableURL = provisioner
        process.arguments = [identity.path, "https://node.tailnet.ts.net:18443", "acceptance.plainpost.central", output.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, taskValue in taskValue }
        process.standardOutput = receipt
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let receiptData = receipt.fileHandleForReading.readDataToEndOfFile()
        let receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptData) as? [String: String])
        let profileName = try XCTUnwrap(receiptObject["profileFile"])
        let profileDocument = try Data(contentsOf: output.appendingPathComponent(profileName))
        let profile = try SyncNodeBootstrapProfile.decode(profileDocument)
        XCTAssertEqual(profile.canonicalOrigin.url.absoluteString, "https://node.tailnet.ts.net:18443")
        XCTAssertEqual(profile.nodeDeviceID.rawValue, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(profile.signingKeyDigest, try NodeSessionWire.decodeBase64URL("aYvqY9xEo0RmP_FCmuoQhC3ye2uZHvJYZrLGwCzcxb4"))
        XCTAssertEqual(profile.centralAudience, "acceptance.plainpost.central")
    }
}
