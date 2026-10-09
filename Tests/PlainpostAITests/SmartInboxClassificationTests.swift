import Foundation
import Testing
@testable import PlainpostAI
@testable import PlainpostCore

private func mailboxFixture(id: String, subject: String = "Subject") -> MailboxListMessage {
    MailboxListMessage(
        id: MessageID(id),
        threadID: nil,
        from: EmailAddress("sender@example.com"),
        fromDisplayName: "Sender",
        subject: subject,
        preview: "Preview",
        smartCategory: .unknown
    )
}

private func classificationInput(
    id: String,
    accountID: String,
    recipients: [String] = ["me@example.com"],
    body: String = "Plain text body"
) -> SmartInboxClassificationInput {
    SmartInboxClassificationInput(
        message: mailboxFixture(id: id),
        accountID: AccountID(accountID),
        recipients: recipients.map { EmailAddress($0) },
        bodyExcerpt: body
    )
}

private func labelDefinition(
    id: String,
    title: String,
    description: String,
    scope: MailLabelScope,
    enabled: Bool = true
) -> MailLabelDefinition {
    try! MailLabelDefinition.validated(
        id: id,
        title: title,
        description: description,
        isSmartInboxEnabled: enabled,
        scope: scope,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}

private func catalog(_ labels: [MailLabelDefinition], fingerprint: String = "catalog-v1") -> MailLabelCatalogSnapshot {
    MailLabelCatalogSnapshot(
        labels: labels,
        fingerprint: fingerprint,
        createdAt: Date(timeIntervalSince1970: 1)
    )
}

private func requestMessage(id: String, eligibleLabelIDs: [String]) -> AIClassificationMessage {
    AIClassificationMessage(
        id: MessageID(id),
        accountID: AccountID("a"),
        senderAddress: "sender@example.com",
        senderDisplayName: "Sender",
        recipients: ["me@example.com"],
        subject: "Subject",
        preview: "Preview",
        bodyExcerpt: "Plain text body",
        eligibleLabelIDs: eligibleLabelIDs
    )
}

private func request(
    messages: [AIClassificationMessage],
    labels: [AIClassificationLabelDefinition] = [],
    fingerprint: String = "catalog-v1"
) -> AIClassificationBatchRequest {
    AIClassificationBatchRequest(
        messages: messages,
        labels: labels,
        catalogFingerprint: fingerprint
    )
}

@Test func promptContainsOnlyEligibleLabelsAndBoundedPlainText() throws {
    let snapshot = catalog([
        labelDefinition(
            id: "global-travel",
            title: "Travel",
            description: "Flights and hotel confirmations.",
            scope: .allAccounts
        ),
        labelDefinition(
            id: "account-a-vip",
            title: "VIP",
            description: "Important contacts for account A.",
            scope: .account(AccountID("a"))
        ),
        labelDefinition(
            id: "account-b-private",
            title: "Private",
            description: "Only for account B.",
            scope: .account(AccountID("b"))
        ),
        labelDefinition(
            id: "disabled-label",
            title: "Disabled",
            description: "Not sent to the classifier.",
            scope: .allAccounts,
            enabled: false
        ),
    ])

    let request = try #require(SmartInboxBatchBuilder.makeRequests(
        inputs: [
            classificationInput(
                id: "m1",
                accountID: "a",
                body: String(repeating: "x", count: 4_000)
            ),
        ],
        catalog: snapshot,
        limits: .init(maxMessages: 10, maxPromptCharacters: 12_000)
    ).first)
    let prompt = SmartInboxClassificationPrompt.render(request)

    #expect(request.messages[0].recipients == ["me@example.com"])
    #expect(request.messages[0].bodyExcerpt.count == 3_000)
    #expect(request.messages[0].eligibleLabelIDs == ["account-a-vip", "global-travel"])
    #expect(prompt.contains("global-travel"))
    #expect(prompt.contains("account-a-vip"))
    #expect(!prompt.contains("account-b-private"))
    #expect(!prompt.contains("disabled-label"))
    #expect(!prompt.contains("<html"))
}

@Test func builderCreatesAccountHomogeneousBatchesWithScopedCatalogs() throws {
    let snapshot = catalog([
        labelDefinition(
            id: "global",
            title: "Global",
            description: "Available everywhere.",
            scope: .allAccounts
        ),
        labelDefinition(
            id: "account-a",
            title: "Account A",
            description: "Available only for account A.",
            scope: .account(AccountID("a"))
        ),
        labelDefinition(
            id: "account-b",
            title: "Account B",
            description: "Available only for account B.",
            scope: .account(AccountID("b"))
        ),
    ])

    let requests = try SmartInboxBatchBuilder.makeRequests(
        inputs: [
            classificationInput(id: "a1", accountID: "a"),
            classificationInput(id: "b1", accountID: "b"),
            classificationInput(id: "a2", accountID: "a"),
        ],
        catalog: snapshot,
        limits: .init(maxMessages: 10, maxPromptCharacters: 12_000)
    )

    #expect(requests.map { Set($0.messages.map(\.accountID)) } == [
        Set([AccountID("a")]),
        Set([AccountID("b")]),
    ])
    #expect(requests[0].messages.map(\.id) == [MessageID("a1"), MessageID("a2")])
    #expect(requests[0].labels.map(\.id) == ["account-a", "global"])
    #expect(requests[1].messages.map(\.id) == [MessageID("b1")])
    #expect(requests[1].labels.map(\.id) == ["account-b", "global"])
    #expect(requests.allSatisfy { $0.catalogFingerprint == "catalog-v1" })
}

@Test func catalogOverheadCanPreventEvenAnEmptyMessageFromFitting() {
    let snapshot = catalog([
        labelDefinition(
            id: String(repeating: "i", count: 300),
            title: String(repeating: "t", count: 64),
            description: String(repeating: "d", count: 280),
            scope: .allAccounts
        ),
    ])
    let input = classificationInput(id: "too-small", accountID: "a", recipients: [], body: "")

    #expect(throws: SmartInboxBatchBuilderError.messageCannotFit(id: MessageID("too-small"))) {
        try SmartInboxBatchBuilder.makeRequests(
            inputs: [input],
            catalog: snapshot,
            limits: .init(maxMessages: 1, maxPromptCharacters: 400)
        )
    }
}

@Test func builderRemovesEmptyRecipientStructureWhenAddressFieldsAreEmpty() throws {
    let message = MailboxListMessage(
        id: MessageID("empty-recipient-structure"),
        threadID: nil,
        from: EmailAddress(""),
        fromDisplayName: nil,
        subject: "",
        preview: "",
        smartCategory: .unknown
    )
    let emptyInput = SmartInboxClassificationInput(
        message: message,
        accountID: AccountID("a"),
        recipients: [],
        bodyExcerpt: ""
    )
    let snapshot = catalog([])
    let baseline = try #require(SmartInboxBatchBuilder.makeRequests(
        inputs: [emptyInput],
        catalog: snapshot,
        limits: .init(maxMessages: 1, maxPromptCharacters: 12_000)
    ).first)
    let exactEmptyBudget = SmartInboxClassificationPrompt.render(baseline).count
    let structurallyNonemptyInput = SmartInboxClassificationInput(
        message: message,
        accountID: AccountID("a"),
        recipients: Array(repeating: EmailAddress(""), count: 128),
        bodyExcerpt: ""
    )

    let request = try #require(SmartInboxBatchBuilder.makeRequests(
        inputs: [structurallyNonemptyInput],
        catalog: snapshot,
        limits: .init(maxMessages: 1, maxPromptCharacters: exactEmptyBudget)
    ).first)

    #expect(request.messages[0].recipients == [])
    #expect(SmartInboxClassificationPrompt.render(request).count <= exactEmptyBudget)
}

@Test func builderDropsUnboundedRecipientListAsOneField() throws {
    let message = MailboxListMessage(
        id: MessageID("unbounded-recipients"),
        threadID: nil,
        from: EmailAddress(""),
        fromDisplayName: nil,
        subject: "",
        preview: "",
        smartCategory: .unknown
    )
    let snapshot = catalog([])
    let emptyInput = SmartInboxClassificationInput(
        message: message,
        accountID: AccountID("a"),
        recipients: [],
        bodyExcerpt: ""
    )
    let baseline = try #require(SmartInboxBatchBuilder.makeRequests(
        inputs: [emptyInput],
        catalog: snapshot,
        limits: .init(maxMessages: 1, maxPromptCharacters: 12_000)
    ).first)
    let exactEmptyBudget = SmartInboxClassificationPrompt.render(baseline).count
    let input = SmartInboxClassificationInput(
        message: message,
        accountID: AccountID("a"),
        recipients: Array(repeating: EmailAddress("x"), count: 512),
        bodyExcerpt: ""
    )

    let request = try #require(SmartInboxBatchBuilder.makeRequests(
        inputs: [input],
        catalog: snapshot,
        limits: .init(maxMessages: 1, maxPromptCharacters: exactEmptyBudget)
    ).first)

    #expect(request.messages[0].recipients == [])
    #expect(SmartInboxClassificationPrompt.render(request).count <= exactEmptyBudget)
}

@Test func legacyBatchRequestDecodesWithV2Defaults() throws {
    let data = try #require(
        """
        {
          "messages": [{
            "id": "legacy",
            "senderAddress": "sender@example.com",
            "senderDisplayName": "Sender",
            "subject": "Subject",
            "preview": "Preview"
          }]
        }
        """.data(using: .utf8)
    )

    let decoded = try JSONDecoder().decode(AIClassificationBatchRequest.self, from: data)

    #expect(decoded.labels == [])
    #expect(decoded.catalogFingerprint == "")
    #expect(decoded.messages[0].accountID == AccountID(""))
    #expect(decoded.messages[0].recipients == [])
    #expect(decoded.messages[0].bodyExcerpt == "")
    #expect(decoded.messages[0].eligibleLabelIDs == [])
}

@Test func promptOmitsInternalAccountAndCatalogIdentifiers() {
    let batch = request(
        messages: [
            AIClassificationMessage(
                id: MessageID("m1"),
                accountID: AccountID("internal-account-marker"),
                senderAddress: "sender@example.com",
                senderDisplayName: "Sender",
                recipients: ["me@example.com"],
                subject: "Subject",
                preview: "Preview",
                bodyExcerpt: "Plain text body",
                eligibleLabelIDs: ["travel"]
            ),
        ],
        labels: [
            .init(id: "travel", title: "Travel", description: "Travel messages."),
        ],
        fingerprint: "internal-fingerprint-marker"
    )

    let prompt = SmartInboxClassificationPrompt.render(batch)

    #expect(!prompt.contains("internal-account-marker"))
    #expect(!prompt.contains("internal-fingerprint-marker"))
    #expect(prompt.contains("\"eligible_label_ids\":[\"travel\"]"))
    #expect(prompt.contains("\"label_definitions\""))
}

@Test func builderRespectsCountAndPromptBounds() throws {
    let inputs = (0..<9).map {
        mailboxFixture(id: "m-\($0)", subject: String(repeating: "x", count: 80))
    }
    let requests = try SmartInboxBatchBuilder.makeRequests(
        messages: inputs,
        limits: .init(maxMessages: 4, maxPromptCharacters: 1_200)
    )

    #expect(requests.flatMap(\.messages).map(\.id) == inputs.map(\.id))
    #expect(requests.allSatisfy { $0.messages.count <= 4 })
    #expect(requests.allSatisfy { SmartInboxClassificationPrompt.render($0).count <= 1_200 })
}

@Test func builderTruncatesOneOversizedMessageDeterministically() throws {
    let message = MailboxListMessage(
        id: MessageID("m-oversized"),
        threadID: nil,
        from: EmailAddress(String(repeating: "a", count: 500) + "@example.com"),
        fromDisplayName: String(repeating: "n", count: 500),
        subject: String(repeating: "s", count: 2_000),
        preview: String(repeating: "p", count: 4_000),
        smartCategory: .unknown
    )
    let limits = SmartInboxBatchLimits(maxMessages: 1, maxPromptCharacters: 1_800)

    let first = try #require(SmartInboxBatchBuilder.makeRequests(messages: [message], limits: limits).first)
    let second = try #require(SmartInboxBatchBuilder.makeRequests(messages: [message], limits: limits).first)

    #expect(first == second)
    #expect(first.messages.map(\.id) == [message.id])
    #expect(first.messages[0].preview.count < message.preview.count)
    #expect(SmartInboxClassificationPrompt.render(first).count <= limits.maxPromptCharacters)
}

@Test func validatorSalvagesValidSiblingsAndUsesLowConfidenceCategory() {
    let request = AIClassificationBatchRequest(messages: ["a", "b", "c"].map {
        AIClassificationMessage(mailboxFixture(id: $0))
    })
    let response = AIClassificationBatchResponse(results: [
        .init(id: "a", category: "personal", priority: "high", requiresAction: true, confidence: 0.91),
        .init(id: "b", category: "newsletter", priority: "normal", requiresAction: false, confidence: 0.18),
        .init(id: "c", category: "invented", priority: "normal", requiresAction: false, confidence: 0.80),
    ])

    let validated = SmartInboxBatchValidator.validate(request: request, response: response)
    #expect(validated.valid.map(\.messageID.rawValue) == ["a", "b"])
    #expect(validated.valid[1].category == .newsletter)
    #expect(validated.unresolved == [MessageID(rawValue: "c")])
}

@Test func validatorDropsWeakLabelsAndDeduplicatesStrongestConfidence() {
    let batch = request(messages: [requestMessage(id: "m1", eligibleLabelIDs: ["travel", "weak"])])
    let response = AIClassificationBatchResponse(results: [
        .init(
            id: "m1",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: [
                .init(id: "travel", confidence: 0.81),
                .init(id: "travel", confidence: 0.93),
                .init(id: "weak", confidence: 0.79),
            ]
        ),
    ])

    let validation = SmartInboxBatchValidator.validate(request: batch, response: response)

    #expect(validation.valid[0].labelMatches == [
        .init(labelID: "travel", confidence: 0.93),
    ])
    #expect(validation.unresolved.isEmpty)
    #expect(validation.diagnostics.isEmpty)
}

@Test func validatorAcceptsExactLabelThresholdAndPreservesConfidence() {
    let batch = request(messages: [
        requestMessage(id: "m1", eligibleLabelIDs: ["threshold"]),
    ])
    let response = AIClassificationBatchResponse(results: [
        .init(
            id: "m1",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.87,
            labels: [
                .init(id: "threshold", confidence: 0.80),
            ]
        ),
    ])

    let validation = SmartInboxBatchValidator.validate(request: batch, response: response)

    #expect(validation.valid[0].confidence == 0.87)
    #expect(validation.valid[0].labelMatches == [
        .init(labelID: "threshold", confidence: 0.80),
    ])
    #expect(validation.unresolved.isEmpty)
    #expect(validation.diagnostics.isEmpty)
}

@Test func validatorIgnoresProviderLabelsWhenMessageHasNoEligibleLabels() {
    let batch = request(messages: [
        requestMessage(id: "invented", eligibleLabelIDs: []),
        requestMessage(id: "missing", eligibleLabelIDs: []),
    ])
    let response = AIClassificationBatchResponse(results: [
        .init(
            id: "invented",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: [.init(id: "not-configured", confidence: 0.95)]
        ),
        .init(
            id: "missing",
            category: "personal",
            priority: "high",
            requiresAction: true,
            confidence: 0.88,
            labels: nil
        ),
    ])

    let validation = SmartInboxBatchValidator.validate(request: batch, response: response)

    #expect(validation.valid.map(\.messageID.rawValue) == ["invented", "missing"])
    #expect(validation.valid.allSatisfy { $0.labelMatches.isEmpty })
    #expect(validation.unresolved.isEmpty)
    #expect(validation.diagnostics.isEmpty)
}

@Test func unknownOrOutOfScopeLabelInvalidatesOnlyThatMessage() {
    let batch = request(messages: [
        requestMessage(id: "m1", eligibleLabelIDs: ["travel"]),
        requestMessage(id: "m2", eligibleLabelIDs: ["vip"]),
    ])
    let response = AIClassificationBatchResponse(results: [
        .init(
            id: "m1",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: [.init(id: "unknown", confidence: 0.95)]
        ),
        .init(
            id: "m2",
            category: "personal",
            priority: "high",
            requiresAction: true,
            confidence: 0.88,
            labels: [.init(id: "vip", confidence: 0.91)]
        ),
    ])

    let validation = SmartInboxBatchValidator.validate(request: batch, response: response)

    #expect(validation.valid.map(\.messageID) == [MessageID("m2")])
    #expect(validation.unresolved == [MessageID("m1")])
    #expect(validation.diagnostics == [.init(code: .invalidLabelID, count: 1)])
}

@Test func malformedLabelsInvalidateOnlyTheirMessages() {
    let batch = request(messages: [
        requestMessage(id: "missing-list", eligibleLabelIDs: ["travel"]),
        requestMessage(id: "missing-id", eligibleLabelIDs: ["travel"]),
        requestMessage(id: "bad-confidence", eligibleLabelIDs: ["travel"]),
        requestMessage(id: "valid-empty", eligibleLabelIDs: ["travel"]),
    ])
    let response = AIClassificationBatchResponse(results: [
        .init(
            id: "missing-list",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: nil
        ),
        .init(
            id: "missing-id",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: [.init(id: nil, confidence: 0.9)]
        ),
        .init(
            id: "bad-confidence",
            category: "travel",
            priority: "normal",
            requiresAction: false,
            confidence: 0.9,
            labels: [.init(id: "travel", confidence: 1.1)]
        ),
        .init(
            id: "valid-empty",
            category: "personal",
            priority: "low",
            requiresAction: false,
            confidence: 0.8,
            labels: []
        ),
    ])

    let validation = SmartInboxBatchValidator.validate(request: batch, response: response)

    #expect(validation.valid.map(\.messageID) == [MessageID("valid-empty")])
    #expect(validation.unresolved == [
        MessageID("missing-list"),
        MessageID("missing-id"),
        MessageID("bad-confidence"),
    ])
    #expect(validation.diagnostics == [
        .init(code: .missingLabels, count: 1),
        .init(code: .invalidLabelID, count: 1),
        .init(code: .invalidLabelConfidence, count: 1),
    ])
}

@Test func validatorMarksDuplicateUnknownAndMissingIDsUnresolved() {
    let request = AIClassificationBatchRequest(messages: ["a", "b", "c"].map {
        AIClassificationMessage(mailboxFixture(id: $0))
    })
    let response = AIClassificationBatchResponse(results: [
        .init(id: "a", category: "personal", priority: "high", requiresAction: true, confidence: 0.91),
        .init(id: "a", category: "personal", priority: "high", requiresAction: true, confidence: 0.91),
        .init(id: "outside", category: "personal", priority: "high", requiresAction: true, confidence: 0.91),
    ])

    let validated = SmartInboxBatchValidator.validate(request: request, response: response)
    #expect(validated.valid.isEmpty)
    #expect(validated.unresolved == [MessageID("a"), MessageID("b"), MessageID("c")])
    #expect(validated.diagnostics == [
        .init(code: .unknownResult, count: 1),
        .init(code: .duplicateResult, count: 1),
        .init(code: .missingResult, count: 2),
    ])
}

@Test func validatorRejectsInvalidConfidenceAndPriorityWithoutDiscardingValidItems() {
    let request = AIClassificationBatchRequest(messages: ["finite", "nan", "outside", "priority"].map {
        AIClassificationMessage(mailboxFixture(id: $0))
    })
    let response = AIClassificationBatchResponse(results: [
        .init(id: "finite", category: "finance", priority: "low", requiresAction: false, confidence: 0),
        .init(id: "nan", category: "finance", priority: "low", requiresAction: false, confidence: .nan),
        .init(id: "outside", category: "finance", priority: "low", requiresAction: false, confidence: 1.01),
        .init(id: "priority", category: "finance", priority: "urgent", requiresAction: false, confidence: 0.5),
    ])

    let validated = SmartInboxBatchValidator.validate(request: request, response: response)
    #expect(validated.valid.map(\.messageID.rawValue) == ["finite"])
    #expect(validated.unresolved == [MessageID("nan"), MessageID("outside"), MessageID("priority")])
}

@Test func validatorIsolatesNilIDCandidateAndKeepsRequestedMessageUnresolved() {
    let request = AIClassificationBatchRequest(messages: [
        AIClassificationMessage(mailboxFixture(id: "requested")),
    ])
    let response = AIClassificationBatchResponse(results: [
        .init(id: nil, category: "personal", priority: "normal", requiresAction: false, confidence: 0.8),
    ])

    let validated = SmartInboxBatchValidator.validate(request: request, response: response)
    #expect(validated.valid.isEmpty)
    #expect(validated.unresolved == [MessageID("requested")])
    #expect(validated.diagnostics == [
        .init(code: .missingID, count: 1),
        .init(code: .missingResult, count: 1),
    ])
}

@Test func validatorRejectsMissingRequiredBooleanWithoutDiscardingValidSibling() {
    let request = AIClassificationBatchRequest(messages: ["valid", "missing-bool"].map {
        AIClassificationMessage(mailboxFixture(id: $0))
    })
    let response = AIClassificationBatchResponse(results: [
        .init(id: "valid", category: "personal", priority: "high", requiresAction: true, confidence: 0.9),
        .init(id: "missing-bool", category: "notification", priority: "normal", requiresAction: nil, confidence: 0.8),
    ])

    let validated = SmartInboxBatchValidator.validate(request: request, response: response)
    #expect(validated.valid.map(\.messageID.rawValue) == ["valid"])
    #expect(validated.unresolved == [MessageID("missing-bool")])
    #expect(validated.diagnostics == [.init(code: .missingRequiresAction, count: 1)])
}

@Test func promptBudgetUsesConservativeCharacterCeiling() {
    #expect(SmartInboxPromptBudget.characters(maxContextTokens: 1_000) == 4_000)
    #expect(SmartInboxPromptBudget.characters(maxContextTokens: 7_000) == 12_000)
    #expect(SmartInboxPromptBudget.characters(maxContextTokens: 5_000, requestedCeiling: 6_000) == 6_000)
}

@Test func classificationResponseUsesSnakeCaseResponseWireKey() throws {
    let data = try #require(
        """
        {"results":[{"id":"m-1","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[]}]}
        """.data(using: .utf8)
    )

    let response = try JSONDecoder().decode(AIClassificationBatchResponse.self, from: data)
    let candidate = try #require(response.results.first)
    #expect(candidate.requiresAction == true)

    let encoded = try JSONEncoder().encode(response)
    let responseObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let results = try #require(responseObject["results"] as? [[String: Any]])
    let object = try #require(results.first)
    #expect(object["requires_action"] as? Bool == true)
    #expect(object["requiresAction"] == nil)
    #expect(Set(object.keys) == ["id", "category", "priority", "requires_action", "confidence", "labels"])
}

@Test func ollamaClassificationSchemaIsClosedAndConstrainsEveryRequiredField() throws {
    let schema = SmartInboxClassificationPrompt.jsonSchema
    #expect(schema["type"] as? String == "object")
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(schema["required"] as? [String] == ["results"])

    let properties = try #require(schema["properties"] as? [String: Any])
    let results = try #require(properties["results"] as? [String: Any])
    #expect(results["type"] as? String == "array")
    let item = try #require(results["items"] as? [String: Any])
    #expect(item["type"] as? String == "object")
    #expect(item["additionalProperties"] as? Bool == false)
    #expect(item["required"] as? [String] == [
        "id", "category", "priority", "requires_action", "confidence", "labels",
    ])

    let fields = try #require(item["properties"] as? [String: Any])
    #expect(Set(fields.keys) == ["id", "category", "priority", "requires_action", "confidence", "labels"])
    #expect((fields["id"] as? [String: Any])?["type"] as? String == "string")
    #expect((fields["category"] as? [String: Any])?["enum"] as? [String] == SmartCategory.allCases.map(\.rawValue))
    #expect((fields["priority"] as? [String: Any])?["enum"] as? [String] == SmartPriority.allCases.map(\.rawValue))
    #expect((fields["requires_action"] as? [String: Any])?["type"] as? String == "boolean")
    #expect((fields["confidence"] as? [String: Any])?["minimum"] as? Int == 0)
    #expect((fields["confidence"] as? [String: Any])?["maximum"] as? Int == 1)
    let labels = try #require(fields["labels"] as? [String: Any])
    #expect(labels["type"] as? String == "array")
    let labelItem = try #require(labels["items"] as? [String: Any])
    #expect(labelItem["type"] as? String == "object")
    #expect(labelItem["additionalProperties"] as? Bool == false)
    #expect(labelItem["required"] as? [String] == ["id", "confidence"])
    let labelFields = try #require(labelItem["properties"] as? [String: Any])
    #expect(Set(labelFields.keys) == ["id", "confidence"])
    #expect((labelFields["id"] as? [String: Any])?["type"] as? String == "string")
    #expect((labelFields["confidence"] as? [String: Any])?["minimum"] as? Int == 0)
    #expect((labelFields["confidence"] as? [String: Any])?["maximum"] as? Int == 1)
    #expect(fields["reason"] == nil)
}

@Test func classifierContractUsesLabelSchemaAndPromptVersions() {
    #expect(SmartInboxClassifierContract.schemaVersion == "smart-inbox-triage-labels-v2")
    #expect(SmartInboxClassifierContract.promptVersion == "2026-09-09")
}
