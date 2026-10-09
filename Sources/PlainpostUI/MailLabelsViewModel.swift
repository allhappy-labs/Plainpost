import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostOperations

public struct MailLabelDraft: Equatable, Sendable {
    public let existingLabelID: String?
    public var title: String
    public var description: String
    public var isSmartInboxEnabled: Bool
    public let scope: MailLabelScope

    public init(
        existingLabelID: String? = nil,
        title: String = "",
        description: String = "",
        isSmartInboxEnabled: Bool = false,
        scope: MailLabelScope
    ) {
        self.existingLabelID = existingLabelID
        self.title = title
        self.description = description
        self.isSmartInboxEnabled = isSmartInboxEnabled
        self.scope = scope
    }
}

public enum MailLabelConfirmation: Equatable, Sendable {
    case disableForEmptyDescription
    case reclassify(MailLabelReclassificationPreview)
    case delete(MailLabelDeletionPreview)
}

@_spi(DesignPreview)
public enum MailLabelsDesignPreviewState: Sendable {
    case standard
    case accountScope
    case empty
    case emptyAdd
    case descriptionValidation
    case disableConfirmation
    case reclassifyConfirmation
    case deleteConfirmation
    case progress
}

public struct MailLabelRunProgress: Equatable, Sendable {
    public let updated: Int
    public let unchanged: Int
    public let failed: Int

    public init(updated: Int, unchanged: Int, failed: Int) {
        self.updated = updated
        self.unchanged = unchanged
        self.failed = failed
    }

    public var summary: String {
        if failed == 0 {
            return "\(updated) updated, \(unchanged) unchanged"
        }
        return "\(updated) updated, \(unchanged) unchanged, \(failed) failed"
    }
}

public typealias MailLabelReclassificationRunner = @MainActor @Sendable (
    PlainpostSmartInboxRunRequest
) async throws -> MailLabelRunProgress
@MainActor
public final class MailLabelsViewModel: ObservableObject {
    @Published public var selection: AccountManagementSelection {
        didSet {
            if let selectedDirectAccountID,
               selection != .account(selectedDirectAccountID) {
                selection = .account(selectedDirectAccountID)
            }
        }
    }
    @Published public private(set) var labels: [MailLabelDefinition] = []
    @Published public var selectedLabelID: String?
    @Published public var draft: MailLabelDraft?
    @Published public private(set) var validationMessage: String?
    @Published public private(set) var confirmation: MailLabelConfirmation?
    @Published public private(set) var progress: MailLabelRunProgress?
    @Published public private(set) var isWorking = false
    /// Whether loading opens the first label. The Mac shows the list and editor
    /// side by side, so it opens on the first label. iOS pushes the editor for
    /// any selected label, so there it opens only from a row tap or Add.
    var selectsFirstLabelOnLoad = MailLabelsViewModel.platformSelectsFirstLabelOnLoad

    #if os(iOS)
    static let platformSelectsFirstLabelOnLoad = false
    #else
    static let platformSelectsFirstLabelOnLoad = true
    #endif

    public let accounts: [Account]
    private let selectedDirectAccountID: AccountID?
    private let directSourceGeneration: Int64?

    private let definitions: (any MailLabelDefinitionRepository)?
    private let runReclassification: MailLabelReclassificationRunner
    private var previewLabels: [MailLabelDefinition]
    private let previewDeletion: MailLabelDeletionPreview?
    private let previewReclassificationCount: Int
    private var designPreviewState: MailLabelsDesignPreviewState?

    public init(
        definitions: any MailLabelDefinitionRepository,
        accounts: [Account],
        selectedDirectAccountID: AccountID? = nil,
        runReclassification: @escaping MailLabelReclassificationRunner
    ) {
        self.selection = selectedDirectAccountID.map(AccountManagementSelection.account) ?? .allAccounts
        self.definitions = definitions
        self.selectedDirectAccountID = selectedDirectAccountID
        self.directSourceGeneration = selectedDirectAccountID.flatMap { id in
            try? (definitions as? SQLiteMailStore)?.mailSource(accountID: id).generation
        }
        self.accounts = selectedDirectAccountID.map { id in accounts.filter { $0.id == id } } ?? accounts
        self.runReclassification = runReclassification
        self.previewLabels = []
        self.previewDeletion = nil
        self.previewReclassificationCount = 0
        self.designPreviewState = nil
    }

    init(
        accounts: [Account],
        labels: [MailLabelDefinition],
        deletionPreview: MailLabelDeletionPreview? = nil,
        reclassificationCount: Int = 12,
        runReclassification: @escaping MailLabelReclassificationRunner
    ) {
        self.selection = .allAccounts
        self.definitions = nil
        self.selectedDirectAccountID = nil
        self.directSourceGeneration = nil
        self.accounts = accounts
        self.runReclassification = runReclassification
        self.previewLabels = labels
        self.previewDeletion = deletionPreview
        self.previewReclassificationCount = reclassificationCount
        self.designPreviewState = nil
    }

    public var requiresDisableConfirmation: Bool {
        guard let draft,
              draft.existingLabelID != nil,
              draft.isSmartInboxEnabled,
              draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let existing = labels.first(where: { $0.id == draft.existingLabelID })
        else {
            return false
        }
        return existing.isSmartInboxEnabled
    }

    public func load() async {
        if let designPreviewState {
            configureDesignPreview(designPreviewState)
        } else {
            reload()
        }
    }

    public func selectAccount(_ selection: AccountManagementSelection) {
        self.selection = selectedDirectAccountID.map(AccountManagementSelection.account) ?? selection
        confirmation = nil
        progress = nil
        reload()
    }

    func scopeDisplayName(_ scope: MailLabelScope) -> String {
        guard case .account(let accountID) = scope else { return "All Accounts" }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return accountID.rawValue
        }
        let displayName = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = account.email.rawValue
        guard !displayName.isEmpty,
              displayName.caseInsensitiveCompare(email) != .orderedSame else {
            return email
        }
        return "\(displayName) — \(email)"
    }

    public func addLabel() {
        guard directSourceIsCurrent else { return }
        selectedLabelID = nil
        confirmation = nil
        progress = nil
        validationMessage = nil
        draft = MailLabelDraft(scope: selectedScope)
    }

    public func selectLabel(id: String) {
        guard let label = labels.first(where: { $0.id == id }) else { return }
        selectedLabelID = id
        draft = Self.draft(for: label)
        confirmation = nil
        progress = nil
        validationMessage = nil
    }

    public func setSmartInboxEnabled(_ enabled: Bool) {
        guard var draft else { return }
        if enabled,
           draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.isSmartInboxEnabled = false
            self.draft = draft
            validationMessage = "Add a description before using this label in Smart Inbox."
            return
        }
        draft.isSmartInboxEnabled = enabled
        self.draft = draft
        validationMessage = nil
    }

    /// The iOS label row's toggle: changes only that label's Smart Inbox flag. Unlike
    /// `selectLabel` + `save`, it neither selects the label nor opens a draft (which
    /// would push the editor); an editor already open on a label keeps its draft.
    /// Enabling a label with no description is the exception: its editor opens with
    /// the reason, since the list has nowhere to show it.
    public func setSmartInboxEnabled(_ enabled: Bool, forLabelID id: String) async {
        guard let label = labels.first(where: { $0.id == id }),
              label.isSmartInboxEnabled != enabled,
              canMutate(label.scope) else { return }
        if enabled, label.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The list can't show why; open the label's editor (on iOS a draft pushes it)
            // with the message so a description can be added there.
            selectLabel(id: id)
            setSmartInboxEnabled(true)
            return
        }
        do {
            try write(MailLabelDefinition.validated(
                id: label.id,
                title: label.title,
                description: label.description,
                isSmartInboxEnabled: enabled,
                scope: label.scope,
                createdAt: label.createdAt,
                updatedAt: Date()
            ))
        } catch let error as MailLabelValidationError {
            validationMessage = message(for: error)
            return
        } catch {
            validationMessage = "The label could not be saved."
            return
        }
        let openDraft = draft
        reload(selectingFirst: false)
        if var openDraft, openDraft.existingLabelID == selectedLabelID {
            if openDraft.existingLabelID == id { openDraft.isSmartInboxEnabled = enabled }
            draft = openDraft
        }
    }

    public func save() async {
        guard let draft, canMutate(draft.scope) else { return }
        if requiresDisableConfirmation {
            confirmation = .disableForEmptyDescription
            return
        }
        await persist(draft)
    }

    public func previewReclassification() async {
        guard let labelID = draft?.existingLabelID,
              let label = labels.first(where: { $0.id == labelID }),
              canMutate(label.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let preview: MailLabelReclassificationPreview
            if let definitions {
                preview = try await definitions.previewMailLabelReclassification(id: labelID)
            } else if let label = labels.first(where: { $0.id == labelID }) {
                preview = MailLabelReclassificationPreview(
                    labelID: labelID,
                    scope: label.scope,
                    affectedMessageCount: previewReclassificationCount
                )
            } else {
                throw MailLabelValidationError.unknownLabel
            }
            confirmation = .reclassify(preview)
            validationMessage = nil
        } catch {
            validationMessage = "Existing mail could not be previewed."
        }
    }

    public func confirmReclassification() async {
        guard case .reclassify(let preview) = confirmation,
              let label = labels.first(where: { $0.id == preview.labelID }),
              canMutate(label.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let scope = preview.scope.accountID
                .map(PlainpostSmartInboxRunScope.account)
                ?? .allAccounts
            progress = try await runReclassification(
                PlainpostSmartInboxRunRequest(
                    mode: .rerunAll,
                    scope: scope,
                    requestedLabelID: preview.labelID
                )
            )
            confirmation = nil
            validationMessage = nil
        } catch {
            validationMessage = "Processing did not complete. Some messages may already be updated."
        }
    }

    public func previewDeletion() async {
        guard let labelID = draft?.existingLabelID,
              let label = labels.first(where: { $0.id == labelID }),
              canMutate(label.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let preview: MailLabelDeletionPreview
            if let definitions {
                preview = try definitions.previewMailLabelDeletion(id: labelID)
            } else if let previewDeletion, previewDeletion.labelID == labelID {
                preview = previewDeletion
            } else if let label = labels.first(where: { $0.id == labelID }) {
                preview = MailLabelDeletionPreview(
                    labelID: labelID,
                    scope: label.scope,
                    affectedMessageCount: 0,
                    affectedRuleCount: 0
                )
            } else {
                throw MailLabelValidationError.unknownLabel
            }
            confirmation = .delete(preview)
            validationMessage = nil
        } catch {
            validationMessage = "The label deletion impact could not be loaded."
        }
    }

    public func confirmDeletion() async {
        guard case .delete(let preview) = confirmation,
              let label = labels.first(where: { $0.id == preview.labelID }),
              canMutate(label.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let definitions {
                try definitions.deleteMailLabel(id: preview.labelID)
            } else {
                previewLabels.removeAll { $0.id == preview.labelID }
            }
            confirmation = nil
            // The deleted label's editor closes (iOS pops back to the list) rather than
            // moving on to another label.
            selectedLabelID = nil
            draft = nil
            reload(selectingFirst: false)
        } catch {
            validationMessage = "The label could not be deleted."
        }
    }

    public func confirmDescriptionClearAndSave() async {
        guard var draft, canMutate(draft.scope) else { return }
        draft.isSmartInboxEnabled = false
        self.draft = draft
        confirmation = nil
        await persist(draft)
    }

    public func dismissConfirmation() {
        confirmation = nil
    }

    func configureDesignPreview(_ state: MailLabelsDesignPreviewState) {
        designPreviewState = state
        reload()

        switch state {
        case .standard:
            break
        case .accountScope:
            selection = .account(AccountID("a"))
            reload()
        case .empty:
            break
        case .emptyAdd:
            addLabel()
        case .descriptionValidation:
            setSmartInboxEnabled(true)
        case .disableConfirmation:
            guard var draft else { return }
            draft.description = ""
            self.draft = draft
            confirmation = .disableForEmptyDescription
        case .reclassifyConfirmation:
            guard let label = selectedLabel else { return }
            confirmation = .reclassify(
                MailLabelReclassificationPreview(
                    labelID: label.id,
                    scope: label.scope,
                    affectedMessageCount: previewReclassificationCount
                )
            )
        case .deleteConfirmation:
            guard let label = selectedLabel else { return }
            confirmation = .delete(
                previewDeletion
                    ?? MailLabelDeletionPreview(
                        labelID: label.id,
                        scope: label.scope,
                        affectedMessageCount: 12,
                        affectedRuleCount: 2
                    )
            )
        case .progress:
            progress = MailLabelRunProgress(updated: 18, unchanged: 3, failed: 0)
        }
    }

    /// Keeps the selected label when it is still listed. Otherwise it selects the
    /// first label when `selectingFirst` is true (by default, only where
    /// `selectsFirstLabelOnLoad` is), and leaves nothing selected when it is false,
    /// as after a deletion.
    private func reload(selectingFirst: Bool? = nil) {
        let selectingFirst = selectingFirst ?? selectsFirstLabelOnLoad
        do {
            guard directSourceIsCurrent else {
                labels = []
                selectedLabelID = nil
                draft = nil
                confirmation = nil
                return
            }
            if let definitions {
                let loaded = try definitions.mailLabels(effectiveFor: selectedAccountID)
                labels = switch effectiveSelection {
                case .allAccounts:
                    loaded.filter { $0.scope == .allAccounts }
                case .account(let accountID):
                    loaded.filter { $0.scope.includes(accountID) }
                }
            } else {
                labels = previewLabels
                    .filter { label in
                        switch effectiveSelection {
                        case .allAccounts:
                            label.scope == .allAccounts
                        case .account(let accountID):
                            label.scope.includes(accountID)
                        }
                    }
                    .sorted { lhs, rhs in
                        let lhsRank = lhs.scope == .allAccounts ? 0 : 1
                        let rhsRank = rhs.scope == .allAccounts ? 0 : 1
                        if lhsRank != rhsRank { return lhsRank < rhsRank }
                        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                        return lhs.id < rhs.id
                    }
            }

            if let selectedDirectAccountID {
                labels.removeAll { $0.scope != .account(selectedDirectAccountID) }
            }

            if let selectedLabelID,
               let selected = labels.first(where: { $0.id == selectedLabelID }) {
                draft = Self.draft(for: selected)
            } else if selectingFirst, let first = labels.first {
                selectedLabelID = first.id
                draft = Self.draft(for: first)
            } else {
                selectedLabelID = nil
                draft = nil
            }
            validationMessage = nil
        } catch {
            validationMessage = "Labels could not be loaded."
        }
    }

    private func write(_ label: MailLabelDefinition) throws {
        if let definitions {
            try definitions.saveMailLabel(label)
        } else {
            previewLabels.removeAll { $0.id == label.id }
            previewLabels.append(label)
        }
    }

    private func persist(_ draft: MailLabelDraft) async {
        guard canMutate(draft.scope) else { return }
        do {
            let now = Date()
            let existing = draft.existingLabelID.flatMap { id in
                labels.first(where: { $0.id == id })
            }
            let label = try MailLabelDefinition.validated(
                id: draft.existingLabelID ?? "label_\(UUID().uuidString.lowercased())",
                title: draft.title,
                description: draft.description,
                isSmartInboxEnabled: draft.isSmartInboxEnabled,
                scope: draft.scope,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try write(label)
            selectedLabelID = label.id
            confirmation = nil
            progress = nil
            reload()
        } catch let error as MailLabelValidationError {
            validationMessage = message(for: error)
        } catch {
            validationMessage = "The label could not be saved."
        }
    }

    private var selectedAccountID: AccountID? {
        if let selectedDirectAccountID { return selectedDirectAccountID }
        if case .account(let id) = selection { return id }
        return nil
    }

    private var effectiveSelection: AccountManagementSelection {
        selectedDirectAccountID.map(AccountManagementSelection.account) ?? selection
    }

    private var directSourceIsCurrent: Bool {
        guard let selectedDirectAccountID else { return true }
        guard let store = definitions as? SQLiteMailStore,
              let directSourceGeneration,
              (try? store.requireDirectMailSource(accountID: selectedDirectAccountID)) != nil,
              let source = try? store.mailSource(accountID: selectedDirectAccountID) else { return false }
        return source.generation == directSourceGeneration
    }

    private func canMutate(_ scope: MailLabelScope) -> Bool {
        guard directSourceIsCurrent else { return false }
        return selectedDirectAccountID.map { scope == .account($0) } ?? true
    }

    private var selectedScope: MailLabelScope {
        switch effectiveSelection {
        case .allAccounts: .allAccounts
        case .account(let id): .account(id)
        }
    }

    private var selectedLabel: MailLabelDefinition? {
        guard let selectedLabelID else { return nil }
        return labels.first { $0.id == selectedLabelID }
    }

    private static func draft(for label: MailLabelDefinition) -> MailLabelDraft {
        MailLabelDraft(
            existingLabelID: label.id,
            title: label.title,
            description: label.description,
            isSmartInboxEnabled: label.isSmartInboxEnabled,
            scope: label.scope
        )
    }

    private func message(for error: MailLabelValidationError) -> String {
        switch error {
        case .missingTitle:
            "Enter a label title."
        case .titleTooLong:
            "Keep the title to 64 characters or fewer."
        case .descriptionTooLong:
            "Keep the description to 280 characters or fewer."
        case .smartInboxDescriptionRequired:
            "Add a description before using this label in Smart Inbox."
        case .duplicateEffectiveTitle:
            "A label with this title already exists in this scope."
        case .effectiveSmartInboxLimitExceeded(let scope):
            "\(scopeName(scope)) already has 24 labels enabled for Smart Inbox."
        case .immutableScope:
            "A label's scope cannot be changed after creation."
        case .unknownLabel:
            "This label no longer exists."
        case .outOfScopeLabel:
            "This label is not available in the selected account."
        }
    }

    private func scopeName(_ scope: MailLabelScope) -> String {
        switch scope {
        case .allAccounts:
            return "All Accounts"
        case .account(let id):
            guard let account = accounts.first(where: { $0.id == id }) else {
                return id.rawValue
            }
            return account.displayName.isEmpty ? account.email.rawValue : account.displayName
        }
    }
}
