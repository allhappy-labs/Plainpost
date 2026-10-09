import XCTest
import PlainpostAccountRuntime
@testable import PlainpostUI

final class SyncNodeSettingsViewModelTests: XCTestCase {
    @MainActor
    func testAttachmentStateIsAccountAndOperationScopedAndCleansArtifacts() throws {
        let state = PlainpostAttachmentState(accountID: "account-a")
        let token = state.begin(attachmentID: "attachment-a")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-attachment-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("file.txt")
        try Data("bytes".utf8).write(to: url)
        let artifact = PlainpostAttachmentArtifact(url: url, filename: "file.txt")
        state.publish(PlainpostAttachmentEvent(accountID: "account-b", attachmentID: "attachment-a", operationToken: token, outcome: .saved(artifact)))
        XCTAssertNil(state.event)
        state.publish(PlainpostAttachmentEvent(accountID: "account-a", attachmentID: "attachment-b", operationToken: token, outcome: .saved(artifact)))
        XCTAssertNil(state.event)
        state.publish(PlainpostAttachmentEvent(accountID: "account-a", attachmentID: "attachment-a", operationToken: token, outcome: .saved(artifact)))
        XCTAssertNotNil(state.event)
        state.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testAttachmentStateRejectsOutOfOrderTokenAndCleansStaleArtifact() throws {
        let state = PlainpostAttachmentState(accountID: "account-a")
        let firstToken = state.begin(attachmentID: "attachment-a")
        let secondToken = state.begin(attachmentID: "attachment-a")
        XCTAssertNotEqual(firstToken, secondToken)

        let staleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)
        let staleURL = staleDirectory.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: staleURL)
        state.publish(PlainpostAttachmentEvent(accountID: "account-a", attachmentID: "attachment-a", operationToken: firstToken, outcome: .saved(PlainpostAttachmentArtifact(url: staleURL, filename: "stale.txt"))))
        XCTAssertNil(state.event)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))

        let currentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-current-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: false)
        let currentURL = currentDirectory.appendingPathComponent("current.txt")
        try Data("current".utf8).write(to: currentURL)
        state.publish(PlainpostAttachmentEvent(accountID: "account-a", attachmentID: "attachment-a", operationToken: secondToken, outcome: .saved(PlainpostAttachmentArtifact(url: currentURL, filename: "current.txt"))))
        XCTAssertNotNil(state.event)
        state.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentDirectory.path))
    }

    @MainActor
    func testSettingsExposeOperationalFactsWithoutSecrets() {
        let snapshot = SyncNodeSettingsSnapshot(
            version: "node-1.4.0",
            reachability: "Reachable",
            syncLag: "12 seconds",
            storage: "4.2 GB",
            provider: "Google",
            mailboxAssignments: ["INBOX", "Sent"],
            backup: "Healthy",
            endpoint: "https://node.tailnet.example:8443",
            updateStatus: "Up to date"
        )
        let model = SyncNodeSettingsViewModel(snapshot: snapshot)

        XCTAssertEqual(model.snapshot.version, "node-1.4.0")
        XCTAssertEqual(model.snapshot.mailboxAssignments, ["INBOX", "Sent"])
        XCTAssertFalse(model.secretFreeDescription.contains("accessToken"))
        XCTAssertFalse(model.secretFreeDescription.contains("refreshToken"))
        XCTAssertFalse(model.secretFreeDescription.contains("clientSecret"))
        XCTAssertFalse(model.secretFreeDescription.contains("authorizationCode"))
    }

    @MainActor
    func testNodeSettingsOwnsProviderOnboardingAction() {
        var connectCount = 0
        let model = SyncNodeSettingsViewModel(connectProvider: { connectCount += 1 })

        XCTAssertTrue(model.canConnectProvider)
        model.connectProvider()
        XCTAssertEqual(connectCount, 1)
    }
}
