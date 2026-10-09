import Foundation
import XCTest

/// Runs `Scripts/test-service-keychain-group-contract.sh` against a fake
/// signed bundle; no real codesign, keychain or signing identity is used.
final class ServiceKeychainGroupContractScriptTests: XCTestCase {
    private let accountShared = "9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"

    func testPassesOnlyWhenBothGroupsAreEffective() throws {
        let result = try run(groups: [accountShared], vaultRecord: "SERVICE_VAULT_GROUP=\(accountShared)")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("check=account_shared outcome=pass"), result.output)
        XCTAssertTrue(result.output.contains("check=service_vault_group outcome=pass"), result.output)
    }

    func testFailsLoudlyWhenTheServiceOnlyHasItsOwnGroup() throws {
        let result = try run(groups: ["9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"], vaultRecord: "SERVICE_VAULT_GROUP=\(accountShared)")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("check=account_shared outcome=missing"), result.output)
        XCTAssertTrue(result.output.contains("check=service_vault_group outcome=missing"), result.output)
    }

    func testFailsWhenTheSpikeRecordIsAbsentOrFromAnotherTeam() throws {
        let absent = try run(groups: [accountShared], vaultRecord: "KEY_OUTCOME=shared")
        XCTAssertEqual(absent.status, 1)
        XCTAssertTrue(absent.output.contains("check=account_shared outcome=pass"), absent.output)
        XCTAssertTrue(absent.output.contains("check=service_vault_group outcome=missing_record"), absent.output)

        let stale = try run(groups: [accountShared, "PCQG52JLF9.com.olhapi.Plainpost.AccountShared"], vaultRecord: "SERVICE_VAULT_GROUP=PCQG52JLF9.com.olhapi.Plainpost.AccountShared")
        XCTAssertEqual(stale.status, 1)
        XCTAssertTrue(stale.output.contains("check=service_vault_group outcome=stale_record"), stale.output)
    }

    func testFailsWhenEntitlementsCannotBeRead() throws {
        let result = try run(groups: nil, vaultRecord: "SERVICE_VAULT_GROUP=\(accountShared)")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("check=account_shared outcome=unreadable_entitlements"), result.output)
    }

    private func run(groups: [String]?, vaultRecord: String) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-keychain-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Plainpost.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Library/Helpers/PlainpostService.app"), withIntermediateDirectories: true)
        let record = root.appendingPathComponent("spike.md")
        try "# Spike\n\n\(vaultRecord)\n".write(to: record, atomically: true, encoding: .utf8)
        let plist = root.appendingPathComponent("entitlements.plist")
        if let groups {
            let data = try PropertyListSerialization.data(fromPropertyList: ["keychain-access-groups": groups], format: .xml, options: 0)
            try data.write(to: plist)
        }
        let codesign = root.appendingPathComponent("codesign.sh")
        let body = groups == nil ? "exit 1" : "/bin/cat \"\(plist.path)\""
        try "#!/bin/sh\n[ \"$1\" = \"-d\" ] || exit 2\n\(body)\n".write(to: codesign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path)

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("Scripts/test-service-keychain-group-contract.sh").path, bundle.path]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "PLAINPOST_SERVICE_KEYCHAIN_SPIKE_RECORD": record.path,
            "PLAINPOST_SERVICE_KEYCHAIN_CONTRACT_CODESIGN_COMMAND": codesign.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
