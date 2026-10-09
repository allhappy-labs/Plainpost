import Foundation
import XCTest

enum SyncNodeUnraidReleaseStage: String, CaseIterable, Sendable {
    case postgresIsolation = "postgres-isolation"
    case tlsReadiness = "tls-readiness"
    case nativeEnrollment = "native-enrollment"
    case gmailSync = "gmail-sync"
    case clientAPIContent = "client-api-content"
    case clientAPIMutations = "client-api-mutations"
    case restartRecovery = "restart-recovery"
    case backupRestore = "backup-restore"
    case replacementFence = "replacement-fence"
    case notification = "notification"
    case erase = "erase"
    case privacyNetwork = "privacy-network"
    case cleanup = "cleanup"
}

enum SyncNodeUnraidReleaseGateDecision: Equatable, Sendable {
    case incomplete(reason: String)
    case ready
}

struct SyncNodeUnraidReleaseConfiguration: Sendable {
    private let runGmailE2E: String
    private let gmailCredentialsPath: String
    private let gmailTokenPath: String

    init(environment: [String: String]) {
        runGmailE2E = environment["PLAINPOST_RUN_GMAIL_E2E"] ?? ""
        gmailCredentialsPath = environment["PLAINPOST_GMAIL_CREDENTIALS_FILE"] ?? ""
        gmailTokenPath = environment["PLAINPOST_GMAIL_TOKEN_FILE"] ?? ""
    }

    var gateDecision: SyncNodeUnraidReleaseGateDecision {
        guard runGmailE2E == "1" else {
            return .incomplete(reason: "gmail-e2e-disabled")
        }
        guard !gmailCredentialsPath.isEmpty, !gmailTokenPath.isEmpty else {
            return .incomplete(reason: "gmail-credentials-missing")
        }
        return .ready
    }
}

@MainActor
final class SyncNodeUnraidReleaseLiveTests: XCTestCase {
    func testTask6StageLedgerIsClosedAndOrdered() {
        XCTAssertEqual(
            SyncNodeUnraidReleaseStage.allCases.map(\.rawValue),
            [
                "postgres-isolation", "tls-readiness", "native-enrollment",
                "gmail-sync", "client-api-content", "client-api-mutations",
                "restart-recovery", "backup-restore", "replacement-fence",
                "notification", "erase", "privacy-network", "cleanup",
            ]
        )
    }

    func testGmailReleaseGateWithoutExplicitOptInIsIncomplete() {
        let configuration = SyncNodeUnraidReleaseConfiguration(environment: [:])
        XCTAssertEqual(configuration.gateDecision, .incomplete(reason: "gmail-e2e-disabled"))
    }

    func testCredentialedRunUsesRepositoryOwnedOwnerWithoutSelfAttestedEvidence() throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = SyncNodeUnraidReleaseConfiguration(environment: environment)
        guard configuration.gateDecision == .ready else {
            throw XCTSkip("INCOMPLETE: Gmail E2E is not explicitly enabled with mounted credentials")
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let owner = repositoryRoot.appendingPathComponent("Scripts/test-sync-node-e2e.sh")
        let ownerSource = try String(contentsOf: owner, encoding: .utf8)
        XCTAssertTrue(ownerSource.contains("exercise-unraid-native-tls.sh"))
        XCTAssertTrue(ownerSource.contains("release-artifacts-failed-verification"))
        XCTAssertTrue(ownerSource.contains("production release has no repository-owned Gmail/client scenario runner"))
        XCTAssertFalse(ownerSource.contains("PLAINPOST_SYNC_NODE_RELEASE_EVIDENCE_FILE"))
        XCTAssertFalse(ownerSource.contains("status=passed"))
        XCTAssertFalse(ownerSource.contains("ssh "))
    }
}
