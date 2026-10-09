import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime

public struct MailRuleDraft: Equatable, Sendable {
    public let existingRuleID: String?
    public var name: String
    public var isEnabled: Bool
    public let scope: MailRuleScope
    public var conditions: [MailRuleCondition]
    public var actions: Set<MailRuleAction>
    public var selectedLabelIDs: Set<String>

    public init(
        existingRuleID: String? = nil,
        name: String = "",
        isEnabled: Bool = true,
        scope: MailRuleScope,
        conditions: [MailRuleCondition] = [
            .init(field: .from, operator: .emailIs, value: ""),
        ],
        actions: Set<MailRuleAction> = [.skipInbox],
        selectedLabelIDs: Set<String> = []
    ) {
        self.existingRuleID = existingRuleID
        self.name = name
        self.isEnabled = isEnabled
        self.scope = scope
        self.conditions = conditions
        self.actions = actions
        self.selectedLabelIDs = selectedLabelIDs
    }
}

@MainActor
public final class MailRulesViewModel: ObservableObject {
    @Published public private(set) var selection: MailRuleAccountSelection = .allAccounts
    @Published public private(set) var visibleRules: [MailRule] = []
    @Published public private(set) var visibleLabels: [MailLabelDefinition] = []
    @Published public var selectedRuleID: String?
    @Published public var draft: MailRuleDraft?
    @Published public private(set) var validationMessage: String?
    @Published public private(set) var existingPreview: MailRuleExistingPreview?
    @Published public private(set) var activeRun: MailRuleRun?
    @Published public private(set) var isWorking = false

    public let accounts: [Account]
    private let selectedDirectAccountID: AccountID?
    private let directSourceGeneration: Int64?
    private let store: SQLiteMailStore?
    private let processor: MailRuleProcessor?
    private var previewRules: [MailRule]
    private var previewLabels: [MailLabelDefinition]

    public init(
        store: SQLiteMailStore, processor: MailRuleProcessor, accounts: [Account],
        selectedDirectAccountID: AccountID? = nil
    ) {
        self.store = store
        self.processor = processor
        self.selectedDirectAccountID = selectedDirectAccountID
        self.directSourceGeneration = selectedDirectAccountID.flatMap {
            try? store.mailSource(accountID: $0).generation
        }
        self.accounts = selectedDirectAccountID.map { id in accounts.filter { $0.id == id } } ?? accounts
        self.previewRules = []
        self.previewLabels = []
        if let selectedDirectAccountID { selection = .account(selectedDirectAccountID) }
        reload()
    }

    private init(
        accounts: [Account],
        rules: [MailRule],
        labels: [MailLabelDefinition] = []
    ) {
        self.store = nil
        self.processor = nil
        self.selectedDirectAccountID = nil
        self.directSourceGeneration = nil
        self.accounts = accounts
        self.previewRules = rules
        self.previewLabels = labels
        reload()
    }

    public func reload() {
        do {
            guard directSourceIsCurrent else {
                visibleRules = []
                visibleLabels = []
                selectedRuleID = nil
                draft = nil
                existingPreview = nil
                activeRun = nil
                return
            }
            if let store {
                visibleRules = try store.mailRules(effectiveFor: selectedAccountID)
                visibleLabels = try store.mailLabels(effectiveFor: selectedAccountID)
                if let selectedDirectAccountID {
                    visibleRules.removeAll { $0.scope != .account(selectedDirectAccountID) }
                    visibleLabels.removeAll { $0.scope != .account(selectedDirectAccountID) }
                }
            } else {
                visibleRules = previewRules.filter { rule in
                    selectedAccountID.map(rule.scope.includes) ?? true
                }
                visibleLabels = previewLabels.filter { label in
                    selectedAccountID.map(label.scope.includes) ?? true
                }
            }
            if let selectedRuleID,
               let selectedRule = visibleRules.first(where: { $0.id == selectedRuleID }) {
                draft = Self.draft(for: selectedRule)
                validationMessage = Self.repairMessage(for: selectedRule)
            } else {
                if selectedRuleID != nil {
                    self.selectedRuleID = nil
                    draft = nil
                }
                validationMessage = nil
            }
        } catch {
            validationMessage = "Mail rules could not be loaded."
        }
    }

    public func selectAccount(_ selection: MailRuleAccountSelection) {
        self.selection = selectedDirectAccountID.map(MailRuleAccountSelection.account) ?? selection
        existingPreview = nil
        reload()
    }

    public func selectRule(id: String) {
        guard let rule = visibleRules.first(where: { $0.id == id }) else { return }
        selectedRuleID = id
        draft = Self.draft(for: rule)
        existingPreview = nil
        validationMessage = Self.repairMessage(for: rule)
    }

    public func beginAddingRule() {
        guard directSourceIsCurrent else { return }
        selectedRuleID = nil
        let scope: MailRuleScope = switch selection {
        case .allAccounts: .allAccounts
        case .account(let accountID): .account(accountID)
        }
        draft = MailRuleDraft(scope: scope)
        existingPreview = nil
        validationMessage = nil
    }

    public func saveDraft() {
        guard let draft, canMutate(draft.scope) else { return }
        do {
            let now = Date()
            let old = draft.existingRuleID.flatMap { id in visibleRules.first { $0.id == id } }
            let rule = try MailRule.validated(
                id: draft.existingRuleID ?? "rule_\(UUID().uuidString.lowercased())",
                name: draft.name,
                isEnabled: draft.isEnabled,
                scope: draft.scope,
                conditions: draft.conditions,
                actions: draft.actions,
                labelIDs: draft.selectedLabelIDs.sorted(),
                createdAt: old?.createdAt ?? now,
                updatedAt: now
            )
            if let store { try store.saveMailRule(rule) } else {
                previewRules.removeAll { $0.id == rule.id }
                previewRules.append(rule)
            }
            reload()
            selectRule(id: rule.id)
        } catch let error as MailRuleValidationError {
            validationMessage = Self.message(for: error)
        } catch {
            validationMessage = "The rule could not be saved."
        }
    }

    public func setEnabled(id: String, isEnabled: Bool) {
        guard let rule = visibleRules.first(where: { $0.id == id }),
              canMutate(rule.scope) else { return }
        if isEnabled,
           rule.actions.isEmpty,
           rule.labelIDs.isEmpty {
            selectRule(id: id)
            validationMessage = Self.message(for: .missingActions)
            return
        }
        do {
            if let store { try store.setMailRuleEnabled(id: id, isEnabled: isEnabled) }
            else if let index = previewRules.firstIndex(where: { $0.id == id }) {
                previewRules[index].isEnabled = isEnabled
            }
            reload()
        } catch { validationMessage = "The rule could not be updated." }
    }

    public func deleteSelectedRule() {
        guard let selectedRuleID,
              let rule = visibleRules.first(where: { $0.id == selectedRuleID }),
              canMutate(rule.scope) else { return }
        do {
            if let store { try store.deleteMailRule(id: selectedRuleID) }
            else { previewRules.removeAll { $0.id == selectedRuleID } }
            self.selectedRuleID = nil
            draft = nil
            reload()
        } catch { validationMessage = "The rule could not be deleted." }
    }

    public func previewExisting() async {
        guard let processor, let selectedRuleID,
              let rule = visibleRules.first(where: { $0.id == selectedRuleID }),
              canMutate(rule.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do { existingPreview = try processor.previewExisting(rule: rule) }
        catch { validationMessage = "Existing messages could not be previewed." }
    }

    public func confirmApplyExisting() async {
        guard let processor, let existingPreview,
              let rule = visibleRules.first(where: { $0.id == existingPreview.ruleID }),
              canMutate(rule.scope) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            activeRun = try processor.applyExisting(rule: rule, preview: existingPreview)
            self.existingPreview = nil
        } catch { validationMessage = "The existing-message run could not be started." }
    }

    public func refreshActiveRun() {
        guard let store, let id = activeRun?.id, directSourceIsCurrent else { return }
        activeRun = try? store.mailRuleRun(id: id)
    }

    public func dismissExistingPreview() { existingPreview = nil }

    private var selectedAccountID: AccountID? {
        if let selectedDirectAccountID { return selectedDirectAccountID }
        if case .account(let id) = selection { return id }
        return nil
    }

    private var directSourceIsCurrent: Bool {
        guard let selectedDirectAccountID else { return true }
        guard let store, let directSourceGeneration,
              (try? store.requireDirectMailSource(accountID: selectedDirectAccountID)) != nil,
              let source = try? store.mailSource(accountID: selectedDirectAccountID) else { return false }
        return source.generation == directSourceGeneration
    }

    private func canMutate(_ scope: MailRuleScope) -> Bool {
        guard directSourceIsCurrent else { return false }
        return selectedDirectAccountID.map { scope == .account($0) } ?? true
    }

    public var availableLabelActions: [MailLabelDefinition] {
        guard let scope = draft?.scope else { return [] }
        return visibleLabels.filter { label in
            switch scope {
            case .allAccounts:
                label.scope == .allAccounts
            case .account(let accountID):
                label.scope.includes(accountID)
            }
        }
    }

    private static func draft(for rule: MailRule) -> MailRuleDraft {
        MailRuleDraft(
            existingRuleID: rule.id,
            name: rule.name,
            isEnabled: rule.isEnabled,
            scope: rule.scope,
            conditions: rule.conditions,
            actions: rule.actions,
            selectedLabelIDs: Set(rule.labelIDs)
        )
    }

    private static func repairMessage(for rule: MailRule) -> String? {
        guard !rule.isEnabled, rule.actions.isEmpty, rule.labelIDs.isEmpty else { return nil }
        return message(for: .missingActions)
    }

    private static func message(for error: MailRuleValidationError) -> String {
        switch error {
        case .missingName: "Enter a rule name."
        case .missingConditions: "Add at least one condition."
        case .emptyConditionValue: "Complete every condition value."
        case .invalidConditionOperator: "Choose a valid condition."
        case .missingActions: "Choose at least one action before enabling this rule."
        }
    }

    public static func preview() -> MailRulesViewModel {
        let work = Account(
            id: AccountID("acc-preview-work"), displayName: "Work",
            email: EmailAddress("me@work.example"), imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let rules = [
            try! MailRule.validated(
                id: "preview-global", name: "Newsletters", scope: .allAccounts,
                conditions: [.init(field: .from, operator: .domainIs, value: "news.example")],
                actions: [.skipInbox, .markAsRead]
            ),
            try! MailRule.validated(
                id: "preview-work", name: "Build notifications", scope: .account(work.id),
                conditions: [.init(field: .subject, operator: .contains, value: "Build")],
                actions: [.suppressNotification]
            ),
        ]
        return MailRulesViewModel(accounts: [work], rules: rules)
    }
}
