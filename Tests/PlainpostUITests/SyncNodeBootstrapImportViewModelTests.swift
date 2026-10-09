
import Foundation
import XCTest
import PlainpostAccountRuntime
import PlainpostNodeTransport
@testable import PlainpostUI

@MainActor
final class SyncNodeBootstrapImportViewModelTests: XCTestCase {
    func testServerOriginEditPreservesProtectedNodeIdentityAndAdvancesGeneration() throws {
        let store = InMemoryBootstrapProfileStore()
        let access = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile())
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)
        model.importFile(at: URL(fileURLWithPath: "/protected/setup.plainpostserver"))
        let original = try XCTUnwrap(try model.loadProfile())

        let result = model.replaceServerOrigin("https://replacement.tail1234.ts.net:19443")

        XCTAssertEqual(
            result,
            .saved(
                origin: "https://replacement.tail1234.ts.net:19443",
                nodeFingerprint: "11:11:11:11:11:11"
            )
        )
        let replacement = try XCTUnwrap(try model.loadProfile())
        XCTAssertEqual(replacement.canonicalOrigin.url.absoluteString, "https://replacement.tail1234.ts.net:19443")
        XCTAssertEqual(replacement.nodeDeviceID, original.nodeDeviceID)
        XCTAssertEqual(replacement.signingKeyDigest, original.signingKeyDigest)
        XCTAssertEqual(replacement.capabilityID, original.capabilityID)
        XCTAssertEqual(model.profileGeneration, 2)
    }

    func testServerOriginEditRejectsInvalidAddressWithoutChangingProfile() throws {
        let store = InMemoryBootstrapProfileStore()
        let access = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile())
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)
        model.importFile(at: URL(fileURLWithPath: "/protected/setup.plainpostserver"))
        let original = try XCTUnwrap(try model.loadProfile())

        XCTAssertEqual(model.replaceServerOrigin("http://replacement.example"), .invalidAddress)
        XCTAssertEqual(try model.loadProfile(), original)
        XCTAssertEqual(model.profileGeneration, 1)
    }

    func testImportsLocalProfileThroughSecurityScopeWithBoundedReadAndRedactedPresentation() throws {
        let store = InMemoryBootstrapProfileStore()
        let access = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile())
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)
        let source = URL(fileURLWithPath: "/protected/plainpost-sync-node-test.plainpostserver")

        model.importFile(at: source)

        XCTAssertEqual(access.startedURLs, [source])
        XCTAssertEqual(access.stoppedURLs, [source])
        XCTAssertEqual(access.readLimits, [SyncNodeBootstrapProfile.maximumDocumentBytes])
        XCTAssertEqual(store.importedProfiles.count, 1)
        guard case .imported(let origin, let nodeFingerprint) = model.presentation else {
            return XCTFail("expected redacted imported presentation")
        }
        XCTAssertEqual(origin, "https://node.tail1234.ts.net:18443")
        XCTAssertEqual(nodeFingerprint, "11:11:11:11:11:11")
        let presentation = String(describing: model.presentation)
        XCTAssertFalse(presentation.contains("paWlpaWl"))
        XCTAssertFalse(presentation.contains("11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(model.profileGeneration, 1)
    }

    func testFileImporterAndOpenURLUseTheSameImportPath() throws {
        let store = InMemoryBootstrapProfileStore()
        let access = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile())
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)
        let first = URL(fileURLWithPath: "/protected/first.plainpostserver")
        let second = URL(fileURLWithPath: "/protected/second.plainpostserver")

        model.handleFileImporter(.success([first]))
        model.importFile(at: second)

        XCTAssertEqual(access.startedURLs, [first, second])
        XCTAssertEqual(store.importedProfiles.count, 2)
        XCTAssertEqual(model.profileGeneration, 1, "an exact duplicate does not invalidate an enrollment generation")
    }

    func testRejectsRemoteCustomWrongExtensionAndMultipleFileURLsWithoutReading() {
        let store = InMemoryBootstrapProfileStore()
        let access = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile())
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)
        let invalid: [URL] = [
            URL(string: "https://node.tail1234.ts.net/setup.plainpostserver")!,
            URL(string: "plainpost://server/setup")!,
            URL(fileURLWithPath: "/protected/setup.json"),
        ]

        for url in invalid {
            model.importFile(at: url)
            XCTAssertEqual(model.presentation, .failure(message: SyncNodeBootstrapImportViewModel.failureMessage))
        }
        model.handleFileImporter(.success([
            URL(fileURLWithPath: "/protected/one.plainpostserver"),
            URL(fileURLWithPath: "/protected/two.plainpostserver"),
        ]))

        XCTAssertTrue(access.startedURLs.isEmpty)
        XCTAssertTrue(store.importedProfiles.isEmpty)
    }

    func testOversizedAndMalformedDocumentsShowOnlySafeRetryState() {
        let privateError = "private-capability-error-paWlpaWl"
        for document in [
            Data(repeating: 0x78, count: SyncNodeBootstrapProfile.maximumDocumentBytes + 1),
            Data(privateError.utf8),
        ] {
            let store = InMemoryBootstrapProfileStore()
            let access = BootstrapFileAccessRecorder(document: document)
            let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: access.adapter)

            model.importFile(at: URL(fileURLWithPath: "/protected/setup.plainpostserver"))

            XCTAssertEqual(model.presentation, .failure(message: SyncNodeBootstrapImportViewModel.failureMessage))
            XCTAssertFalse(String(describing: model.presentation).contains(privateError))
            model.presentFileImporter()
            XCTAssertTrue(model.isFileImporterPresented)
        }
    }

    func testLiveReaderPreservesRecoveryFileAndEnforcesTheReadCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostBootstrapImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("setup.plainpostserver")
        let original = canonicalBootstrapProfile()
        try original.write(to: source, options: .withoutOverwriting)
        let store = InMemoryBootstrapProfileStore()
        let model = SyncNodeBootstrapImportViewModel(store: store)

        model.importFile(at: source)

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(store.importedProfiles.count, 1)

        let oversized = directory.appendingPathComponent("oversized.plainpostserver")
        try Data(repeating: 0x78, count: SyncNodeBootstrapProfile.maximumDocumentBytes + 1)
            .write(to: oversized, options: .withoutOverwriting)
        model.importFile(at: oversized)
        XCTAssertEqual(model.presentation, .failure(message: SyncNodeBootstrapImportViewModel.failureMessage))
        XCTAssertEqual(try Data(contentsOf: oversized).count, SyncNodeBootstrapProfile.maximumDocumentBytes + 1)
    }

    func testProfileIdentityChangeAdvancesGenerationButOldRetirementCannotClearNewImport() throws {
        let store = InMemoryBootstrapProfileStore()
        let firstAccess = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile(capabilityByte: 0xA5))
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: firstAccess.adapter)
        model.importFile(at: URL(fileURLWithPath: "/protected/first.plainpostserver"))
        let oldProfile = try XCTUnwrap(try model.loadProfile())
        XCTAssertEqual(model.profileGeneration, 1)

        let secondAccess = BootstrapFileAccessRecorder(document: canonicalBootstrapProfile(capabilityByte: 0xA6))
        model.fileAccess = secondAccess.adapter
        model.importFile(at: URL(fileURLWithPath: "/protected/second.plainpostserver"))
        XCTAssertEqual(model.profileGeneration, 2)

        try model.retireProfile(expectedCapabilityID: oldProfile.capabilityID)
        XCTAssertNotNil(try model.loadProfile())
    }

    func testSameCapabilityIDDivergenceShowsSafeErrorWithoutChangingProfileOrGeneration() throws {
        let store = InMemoryBootstrapProfileStore()
        let firstAccess = BootstrapFileAccessRecorder(
            document: canonicalBootstrapProfile(capabilityByte: 0xA5)
        )
        let model = SyncNodeBootstrapImportViewModel(store: store, fileAccess: firstAccess.adapter)
        model.importFile(at: URL(fileURLWithPath: "/protected/first.plainpostserver"))
        let original = try XCTUnwrap(try model.loadProfile())
        XCTAssertEqual(model.profileGeneration, 1)

        let divergentAccess = BootstrapFileAccessRecorder(
            document: canonicalBootstrapProfile(
                capabilityByte: 0xA6,
                capabilityIDByte: 0xA5
            )
        )
        model.fileAccess = divergentAccess.adapter
        model.importFile(at: URL(fileURLWithPath: "/protected/divergent.plainpostserver"))

        XCTAssertEqual(
            model.presentation,
            .failure(message: SyncNodeBootstrapImportViewModel.failureMessage)
        )
        XCTAssertEqual(model.profileGeneration, 1)
        XCTAssertEqual(try model.loadProfile(), original)
    }
}

private func canonicalBootstrapProfile(
    capabilityByte: UInt8 = 0xA5,
    capabilityIDByte: UInt8? = nil
) -> Data {
    let capabilityID = Data(
        repeating: capabilityIDByte ?? capabilityByte,
        count: 16
    ).base64URLEncoded
    let capability = Data(repeating: capabilityByte, count: 32).base64URLEncoded
    return Data(
        """
        {"capability":"\(capability)","capabilityID":"\(capabilityID)","canonicalOrigin":"https://node.tail1234.ts.net:18443","kind":"sync-node.bootstrap-profile.v1","nodeDeviceID":"11111111-1111-4111-8111-111111111111","signingKeyDigest":"ERERERERERERERERERERERERERERERERERERERERERE"}

        """.utf8
    )
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class BootstrapFileAccessRecorder {
    private let document: Data
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []
    private(set) var readLimits: [Int] = []

    init(document: Data) {
        self.document = document
    }

    var adapter: SyncNodeBootstrapFileAccess {
        SyncNodeBootstrapFileAccess(
            startAccessing: { [unowned self] url in
                startedURLs.append(url)
                return true
            },
            stopAccessing: { [unowned self] url in
                stoppedURLs.append(url)
            },
            read: { [unowned self] _, maximumBytes in
                readLimits.append(maximumBytes)
                return document
            }
        )
    }
}

private final class InMemoryBootstrapProfileStore: SyncNodeBootstrapProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: SyncNodeBootstrapProfile?
    private(set) var importedProfiles: [SyncNodeBootstrapProfile] = []

    func load() throws -> SyncNodeBootstrapProfile? {
        lock.withLock { profile }
    }

    func importProfile(_ profile: SyncNodeBootstrapProfile) throws {
        try lock.withLock {
            if let current = self.profile,
               current.capabilityID == profile.capabilityID,
               current != profile {
                throw AccountRuntimeError.corruptSecret
            }
            self.profile = profile
            importedProfiles.append(profile)
        }
    }

    func replaceOrigin(
        _ origin: NodeEndpointURL,
        expectedCapabilityID: Data
    ) throws -> SyncNodeBootstrapProfile {
        try lock.withLock {
            guard let profile, profile.capabilityID == expectedCapabilityID else {
                throw AccountRuntimeError.corruptSecret
            }
            let replacement = try profile.replacingOrigin(with: origin)
            self.profile = replacement
            importedProfiles.append(replacement)
            return replacement
        }
    }

    func retire(expectedCapabilityID: Data) throws {
        lock.withLock {
            guard profile?.capabilityID == expectedCapabilityID else { return }
            profile = nil
        }
    }
}
