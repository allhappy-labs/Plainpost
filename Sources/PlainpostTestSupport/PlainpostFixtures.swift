import PlainpostCore

public let plainpostTestSearchRebuildPayloadJSON = #"{"operation":"rebuildIndex","recordID":"","providerID":"deterministic","conversation":[],"smartInboxRunRequest":{"mode":"incremental","scope":{"allAccounts":{}}},"enqueueOnly":false}"#

public enum PlainpostFixtures {
    public static let codexActor = Actor(
        id: "codex",
        kind: .cli,
        displayName: "Codex CLI",
        permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
    )

    public static let guiUser = Actor(
        id: "local-user",
        kind: .user,
        displayName: "Local User",
        permissions: .guiUser
    )

    public static let personalAccount = Account(
        id: AccountID("acc_personal"),
        displayName: "Personal",
        email: EmailAddress("me@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )

    public static let inboxMailbox = Mailbox(
        id: MailboxID("mbx_inbox"),
        accountID: personalAccount.id,
        name: "INBOX",
        path: "INBOX",
        specialUse: "\\Inbox"
    )

    public static let aliceThread = MailThread(
        id: ThreadID("thr_alice_1"),
        accountID: personalAccount.id,
        subjectNormalized: "availability",
        participantEmails: [EmailAddress("alice@example.com"), personalAccount.email]
    )

    public static let aliceMessage = MessageSummary(
        id: MessageID("msg_alice_1"),
        threadID: aliceThread.id,
        from: EmailAddress("alice@example.com"),
        subject: "Availability",
        preview: "Can you meet next Tuesday?",
        smartCategory: .personal
    )

    public static let replyDraft = Draft(
        id: DraftID("drf_reply_1"),
        accountID: AccountID("acc_personal"),
        from: EmailAddress("me@example.com"),
        to: [EmailAddress("alice@example.com")],
        cc: [],
        bcc: [],
        subject: "Re: Availability",
        bodyPlain: "Tuesday works for me.",
        createdBy: "codex",
        aiGenerated: true,
        sourceThreadID: ThreadID("thr_alice_1")
    )
}
