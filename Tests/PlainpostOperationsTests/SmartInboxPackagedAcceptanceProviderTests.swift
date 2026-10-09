#if DEBUG
import Darwin
import PlainpostAI
import PlainpostCore
@testable import PlainpostOperationRuntime
import PlainpostOperations
import Foundation
import Testing

@Suite(.serialized)
struct SmartInboxPackagedAcceptanceProviderTests {
    @Test
    func gateRequiresExactValidatedPackagedEnvironment() throws {
        let fixture = try Fixture()
        let resolved = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
            environment: fixture.environment
        )
        let configuration = try #require(resolved)

        let resolvedRoot = fixture.rootURL.resolvingSymlinksInPath().standardizedFileURL
        #expect(configuration.rootURL == resolvedRoot)
        #expect(configuration.gateDirectoryURL == resolvedRoot.appendingPathComponent(
            "SmartInboxAcceptanceGate",
            isDirectory: true
        ))

        var wrongDatabase = fixture.environment
        wrongDatabase["PLAINPOST_ACCEPTANCE_DATABASE_PATH"] = fixture.rootURL
            .appendingPathComponent("Other.sqlite").path
        #expect(throws: SmartInboxPackagedAcceptanceGateError.invalidEnvironment) {
            _ = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
                environment: wrongDatabase
            )
        }

        let otherFixture = try Fixture()
        var differentPrivateRoot = fixture.environment
        differentPrivateRoot["PLAINPOST_DATA_DIR"] = otherFixture.rootURL.path
        #expect(throws: SmartInboxPackagedAcceptanceGateError.invalidEnvironment) {
            _ = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
                environment: differentPrivateRoot
            )
        }
    }

    @Test
    func gateIsAbsentForOrdinaryRuntimeEnvironment() throws {
        #expect(try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
            environment: [
                "PLAINPOST_DATA_DIR": "/ordinary/production/data",
                "PLAINPOST_KEYCHAIN_SERVICE": "Plainpost",
            ]
        ) == nil)
    }

    @Test
    func smartInboxModeRequiresExactGateBeforeTouchingSelectedDatabase() throws {
        for gateValue in [nil, "0", "true"] as [String?] {
            let fixture = try Fixture()
            let databaseURL = fixture.rootURL.appendingPathComponent("Plainpost.sqlite")
            let sentinel = Data("selected-database-must-stay-untouched".utf8)
            try sentinel.write(to: databaseURL)
            var environment = fixture.environment
            environment["PLAINPOST_SMART_INBOX_ACCEPTANCE_GATE"] = gateValue

            #expect(throws: SmartInboxPackagedAcceptanceGateError.invalidEnvironment) {
                _ = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
                    environment: environment
                )
            }
            #expect(try Data(contentsOf: databaseURL) == sentinel)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.rootURL.appendingPathComponent(
                    "SmartInboxAcceptanceGate",
                    isDirectory: true
                ).path
            ))
        }
    }

    @Test
    func gatedFallbackUsesCanonicalClassifierModelBeforeEnvironment() {
        let identity = SmartInboxClassifierIdentity(
            providerID: "ollama",
            modelID: "job-pinned-model",
            schemaVersion: "schema",
            promptVersion: "prompt"
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "ollama",
            smartInboxClassifierIdentity: identity
        )
        let selection = SmartInboxPackagedAcceptanceProviderResolver.fallbackSelection(
            input: input,
            environment: [
                "PLAINPOST_OLLAMA_URL": "http://127.0.0.1:11435",
                "PLAINPOST_OLLAMA_CHAT_MODEL": "environment-model",
                "PLAINPOST_OLLAMA_EMBEDDING_MODEL": "embedding-model",
            ]
        )

        #expect(selection.providerID == "ollama")
        #expect(selection.ollamaBaseURL == URL(string: "http://127.0.0.1:11435"))
        #expect(selection.ollamaChatModelID == "job-pinned-model")
        #expect(selection.ollamaEmbeddingModelID == "embedding-model")
    }

    @Test
    func providerBlocksEachRealBatchUntilItsReleaseAndContinuesSequenceAcrossInstances() async throws {
        let fixture = try Fixture()
        let resolved = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
            environment: fixture.environment
        )
        let configuration = try #require(resolved)
        let firstProvider = SmartInboxPackagedAcceptanceProvider(configuration: configuration)
        let firstRequest = Self.request(messageID: "acceptance-message-00")

        let firstTask = Task {
            try await firstProvider.classifyBatch(firstRequest)
        }
        let firstStarted = configuration.gateDirectoryURL
            .appendingPathComponent("invocation-0001.started")
        try await waitForFile(firstStarted)
        #expect(!firstTask.isCancelled)
        #expect(try String(contentsOf: firstStarted, encoding: .utf8)
            .contains("acceptance-message-00"))

        try createRelease(
            configuration.gateDirectoryURL.appendingPathComponent("invocation-0001.release")
        )
        let firstResponse = try await firstTask.value
        #expect(firstResponse.results.map(\.id) == ["acceptance-message-00"])
        try await waitForFile(
            configuration.gateDirectoryURL.appendingPathComponent("invocation-0001.finished")
        )

        let relaunchedProvider = SmartInboxPackagedAcceptanceProvider(configuration: configuration)
        let secondTask = Task {
            try await relaunchedProvider.classifyBatch(
                Self.request(messageID: "acceptance-message-01")
            )
        }
        let secondStarted = configuration.gateDirectoryURL
            .appendingPathComponent("invocation-0002.started")
        try await waitForFile(secondStarted)
        #expect(try String(contentsOf: secondStarted, encoding: .utf8)
            .contains("acceptance-message-01"))
        try createRelease(
            configuration.gateDirectoryURL.appendingPathComponent("invocation-0002.release")
        )
        _ = try await secondTask.value
    }

    @Test
    func providerRejectsSymlinkedStartedMarkerWithoutTouchingTarget() async throws {
        let fixture = try Fixture()
        let resolved = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
            environment: fixture.environment
        )
        let configuration = try #require(resolved)
        let targetURL = fixture.rootURL.appendingPathComponent("started-target")
        try Data("unchanged".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: configuration.gateDirectoryURL
                .appendingPathComponent("invocation-0001.started"),
            withDestinationURL: targetURL
        )

        do {
            _ = try await SmartInboxPackagedAcceptanceProvider(configuration: configuration)
                .classifyBatch(Self.request(messageID: "acceptance-message-00"))
            Issue.record("Expected a symlinked started marker to be rejected.")
        } catch {
            #expect(error as? SmartInboxPackagedAcceptanceGateError == .invalidMarker)
        }
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "unchanged")
    }

    @Test
    func providerRejectsSymlinkedOrBroadReleaseMarker() async throws {
        for kind in ["symlink", "broad-mode"] {
            let fixture = try Fixture()
            let resolved = try SmartInboxPackagedAcceptanceGateConfiguration.resolve(
                environment: fixture.environment
            )
            let configuration = try #require(resolved)
            let releaseURL = configuration.gateDirectoryURL
                .appendingPathComponent("invocation-0001.release")
            if kind == "symlink" {
                let targetURL = fixture.rootURL.appendingPathComponent("release-target")
                try Data().write(to: targetURL)
                try FileManager.default.createSymbolicLink(
                    at: releaseURL,
                    withDestinationURL: targetURL
                )
            } else {
                #expect(FileManager.default.createFile(
                    atPath: releaseURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o644]
                ))
            }

            do {
                _ = try await SmartInboxPackagedAcceptanceProvider(configuration: configuration)
                    .classifyBatch(Self.request(messageID: "acceptance-message-00"))
                Issue.record("Expected an unsafe release marker to be rejected.")
            } catch {
                #expect(error as? SmartInboxPackagedAcceptanceGateError == .invalidMarker)
            }
        }
    }

    private static func request(messageID: String) -> AIClassificationBatchRequest {
        AIClassificationBatchRequest(
            messages: [
                AIClassificationMessage(
                    id: MessageID(messageID),
                    accountID: AccountID("acceptance-account"),
                    senderAddress: "sender@example.invalid",
                    senderDisplayName: "Acceptance",
                    recipients: ["recipient@example.invalid"],
                    subject: "Packaged acceptance",
                    preview: "Synthetic acceptance message",
                    bodyExcerpt: "Synthetic acceptance body",
                    eligibleLabelIDs: []
                )
            ]
        )
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func createRelease(_ url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SmartInboxPackagedAcceptanceGateError.unableToCreateGate
        }
    }

}

private final class Fixture {
    let rootURL: URL
    let environment: [String: String]

    init() throws {
        rootURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("plainpost-acceptance.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let service = "com.marynavdovenko.Plainpost.Acceptance.\(UUID().uuidString)"
        environment = [
            "PLAINPOST_ACCEPTANCE_MODE": "smart-inbox",
            "PLAINPOST_ACCEPTANCE_ROOT": rootURL.path,
            "PLAINPOST_ACCEPTANCE_DATABASE_PATH": rootURL.appendingPathComponent("Plainpost.sqlite").path,
            "PLAINPOST_ACCEPTANCE_KEYCHAIN_SERVICE": service,
            "PLAINPOST_DATA_DIR": rootURL.path,
            "PLAINPOST_KEYCHAIN_SERVICE": service,
            "PLAINPOST_SMART_INBOX_ACCEPTANCE_GATE": "1",
        ]
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
#endif
