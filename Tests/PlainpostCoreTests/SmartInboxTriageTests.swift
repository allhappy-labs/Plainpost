import Testing
@testable import PlainpostCore

func mailboxFixture(
    id: String,
    fromDisplayName: String? = "Sender",
    subject: String = "Subject"
) -> MailboxListMessage {
    MailboxListMessage(
        id: MessageID(id),
        threadID: nil,
        from: EmailAddress("sender@example.com"),
        fromDisplayName: fromDisplayName,
        subject: subject,
        preview: "Preview",
        smartCategory: .unknown
    )
}

@Test func triageContractHasStableWireValues() {
    #expect(SmartCategory.invitation.rawValue == "invitation")
    #expect(SmartCategory.invitationResponse.rawValue == "invitation_response")
    #expect(SmartPriority.high.rawValue == "high")
    #expect(SmartPriority.normal.rawValue == "normal")
    #expect(SmartPriority.low.rawValue == "low")
    #expect(SmartInboxClassifierContract.schemaVersion == "smart-inbox-triage-labels-v2")
}

@Test func mailboxProjectionDefaultsToNeutralTriage() {
    let message = mailboxFixture(id: "m-1")
    #expect(message.smartPriority == .normal)
    #expect(message.smartRequiresAction == false)
    #expect(message.smartConfidence == nil)
}

@Test func classifierIdentityResolvesConfiguredNonDefaultOllamaModel() {
    let identity = SmartInboxClassifierIdentity.resolve(
        providerID: "ollama",
        modelID: nil,
        environment: ["PLAINPOST_OLLAMA_CHAT_MODEL": "gemma3:12b"]
    )

    #expect(identity.modelID == "gemma3:12b")
    #expect(identity.discriminator.contains("ollama:gemma3:12b:"))
}

@Test func foundationAndDeterministicClassifierIdentitiesRemainStable() {
    #expect(
        SmartInboxClassifierIdentity.resolve(
            providerID: "foundation",
            modelID: nil,
            environment: ["PLAINPOST_OLLAMA_CHAT_MODEL": "ignored"]
        ).modelID == "apple-foundation-system"
    )
    #expect(
        SmartInboxClassifierIdentity.resolve(
            providerID: "deterministic",
            modelID: nil,
            environment: ["PLAINPOST_OLLAMA_CHAT_MODEL": "ignored"]
        ).modelID == "deterministic-local"
    )
}
