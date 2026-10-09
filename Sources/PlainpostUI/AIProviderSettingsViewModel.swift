import Foundation
import PlainpostAI
import PlainpostOperations

public protocol AIProviderPreferenceStore {
    func selectedProviderID() -> String?
    func saveSelectedProviderID(_ providerID: String)
    func smartInboxMode() -> SmartInboxMode
    func saveSmartInboxMode(_ mode: SmartInboxMode)
}

extension AIProviderPreferenceStore {
    public func smartInboxMode() -> SmartInboxMode { .allMail }
    public func saveSmartInboxMode(_ mode: SmartInboxMode) {}
    public func smartInboxEnabled() -> Bool { smartInboxMode().isEnabled }
}

public enum AIProviderSelection {
    public static let defaultProviderID = "foundation"
    public static let supportedProviderIDs: Set<String> = ["foundation", "ollama", OpenRouterConfiguration.providerID]
    /// The providers Settings offers. Ollama stays a development option configured by environment.
    public static let userChoosableProviderIDs: [String] = ["foundation", OpenRouterConfiguration.providerID]

    public static func resolvedProviderID(_ storedProviderID: String?) -> String {
        guard let storedProviderID, supportedProviderIDs.contains(storedProviderID) else {
            return defaultProviderID
        }
        return storedProviderID
    }

    public static func resolvedProviderID(
        from preferenceStore: any AIProviderPreferenceStore
    ) -> String {
        resolvedProviderID(preferenceStore.selectedProviderID())
    }

    /// The model a Smart Inbox run records, so changing the OpenRouter model shows up as a
    /// new classifier. Nil lets the classifier identity pick the provider's default.
    public static func classifierModelID(
        providerID: String,
        openRouterStore: any OpenRouterConfigurationStoring = KeychainOpenRouterConfigurationStore.shared
    ) -> String? {
        guard providerID == OpenRouterConfiguration.providerID,
              let modelID = openRouterStore.load()?.modelID, !modelID.isEmpty else { return nil }
        return "openrouter:\(modelID)"
    }
}

public final class UserDefaultsAIProviderPreferenceStore: AIProviderPreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let now: () -> Date
    public static let smartInboxEnabledKey = "Plainpost.smartInbox.enabled"
    public static let smartInboxModeKey = "Plainpost.smartInbox.mode"
    private let selectedProviderKey: String

    public init(
        defaults: UserDefaults = .standard,
        selectedProviderKey: String = "Plainpost.ai.selectedProviderID",
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.selectedProviderKey = selectedProviderKey
        self.now = now
    }

    public func smartInboxMode() -> SmartInboxMode {
        if let data = defaults.data(forKey: Self.smartInboxModeKey),
           let mode = try? JSONDecoder().decode(SmartInboxMode.self, from: data) {
            return mode
        }
        let legacy = defaults.object(forKey: Self.smartInboxEnabledKey) == nil
            ? nil : defaults.bool(forKey: Self.smartInboxEnabledKey)
        let mode = SmartInboxMode.migratingLegacy(enabled: legacy, now: now())
        saveSmartInboxMode(mode)
        return mode
    }

    public func saveSmartInboxMode(_ mode: SmartInboxMode) {
        defaults.set(try? JSONEncoder().encode(mode), forKey: Self.smartInboxModeKey)
        // `@AppStorage(smartInboxEnabledKey)` readers (the Mac Navigate menu) keep working.
        defaults.set(mode.isEnabled, forKey: Self.smartInboxEnabledKey)
    }

    public func selectedProviderID() -> String? {
        defaults.string(forKey: selectedProviderKey)
    }

    public func saveSelectedProviderID(_ providerID: String) {
        defaults.set(providerID, forKey: selectedProviderKey)
    }
}

public enum SmartInboxModeChoice: String, CaseIterable, Identifiable, Sendable {
    case off, newMailOnly, allMail
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .newMailOnly: "New mail only"
        case .allMail: "All mail"
        }
    }
    public init(_ mode: SmartInboxMode) {
        switch mode {
        case .off: self = .off
        case .newMailOnly: self = .newMailOnly
        case .allMail: self = .allMail
        }
    }
}

public final class AIProviderSettingsViewModel: ObservableObject {
    @Published public private(set) var rows: [AIProviderSettingsRowModel]
    @Published public private(set) var selectedProviderID: String
    @Published public private(set) var smartInboxMode: SmartInboxMode
    @Published public private(set) var smartInboxPolicyError: String?
    @Published public var openRouterAPIKey: String
    @Published public var openRouterModelID: String
    @Published public private(set) var openRouterMessage: String?
    @Published public private(set) var isCheckingOpenRouter = false
    /// Bumps whenever the selected provider's configuration changes, so open AI panes rebuild.
    @Published public private(set) var configurationRevision = 0
    private let persistSmartInboxPolicy: (SmartInboxMode) throws -> Void
    private let now: () -> Date
    /// False before iOS 26: Smart Inbox then counts as Off everywhere (no mailbox row, no
    /// sorting) while the stored choice is left alone, so upgrading restores it.
    public let aiGenerationAvailable: Bool

    public let title = "AI Providers"
    private var statuses: [AIProviderStatusSnapshot]
    private let preferenceStore: (any AIProviderPreferenceStore)?
    private let openRouterStore: (any OpenRouterConfigurationStoring)?
    private let checkOpenRouterConnection: @Sendable (OpenRouterConfiguration) async throws -> Void

    public var smartInboxEnabled: Bool { smartInboxMode.isEnabled }

    public init(
        statuses: [AIProviderStatusSnapshot],
        selectedProviderID: String,
        preferenceStore: (any AIProviderPreferenceStore)? = nil,
        now: @escaping () -> Date = Date.init,
        aiGenerationAvailable: Bool = true,
        persistSmartInboxPolicy: @escaping (SmartInboxMode) throws -> Void = { _ in },
        openRouterStore: (any OpenRouterConfigurationStoring)? = nil,
        checkOpenRouterConnection: @escaping @Sendable (OpenRouterConfiguration) async throws -> Void = {
            try await OpenRouterProvider(configuration: $0).checkConnection()
        }
    ) {
        self.aiGenerationAvailable = aiGenerationAvailable
        self.openRouterStore = openRouterStore
        self.checkOpenRouterConnection = checkOpenRouterConnection
        let openRouter = openRouterStore?.load()
        self.openRouterAPIKey = openRouter?.apiKey ?? ""
        self.openRouterModelID = openRouter?.modelID ?? ""
        self.smartInboxMode = aiGenerationAvailable
            ? preferenceStore?.smartInboxMode() ?? .allMail
            : .off
        self.persistSmartInboxPolicy = persistSmartInboxPolicy
        self.now = now
        self.statuses = statuses
        self.preferenceStore = preferenceStore
        let supportedProviderIDs = Set(statuses.map(\.providerID))
        let defaultProviderID = supportedProviderIDs.contains(AIProviderSelection.defaultProviderID)
            ? AIProviderSelection.defaultProviderID
            : statuses.first?.providerID ?? selectedProviderID
        let resolvedProviderID: String
        if let storedProviderID = preferenceStore?.selectedProviderID(),
           supportedProviderIDs.contains(storedProviderID) {
            resolvedProviderID = storedProviderID
        } else if supportedProviderIDs.contains(selectedProviderID) {
            resolvedProviderID = selectedProviderID
        } else {
            resolvedProviderID = defaultProviderID
        }
        self.selectedProviderID = resolvedProviderID
        self.rows = Self.rows(for: statuses, selectedProviderID: resolvedProviderID)
        if preferenceStore?.selectedProviderID() != resolvedProviderID {
            preferenceStore?.saveSelectedProviderID(resolvedProviderID)
        }
    }

    public func setSmartInboxMode(_ choice: SmartInboxModeChoice) {
        guard aiGenerationAvailable, choice != SmartInboxModeChoice(smartInboxMode) else { return }
        let mode: SmartInboxMode = switch choice {
        case .off: .off
        case .newMailOnly: .newMailOnly(since: now())
        case .allMail: .allMail
        }
        do {
            try persistSmartInboxPolicy(mode)
            preferenceStore?.saveSmartInboxMode(mode)
            smartInboxPolicyError = nil
            smartInboxMode = mode
        } catch {
            smartInboxPolicyError = "Unable to update Smart Inbox. Try again."
        }
    }

    public var selectedRow: AIProviderSettingsRowModel? {
        rows.first { $0.id == selectedProviderID }
    }

    /// Changes with the selected provider and with any change to its configuration.
    public var providerConfigurationKey: String { "\(selectedProviderID)#\(configurationRevision)" }

    public var choosableRows: [AIProviderSettingsRowModel] {
        AIProviderSelection.userChoosableProviderIDs.compactMap { id in rows.first { $0.id == id } }
    }

    public func selectProvider(_ providerID: String) {
        // Settings' own choices stay selectable while unready, so their setup shows.
        guard let status = statuses.first(where: { $0.providerID == providerID }),
              status.state == .ready || AIProviderSelection.userChoosableProviderIDs.contains(providerID) else {
            return
        }
        selectedProviderID = providerID
        preferenceStore?.saveSelectedProviderID(providerID)
        rows = Self.rows(for: statuses, selectedProviderID: providerID)
    }

    /// Stores the OpenRouter key and model; clearing both removes them.
    @discardableResult
    public func saveOpenRouter() -> Bool {
        guard let openRouterStore else { return false }
        let configuration = OpenRouterConfiguration(apiKey: openRouterAPIKey, modelID: openRouterModelID)
        do {
            if configuration.apiKey.isEmpty && configuration.modelID.isEmpty {
                try openRouterStore.clear()
            } else {
                try openRouterStore.save(configuration)
            }
        } catch {
            openRouterMessage = "Couldn’t save the OpenRouter settings to the Keychain."
            return false
        }
        openRouterAPIKey = configuration.apiKey
        openRouterModelID = configuration.modelID
        openRouterMessage = configuration.isComplete ? nil : OpenRouterError.notConfigured.errorDescription
        let status = AIProviderStatusService.openRouter(configuration: configuration)
        statuses = statuses.map { $0.providerID == status.providerID ? status : $0 }
        rows = Self.rows(for: statuses, selectedProviderID: selectedProviderID)
        configurationRevision += 1
        return true
    }

    /// Saves, then sends OpenRouter a one-word request and reports its answer.
    @MainActor
    public func checkOpenRouter() async {
        guard saveOpenRouter() else { return }
        let configuration = OpenRouterConfiguration(apiKey: openRouterAPIKey, modelID: openRouterModelID)
        guard configuration.isComplete else { return }
        isCheckingOpenRouter = true
        openRouterMessage = nil
        defer { isCheckingOpenRouter = false }
        do {
            try await checkOpenRouterConnection(configuration)
            openRouterMessage = "Connected. \(configuration.modelID) answered."
        } catch {
            openRouterMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn’t reach OpenRouter. Check your connection and try again."
        }
    }

    public static func production(
        preferenceStore: (any AIProviderPreferenceStore)? = UserDefaultsAIProviderPreferenceStore(),
        now: @escaping () -> Date = Date.init,
        aiGenerationAvailable: Bool? = nil,
        persistSmartInboxPolicy: @escaping (SmartInboxMode) throws -> Void = { _ in },
        openRouterStore: (any OpenRouterConfigurationStoring)? = KeychainOpenRouterConfigurationStore.shared
    ) -> AIProviderSettingsViewModel {
        configuredDefault(
            preferenceStore: preferenceStore, now: now,
            aiGenerationAvailable: aiGenerationAvailable ?? PlainpostAIGenerationPolicy.current,
            persistSmartInboxPolicy: persistSmartInboxPolicy,
            openRouterStore: openRouterStore
        )
    }

    public static func preview(
        preferenceStore: (any AIProviderPreferenceStore)? = nil
    ) -> AIProviderSettingsViewModel {
        configuredDefault(preferenceStore: preferenceStore)
    }

    private static func configuredDefault(
        preferenceStore: (any AIProviderPreferenceStore)?,
        now: @escaping () -> Date = Date.init,
        aiGenerationAvailable: Bool = true,
        persistSmartInboxPolicy: @escaping (SmartInboxMode) throws -> Void = { _ in },
        openRouterStore: (any OpenRouterConfigurationStoring)? = nil
    ) -> AIProviderSettingsViewModel {
        AIProviderSettingsViewModel(
            statuses: [
                AIProviderStatusService.foundation(),
                AIProviderStatusSnapshot(
                    providerID: "ollama",
                    displayName: "Ollama Local",
                    state: .unavailable,
                    chatModelID: "qwen3:8b",
                    embeddingModelID: "mxbai-embed-large",
                    localOnly: true,
                    detail: "Ollama has not been checked in this session."
                ),
                AIProviderStatusService.openRouter(configuration: openRouterStore?.load()),
            ],
            selectedProviderID: AIProviderSelection.defaultProviderID,
            preferenceStore: preferenceStore,
            now: now,
            aiGenerationAvailable: aiGenerationAvailable,
            persistSmartInboxPolicy: persistSmartInboxPolicy,
            openRouterStore: openRouterStore
        )
    }

    private static func rows(
        for statuses: [AIProviderStatusSnapshot],
        selectedProviderID: String
    ) -> [AIProviderSettingsRowModel] {
        statuses.map { status in
            AIProviderSettingsRowModel(status: status, isSelected: status.providerID == selectedProviderID)
        }
    }
}

public struct AIProviderSettingsRowModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let statusLabel: String
    public let localityLabel: String
    public let modelSummary: String
    public let detail: String
    public let systemImage: String
    public let isSelected: Bool
    public let isSelectable: Bool

    public init(
        id: String,
        title: String,
        statusLabel: String,
        localityLabel: String,
        modelSummary: String,
        detail: String,
        systemImage: String,
        isSelected: Bool,
        isSelectable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.statusLabel = statusLabel
        self.localityLabel = localityLabel
        self.modelSummary = modelSummary
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isSelectable = isSelectable
    }

    public init(status: AIProviderStatusSnapshot, isSelected: Bool) {
        self.id = status.providerID
        self.title = status.displayName
        self.statusLabel = status.state == .ready ? "Ready" : "Unavailable"
        self.localityLabel = status.localOnly ? "Local only" : "Sent to \(status.displayName)"
        self.modelSummary = Self.modelSummary(
            providerID: status.providerID,
            chatModelID: status.chatModelID,
            embeddingModelID: status.embeddingModelID
        )
        self.detail = status.detail
        self.systemImage = Self.systemImage(providerID: status.providerID)
        self.isSelected = isSelected
        self.isSelectable = status.state == .ready
    }

    /// The name Settings shows in the provider picker.
    public var choiceTitle: String { id == "foundation" ? "Apple Intelligence" : title }

    private static func modelSummary(
        providerID: String,
        chatModelID: String?,
        embeddingModelID: String?
    ) -> String {
        if providerID == "foundation" {
            return "Apple system language model"
        }
        if providerID == OpenRouterConfiguration.providerID {
            return chatModelID ?? "No model"
        }
        let chat = chatModelID ?? "none"
        let embeddings = embeddingModelID ?? "none"
        return "Chat: \(chat) · Embeddings: \(embeddings)"
    }

    public var isAppleSystemModel: Bool { id == "foundation" }

    private static func systemImage(providerID: String) -> String {
        switch providerID {
        case "foundation":
            return "apple.intelligence"
        case "ollama":
            return "server.rack"
        case OpenRouterConfiguration.providerID:
            return "network"
        case "disabled":
            return "power"
        default:
            return "cpu"
        }
    }
}
