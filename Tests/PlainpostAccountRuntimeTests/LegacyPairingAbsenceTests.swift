import Foundation
import XCTest

final class LegacyPairingAbsenceTests: XCTestCase {
    func testPackageRetainsNonPairingProductTestOwners() throws {
        let package = try source(at: "Package.swift")
        for target in [
            "PlainpostIntegrationTests",
            "PlainpostAppTests",
            "PlainpostServiceIPCTests",
            "PlainpostServiceTests",
        ] {
            XCTAssertTrue(package.contains("name: \"\(target)\""), "missing non-pairing test owner \(target)")
        }
    }

    func testIOSAppRetainsAuthorizedMailWorkspace() throws {
        let app = try source(at: "Apps/PlainpostiOS/Plainpost/PlainpostApp.swift")
        XCTAssertTrue(app.contains("MobileMailRootView"), "authorized iOS sessions must retain the mail product")
        XCTAssertFalse(app.contains("ContentUnavailableView(\n                    \"Sync Node required\""))
    }

    func testProductionSourcesAndPackageContainNoLegacyPairingSurface() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbidden = [
            "PlainpostIOSPairingFixture",
            "PairingInvitation",
            "PairingBootstrapRequest",
            "PairingAuthority",
            "MobilePairingStore",
            "DevicePairing",
            "PlainpostServiceDevicePairingAdapter",
            "PlainpostPairing",
            "pairDevice",
            "VaultTLSCredentialStore",
            "DeviceTLSCredential",
            "PairingWorkspaceModel",
            "MobilePairingViews",
            "paired-device",
            "directHumanDelivery",
            "DirectHuman",
            "DeviceHumanSendReview",
            "DeviceComposeMutation",
            "DeviceProjection",
        ]

        let paths = ["Package.swift", "Sources", "Apps"]
        let enumerator = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let files = try XCTUnwrap(enumerator?.allObjects as? [URL])
            .filter { file in
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return false
                }
                guard ["swift", "pbxproj"].contains(file.pathExtension) || file.lastPathComponent == "Package.swift" else {
                    return false
                }
                let relative = file.path.replacingOccurrences(of: repository.path + "/", with: "")
                return paths.contains(relative) || paths.contains { relative.hasPrefix($0 + "/") }
            }

        for file in files {
            var source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "SQLiteMailStore.swift" {
                source = try sourceExcludingImmutableLegacyMigrationHistory(source)
            }
            for symbol in forbidden where source.contains(symbol) {
                XCTFail("legacy pairing surface \(symbol) remains in \(file.path)")
            }
        }
    }

    func testLegacyStorageNamesExistOnlyInHistoricalMigrationsAndV51DropList() throws {
        let source = try sourceExcludingImmutableLegacyMigrationHistory(
            source(at: "Sources/PlainpostDB/SQLiteMailStore.swift")
        )
        for name in [
            "device_projection",
            "device_compose",
            "device_send_reviews",
            "device_projection_accounts_insert",
            "device_projection_accounts_update",
            "device_projection_accounts_delete",
            "device_projection_mailboxes_insert",
            "device_projection_mailboxes_update",
            "device_projection_mailboxes_delete",
            "device_projection_threads_insert",
            "device_projection_threads_update",
            "device_projection_threads_delete",
            "device_projection_messages_insert",
            "device_projection_messages_update",
            "device_projection_messages_delete",
        ] {
            XCTAssertFalse(source.contains(name), "live legacy storage reference remains: \(name)")
        }
    }

    private func sourceExcludingImmutableLegacyMigrationHistory(_ source: String) throws -> String {
        var result = source
        let regions = [
            (
                "    public func migrate() throws {",
                "        Self.registerLegacyPairingRemovalV51(on: &migrator)"
            ),
            (
                "    static func registerLegacyPairingRemovalV51(on migrator: inout DatabaseMigrator) {",
                "    private static func repairCredentialBlockedSyncJobs("
            ),
            (
                "    private static func sanitizeLegacyDeviceComposeMutationReceipts(",
                "    public var accounts: [Account] {"
            ),
            (
                "    private static func reconcileOwnershipV46(",
                "    private static func accountDeletionOwnership("
            ),
        ]
        for (startMarker, endMarker) in regions {
            let start = try XCTUnwrap(result.range(of: startMarker)?.lowerBound)
            let end = try XCTUnwrap(
                result.range(of: endMarker, range: start..<result.endIndex)?.lowerBound
            )
            result.removeSubrange(start..<end)
        }
        return result
    }

    private func source(at relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
