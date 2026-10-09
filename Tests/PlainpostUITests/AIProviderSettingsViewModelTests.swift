import XCTest
import PlainpostAI
import PlainpostOperations
@testable import PlainpostUI

final class AIProviderSettingsViewModelTests: XCTestCase {
    func testSmartInboxDefaultsOnAndOffPersistsWithoutChangingProvider() throws {
        let suite = "SmartInboxSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSelectedProviderID("ollama")
        var writes: [SmartInboxMode] = []
        let settings = AIProviderSettingsViewModel.production(preferenceStore: preferences,
            persistSmartInboxPolicy: { writes.append($0) })
        XCTAssertTrue(settings.smartInboxEnabled)
        settings.setSmartInboxMode(.off)
        settings.setSmartInboxMode(.off)
        XCTAssertFalse(settings.smartInboxEnabled)
        XCTAssertEqual(writes, [.off])
        XCTAssertEqual(preferences.selectedProviderID(), "ollama")
        let reopened = AIProviderSettingsViewModel.production(preferenceStore: UserDefaultsAIProviderPreferenceStore(defaults: defaults))
        XCTAssertFalse(reopened.smartInboxEnabled)
        reopened.setSmartInboxMode(.allMail)
        XCTAssertTrue(preferences.smartInboxEnabled())
    }

    /// Before iOS 26 Smart Inbox counts as Off, but the stored choice survives so an
    /// upgrade restores it.
    func testUnavailableAIGenerationTreatsSmartInboxAsOffWithoutOverwritingTheStoredMode() throws {
        let suite = "SmartInboxPreIOS26.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        var writes: [SmartInboxMode] = []
        let settings = AIProviderSettingsViewModel.production(
            preferenceStore: preferences,
            aiGenerationAvailable: false,
            persistSmartInboxPolicy: { writes.append($0) }
        )

        XCTAssertEqual(settings.smartInboxMode, .off)
        XCTAssertFalse(settings.smartInboxEnabled)
        settings.setSmartInboxMode(.newMailOnly)
        XCTAssertEqual(settings.smartInboxMode, .off)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(preferences.smartInboxMode(), .allMail)

        let upgraded = AIProviderSettingsViewModel.production(
            preferenceStore: preferences, aiGenerationAvailable: true
        )
        XCTAssertEqual(upgraded.smartInboxMode, .allMail)
        XCTAssertTrue(upgraded.smartInboxEnabled)
    }

    func testSmartInboxPolicyFailurePreservesPublishedAndPersistedChoice() throws {
        let suite = "SmartInboxSettingsFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        let settings = AIProviderSettingsViewModel.production(preferenceStore: preferences,
            persistSmartInboxPolicy: { _ in throw CocoaError(.fileWriteNoPermission) })
        settings.setSmartInboxMode(.off)
        XCTAssertTrue(settings.smartInboxEnabled)
        XCTAssertTrue(preferences.smartInboxEnabled())
        XCTAssertEqual(settings.smartInboxPolicyError, "Unable to update Smart Inbox. Try again.")
    }

    func testChoosingNewMailOnlyStampsTheCutoffAndPersistsBothCopies() throws {
        let suite = "SmartInboxModeChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        var mirrored: [SmartInboxMode] = []
        let now = Date(timeIntervalSince1970: 7_000)
        let settings = AIProviderSettingsViewModel.production(
            preferenceStore: preferences,
            now: { now },
            persistSmartInboxPolicy: { mirrored.append($0) }
        )
        settings.setSmartInboxMode(.newMailOnly)
        XCTAssertEqual(settings.smartInboxMode, .newMailOnly(since: now))
        XCTAssertEqual(preferences.smartInboxMode(), .newMailOnly(since: now))
        XCTAssertEqual(mirrored, [.newMailOnly(since: now)])
        // Re-picking the same choice keeps the existing cutoff.
        settings.setSmartInboxMode(.newMailOnly)
        XCTAssertEqual(mirrored.count, 1)
    }

    func testSmartInboxModeFailureKeepsThePreviousChoice() throws {
        let suite = "SmartInboxModeFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        let settings = AIProviderSettingsViewModel.production(
            preferenceStore: preferences,
            persistSmartInboxPolicy: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        settings.setSmartInboxMode(.off)
        XCTAssertEqual(settings.smartInboxMode, .allMail)
        XCTAssertEqual(preferences.smartInboxMode(), .allMail)
        XCTAssertEqual(settings.smartInboxPolicyError, "Unable to update Smart Inbox. Try again.")
    }

    func testCanonicalPreferenceResolverReadsSuiteScopedStore() throws {
        let suiteName = "PlainpostAIProviderPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults)

        store.saveSelectedProviderID("ollama")
        XCTAssertEqual(AIProviderSelection.resolvedProviderID(from: store), "ollama")

        store.saveSelectedProviderID("deterministic")
        XCTAssertEqual(AIProviderSelection.resolvedProviderID(from: store), "foundation")
    }

    func testDefaultSettingsRowsExposeProviderChoicesAndFlagTheRemoteOne() {
        let viewModel = AIProviderSettingsViewModel.preview()

        XCTAssertEqual(
            viewModel.rows.map(\.title),
            ["Apple Foundation Models", "Ollama Local", "OpenRouter"]
        )
        XCTAssertEqual(viewModel.title, "AI Providers")
        XCTAssertEqual(viewModel.rows.map(\.localityLabel), ["Local only", "Local only", "Sent to OpenRouter"])
        XCTAssertFalse(viewModel.rows.contains { $0.detail.localizedCaseInsensitiveContains("cloud") })
    }

    func testSelectedProviderRowExposesStatusModelsAndSymbol() throws {
        let viewModel = AIProviderSettingsViewModel(
            statuses: [
                AIProviderStatusService.foundation(availability: .available),
                ollamaStatus(state: .unavailable)
            ],
            selectedProviderID: "foundation"
        )
        let selected = try XCTUnwrap(viewModel.selectedRow)

        XCTAssertEqual(selected.id, "foundation")
        XCTAssertEqual(selected.statusLabel, "Ready")
        XCTAssertEqual(selected.localityLabel, "Local only")
        XCTAssertEqual(selected.modelSummary, "Apple system language model")
        XCTAssertEqual(selected.systemImage, "apple.intelligence")
        XCTAssertTrue(selected.isSelected)
    }

    func testOllamaSettingsRowCanReflectReadyLocalStatus() throws {
        let viewModel = AIProviderSettingsViewModel(
            statuses: [
                AIProviderStatusService.foundation(availability: .available),
                AIProviderStatusSnapshot(
                    providerID: "ollama",
                    displayName: "Ollama Local",
                    state: .ready,
                    chatModelID: "qwen3:8b",
                    embeddingModelID: "mxbai-embed-large",
                    localOnly: true,
                    detail: "Ollama responded locally with configured models."
                )
            ],
            selectedProviderID: "ollama"
        )

        let selected = try XCTUnwrap(viewModel.selectedRow)
        XCTAssertEqual(selected.id, "ollama")
        XCTAssertEqual(selected.statusLabel, "Ready")
        XCTAssertEqual(selected.localityLabel, "Local only")
        XCTAssertEqual(selected.modelSummary, "Chat: qwen3:8b · Embeddings: mxbai-embed-large")
        XCTAssertEqual(selected.systemImage, "server.rack")
        XCTAssertEqual(selected.detail, "Ollama responded locally with configured models.")
    }

    func testFoundationModelsRowShowsLocalAppleProviderDetails() throws {
        let viewModel = AIProviderSettingsViewModel(
            statuses: [
                AIProviderStatusService.foundation(availability: .available)
            ],
            selectedProviderID: "foundation"
        )

        let selected = try XCTUnwrap(viewModel.selectedRow)
        XCTAssertEqual(selected.id, "foundation")
        XCTAssertEqual(selected.title, "Apple Foundation Models")
        XCTAssertEqual(selected.statusLabel, "Ready")
        XCTAssertEqual(selected.localityLabel, "Local only")
        XCTAssertEqual(selected.modelSummary, "Apple system language model")
        XCTAssertEqual(selected.systemImage, "apple.intelligence")
        XCTAssertEqual(selected.detail, "Apple on-device Foundation Models are available.")
    }

    func testSelectingProviderUpdatesRowsAndPersistsAcrossReload() throws {
        let suiteName = "PlainpostAIProviderSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults)

        let statuses = [
            AIProviderStatusService.foundation(availability: .available),
            ollamaStatus(state: .ready)
        ]
        let first = AIProviderSettingsViewModel(
            statuses: statuses,
            selectedProviderID: "foundation",
            preferenceStore: store
        )
        first.selectProvider("ollama")

        XCTAssertEqual(first.selectedProviderID, "ollama")
        XCTAssertTrue(first.rows.first { $0.id == "ollama" }?.isSelected == true)
        XCTAssertFalse(first.rows.first { $0.id == "foundation" }?.isSelected == true)

        let second = AIProviderSettingsViewModel(
            statuses: statuses,
            selectedProviderID: "foundation",
            preferenceStore: store
        )
        let selected = try XCTUnwrap(second.selectedRow)
        XCTAssertEqual(selected.id, "ollama")
        XCTAssertTrue(selected.isSelected)
    }

    func testLegacyDeterministicSelectionMigratesToFoundationAndPersists() throws {
        let suiteName = "PlainpostAIProviderSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        store.saveSelectedProviderID("deterministic")

        let viewModel = AIProviderSettingsViewModel(
            statuses: [AIProviderStatusService.foundation(availability: .available)],
            selectedProviderID: "foundation",
            preferenceStore: store
        )

        XCTAssertEqual(viewModel.selectedProviderID, "foundation")
        XCTAssertEqual(store.selectedProviderID(), "foundation")
        XCTAssertTrue(viewModel.rows.first { $0.id == "foundation" }?.isSelected == true)
    }

    func testUnavailableProviderCannotReplaceCurrentSelection() throws {
        let viewModel = AIProviderSettingsViewModel(
            statuses: [
                AIProviderStatusService.foundation(availability: .available),
                ollamaStatus(state: .unavailable)
            ],
            selectedProviderID: "foundation"
        )
        viewModel.selectProvider("remote-cloud")
        viewModel.selectProvider("ollama")

        XCTAssertEqual(viewModel.selectedProviderID, "foundation")
        XCTAssertTrue(viewModel.rows.first { $0.id == "foundation" }?.isSelected == true)
    }

    func testSmartInboxModeDefaultsPerPlatformOnFreshInstall() throws {
        let suite = "SmartInboxModeFresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_000)
        let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults, now: { now })
        #if os(iOS)
        XCTAssertEqual(store.smartInboxMode(), .newMailOnly(since: now))
        #else
        XCTAssertEqual(store.smartInboxMode(), .allMail)
        #endif
        // The resolved default is persisted, so the cutoff never drifts on later reads.
        let later = UserDefaultsAIProviderPreferenceStore(defaults: defaults, now: { Date(timeIntervalSince1970: 9_000) })
        XCTAssertEqual(later.smartInboxMode(), store.smartInboxMode())
    }

    func testSmartInboxModeMigratesLegacyBoolean() throws {
        for (legacy, expectedMac, expectedIOS) in [
            (false, SmartInboxMode.off, SmartInboxMode.off),
            (true, .allMail, .newMailOnly(since: Date(timeIntervalSince1970: 2_000))),
        ] {
            let suite = "SmartInboxModeLegacy.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(legacy, forKey: UserDefaultsAIProviderPreferenceStore.smartInboxEnabledKey)
            let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults, now: { Date(timeIntervalSince1970: 2_000) })
            #if os(iOS)
            XCTAssertEqual(store.smartInboxMode(), expectedIOS)
            #else
            XCTAssertEqual(store.smartInboxMode(), expectedMac)
            #endif
            XCTAssertEqual(store.smartInboxEnabled(), legacy)
        }
    }

    func testSavingSmartInboxModeRoundTripsAndKeepsLegacyKeyInSync() throws {
        let suite = "SmartInboxModeSave.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        let since = Date(timeIntervalSince1970: 5_000)
        store.saveSmartInboxMode(.newMailOnly(since: since))
        XCTAssertEqual(store.smartInboxMode(), .newMailOnly(since: since))
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsAIProviderPreferenceStore.smartInboxEnabledKey))
        store.saveSmartInboxMode(.off)
        XCTAssertFalse(store.smartInboxEnabled())
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsAIProviderPreferenceStore.smartInboxEnabledKey))
    }

    private func ollamaStatus(state: AIProviderStatusState) -> AIProviderStatusSnapshot {
        AIProviderStatusSnapshot(
            providerID: "ollama",
            displayName: "Ollama Local",
            state: state,
            chatModelID: "qwen3:8b",
            embeddingModelID: "mxbai-embed-large",
            localOnly: true,
            detail: "Ollama status for test."
        )
    }

    func testOpenRouterIsChoosableBeforeSetupAndBecomesReadyOnceSaved() throws {
        let suite = "OpenRouterSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        let store = InMemoryOpenRouterConfigurationStore()
        let settings = AIProviderSettingsViewModel.production(preferenceStore: preferences, openRouterStore: store)

        XCTAssertEqual(settings.choosableRows.map(\.id), ["foundation", "openrouter"])
        XCTAssertEqual(settings.choosableRows.map(\.choiceTitle), ["Apple Intelligence", "OpenRouter"])
        settings.selectProvider("openrouter")
        XCTAssertEqual(settings.selectedProviderID, "openrouter")
        XCTAssertEqual(preferences.selectedProviderID(), "openrouter")
        XCTAssertEqual(settings.selectedRow?.isSelectable, false)

        let keyBefore = settings.providerConfigurationKey
        settings.openRouterAPIKey = " sk-or-1 "
        settings.openRouterModelID = "openai/gpt-4o-mini"
        XCTAssertTrue(settings.saveOpenRouter())

        XCTAssertEqual(store.load(), OpenRouterConfiguration(apiKey: "sk-or-1", modelID: "openai/gpt-4o-mini"))
        XCTAssertEqual(settings.openRouterAPIKey, "sk-or-1")
        XCTAssertEqual(settings.selectedRow?.isSelectable, true)
        XCTAssertEqual(settings.selectedRow?.modelSummary, "openai/gpt-4o-mini")
        XCTAssertEqual(settings.selectedRow?.localityLabel, "Sent to OpenRouter")
        XCTAssertNil(settings.openRouterMessage)
        XCTAssertNotEqual(settings.providerConfigurationKey, keyBefore)

        let reopened = AIProviderSettingsViewModel.production(
            preferenceStore: UserDefaultsAIProviderPreferenceStore(defaults: defaults), openRouterStore: store
        )
        XCTAssertEqual(reopened.selectedProviderID, "openrouter")
        XCTAssertEqual(reopened.openRouterModelID, "openai/gpt-4o-mini")
        XCTAssertEqual(reopened.selectedRow?.isSelectable, true)
    }

    func testClearingOpenRouterFieldsRemovesTheStoredConfiguration() {
        let store = InMemoryOpenRouterConfigurationStore(OpenRouterConfiguration(apiKey: "k", modelID: "m"))
        let settings = AIProviderSettingsViewModel.production(preferenceStore: nil, openRouterStore: store)
        settings.openRouterAPIKey = ""
        settings.openRouterModelID = " "
        XCTAssertTrue(settings.saveOpenRouter())
        XCTAssertNil(store.load())
        XCTAssertEqual(settings.openRouterMessage, "Add an OpenRouter API key and model.")
    }

    @MainActor
    func testCheckingOpenRouterSavesThenReportsTheProvidersAnswer() async {
        let store = InMemoryOpenRouterConfigurationStore()
        let settings = AIProviderSettingsViewModel(
            statuses: [AIProviderStatusService.openRouter(configuration: nil)],
            selectedProviderID: "openrouter",
            openRouterStore: store,
            checkOpenRouterConnection: { _ in
                throw OpenRouterError.requestFailed(status: 404, message: "No endpoints found.")
            }
        )
        settings.openRouterAPIKey = "k"
        settings.openRouterModelID = "nope/model"
        await settings.checkOpenRouter()
        XCTAssertEqual(store.load()?.modelID, "nope/model")
        XCTAssertEqual(settings.openRouterMessage, "OpenRouter doesn’t know this model. Check the model name. No endpoints found.")
        XCTAssertFalse(settings.isCheckingOpenRouter)

        let connected = AIProviderSettingsViewModel(
            statuses: [AIProviderStatusService.openRouter(configuration: nil)],
            selectedProviderID: "openrouter",
            openRouterStore: store,
            checkOpenRouterConnection: { _ in }
        )
        await connected.checkOpenRouter()
        XCTAssertEqual(connected.openRouterMessage, "Connected. nope/model answered.")
    }

    func testSmartInboxClassifierModelTracksTheOpenRouterModel() {
        let store = InMemoryOpenRouterConfigurationStore(OpenRouterConfiguration(apiKey: "k", modelID: "x/y"))
        XCTAssertEqual(AIProviderSelection.classifierModelID(providerID: "openrouter", openRouterStore: store), "openrouter:x/y")
        XCTAssertNil(AIProviderSelection.classifierModelID(providerID: "foundation", openRouterStore: store))
        XCTAssertEqual(AIProviderSelection.resolvedProviderID("openrouter"), "openrouter")
    }
}
