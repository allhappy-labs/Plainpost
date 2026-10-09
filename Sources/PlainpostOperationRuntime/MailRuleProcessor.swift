import PlainpostCore
import PlainpostDB

public struct MailRuleProcessingResult: Equatable, Sendable {
    public let newMessageIDs: [MessageID]
    public let suppressedNotificationMessageIDs: Set<MessageID>

    public init(
        newMessageIDs: [MessageID],
        suppressedNotificationMessageIDs: Set<MessageID>
    ) {
        self.newMessageIDs = newMessageIDs
        self.suppressedNotificationMessageIDs = suppressedNotificationMessageIDs
    }
}

private struct MailRuleNotificationEvaluation {
    let message: MessageSummary
    let matchingRules: [MailRule]
    let actions: Set<MailRuleAction>
}

public enum MailRuleNotificationPolicy {
    public static func evaluate(
        messageIDs: [MessageID],
        accountID: AccountID,
        store: SQLiteMailStore
    ) throws -> Set<MessageID> {
        Set(try evaluations(
            messageIDs: messageIDs,
            accountID: accountID,
            store: store
        ).compactMap { evaluation in
            evaluation.actions.contains(.suppressNotification)
                ? evaluation.message.id
                : nil
        })
    }

    fileprivate static func evaluations(
        messageIDs: [MessageID],
        accountID: AccountID,
        store: SQLiteMailStore
    ) throws -> [MailRuleNotificationEvaluation] {
        let orderedIDs = Array(Set(messageIDs)).sorted { $0.rawValue < $1.rawValue }
        let rules = try store.mailRules(effectiveFor: accountID).filter(\.isEnabled)
        return try store.messageSummaries(ids: orderedIDs).map { message in
            let matchingRules = rules.filter {
                MailRuleEvaluator.matches(
                    message: message,
                    accountID: accountID,
                    rule: $0
                )
            }
            return MailRuleNotificationEvaluation(
                message: message,
                matchingRules: matchingRules,
                actions: MailRuleEvaluator.actions(
                    for: message,
                    accountID: accountID,
                    rules: matchingRules
                )
            )
        }
    }
}

public final class MailRuleProcessor: @unchecked Sendable {
    private let store: SQLiteMailStore
    private let workerSignal: any OperationWorkerSignaling
    private let expectedDirectSourceGeneration: Int64?
    private let requireDirectSourceGeneration: Bool
    /// The device-wide iOS runtime: each account's rule work is fenced on that account's own
    /// current Direct generation, and Sync Node accounts' mail is left alone.
    private let perAccountDirectSource: Bool
    private let actor = Actor(
        id: "mail-rule-engine",
        kind: .system,
        displayName: "Mail Rule Engine",
        permissions: .guiUser
    )

    public init(
        store: SQLiteMailStore,
        workerSignal: any OperationWorkerSignaling = NoopOperationWorkerSignal(),
        expectedDirectSourceGeneration: Int64? = nil,
        requireDirectSourceGeneration: Bool = false,
        perAccountDirectSource: Bool = false
    ) {
        self.perAccountDirectSource = perAccountDirectSource
        self.store = store
        self.workerSignal = workerSignal
        self.expectedDirectSourceGeneration = expectedDirectSourceGeneration
        self.requireDirectSourceGeneration = requireDirectSourceGeneration
    }

    public func processNewMessages(
        _ messageIDs: [MessageID],
        accountID: AccountID
    ) throws -> MailRuleProcessingResult {
        try requireSelectedDirectSourceGeneration()
        let orderedIDs = Array(Set(messageIDs)).sorted { $0.rawValue < $1.rawValue }
        // A fenced (device-wide) sync of a Sync Node account in fallback: its mail is the
        // Node's to apply rules to, as while the Node mirrors it.
        if expectedDirectSourceGeneration != nil || perAccountDirectSource,
           (try? store.explicitMailSource(accountID: accountID))?.kind == .nodeBacked {
            return MailRuleProcessingResult(newMessageIDs: orderedIDs, suppressedNotificationMessageIDs: [])
        }
        let generation = try generation(for: accountID)
        var suppressed = Set<MessageID>()
        var queuedDurableWork = false

        for evaluation in try MailRuleNotificationPolicy.evaluations(
            messageIDs: orderedIDs,
            accountID: accountID,
            store: store
        ) {
            let message = evaluation.message
            let matchingRules = evaluation.matchingRules
            guard !matchingRules.isEmpty else { continue }
            try requireUnchangedDirectSource(accountID: accountID, generation: generation)
            let actions = evaluation.actions
            do {
                let inserted = try store.enqueueMailRuleActions(
                    messageID: message.id,
                    accountID: accountID,
                    actions: actions,
                    sourceRuleIDs: matchingRules.map(\.id),
                    expectedDirectSourceGeneration: generation
                )
                queuedDurableWork = queuedDurableWork || inserted.contains {
                    !$0.durableJobIDs.isEmpty
                }
            } catch {
                try requireUnchangedDirectSource(accountID: accountID, generation: generation)
                try? store.recordMailRuleEvaluationFailure(messageID: message.id, error: error)
            }
            if actions.contains(.suppressNotification) {
                suppressed.insert(message.id)
            }
            for rule in matchingRules {
                do {
                    try requireUnchangedDirectSource(accountID: accountID, generation: generation)
                    try store.replaceRuleLabels(
                        ruleID: rule.id,
                        labelIDs: rule.labelIDs,
                        on: message.id,
                        actor: actor,
                        selectedDirectSource: generation.map {
                            (accountID, $0)
                        }
                    )
                } catch {
                    try requireUnchangedDirectSource(accountID: accountID, generation: generation)
                    try? store.recordMailRuleEvaluationFailure(messageID: message.id, error: error)
                }
            }
        }

        if queuedDurableWork {
            Task { try? await workerSignal.signalWork() }
        }
        return MailRuleProcessingResult(
            newMessageIDs: orderedIDs,
            suppressedNotificationMessageIDs: suppressed
        )
    }

    public func previewExisting(rule: MailRule) throws -> MailRuleExistingPreview {
        let accountID: AccountID?
        switch rule.scope {
        case .allAccounts:
            accountID = nil
        case .account(let scopedAccountID):
            accountID = scopedAccountID
        }
        var matches: [MailRuleExistingMatch] = []
        var countsByAccount: [AccountID: MailRuleActionCounts] = [:]
        for candidate in try store.mailRuleCandidateMessages(accountID: accountID) {
            if perAccountDirectSource,
               (try? store.requireDirectMailSource(accountID: candidate.accountID)) == nil { continue }
            guard MailRuleEvaluator.matches(
                message: candidate.message,
                accountID: candidate.accountID,
                rule: rule
            ) else {
                continue
            }
            var actions = MailRuleEvaluator.actions(
                for: candidate.message,
                accountID: candidate.accountID,
                rules: [rule]
            )
            actions.remove(.suppressNotification)
            if actions.contains(.skipInbox) {
                let alreadySkipped = try store.hasMailRuleAction(
                    .skipInbox,
                    messageID: candidate.message.id
                )
                if !storeHasEffectiveInboxMembership(candidate) || alreadySkipped {
                    actions.remove(.skipInbox)
                }
            }
            if candidate.message.isSeen {
                actions.remove(.markAsRead)
            }
            guard !actions.isEmpty || !rule.labelIDs.isEmpty else { continue }
            matches.append(MailRuleExistingMatch(
                messageID: candidate.message.id,
                accountID: candidate.accountID,
                subject: candidate.message.subject,
                sender: candidate.message.from,
                actions: actions,
                labelIDs: rule.labelIDs
            ))
            let current = countsByAccount[candidate.accountID] ?? .init()
            countsByAccount[candidate.accountID] = MailRuleActionCounts(
                archiveCount: current.archiveCount + (actions.contains(.skipInbox) ? 1 : 0),
                markReadCount: current.markReadCount + (actions.contains(.markAsRead) ? 1 : 0)
            )
        }
        return MailRuleExistingPreview(
            ruleID: rule.id,
            matches: matches,
            countsByAccount: countsByAccount
        )
    }

    public func applyExisting(
        rule: MailRule,
        preview: MailRuleExistingPreview
    ) throws -> MailRuleRun {
        try requireSelectedDirectSourceGeneration()
        guard preview.ruleID == rule.id else {
            throw PlainpostError.validationFailed("The mail rule preview is no longer valid.")
        }
        var generations: [AccountID: Int64?] = [:]
        for match in preview.matches where generations[match.accountID] == nil {
            generations[match.accountID] = try generation(for: match.accountID)
        }
        for match in preview.matches {
            try requireUnchangedDirectSource(accountID: match.accountID, generation: generations[match.accountID] ?? nil)
        }
        let runID = try store.createMailRuleRun(ruleID: rule.id, matches: preview.matches)
        var queuedWork = false
        for batchStart in stride(from: 0, to: preview.matches.count, by: 100) {
            let batchEnd = min(batchStart + 100, preview.matches.count)
            for match in preview.matches[batchStart..<batchEnd] {
                let generation = generations[match.accountID] ?? nil
                try requireUnchangedDirectSource(accountID: match.accountID, generation: generation)
                var jobIDs: [String] = []
                var itemError: Error?
                do {
                    let records = try store.enqueueMailRuleActions(
                        messageID: match.messageID,
                        accountID: match.accountID,
                        actions: match.actions,
                        sourceRuleIDs: [rule.id],
                        expectedDirectSourceGeneration: generation
                    )
                    jobIDs = records.flatMap(\.durableJobIDs)
                    queuedWork = queuedWork || !jobIDs.isEmpty
                } catch {
                    try requireUnchangedDirectSource(accountID: match.accountID, generation: generation)
                    itemError = error
                }
                do {
                    try store.replaceRuleLabels(
                        ruleID: rule.id,
                        labelIDs: match.labelIDs,
                        on: match.messageID,
                        actor: actor,
                        selectedDirectSource: generation.map {
                            (match.accountID, $0)
                        }
                    )
                } catch {
                    try requireUnchangedDirectSource(accountID: match.accountID, generation: generation)
                    itemError = itemError ?? error
                }
                try store.updateMailRuleRunItem(
                    runID: runID,
                    messageID: match.messageID,
                    jobIDs: jobIDs,
                    error: itemError
                )
            }
        }
        if queuedWork {
            Task { try? await workerSignal.signalWork() }
        }
        return try store.mailRuleRun(id: runID)
    }

    /// The generation `accountID`'s rule work is fenced on: the selected one, or (device-wide)
    /// the account's own current Direct generation.
    private func generation(for accountID: AccountID) throws -> Int64? {
        if let expectedDirectSourceGeneration { return expectedDirectSourceGeneration }
        guard perAccountDirectSource else { return nil }
        try store.requireDirectMailSource(accountID: accountID)
        return try store.mailSource(accountID: accountID).generation
    }

    private func requireSelectedDirectSourceGeneration() throws {
        if requireDirectSourceGeneration && expectedDirectSourceGeneration == nil && !perAccountDirectSource {
            throw PlainpostError.permissionDenied(
                "A selected Direct mail source is required for mail rule actions."
            )
        }
    }

    private func requireUnchangedDirectSource(accountID: AccountID, generation: Int64?) throws {
        guard let generation else { return }
        try store.requireDirectMailSource(accountID: accountID)
        guard try store.mailSource(accountID: accountID).generation
            == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
    }

    private func storeHasEffectiveInboxMembership(
        _ candidate: MailRuleCandidateMessage
    ) -> Bool {
        (try? store.hasInboxMembership(
            messageID: candidate.message.id,
            accountID: candidate.accountID
        )) == true
    }
}
