import XCTest
import GRDB
import SQLite3
import Darwin
import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport
import PlainpostAccountDeletionTestSupport

final class SQLiteMailStoreTests: XCTestCase {
    func testNotificationIdentityBatchesPreserveOwnershipAndSkipDeletedMessages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-identities-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.databasePool.write { database in
            try database.execute(sql: """
                INSERT INTO threads(id, account_id, subject_normalized, participant_emails) VALUES ('thread-a', 'a', '', '[]');
                INSERT INTO messages(id, account_id, thread_id, from_email, subject, preview, body_text, smart_category, is_deleted) VALUES
                  ('explicit-a', 'a', NULL, 'x@example.test', '', '', 'body', 'personal', 0),
                  ('explicit-b', 'b', 'thread-a', 'x@example.test', '', '', 'body', 'personal', 0),
                  ('member-a', NULL, NULL, 'x@example.test', '', '', 'body', 'personal', 0),
                  ('ambiguous', NULL, 'thread-a', 'x@example.test', '', '', 'body', 'personal', 0),
                  ('thread-only', NULL, 'thread-a', 'x@example.test', '', '', 'body', 'personal', 0),
                  ('orphan', NULL, NULL, 'x@example.test', '', '', 'body', 'personal', 0),
                  ('deleted', 'a', NULL, 'x@example.test', '', '', 'body', 'personal', 1);
                INSERT INTO mailbox_messages(account_id, mailbox_path, uid_validity, uid, message_id) VALUES
                  ('a', 'INBOX', 1, 1, 'member-a'), ('a', 'INBOX', 1, 2, 'ambiguous'),
                  ('b', 'INBOX', 1, 1, 'ambiguous'), ('b', 'INBOX', 1, 2, 'explicit-a');
                """)
        }
        XCTAssertEqual(try store.notificationMessageIDs(accountID: AccountID("a"), after: nil).map(\.rawValue),
                       ["explicit-a", "member-a", "thread-only"])
        XCTAssertEqual(try store.notificationMessageIDs(accountID: AccountID("b"), after: nil).map(\.rawValue), ["explicit-b"])
        XCTAssertEqual(try store.notificationMessageIDs(accountID: nil, after: nil).map(\.rawValue),
                       ["ambiguous", "explicit-a", "explicit-b", "member-a", "orphan", "thread-only"])
        XCTAssertEqual(try store.notificationMessageAccountID(MessageID("member-a")), AccountID("a"))
        XCTAssertEqual(try store.notificationMessageAccountID(MessageID("thread-only")), AccountID("a"))
        XCTAssertNil(try store.notificationMessageAccountID(MessageID("orphan")))
    }

    func testNotificationIdentityKeysetClampsLargeLimitsAndPropagatesReadFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-batches-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.databasePool.write { database in
            try database.execute(sql: """
                WITH RECURSIVE fixture(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM fixture WHERE n < 600)
                INSERT INTO messages(id, from_email, subject, preview, smart_category)
                SELECT printf('m%03d', n), 'x@example.test', '', '', 'personal' FROM fixture
                """)
        }
        let first = try store.notificationMessageIDs(accountID: nil, after: nil, limit: Int.max)
        let second = try store.notificationMessageIDs(accountID: nil, after: first.last, limit: Int.max)
        let last = try store.notificationMessageIDs(accountID: nil, after: second.last, limit: Int.max)
        XCTAssertEqual(first.count, 256)
        XCTAssertEqual(first.first?.rawValue, "m001")
        XCTAssertEqual(first.last?.rawValue, "m256")
        XCTAssertEqual(second.first?.rawValue, "m257")
        XCTAssertEqual(second.last?.rawValue, "m512")
        XCTAssertEqual(last.count, 88)
        XCTAssertEqual(last.last?.rawValue, "m600")
        XCTAssertTrue(try store.notificationMessageIDs(accountID: nil, after: last.last).isEmpty)
        XCTAssertTrue(try store.notificationMessageIDs(accountID: nil, after: nil, limit: 0).isEmpty)
        try store.databasePool.write { try $0.execute(sql: "DROP TABLE messages") }
        XCTAssertThrowsError(try store.notificationMessageIDs(accountID: nil, after: nil))
    }

    func testAIConversationReferenceUsesOnlyPersistedExactConversationIdentity() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-reference-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("acc-ai-reference"),
            displayName: "AI Reference",
            email: EmailAddress("owner@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let realThread = MailThread(
            id: ThreadID("thr-real"),
            accountID: account.id,
            subjectNormalized: "real",
            participantEmails: [account.email]
        )
        try store.cacheAccounts([account])
        try store.cacheThreads([realThread])

        let messages = [
            MessageSummary(
                id: MessageID("msg-real"), threadID: realThread.id,
                from: EmailAddress("sender@example.com"), subject: "Real", preview: "Real",
                smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX",
                isDeleted: false, body: "Real"
            ),
            MessageSummary(
                id: MessageID("msg-legacy"), threadID: ThreadID("thr_uid_INBOX_1_42"),
                from: EmailAddress("sender@example.com"), subject: "Legacy", preview: "Legacy",
                smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX",
                isDeleted: false, body: "Legacy"
            ),
            MessageSummary(
                id: MessageID("msg-unthreaded"), threadID: nil,
                from: EmailAddress("sender@example.com"), subject: "Loose", preview: "Loose",
                smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX",
                isDeleted: false, body: "Loose"
            ),
        ]
        for (index, message) in messages.enumerated() {
            try store.cacheMessageReliably(message)
            try store.recordCachedUID(
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: index + 1,
                messageID: message.id
            )
        }

        XCTAssertEqual(
            try store.aiConversationReference(
                messageID: MessageID("msg-real"), threadID: realThread.id, accountID: account.id
            ),
            PlainpostAIConversationReference(recordID: realThread.id.rawValue, kind: .thread)
        )
        XCTAssertEqual(
            try store.aiConversationReference(
                messageID: MessageID("msg-legacy"),
                threadID: ThreadID("thr_uid_INBOX_1_42"),
                accountID: account.id
            ),
            PlainpostAIConversationReference(recordID: "msg-legacy", kind: .message)
        )
        XCTAssertEqual(
            try store.aiConversationReference(
                messageID: MessageID("msg-unthreaded"), threadID: nil, accountID: account.id
            ),
            PlainpostAIConversationReference(recordID: "msg-unthreaded", kind: .message)
        )
        XCTAssertEqual(
            try store.aiConversationReference(
                messageID: MessageID("msg-unthreaded"),
                threadID: ThreadID(MailSearchStableIdentity.message(
                    accountID: account.id,
                    messageID: MessageID("msg-unthreaded")
                )),
                accountID: account.id
            ),
            PlainpostAIConversationReference(recordID: "msg-unthreaded", kind: .message)
        )
        XCTAssertThrowsError(
            try store.aiConversationReference(
                messageID: MessageID("msg-real"),
                threadID: ThreadID("thr-wrong"),
                accountID: account.id
            )
        )
    }

    func testInMemoryCompareAndSaveRejectsLateSourceWithoutOverwritingCurrentTranslation() throws {
        let sourceA = translationMessage(body: "Source A")
        let sourceB = translationMessage(body: "Source B")
        let translationA = cachedTranslation(for: sourceA, translatedBody: "Translated A")
        let translationB = cachedTranslation(for: sourceB, translatedBody: "Translated B")
        let store = InMemoryMailStore(messages: [sourceA])
        store.cacheMessage(sourceB)

        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translationB,
                expectedSourceFingerprint: translationB.sourceFingerprint
            ),
            .saved
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translationA,
                expectedSourceFingerprint: translationA.sourceFingerprint
            ),
            .sourceChanged
        )
        XCTAssertEqual(
            try store.cachedTranslation(
                messageID: sourceA.id,
                targetLanguageID: "en"
            ),
            translationB
        )
    }

    func testSQLiteCompareAndSaveRejectsLateSourceWithoutOverwritingCurrentTranslation() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let sourceA = translationMessage(body: "Source A")
        let sourceB = translationMessage(body: "Source B")
        let translationA = cachedTranslation(for: sourceA, translatedBody: "Translated A")
        let translationB = cachedTranslation(for: sourceB, translatedBody: "Translated B")
        try store.cacheMessage(sourceA)
        try store.cacheMessage(sourceB)

        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translationB,
                expectedSourceFingerprint: translationB.sourceFingerprint
            ),
            .saved
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translationA,
                expectedSourceFingerprint: translationA.sourceFingerprint
            ),
            .sourceChanged
        )
        XCTAssertEqual(
            try store.cachedTranslation(
                messageID: sourceA.id,
                targetLanguageID: "en"
            ),
            translationB
        )
    }

    func testMessageTranslationCachePersistsValidationIdentityAndIgnoresLateSaveAfterDelete() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try cacheOwnedMessage(PlainpostFixtures.aliceMessage, store: store, uid: 8_001)
        let cached = CachedMessageTranslation(
            messageID: PlainpostFixtures.aliceMessage.id,
            targetLanguageID: "en",
            sourceFingerprint: MailTranslationFingerprint.message(PlainpostFixtures.aliceMessage),
            providerID: "foundation",
            modelID: "apple-foundation-system",
            contractVersion: "message-translation-v1",
            bodyKind: .html,
            translatedBody: "<p>Hello</p>",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                cached,
                expectedSourceFingerprint: cached.sourceFingerprint
            ),
            .saved
        )

        let reopened = try SQLiteMailStore(path: url.path)
        XCTAssertEqual(
            try reopened.cachedTranslation(
                messageID: cached.messageID,
                targetLanguageID: cached.targetLanguageID
            ),
            cached
        )
        _ = try reopened.markDeleted(
            cached.messageID,
            deleted: true,
            actor: Actor(
                id: "local-user",
                kind: .user,
                displayName: "Local User",
                permissions: .guiUser
            )
        )
        XCTAssertNil(try reopened.cachedTranslation(
            messageID: cached.messageID,
            targetLanguageID: cached.targetLanguageID
        ))
        XCTAssertEqual(
            try reopened.compareAndSaveCachedTranslation(
                cached,
                expectedSourceFingerprint: cached.sourceFingerprint
            ),
            .sourceChanged
        )
        XCTAssertNil(try reopened.cachedTranslation(
            messageID: cached.messageID,
            targetLanguageID: cached.targetLanguageID
        ))
    }

    func testInMemoryMessageTranslationCachePreservesOriginalCreationWhenReplacingEntry() throws {
        let source = translationMessage(body: "Source")
        let sourceFingerprint = MailTranslationFingerprint.message(source)
        let store = InMemoryMailStore(messages: [source])
        let original = CachedMessageTranslation(
            messageID: source.id,
            targetLanguageID: "en",
            sourceFingerprint: sourceFingerprint,
            providerID: "foundation",
            modelID: "apple-foundation-system",
            contractVersion: "message-translation-v1",
            bodyKind: .plainText,
            translatedBody: "Hello",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let replacement = CachedMessageTranslation(
            messageID: original.messageID,
            targetLanguageID: original.targetLanguageID,
            sourceFingerprint: sourceFingerprint,
            providerID: "other-provider",
            modelID: "other-model",
            contractVersion: "message-translation-v2",
            bodyKind: .html,
            translatedBody: "<p>Hello again</p>",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                original,
                expectedSourceFingerprint: sourceFingerprint
            ),
            .saved
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                replacement,
                expectedSourceFingerprint: sourceFingerprint
            ),
            .saved
        )

        XCTAssertEqual(
            try store.cachedTranslation(
                messageID: original.messageID,
                targetLanguageID: original.targetLanguageID
            ),
            CachedMessageTranslation(
                messageID: replacement.messageID,
                targetLanguageID: replacement.targetLanguageID,
                sourceFingerprint: sourceFingerprint,
                providerID: "other-provider",
                modelID: "other-model",
                contractVersion: "message-translation-v2",
                bodyKind: .html,
                translatedBody: "<p>Hello again</p>",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        )
    }

    func testInMemoryMessageTranslationCacheClearsAndIgnoresLateSaveAfterSoftDelete() throws {
        let message = PlainpostFixtures.aliceMessage
        let store = InMemoryMailStore(messages: [message])
        let translation = CachedMessageTranslation(
            messageID: message.id,
            targetLanguageID: "en",
            sourceFingerprint: MailTranslationFingerprint.message(message),
            providerID: "foundation",
            modelID: "apple-foundation-system",
            contractVersion: "message-translation-v1",
            bodyKind: .plainText,
            translatedBody: "Hello",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: translation.sourceFingerprint
            ),
            .saved
        )

        _ = try store.markDeleted(message.id, deleted: true, actor: PlainpostFixtures.guiUser)

        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: translation.sourceFingerprint
            ),
            .sourceChanged
        )
        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testInMemoryTranslationSaveSerializesWithSoftDelete() throws {
        let message = PlainpostFixtures.aliceMessage
        let gate = TranslationCacheRaceGate()
        let store = InMemoryMailStore(
            messages: [message],
            onTranslationSaveAfterActiveCheck: {
                gate.saveObservedActive.signal()
                _ = gate.resumeSave.wait(timeout: .now() + 2)
            },
            onMessageDeleteBeforeTranslationCacheMutation: {
                gate.deleteReady.signal()
                _ = gate.continueDelete.wait(timeout: .now() + 2)
            }
        )
        let translation = CachedMessageTranslation(
            messageID: message.id,
            targetLanguageID: "en",
            sourceFingerprint: MailTranslationFingerprint.message(message),
            providerID: "foundation",
            modelID: "apple-foundation-system",
            contractVersion: "message-translation-v1",
            bodyKind: .plainText,
            translatedBody: "Hello",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let saveWorker = TranslationCacheRaceWorker {
            _ = try? store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: translation.sourceFingerprint
            )
            gate.saveCompleted.signal()
        }
        saveWorker.start()
        XCTAssertEqual(gate.saveObservedActive.wait(timeout: .now() + 2), .success)

        let deleteWorker = TranslationCacheRaceWorker {
            _ = try? store.markDeleted(message.id, deleted: true, actor: PlainpostFixtures.guiUser)
            gate.deleteCompleted.signal()
        }
        deleteWorker.start()
        XCTAssertEqual(gate.deleteReady.wait(timeout: .now() + 2), .success)
        gate.continueDelete.signal()
        XCTAssertEqual(gate.deleteCompleted.wait(timeout: .now() + 0.1), .timedOut)

        gate.resumeSave.signal()
        XCTAssertEqual(gate.saveCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(gate.deleteCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testMessageTranslationFingerprintChangesForBodyAndHTMLButIsStableForIdenticalContent() {
        let original = MessageSummary(
            id: MessageID("msg-translation-fingerprint"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translation",
            preview: "Original body",
            body: "Original body",
            bodyHTML: "<p>Original body</p>",
            smartCategory: .personal
        )
        let changedBody = MessageSummary(
            id: original.id,
            threadID: original.threadID,
            from: original.from,
            subject: original.subject,
            preview: original.preview,
            body: "Changed body",
            bodyHTML: original.bodyHTML,
            smartCategory: original.smartCategory
        )
        let changedHTML = MessageSummary(
            id: original.id,
            threadID: original.threadID,
            from: original.from,
            subject: original.subject,
            preview: original.preview,
            body: original.body,
            bodyHTML: "<p>Changed body</p>",
            smartCategory: original.smartCategory
        )
        let identical = MessageSummary(
            id: original.id,
            threadID: original.threadID,
            from: original.from,
            subject: original.subject,
            preview: original.preview,
            body: original.body,
            bodyHTML: original.bodyHTML,
            smartCategory: original.smartCategory
        )

        XCTAssertNotEqual(
            MailTranslationFingerprint.message(original),
            MailTranslationFingerprint.message(changedBody)
        )
        XCTAssertNotEqual(
            MailTranslationFingerprint.message(original),
            MailTranslationFingerprint.message(changedHTML)
        )
        XCTAssertEqual(
            MailTranslationFingerprint.message(original),
            MailTranslationFingerprint.message(identical)
        )
    }

    func testMessageTranslationFingerprintSeparatesBodyKindHTMLPresenceAndFieldBoundaries() {
        func message(body: String, html: String?) -> MessageSummary {
            MessageSummary(
                id: MessageID("msg-translation-fingerprint-encoding"),
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                subject: "Translation",
                preview: body,
                body: body,
                bodyHTML: html,
                smartCategory: .personal
            )
        }

        let absentHTML = message(body: "", html: nil)
        let presentEmptyHTML = message(body: "", html: "")
        let delimiterInBody = message(
            body: "left\u{1f}right",
            html: "tail"
        )
        let delimiterInHTML = message(
            body: "left",
            html: "right\u{1f}tail"
        )

        XCTAssertNotEqual(
            MailTranslationFingerprint.source(
                messageID: absentHTML.id,
                body: .plainText("")
            ),
            MailTranslationFingerprint.source(
                messageID: presentEmptyHTML.id,
                body: .html("")
            )
        )
        XCTAssertNotEqual(
            MailTranslationFingerprint.message(delimiterInBody),
            MailTranslationFingerprint.message(delimiterInHTML)
        )
        let htmlSource = EmailBodyInput.html("<p>Body</p>")
        XCTAssertEqual(
            MailTranslationFingerprint.source(
                messageID: absentHTML.id,
                body: htmlSource
            ),
            MailTranslationFingerprint.source(
                messageID: absentHTML.id,
                renderedBody: EmailBodyRenderer.render(htmlSource)
            )
        )
    }

    private func translationMessage(body: String) -> MessageSummary {
        MessageSummary(
            id: MessageID("msg-translation-atomic-save"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translation",
            preview: body,
            body: body,
            smartCategory: .personal
        )
    }

    private func cachedTranslation(
        for message: MessageSummary,
        translatedBody: String
    ) -> CachedMessageTranslation {
        CachedMessageTranslation(
            messageID: message.id,
            targetLanguageID: "en",
            sourceFingerprint: MailTranslationFingerprint.message(message),
            providerID: "foundation",
            modelID: "apple-foundation-system",
            contractVersion: "message-translation-v1",
            bodyKind: .plainText,
            translatedBody: translatedBody,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func testSmartInboxActivitySelectsIncrementalQueuedRunningAndPausingJobsByStateRank() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_100_000)
        let queued = try enqueueActivityJob(store: store, suffix: "queued", mode: .incremental)
        let running = try enqueueActivityJob(store: store, suffix: "running", mode: .incremental)
        try updateActivityJob(
            id: queued.id,
            state: .queued,
            updatedAt: now.addingTimeInterval(20),
            at: url
        )
        try updateActivityJob(
            id: running.id,
            state: .running,
            pauseRequested: true,
            updatedAt: now,
            at: url
        )

        let selected = try XCTUnwrap(store.smartInboxActivityJob(now: now.addingTimeInterval(30)))

        XCTAssertEqual(selected.id, running.id)
        XCTAssertEqual(selected.state, .running)
        XCTAssertTrue(selected.pauseRequested)
    }

    func testSmartInboxActivityKeepsManualPauseVisibleAndPrefersItOverQueuedWork() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_100_100)
        let paused = try enqueueActivityJob(store: store, suffix: "paused", mode: .incremental)
        let queued = try enqueueActivityJob(store: store, suffix: "queued-after-pause", mode: .incremental)
        try updateActivityJob(
            id: paused.id,
            state: .paused,
            pauseReason: "user-requested",
            updatedAt: now,
            at: url
        )
        try updateActivityJob(
            id: queued.id,
            state: .queued,
            updatedAt: now.addingTimeInterval(10),
            at: url
        )

        XCTAssertEqual(
            try store.smartInboxActivityJob(now: now.addingTimeInterval(20))?.id,
            paused.id
        )
    }

    func testSmartInboxActivityShowsRecentFailureButActiveWorkReplacesIt() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_100_200)
        let failed = try enqueueActivityJob(store: store, suffix: "recent-failure", mode: .rerunAll)
        try updateActivityJob(
            id: failed.id,
            state: .failed,
            errorMessage: "raw provider response",
            updatedAt: now.addingTimeInterval(-3_600),
            at: url
        )

        XCTAssertEqual(try store.smartInboxActivityJob(now: now)?.id, failed.id)

        let active = try enqueueActivityJob(store: store, suffix: "new-active", mode: .incremental)
        try updateActivityJob(
            id: active.id,
            state: .queued,
            updatedAt: now.addingTimeInterval(1),
            at: url
        )
        XCTAssertEqual(try store.smartInboxActivityJob(now: now.addingTimeInterval(2))?.id, active.id)
    }

    func testSmartInboxActivityHidesOldFailureCompletionAndCancellation() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_100_300)
        for (suffix, state, age) in [
            ("old-failure", PlainpostOperationState.failed, 3_601.0),
            ("completed", .completed, 1.0),
            ("cancelled", .cancelled, 1.0),
        ] {
            let job = try enqueueActivityJob(store: store, suffix: suffix, mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: state,
                updatedAt: now.addingTimeInterval(-age),
                at: url
            )
        }

        XCTAssertNil(try store.smartInboxActivityJob(now: now))
    }

    func testSelectedDirectSmartInboxActivityAndActionsStayWithinAccountAndGeneration() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("smart-inbox-other-account"), displayName: "Other",
            email: EmailAddress("other@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try store.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }
        func enqueue(_ accountID: AccountID, mode: PlainpostSmartInboxRunMode) throws -> PlainpostDurableJob {
            let input = PlainpostAIOperationInput(
                operation: .recategorizeInbox, recordID: "",
                accountID: accountID, expectedDirectSourceGeneration: 1,
                providerID: "deterministic",
                smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                    mode: mode, scope: .account(accountID), requestedLabelID: nil
                ), smartInboxRequestID: UUID().uuidString
            )
            return try store.enqueueJob(.init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: UUID().uuidString
            ))
        }
        let foreign = try enqueue(first.id, mode: .rerunAll)
        let selected = try enqueue(second.id, mode: .incremental)

        XCTAssertEqual(
            try store.smartInboxActivityJob(accountID: second.id, sourceGeneration: 1)?.id,
            selected.id
        )
        XCTAssertNil(try store.activeSmartInboxRerunJob(accountID: second.id, sourceGeneration: 1))
        XCTAssertThrowsError(try store.requestJobPause(
            id: foreign.id, accountID: second.id, sourceGeneration: 1
        ))
        XCTAssertEqual(try store.job(id: foreign.id).state, .queued)
        try store.requestJobPause(id: selected.id, accountID: second.id, sourceGeneration: 1)
        XCTAssertEqual(try store.job(id: selected.id).state, .paused)
        XCTAssertThrowsError(try store.resumeUserPausedJob(
            id: selected.id, accountID: first.id, sourceGeneration: 1, now: Date()
        ))
        XCTAssertEqual(try store.job(id: selected.id).state, .paused)

        try forceNodeSourceForStaleJobFixture(
            accountID: second.id, generation: 2, providerIdentity: second.email.rawValue, at: url
        )
        XCTAssertThrowsError(try store.smartInboxActivityJob(
            accountID: second.id, sourceGeneration: 1
        ))
        XCTAssertThrowsError(try store.resumeUserPausedJob(
            id: selected.id, accountID: second.id, sourceGeneration: 1, now: Date()
        ))
        XCTAssertEqual(try store.job(id: selected.id).state, .paused)
    }

    func testSelectedDirectSmartInboxHidesPersistedJobMissingGeneration() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox, recordID: "",
            accountID: account.id, expectedDirectSourceGeneration: 1,
            providerID: "deterministic",
            smartInboxRunRequest: .init(
                mode: .rerunAll, scope: .account(account.id), requestedLabelID: nil
            )
        )
        let job = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: UUID().uuidString
        ))
        try executeSQL(
            "UPDATE durable_jobs SET payload_json = json_remove(payload_json, '$.expectedDirectSourceGeneration') WHERE id = '\(job.id)';",
            at: url
        )

        XCTAssertNil(try store.smartInboxActivityJob(accountID: account.id, sourceGeneration: 1))
        XCTAssertNil(try store.activeSmartInboxRerunJob(accountID: account.id, sourceGeneration: 1))
        XCTAssertThrowsError(try store.requestJobPause(
            id: job.id, accountID: account.id, sourceGeneration: 1
        ))
    }

    func testSelectedDirectClaimLeavesForeignPriorityAndExpiredLeaseUntouched() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let selected = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("foreign-node-claim"), displayName: "Node",
            email: EmailAddress("node@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([selected, foreign])
        _ = try store.replaceMailSource(AccountMailSource(
            accountID: selected.id, kind: .direct, mode: nil,
            nodeID: nil, logicalMailboxID: nil,
            providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        let selectedGeneration = try store.mailSource(accountID: selected.id).generation
        let start = Date()
        func enqueue(_ account: AccountID, _ priority: Int) throws -> PlainpostDurableJob {
            let input = PlainpostInboxSyncInput(
                accountID: account, trigger: .manual,
                expectedDirectSourceGeneration: account == selected.id
                    ? selectedGeneration : nil
            )
            return try store.enqueueJob(.init(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                priority: priority, idempotencyKey: UUID().uuidString
            ))
        }
        let foreignExpired = try enqueue(foreign.id, 30)
        let leasedForeign = try XCTUnwrap(store.claimNextJob(
            now: start.addingTimeInterval(1), leaseDuration: 10,
            allowedKinds: [.inboxSync]
        ))
        XCTAssertEqual(leasedForeign.id, foreignExpired.id)
        let foreignQueued = try enqueue(foreign.id, 20)
        let foreignCancelled = try enqueue(foreign.id, 19)
        let foreignPaused = try enqueue(foreign.id, 18)
        try executeSQL("""
            UPDATE durable_jobs SET state = 'running', cancellation_requested = 1,
                lease_token = 'foreign-cancel-lease', lease_expires_at = 1
            WHERE id = '\(foreignCancelled.id)';
            UPDATE durable_jobs SET state = 'running', pause_requested = 1,
                lease_token = 'foreign-pause-lease', lease_expires_at = 1
            WHERE id = '\(foreignPaused.id)';
            """, at: url)
        let selectedQueued = try enqueue(selected.id, 10)
        let now = start.addingTimeInterval(20)
        let claimed = try XCTUnwrap(store.claimNextJob(
            now: now, allowedKinds: [.inboxSync],
            selectedDirectAccountID: selected.id,
            expectedDirectSourceGeneration: selectedGeneration
        ))
        XCTAssertEqual(claimed.id, selectedQueued.id)
        XCTAssertEqual(try store.job(id: foreignExpired.id).state, .running)
        XCTAssertEqual(try store.job(id: foreignExpired.id).leaseToken, leasedForeign.leaseToken)
        XCTAssertEqual(try store.job(id: foreignQueued.id).state, .queued)
        XCTAssertEqual(try store.job(id: foreignCancelled.id).state, .running)
        XCTAssertEqual(try store.job(id: foreignCancelled.id).leaseToken, "foreign-cancel-lease")
        XCTAssertEqual(try store.job(id: foreignPaused.id).state, .running)
        XCTAssertEqual(try store.job(id: foreignPaused.id).leaseToken, "foreign-pause-lease")

        try forceNodeSourceForStaleJobFixture(
            accountID: selected.id, generation: 2, providerIdentity: selected.email.rawValue, at: url
        )
        XCTAssertThrowsError(try store.claimNextJob(
            now: now.addingTimeInterval(1), allowedKinds: [.inboxSync],
            selectedDirectAccountID: selected.id,
            expectedDirectSourceGeneration: selectedGeneration
        ))
        XCTAssertEqual(try store.job(id: foreignExpired.id).state, .running)
        XCTAssertEqual(try store.job(id: selectedQueued.id).state, .running)
    }

    /// The every-Direct-account claim takes a job only at its own account's current Direct
    /// generation: one account's source switch strands only that account's jobs.
    func testEveryDirectAccountClaimSkipsJobsWhoseAccountChangedSource() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let first = PlainpostFixtures.personalAccount
        let second = Account(id: AccountID("claim-second"), displayName: "Second",
                             email: EmailAddress("second@example.com"),
                             imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try store.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try store.replaceMailSource(AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0)
        }
        func enqueueSync(_ account: Account, generation: Int64?) throws -> PlainpostDurableJob {
            let input = PlainpostInboxSyncInput(
                accountID: account.id, trigger: .manual, expectedDirectSourceGeneration: generation
            )
            return try store.enqueueJob(.init(
                kind: .inboxSync, payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: UUID().uuidString
            ))
        }
        let firstGeneration = try store.mailSource(accountID: first.id).generation
        let secondGeneration = try store.mailSource(accountID: second.id).generation
        let firstJob = try enqueueSync(first, generation: firstGeneration)
        let secondJob = try enqueueSync(second, generation: secondGeneration)
        let unversioned = try enqueueSync(first, generation: nil)
        try forceNodeSourceForStaleJobFixture(
            accountID: second.id, generation: secondGeneration + 1,
            providerIdentity: second.email.rawValue, at: url
        )

        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync], everyDirectAccount: true))
        XCTAssertEqual(claimed.id, firstJob.id)
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.inboxSync], everyDirectAccount: true))
        XCTAssertEqual(try store.job(id: secondJob.id).state, .queued)
        XCTAssertEqual(try store.job(id: unversioned.id).state, .queued)
    }

    func testSelectedDirectClaimSkipsUnversionedAndABAMailboxJobs() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil,
            nodeID: nil, logicalMailboxID: nil,
            providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        let message = PlainpostFixtures.aliceMessage
        try cacheOwnedMessage(message, store: store, uid: 6_101)

        func enqueue<T: Encodable>(_ kind: PlainpostOperationKind, _ input: T) throws -> PlainpostDurableJob {
            let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
            return try store.enqueueJob(.init(
                kind: kind, payloadJSON: payload, idempotencyKey: UUID().uuidString
            ))
        }
        let oldFlag = try enqueue(.mailboxFlag, PlainpostMailboxFlagInput(
            messageID: message.id, accountID: account.id, mailboxPath: "INBOX",
            uidValidity: 1, uid: 6_101, desiredSeen: true,
            expectedDirectSourceGeneration: 1
        ))
        let unversionedArchive = try enqueue(.mailboxArchive, PlainpostMailboxArchiveInput(
            messageID: message.id, accountID: account.id, sourceMailboxPath: "INBOX",
            destinationMailboxPath: "Archive", uidValidity: 1, uid: 6_101
        ))
        let oldSync = try enqueue(.inboxSync, PlainpostInboxSyncInput(
            accountID: account.id, trigger: .manual,
            expectedDirectSourceGeneration: 1
        ))
        let leasedFlag = try XCTUnwrap(store.claimNextJob(
            allowedKinds: [.mailboxFlag], selectedDirectAccountID: account.id,
            expectedDirectSourceGeneration: 1
        ))
        XCTAssertEqual(leasedFlag.id, oldFlag.id)
        try forceNodeSourceForStaleJobFixture(
            accountID: account.id, generation: 2, providerIdentity: account.email.rawValue, at: url
        )
        try forceDirectSourceForStaleJobFixture(accountID: account.id, generation: 3, at: url)
        XCTAssertNil(try store.claimNextJob(
            allowedKinds: [.mailboxFlag, .mailboxArchive, .inboxSync],
            selectedDirectAccountID: account.id, expectedDirectSourceGeneration: 3
        ))
        XCTAssertThrowsError(try store.completeJob(
            id: oldFlag.id, leaseToken: try XCTUnwrap(leasedFlag.leaseToken),
            resultArtifactID: nil
        ))
        XCTAssertEqual(try store.job(id: oldFlag.id).state, .running)
        XCTAssertEqual(try store.job(id: unversionedArchive.id).state, .queued)
        XCTAssertEqual(try store.job(id: oldSync.id).state, .queued)
    }

    func testDirectSmartInboxRejectsMissingAndStaleGenerationAtEnqueueAndClaim() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        func input(_ generation: Int64?, requestID: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox, recordID: "",
                accountID: account.id, expectedDirectSourceGeneration: generation,
                providerID: "deterministic",
                smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                    mode: .rerunAll, scope: .account(account.id), requestedLabelID: nil
                ), smartInboxRequestID: requestID
            )
        }
        XCTAssertThrowsError(try store.enqueueSmartInboxJob(input: input(nil, requestID: "missing")))
        XCTAssertThrowsError(try store.enqueueSmartInboxJob(input: input(0, requestID: "stale")))
        guard case .job(let queued) = try store.enqueueSmartInboxJob(input: input(1, requestID: "current")) else {
            return XCTFail("Expected a durable Direct Smart Inbox job.")
        }
        XCTAssertEqual(
            try JSONDecoder().decode(PlainpostAIOperationInput.self, from: Data(queued.payloadJSON.utf8))
                .expectedDirectSourceGeneration, 1
        )
        try forceNodeSourceForStaleJobFixture(
            accountID: account.id, generation: 2, providerIdentity: account.email.rawValue, at: url
        )
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation]))
        XCTAssertEqual(try store.job(id: queued.id).state, .queued)
    }

    func testDirectSmartInboxRejectsCheckpointAfterSourceTransition() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox, recordID: "", accountID: account.id,
            expectedDirectSourceGeneration: 1, providerID: "deterministic",
            smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                mode: .rerunAll, scope: .account(account.id), requestedLabelID: nil
            ), smartInboxRequestID: "checkpoint-transition"
        )
        guard case .job = try store.enqueueSmartInboxJob(input: input) else {
            return XCTFail("Expected a durable Direct Smart Inbox job.")
        }
        let running = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try forceNodeSourceForStaleJobFixture(
            accountID: account.id, generation: 2, providerIdentity: account.email.rawValue, at: url
        )
        XCTAssertThrowsError(try store.prepareSmartInboxWork(
            jobID: running.id, leaseToken: try XCTUnwrap(running.leaseToken), seeds: []
        ))
    }

    func testSelectedDirectDiagnosticsPagesStayWithinAccountAndGeneration() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("diagnostics-other-account"), displayName: "Other",
            email: EmailAddress("other@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try store.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }

        let now = Date(timeIntervalSince1970: 1_759_000_000)
        var selectedJobIDs = Set<String>()
        func enqueue(_ accountID: AccountID, suffix: String) throws -> PlainpostDurableJob {
            let input = PlainpostAIOperationInput(
                operation: .recategorizeInbox, recordID: "", providerID: "deterministic",
                smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                    mode: .incremental, scope: .account(accountID), requestedLabelID: nil
                ), smartInboxRequestID: "diagnostics-\(suffix)-\(UUID().uuidString)"
            )
            let job = try store.enqueueJob(.init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: "diagnostics-\(suffix)-\(UUID().uuidString)"
            ))
            if accountID == first.id { selectedJobIDs.insert(job.id) }
            return job
        }

        for index in 0..<25 {
            let job = try enqueue(first.id, suffix: "selected-\(index)")
            try updateActivityJob(
                id: job.id, state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)), at: url
            )
        }
        for index in 0..<3 {
            let job = try enqueue(second.id, suffix: "foreign-\(index)")
            try updateActivityJob(
                id: job.id, state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)), at: url
            )
        }

        let firstPage = try store.diagnosticsJobPage(
            now: now, anchor: nil, offset: 0, limit: 20,
            accountID: first.id, sourceGeneration: 1
        )
        XCTAssertEqual(firstPage.totalTerminalCount, 25)
        XCTAssertEqual(firstPage.terminalJobs.count, 20)
        XCTAssertTrue(Set(firstPage.terminalJobs.map(\.id)).isSubset(of: selectedJobIDs))

        let secondPage = try store.diagnosticsJobPage(
            now: now, anchor: try XCTUnwrap(firstPage.anchor), offset: 20, limit: 20,
            accountID: first.id, sourceGeneration: 1
        )
        XCTAssertEqual(secondPage.totalTerminalCount, 25)
        XCTAssertEqual(secondPage.terminalJobs.count, 5)
        XCTAssertTrue(Set(secondPage.terminalJobs.map(\.id)).isSubset(of: selectedJobIDs))

        let source = try store.mailSource(accountID: first.id)
        _ = try store.replaceMailSource(
            source.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: first.email.rawValue
            ), expectedGeneration: source.generation
        )
        XCTAssertThrowsError(try store.diagnosticsJobPage(
            now: now, anchor: nil, offset: 0, limit: 20,
            accountID: first.id, sourceGeneration: 1
        ))
    }

    func testSelectedDirectSmartInboxBlockersStayWithinAccountAndGeneration() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("blockers-other-account"), displayName: "Other",
            email: EmailAddress("other@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([first, second])
        for account in [first, second] {
            _ = try store.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }

        XCTAssertEqual(
            try store.smartInboxSyncBlockers(accountID: first.id, sourceGeneration: 1)
                .map(\.accountID),
            [first.id]
        )

        let source = try store.mailSource(accountID: first.id)
        _ = try store.replaceMailSource(
            source.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: first.email.rawValue
            ), expectedGeneration: source.generation
        )
        XCTAssertThrowsError(try store.smartInboxSyncBlockers(
            accountID: first.id, sourceGeneration: 1
        ))
    }

    func testDiagnosticsJobPagesAreStableAcrossNewEvents() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_000)
        let active = try enqueueActivityJob(store: store, suffix: "diagnostics-active", mode: .incremental)
        try updateActivityJob(id: active.id, state: .running, updatedAt: now.addingTimeInterval(-7_200), at: url)

        for index in 0..<45 {
            let job = try enqueueActivityJob(store: store, suffix: "diagnostics-terminal-\(index)", mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        XCTAssertEqual(first.activeJobs.map(\.id), [active.id])
        XCTAssertEqual(first.terminalJobs.count, 20)
        XCTAssertEqual(first.totalTerminalCount, 45)
        XCTAssertEqual(first.offset, 0)

        let anchor = try XCTUnwrap(first.anchor)
        let second = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)
        XCTAssertEqual(second.terminalJobs.count, 20)

        let equalTimestamp = try enqueueActivityJob(
            store: store,
            suffix: "diagnostics-equal-after-anchor",
            mode: .incremental
        )
        try executeSQL(
            """
            UPDATE durable_jobs
            SET id = '0000-diagnostics-equal-after-anchor',
                state = 'completed',
                updated_at = \(anchor.updatedAt.timeIntervalSince1970)
            WHERE id = '\(equalTimestamp.id)';
            """,
            at: url
        )
        let stableEqualTimestampSecond = try store.diagnosticsJobPage(
            now: now,
            anchor: anchor,
            offset: 20,
            limit: 20
        )
        XCTAssertEqual(stableEqualTimestampSecond.terminalJobs.map(\.id), second.terminalJobs.map(\.id))
        XCTAssertEqual(stableEqualTimestampSecond.totalTerminalCount, 45)

        let third = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 40, limit: 20)
        XCTAssertEqual(third.terminalJobs.count, 5)
        XCTAssertEqual(
            Set((first.terminalJobs + second.terminalJobs + third.terminalJobs).map(\.id)).count,
            45
        )

        let newer = try enqueueActivityJob(store: store, suffix: "diagnostics-newer", mode: .incremental)
        try updateActivityJob(id: newer.id, state: .completed, updatedAt: now.addingTimeInterval(1), at: url)
        let stableSecond = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)
        XCTAssertEqual(stableSecond.terminalJobs.map(\.id), second.terminalJobs.map(\.id))
    }

    func testDiagnosticsHideInternalSmartInboxFollowUpSuccessors() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_250)
        let active = try enqueueActivityJob(
            store: store,
            suffix: "diagnostics-visible-smart-inbox",
            mode: .incremental
        )
        try updateActivityJob(
            id: active.id,
            state: .running,
            updatedAt: now,
            at: url
        )
        let followUp = try enqueueActivityJob(
            store: store,
            suffix: "diagnostics-internal-follow-up",
            mode: .incremental
        )
        try updateActivityJob(
            id: followUp.id,
            state: .paused,
            pauseReason: "smart-inbox-follow-up",
            updatedAt: now.addingTimeInterval(1),
            at: url
        )

        let page = try store.diagnosticsJobPage(
            now: now.addingTimeInterval(2),
            anchor: nil,
            offset: 0,
            limit: 20
        )

        XCTAssertEqual(page.activeJobs.map(\.id), [active.id])
    }

    func testDiagnosticsJobPagesPreserveSessionCutoff() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_500)
        for index in 0..<45 {
            let job = try enqueueActivityJob(store: store, suffix: "diagnostics-cutoff-\(index)", mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        let last = try store.diagnosticsJobPage(
            now: now.addingTimeInterval(3_600),
            anchor: try XCTUnwrap(first.anchor),
            offset: 40,
            limit: 20
        )

        XCTAssertEqual(last.totalTerminalCount, 45)
        XCTAssertEqual(last.offset, 40)
        XCTAssertEqual(last.terminalJobs.count, 5)
    }

    func testDiagnosticsJobPagesExcludeEqualTimestampInsertAfterHighestJobIsPruned() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_600)
        for index in 0..<45 {
            let job = try enqueueActivityJob(store: store, suffix: "diagnostics-reuse-\(index)", mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        let anchor = try XCTUnwrap(first.anchor)
        let second = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)

        try store.pruneTerminalJobs(before: now.addingTimeInterval(-43.5))
        try executeSQL(
            """
            DELETE FROM durable_job_terminal_events
            WHERE sequence = (SELECT MAX(sequence) FROM durable_job_terminal_events);
            """,
            at: url
        )
        let inserted = try enqueueActivityJob(store: store, suffix: "diagnostics-reused-marker", mode: .incremental)
        try executeSQL(
            """
            UPDATE durable_jobs
            SET id = '0000-diagnostics-reused-marker',
                state = 'completed',
                updated_at = \(anchor.updatedAt.timeIntervalSince1970)
            WHERE id = '\(inserted.id)';
            """,
            at: url
        )
        let stableSecond = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)

        XCTAssertEqual(stableSecond.terminalJobs.map(\.id), second.terminalJobs.map(\.id))
        XCTAssertEqual(stableSecond.totalTerminalCount, 44)
    }

    func testDiagnosticsJobPagesExcludeActiveJobThatBecomesTerminalAfterAnchor() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_700)
        for index in 0..<45 {
            let job = try enqueueActivityJob(store: store, suffix: "diagnostics-transition-\(index)", mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }
        let active = try enqueueActivityJob(store: store, suffix: "diagnostics-active-at-anchor", mode: .incremental)
        try updateActivityJob(id: active.id, state: .running, updatedAt: now, at: url)

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        let anchor = try XCTUnwrap(first.anchor)
        let second = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)
        try executeSQL(
            """
            UPDATE durable_jobs
            SET id = '0000-diagnostics-active-at-anchor',
                state = 'completed',
                updated_at = \(anchor.updatedAt.timeIntervalSince1970)
            WHERE id = '\(active.id)';
            """,
            at: url
        )
        let stableSecond = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)

        XCTAssertEqual(stableSecond.terminalJobs.map(\.id), second.terminalJobs.map(\.id))
        XCTAssertEqual(stableSecond.totalTerminalCount, 45)
    }

    func testDiagnosticsJobPagesClampAnOffsetPastTheRemainingRows() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_101_750)
        for index in 0..<45 {
            let job = try enqueueActivityJob(store: store, suffix: "diagnostics-clamp-\(index)", mode: .incremental)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        try executeSQL(
            """
            DELETE FROM durable_jobs
            WHERE state = 'completed'
              AND updated_at < \(now.addingTimeInterval(-34.5).timeIntervalSince1970);
            """,
            at: url
        )
        let recovered = try store.diagnosticsJobPage(
            now: now,
            anchor: try XCTUnwrap(first.anchor),
            offset: 40,
            limit: 20
        )

        XCTAssertEqual(recovered.totalTerminalCount, 35)
        XCTAssertEqual(recovered.offset, 20)
        XCTAssertEqual(recovered.terminalJobs.count, 15)
    }

    func testDiagnosticsJobPagesBreakTimestampTiesByID() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_102_000)
        let first = try enqueueActivityJob(store: store, suffix: "diagnostics-tie-first", mode: .incremental)
        let second = try enqueueActivityJob(store: store, suffix: "diagnostics-tie-second", mode: .incremental)
        let updatedAt = now.addingTimeInterval(-30)
        try updateActivityJob(id: first.id, state: .completed, updatedAt: updatedAt, at: url)
        try updateActivityJob(id: second.id, state: .completed, updatedAt: updatedAt, at: url)

        let page = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        XCTAssertEqual(page.terminalJobs.map(\.id), [first.id, second.id].sorted(by: >))
    }

    func testDiagnosticsPageRemainsStableWhenTerminalIdempotencyKeyIsRetired() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_102_100)
        let key = "diagnostics-periodic-replacement"
        let original = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                idempotencyKey: key,
                replaceTerminalDuplicate: true
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: original.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )
        try updateActivityJob(
            id: original.id,
            state: .completed,
            updatedAt: now.addingTimeInterval(-25.5),
            at: url
        )
        for index in 0..<44 {
            let job = try enqueueActivityJob(
                store: store,
                suffix: "diagnostics-periodic-peer-\(index)",
                mode: .incremental
            )
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }

        let first = try store.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)
        let anchor = try XCTUnwrap(first.anchor)
        let second = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)
        XCTAssertTrue(second.terminalJobs.map(\.id).contains(original.id))
        let occurredAt = try store.job(id: original.id).updatedAt

        _ = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                idempotencyKey: key,
                replaceTerminalDuplicate: true
            )
        )
        let stableSecond = try store.diagnosticsJobPage(now: now, anchor: anchor, offset: 20, limit: 20)

        XCTAssertEqual(try store.job(id: original.id).updatedAt, occurredAt)
        XCTAssertEqual(stableSecond.terminalJobs.map(\.id), second.terminalJobs.map(\.id))
        XCTAssertEqual(stableSecond.totalTerminalCount, 45)
    }

    func testPruningTerminalJobsClearsTerminalEventAllocationsWithoutResettingSequence() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_102_200)
        let terminal = try store.enqueueJob(
            .init(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "prune-terminal-event")
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: terminal.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )
        try updateActivityJob(
            id: terminal.id,
            state: .completed,
            updatedAt: now.addingTimeInterval(-10),
            at: url
        )
        let allocatedSequence = try queryInteger(
            "SELECT seq FROM sqlite_sequence WHERE name = 'durable_job_terminal_events'",
            at: url
        )

        try store.pruneTerminalJobs(before: now)

        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM durable_job_terminal_events", at: url),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT seq FROM sqlite_sequence WHERE name = 'durable_job_terminal_events'",
                at: url
            ),
            allocatedSequence
        )

        let replacement = try store.enqueueJob(
            .init(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "prune-terminal-event-replacement")
        )
        let replacementRunning = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: replacement.id,
            leaseToken: try XCTUnwrap(replacementRunning.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(
            try queryInteger("SELECT MAX(sequence) FROM durable_job_terminal_events", at: url),
            allocatedSequence + 1
        )
    }

    func testDiagnosticsJobsPreserveGlobalNewestFirstOrderingAcrossActiveAndTerminalRows() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_102_300)
        let terminal = try store.enqueueJob(
            .init(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "diagnostics-terminal-order")
        )
        let running = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(running.id, terminal.id)
        try store.completeJob(
            id: terminal.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )
        try updateActivityJob(id: terminal.id, state: .completed, updatedAt: now, at: url)
        let active = try store.enqueueJob(
            .init(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "diagnostics-active-order")
        )
        try updateActivityJob(
            id: active.id,
            state: .queued,
            updatedAt: now.addingTimeInterval(-10),
            at: url
        )

        let jobs = try store.diagnosticsJobs(now: now, recentTerminalLimit: 20)

        XCTAssertEqual(jobs.prefix(2).map(\.id), [terminal.id, active.id])
    }

    func testDiagnosticsPaginationQueryUsesOrderingIndexWithoutTemporarySort() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_752_102_400)
        let details = try queryPlanDetails(
            """
            EXPLAIN QUERY PLAN
            SELECT * FROM durable_jobs
            WHERE state NOT IN ('queued', 'running', 'paused')
              AND updated_at >= \(now.addingTimeInterval(-3_600).timeIntervalSince1970)
              AND (updated_at < \(now.timeIntervalSince1970)
                   OR (updated_at = \(now.timeIntervalSince1970) AND id <= 'diagnostics-anchor'))
              AND terminal_sequence <= 9999999
            ORDER BY updated_at DESC, id DESC
            LIMIT 20 OFFSET 0
            """,
            at: url
        )

        XCTAssertTrue(details.contains { $0.contains("durable_jobs_terminal_diagnostics_order") })
        XCTAssertFalse(details.contains { $0.localizedCaseInsensitiveContains("temp b-tree") })
    }

    func testSmartInboxActivityIgnoresUnrelatedAIOperations() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try cacheOwnedMessage(
            MessageSummary(
                id: MessageID("message-activity-ignore"),
                threadID: ThreadID("thread-activity-ignore"),
                from: EmailAddress("sender@example.com"),
                subject: "Activity fixture",
                preview: "Activity fixture",
                smartCategory: .unknown
            ),
            store: store,
            uid: 9_201
        )
        let input = PlainpostAIOperationInput(
            operation: .summarizeMessage,
            recordID: "message-activity-ignore",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "deterministic"
        )
        _ = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: "activity-ignore-\(UUID().uuidString)"
            )
        )

        XCTAssertNil(try store.smartInboxActivityJob())
    }

    func testWriteContentionEscapesAsTypedErrorAndSucceedsAfterRollback() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try migratedStore(at: url)
        let contendedStore = try SQLiteMailStore(path: url.path, busyTimeout: 0.05)
        let writer = try SQLiteWriteLock(databaseURL: url)
        try writer.beginImmediate()

        XCTAssertThrowsError(try contendedStore.cacheAccounts([PlainpostFixtures.personalAccount])) { error in
            XCTAssertEqual(error as? SQLiteMailStoreError, .transientContention)
        }

        try writer.rollback()
        XCTAssertNoThrow(try contendedStore.cacheAccounts([PlainpostFixtures.personalAccount]))
    }

    func testWriteContentionWaitsForWriterWithinBusyTimeout() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try migratedStore(at: url)
        let waitingStore = try SQLiteMailStore(path: url.path, busyTimeout: 1)
        let writer = try SQLiteWriteLock(databaseURL: url)
        try writer.beginImmediate()
        let released = expectation(description: "held SQLite writer released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            try? writer.rollback()
            released.fulfill()
        }

        XCTAssertNoThrow(try waitingStore.cacheAccounts([PlainpostFixtures.personalAccount]))
        wait(for: [released], timeout: 1)
    }

    func testIncrementalSmartInboxRequestsAttachToExistingActiveJob() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_first_incremental"), threadID: nil,
                from: EmailAddress("first@example.com"), subject: "First", preview: "First",
                smartCategory: .unknown
            )
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .incremental
        )
        guard case .job(let first) = try store.enqueueSmartInboxJob(input: input) else {
            return XCTFail("Expected the first incremental job.")
        }
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_second_incremental"), threadID: nil,
                from: EmailAddress("second@example.com"), subject: "Second", preview: "Second",
                smartCategory: .unknown
            )
        )

        guard case .job(let attached) = try store.enqueueSmartInboxJob(input: input) else {
            return XCTFail("Expected to attach to active incremental work.")
        }

        XCTAssertEqual(attached.id, first.id)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count, 1)
    }

    func testIncrementalSmartInboxClassifierChangeEnqueuesFreshActiveJob() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_classifier_change"), threadID: nil,
                from: EmailAddress("first@example.com"), subject: "Classifier", preview: "Changed",
                smartCategory: .unknown
            )
        )
        func input(modelID: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                modelID: modelID,
                smartInboxRunMode: .incremental
            )
        }
        guard case .job(let first) = try store.enqueueSmartInboxJob(
            input: input(modelID: "deterministic-local-v1")
        ) else {
            return XCTFail("Expected the first incremental job.")
        }

        guard case .job(let changed) = try store.enqueueSmartInboxJob(
            input: input(modelID: "deterministic-local-v2")
        ) else {
            return XCTFail("Expected changed classifier work.")
        }

        XCTAssertNotEqual(changed.id, first.id)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count, 2)
    }

    func testIncrementalSmartInboxEnqueueTracksFullVersionedClassifierIdentity() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = MessageSummary(
            id: MessageID("msg_full_classifier_identity"),
            threadID: nil,
            from: EmailAddress("identity@example.com"),
            subject: "Classifier identity",
            preview: "Track every identity component",
            smartCategory: .unknown
        )
        try cacheOwnedMessage(message, store: store, uid: 1_046)
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        let baseline = SmartInboxClassifierIdentity(
            providerID: "deterministic",
            modelID: "deterministic-local",
            schemaVersion: "schema-v1",
            promptVersion: "prompt-v1"
        )
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try executeSQL(
            "UPDATE messages SET account_id = '\(PlainpostFixtures.personalAccount.id.rawValue)' WHERE id = '\(message.id.rawValue)'",
            at: url
        )
        let seedJob = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                idempotencyKey: "seed-full-classifier-identity-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: baseline.discriminator
                    )
                ),
            ]
        )
        _ = try store.recordSmartInboxClassification(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: .init(
                messageID: message.id,
                category: .personal,
                priority: .normal,
                requiresAction: false,
                confidence: 0.9
            ),
            providerID: baseline.providerID,
            modelID: baseline.modelID,
            classifierDiscriminator: baseline.discriminator,
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.applySmartInboxWork(
            jobID: seedJob.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try store.completeJob(id: seedJob.id, leaseToken: leaseToken, resultArtifactID: nil)

        func input(_ identity: SmartInboxClassifierIdentity) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: identity.providerID,
                modelID: identity.modelID,
                smartInboxClassifierIdentity: identity
            )
        }
        guard case .upToDate = try store.enqueueSmartInboxJob(input: input(baseline)) else {
            return XCTFail("An identical classifier identity should be up to date.")
        }
        let changedIdentities = [
            SmartInboxClassifierIdentity(
                providerID: "ollama", modelID: baseline.modelID,
                schemaVersion: baseline.schemaVersion, promptVersion: baseline.promptVersion
            ),
            SmartInboxClassifierIdentity(
                providerID: baseline.providerID, modelID: "deterministic-local-v2",
                schemaVersion: baseline.schemaVersion, promptVersion: baseline.promptVersion
            ),
            SmartInboxClassifierIdentity(
                providerID: baseline.providerID, modelID: baseline.modelID,
                schemaVersion: "schema-v2", promptVersion: baseline.promptVersion
            ),
            SmartInboxClassifierIdentity(
                providerID: baseline.providerID, modelID: baseline.modelID,
                schemaVersion: baseline.schemaVersion, promptVersion: "prompt-v2"
            ),
        ]
        let changedJobs = try changedIdentities.map { identity -> PlainpostDurableJob in
            guard case .job(let job) = try store.enqueueSmartInboxJob(input: input(identity)) else {
                throw PlainpostError.validationFailed("Expected fresh classifier work.")
            }
            return job
        }

        XCTAssertEqual(Set(changedJobs.map(\.id)).count, changedIdentities.count)
        XCTAssertTrue(changedJobs.allSatisfy { $0.idempotencyKey.hasPrefix("ai:recategorizeInbox:v3:") })
    }

    func testBackgroundJobRecoveryRequeuesExpiredLeaseAndPreservesProgress() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let start = Date().addingTimeInterval(1)
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_expired_recovery"), threadID: nil,
                from: EmailAddress("recovery@example.com"), subject: "Recovery", preview: "Recovery",
                smartCategory: .unknown
            )
        )
        guard case .job(let queued) = try store.enqueueSmartInboxJob(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: "expired-recovery-request"
            )
        ) else {
            return XCTFail("Expected a recoverable Smart Inbox job.")
        }
        let running = try XCTUnwrap(
            store.claimNextJob(now: start, leaseDuration: 10, allowedKinds: [.aiOperation])
        )
        try store.updateJobProgress(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            progress: PlainpostOperationProgress(current: 119, total: 7_808, phase: "classifying", label: "Smart Inbox")
        )

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: start.addingTimeInterval(11)
        )
        let recovered = try XCTUnwrap(store.job(id: queued.id))

        XCTAssertEqual(summary.requeuedExpiredCount, 1)
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertEqual(recovered.progress?.current, 119)
        XCTAssertEqual(recovered.progress?.total, 7_808)
    }

    func testBackgroundJobRecoveryMarksExpiredApprovedDeliveryUncertainWithoutRequeueOrRedispatch() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let approvalPayload = String(
            decoding: try JSONEncoder().encode(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: PlainpostFixtures.guiUser.id
                )
            ),
            as: UTF8.self
        )
        let approved = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .approvedDelivery,
                payloadJSON: approvalPayload,
                maxAttempts: 5,
                idempotencyKey: "approved-delivery-crash-recovery"
            )
        )
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.approvedDelivery]
            )
        )
        XCTAssertEqual(running.id, approved.id)
        XCTAssertEqual(running.attempt, 1)
        try store.requestJobCancellation(id: running.id)

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.approvedDelivery],
            now: start.addingTimeInterval(11)
        )
        let recovered = try store.job(id: approved.id)

        XCTAssertEqual(summary.requeuedExpiredCount, 0)
        XCTAssertEqual(recovered.state, .deliveryUncertain)
        XCTAssertEqual(recovered.attempt, 1)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertEqual(recovered.errorCode, "DELIVERY_UNCERTAIN")
        XCTAssertEqual(
            recovered.errorMessage,
            "Delivery may have crossed the SMTP acceptance boundary before restart. Review before any new send."
        )
        XCTAssertNil(
            try store.claimNextJob(
                now: start.addingTimeInterval(20),
                leaseDuration: 10,
                allowedKinds: [.approvedDelivery]
            )
        )
    }

    func testLatestSmartInboxRerunProjectsActiveThenCompletedAcrossRelaunch() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try migratedStore(at: url)
        try writer.cacheMessage(
            MessageSummary(
                id: MessageID("msg_completed_rerun"),
                threadID: ThreadID("thr_completed_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Completed rerun",
                preview: "Project the terminal result",
                smartCategory: .unknown
            )
        )
        let result = try writer.enqueueSmartInboxJob(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: "completed-request"
            )
        )
        guard case .job(let queued) = result else {
            return XCTFail("Expected a durable rerun job.")
        }
        XCTAssertEqual(try writer.latestSmartInboxRerunJob()?.state, .queued)

        let running = try XCTUnwrap(writer.claimNextJob(allowedKinds: [.aiOperation]))
        try writer.completeJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )

        let relaunched = try migratedStore(at: url)
        let latest = try XCTUnwrap(relaunched.latestSmartInboxRerunJob())
        XCTAssertEqual(latest.id, queued.id)
        XCTAssertEqual(latest.state, .completed)
    }

    func testLatestSmartInboxRerunProjectsActiveThenFailedAcrossRelaunch() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try migratedStore(at: url)
        try writer.cacheMessage(
            MessageSummary(
                id: MessageID("msg_failed_rerun"),
                threadID: ThreadID("thr_failed_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Failed rerun",
                preview: "Project the failure",
                smartCategory: .unknown
            )
        )
        let result = try writer.enqueueSmartInboxJob(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: "failed-request"
            )
        )
        guard case .job(let queued) = result else {
            return XCTFail("Expected a durable rerun job.")
        }
        XCTAssertEqual(try writer.latestSmartInboxRerunJob()?.state, .queued)

        let running = try XCTUnwrap(writer.claimNextJob(allowedKinds: [.aiOperation]))
        try writer.failJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            code: "PROVIDER_FAILED",
            message: "The selected provider failed.",
            retryAt: nil
        )

        let relaunched = try migratedStore(at: url)
        let latest = try XCTUnwrap(relaunched.latestSmartInboxRerunJob())
        XCTAssertEqual(latest.id, queued.id)
        XCTAssertEqual(latest.state, .failed)
        XCTAssertEqual(latest.errorCode, "PROVIDER_FAILED")
    }

    func testActiveSmartInboxRerunSurvivesStoreRelaunch() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try migratedStore(at: url)
        try writer.cacheMessage(
            MessageSummary(
                id: MessageID("msg_durable_rerun"),
                threadID: ThreadID("thr_durable_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Durable rerun",
                preview: "Still active after relaunch",
                smartCategory: .unknown
            )
        )
        let result = try writer.enqueueSmartInboxJob(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: "durable-request"
            )
        )
        guard case .job(let queued) = result else {
            return XCTFail("Expected a durable rerun job.")
        }

        let relaunched = try migratedStore(at: url)
        let active = try XCTUnwrap(relaunched.activeSmartInboxRerunJob())

        XCTAssertEqual(active.id, queued.id)
        XCTAssertEqual(active.state, .queued)
    }

    func testLegacySyncCompletionWithoutScopeFingerprintFailsClosed() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let input = PlainpostInboxSyncInput(
            accountID: PlainpostFixtures.personalAccount.id,
            trigger: .manual
        )
        let payload = try JSONEncoder().encode(input)
        let sync = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                priority: 100,
                idempotencyKey: "legacy-sync"
            )
        )
        try executeSQL("DELETE FROM account_sync_readiness", at: url)
        try executeSQL("DELETE FROM sync_job_scopes", at: url)
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )

        try store.completeJob(
            id: claimed.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(claimed.id, sync.id)
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
    }

    func testMigrationBackfillsOnlyDecodableActiveLegacySyncScopesBeforeScheduleMerge() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        let activeID: String
        let undecodableID: String
        let terminalID: String
        do {
            let writer = try migratedStore(at: url)
            try writer.cacheAccounts([account])
            let active = try writer.enqueueCoalescedInboxSyncJob(
                .init(accountID: account.id, trigger: .realTimeSignal, scope: .incremental)
            )
            activeID = active.id
            let undecodable = try writer.enqueueJob(
                PlainpostJobRequest(
                    kind: .inboxSync,
                    payloadJSON: String(
                        decoding: try JSONEncoder().encode(
                            PlainpostInboxSyncInput(
                                accountID: account.id,
                                trigger: .schedule,
                                scope: .incremental
                            )
                        ),
                        as: UTF8.self
                    ),
                    priority: -100,
                    idempotencyKey: "legacy-undecodable-sync"
                )
            )
            undecodableID = undecodable.id
            try executeSQL(
                "UPDATE durable_jobs SET payload_json = '{\"legacy\":true}' WHERE id = '\(undecodable.id)'",
                at: url
            )
            let terminalInput = PlainpostInboxSyncInput(
                accountID: account.id,
                trigger: .manual,
                scope: .completeHistory
            )
            let terminal = try writer.enqueueJob(
                PlainpostJobRequest(
                    kind: .historicalSync,
                    payloadJSON: String(
                        decoding: try JSONEncoder().encode(terminalInput),
                        as: UTF8.self
                    ),
                    priority: terminalInput.schedulingPriority,
                    idempotencyKey: "legacy-terminal-sync"
                )
            )
            terminalID = terminal.id
            let runningTerminal = try XCTUnwrap(
                writer.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
            )
            XCTAssertEqual(runningTerminal.id, terminal.id)
            try writer.completeJob(
                id: terminal.id,
                leaseToken: try XCTUnwrap(runningTerminal.leaseToken),
                resultArtifactID: nil
            )
        }
        try executeSQL(
            """
            DROP TABLE sync_job_scopes;
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v14-sync-scope-readiness',
                'v41-inbox-sync-reconciliation-generation'
            );
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)

        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM sync_job_scopes WHERE job_id = '\(activeID)'",
                at: url
            ),
            1
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM sync_job_scopes WHERE job_id = '\(undecodableID)'",
                at: url
            ),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM sync_job_scopes WHERE job_id = '\(terminalID)'",
                at: url
            ),
            0
        )

        let scheduled = try migrated.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .schedule, scope: .incremental)
        )
        XCTAssertEqual(scheduled.id, activeID)
        let runningActive = try XCTUnwrap(
            migrated.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(runningActive.id, activeID)
        XCTAssertGreaterThan(
            try migrated.inboxSyncReconciliationGeneration(
                id: activeID,
                leaseToken: try XCTUnwrap(runningActive.leaseToken)
            ),
            0
        )
    }

    func testIncrementalSyncResumesEnabledCompleteHistory() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(
            id: MailboxID("history-archive"), accountID: account.id,
            name: "Archive", path: "Archive", specialUse: "\\Archive"
        )])
        try store.saveMailboxSyncPreference(MailboxSyncPreference(
            accountID: account.id, mailboxPath: "Archive", mode: .recent
        ))
        try store.saveSyncPreferences(MailSyncPreferences(
            accountID: account.id, downloadCompleteHistory: true
        ))

        let job = try store.enqueueCoalescedInboxSyncJob(.init(
            accountID: account.id, trigger: .schedule, scope: .incremental
        ))
        let scope = try XCTUnwrap(store.syncExecutionScope(jobID: job.id))
        XCTAssertTrue(scope.downloadCompleteHistory)
        XCTAssertFalse(scope.incrementalOnly)
        XCTAssertEqual(Set(scope.mailboxPaths), Set(["INBOX", "Archive"]))
    }

    /// New mail after a finished complete-history download is fresh mail, so a real-time pass
    /// stays incremental and its Inbox arrivals can notify.
    func testIncrementalSyncAfterFinishedCompleteHistoryStaysIncremental() throws {
        XCTAssertTrue(try completeHistoryIncrementalScope(finishedMailboxes: ["INBOX", "Archive"]))
        // One mailbox still downloading its history keeps the pass a history pass.
        XCTAssertFalse(try completeHistoryIncrementalScope(finishedMailboxes: ["INBOX"]))
    }

    private func completeHistoryIncrementalScope(finishedMailboxes: [String]) throws -> Bool {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        try store.cacheMailboxes([Mailbox(
            id: MailboxID("history-archive"), accountID: account.id,
            name: "Archive", path: "Archive", specialUse: "\\Archive"
        )])
        try store.saveMailboxSyncPreference(MailboxSyncPreference(
            accountID: account.id, mailboxPath: "Archive", mode: .recent
        ))
        try store.saveSyncPreferences(MailSyncPreferences(
            accountID: account.id, downloadCompleteHistory: true
        ))
        for path in ["INBOX", "Archive"] {
            let finished = finishedMailboxes.contains(path)
            try store.recordMailboxSyncProgress(
                accountID: account.id, mailboxPath: path, phase: "backfill",
                downloaded: finished ? 3 : 1, estimatedTotal: 3, complete: finished, error: nil
            )
        }
        let job = try store.enqueueCoalescedInboxSyncJob(.init(
            accountID: account.id, trigger: .realTimeSignal, scope: .incremental
        ))
        return try XCTUnwrap(store.syncExecutionScope(jobID: job.id)).incrementalOnly
    }

    func testExplicitSyncIdempotencyKeyIsSeparatedByDirectGeneration() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let account = Account(
            id: AccountID("sync-key-generation"), displayName: "Sync",
            email: EmailAddress("sync@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(
                id: MailboxID("sync-key-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
            ),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let legacy = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .manual, scope: .recent),
            idempotencyKey: "manual-sync-request:direct-generation:1"
        )
        let first = try store.enqueueCoalescedInboxSyncJob(
            .init(
                accountID: account.id, trigger: .manual, scope: .recent,
                expectedDirectSourceGeneration: 1
            ),
            idempotencyKey: "manual-sync-request"
        )
        XCTAssertNotEqual(legacy.id, first.id)
        // Reproduce an older queued request surviving a source handover.
        try executeSQL(
            "UPDATE account_mail_sources SET generation = 3 WHERE account_id = 'sync-key-generation'",
            at: url
        )
        let second = try store.enqueueCoalescedInboxSyncJob(
            .init(
                accountID: account.id, trigger: .manual, scope: .recent,
                expectedDirectSourceGeneration: 3
            ),
            idempotencyKey: "manual-sync-request"
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey)
    }

    func testSmartInboxClassificationCacheStartsEmptyAfterMigration() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)

        XCTAssertEqual(try store.smartInboxClassificationCache(), [:])
    }

    func testFailureSuppressionMigrationBackfillsLatestLegacyFailedFingerprint() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = MessageSummary(
            id: MessageID("legacy-failed-smart-inbox"),
            threadID: ThreadID("legacy-failed-thread"),
            from: EmailAddress("sender@example.com"),
            subject: "Legacy failure",
            preview: "Do not retry unchanged after upgrade",
            smartCategory: .unknown
        )
        try cacheOwnedMessage(message, store: store, uid: 58_001)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        guard case .job(let job) = try store.enqueueSmartInboxJob(input: input) else {
            XCTFail("Expected initial Smart Inbox work")
            return
        }
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)
        let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: job.id))
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: lease,
            seeds: [.init(
                ordinal: 0,
                messageID: message.id.rawValue,
                sourceFingerprint: SmartInboxClassificationFingerprint.message(
                    classificationInput,
                    classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator
                )
            )],
            catalogSnapshot: catalog
        )
        _ = try store.recordSmartInboxWorkItem(
            jobID: job.id,
            leaseToken: lease,
            ordinal: 0,
            state: .failed,
            classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator,
            errorMessage: "Legacy bounded recovery failure"
        )
        try store.completeJob(id: job.id, leaseToken: lease, resultArtifactID: nil)
        try executeSQL(
            """
            DROP TABLE smart_inbox_failure_suppressions;
            DELETE FROM grdb_migrations
            WHERE identifier = 'v58-smart-inbox-failure-suppressions';
            """,
            at: url
        )

        let migrated = try SQLiteMailStore(path: url.path)
        try migrated.migrate()

        guard case .upToDate = try migrated.enqueueSmartInboxJob(input: input) else {
            XCTFail("Expected the legacy failed fingerprint to be suppressed after migration")
            return
        }
    }

    func testSmartInboxTriageMigrationBackfillsNeutralMessageProjectionDefaults() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try migratedStore(at: url)
            try store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_pre_triage"),
                    threadID: nil,
                    from: EmailAddress("legacy@example.com"),
                    subject: "Before triage",
                    preview: "Stored before migration 26",
                    smartCategory: .notification
                )
            )
        }
        try executeSQL(
            """
            ALTER TABLE messages DROP COLUMN smart_priority;
            ALTER TABLE messages DROP COLUMN smart_requires_action;
            ALTER TABLE messages DROP COLUMN smart_confidence;
            DELETE FROM grdb_migrations WHERE identifier = 'v26_smart_inbox_triage';
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)
        let message = try XCTUnwrap(migrated.smartInboxListMessages().first)

        XCTAssertEqual(message.smartPriority, .normal)
        XCTAssertFalse(message.smartRequiresAction)
        XCTAssertNil(message.smartConfidence)
    }

    func testSmartInboxLabelRuntimeMigrationUpgradesDatabaseThatAlreadyRecordedV27() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try migratedStore(at: url)
        try executeSQL(
            """
            ALTER TABLE smart_inbox_work_items DROP COLUMN classifier_discriminator;
            ALTER TABLE smart_inbox_work_items DROP COLUMN provider_id;
            ALTER TABLE smart_inbox_work_items DROP COLUMN model_id;
            ALTER TABLE smart_inbox_work_items DROP COLUMN writes_enriched_projection;
            ALTER TABLE smart_inbox_work_items DROP COLUMN was_updated;
            DELETE FROM grdb_migrations WHERE identifier = 'v28-smart-inbox-label-runtime';
            """,
            at: url
        )

        _ = try migratedStore(at: url)

        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*)
                FROM pragma_table_info('smart_inbox_work_items')
                WHERE name IN (
                    'classifier_discriminator',
                    'provider_id',
                    'model_id',
                    'writes_enriched_projection',
                    'was_updated'
                )
            """,
                at: url
            ),
            5
        )
    }

    func testSmartInboxCompletionAuditMarkerMigrationIsIdempotentAcrossReopen() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer {
            removeSQLiteAndAuditArtifacts(
                databaseURL: url,
                auditLogURL: initial.auditLogURL
            )
        }

        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'smart_inbox_completion_audit_recorded'
                  AND "notnull" = 1 AND dflt_value = '0'
                """,
                at: url
            ),
            1
        )

        _ = try migratedStore(at: url)
        _ = try migratedStore(at: url)
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'smart_inbox_completion_audit_recorded'
                """,
                at: url
            ),
            1
        )
    }

    func testLegacyV42NullFollowUpDemandsMaterializeExactlyOnceForActiveAndTerminalPredecessors() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        let active = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: "legacy-v42-active-predecessor"
        ))
        let terminal = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: "legacy-v42-terminal-predecessor"
        ))
        try executeSQL(
            """
            UPDATE durable_jobs
            SET state = 'completed'
            WHERE id = '\(terminal.id)';
            DROP TABLE smart_inbox_incremental_follow_up_demands;
            CREATE TABLE smart_inbox_incremental_follow_up_demands (
                predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                successor_job_id TEXT,
                FOREIGN KEY(predecessor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE
            );
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, payload_json, created_at, successor_job_id
            ) VALUES
                ('\(active.id)', '\(escapedPayload)', 1000, NULL),
                ('\(terminal.id)', '\(escapedPayload)', 1001, NULL);
            DROP TABLE smart_inbox_promoted_successors;
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v43-smart-inbox-promoted-successor',
                'v44-repair-smart-inbox-follow-up-pairs'
            );
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()

        let activeSuccessors = try queryStrings(
            "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(active.id)'",
            at: url
        )
        XCTAssertEqual(activeSuccessors.count, 1)
        XCTAssertFalse(activeSuccessors[0].isEmpty)
        XCTAssertEqual(try reopened.job(id: activeSuccessors[0]).state, .paused)
        XCTAssertEqual(try reopened.job(id: activeSuccessors[0]).pauseReason, "smart-inbox-follow-up")
        let terminalSuccessor = try XCTUnwrap(
            reopened.terminalSmartInboxSuccessor(after: terminal.id)
        )
        XCTAssertEqual(try reopened.job(id: terminalSuccessor).state, .queued)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(terminal.id)'",
                at: url
            ),
            0
        )

        try reopened.migrate()

        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE 'ai:recategorizeInbox:follow-up:%'",
                at: url
            ),
            2
        )
        XCTAssertEqual(
            try reopened.terminalSmartInboxSuccessor(after: terminal.id),
            terminalSuccessor
        )
    }

    func testV44RepairsDamagedFollowUpIdentityAndOwnershipWithoutMutatingUnrelatedJobs() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .incremental
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let wrongInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "different-classifier",
            smartInboxRunMode: .incremental
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let wrongPayload = String(decoding: try JSONEncoder().encode(wrongInput), as: UTF8.self)
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")

        func enqueue(_ key: String, kind: PlainpostOperationKind = .aiOperation, payloadJSON: String? = nil) throws -> PlainpostDurableJob {
            try store.enqueueJob(.init(
                kind: kind,
                payloadJSON: payloadJSON ?? payload,
                idempotencyKey: key
            ))
        }

        let nullPredecessor = try enqueue("v44-null-predecessor")
        let selfPredecessor = try enqueue("v44-self-predecessor")
        let sharedPredecessorOne = try enqueue("v44-shared-predecessor-one")
        let sharedPredecessorTwo = try enqueue("v44-shared-predecessor-two")
        let wrongKindPredecessor = try enqueue("v44-wrong-kind-predecessor")
        let wrongPayloadPredecessor = try enqueue("v44-wrong-payload-predecessor")
        let unrelatedPredecessor = try enqueue("v44-unrelated-predecessor")
        let sharedTarget = try enqueue("v44-shared-unrelated-target")
        let wrongKindTarget = try enqueue(
            "v44-wrong-kind-unrelated-target",
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON
        )
        let wrongPayloadTarget = try enqueue(
            "v44-wrong-payload-unrelated-target",
            payloadJSON: wrongPayload
        )
        let unrelatedTarget = try enqueue("v44-unrelated-target")
        let missingPredecessorID = "job_missing_v44_predecessor"
        let missingReservedTarget = try enqueue(
            "ai:recategorizeInbox:follow-up:\(missingPredecessorID)"
        )
        try executeSQL(
            """
            UPDATE durable_jobs
            SET state = 'paused', pause_reason = 'smart-inbox-follow-up', progress_phase = 'paused'
            WHERE id = '\(missingReservedTarget.id)';
            DROP TABLE smart_inbox_incremental_follow_up_demands;
            CREATE TABLE smart_inbox_incremental_follow_up_demands (
                predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                successor_job_id TEXT
            );
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, payload_json, created_at, successor_job_id
            ) VALUES
                ('\(nullPredecessor.id)', '\(escapedPayload)', 1000, NULL),
                ('\(selfPredecessor.id)', '\(escapedPayload)', 1001, '\(selfPredecessor.id)'),
                ('\(sharedPredecessorOne.id)', '\(escapedPayload)', 1002, '\(sharedTarget.id)'),
                ('\(sharedPredecessorTwo.id)', '\(escapedPayload)', 1003, '\(sharedTarget.id)'),
                ('\(wrongKindPredecessor.id)', '\(escapedPayload)', 1004, '\(wrongKindTarget.id)'),
                ('\(wrongPayloadPredecessor.id)', '\(escapedPayload)', 1005, '\(wrongPayloadTarget.id)'),
                ('\(unrelatedPredecessor.id)', '\(escapedPayload)', 1006, '\(unrelatedTarget.id)'),
                ('\(missingPredecessorID)', '\(escapedPayload)', 1007, '\(missingReservedTarget.id)');
            DROP TABLE smart_inbox_promoted_successors;
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v43-smart-inbox-promoted-successor',
                'v44-repair-smart-inbox-follow-up-pairs'
            );
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()

        let predecessors = [
            nullPredecessor, selfPredecessor, sharedPredecessorOne,
            sharedPredecessorTwo, wrongKindPredecessor,
            wrongPayloadPredecessor, unrelatedPredecessor,
        ]
        var repairedSuccessorIDs: Set<String> = []
        for predecessor in predecessors {
            let successorID = try XCTUnwrap(queryStrings(
                "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessor.id)'",
                at: url
            ).first)
            XCTAssertNotEqual(successorID, predecessor.id)
            XCTAssertTrue(repairedSuccessorIDs.insert(successorID).inserted)
            let successor = try reopened.job(id: successorID)
            XCTAssertEqual(successor.kind, .aiOperation)
            XCTAssertEqual(successor.payloadJSON, payload)
            XCTAssertEqual(
                successor.idempotencyKey,
                "ai:recategorizeInbox:follow-up:\(predecessor.id)"
            )
        }

        for target in [sharedTarget, wrongKindTarget, wrongPayloadTarget, unrelatedTarget] {
            let preserved = try reopened.job(id: target.id)
            XCTAssertEqual(preserved.kind, target.kind)
            XCTAssertEqual(preserved.payloadJSON, target.payloadJSON)
            XCTAssertEqual(preserved.state, target.state)
            XCTAssertEqual(preserved.idempotencyKey, target.idempotencyKey)
            XCTAssertEqual(preserved.pauseReason, target.pauseReason)
            XCTAssertEqual(preserved.progress, target.progress)
        }
        XCTAssertEqual(try reopened.job(id: missingReservedTarget.id).state, .cancelled)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(missingPredecessorID)'",
                at: url
            ),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM pragma_index_list('smart_inbox_incremental_follow_up_demands') WHERE \"unique\" = 1",
                at: url
            ),
            2
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM pragma_index_list('smart_inbox_promoted_successors') WHERE \"unique\" = 1",
                at: url
            ),
            2
        )

        try reopened.migrate()
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE 'ai:recategorizeInbox:follow-up:%'",
                at: url
            ),
            predecessors.count + 1
        )
    }

    func testV45UsesCollisionSafeSuccessorWithoutMutatingCanonicalKeyOwner() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .incremental
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        let predecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: "v45-collision-predecessor"
        ))
        let canonicalKey = "ai:recategorizeInbox:follow-up:\(predecessor.id)"
        let canonicalOwner = try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            idempotencyKey: canonicalKey
        ))
        try executeSQL(
            """
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES (
                '\(predecessor.id)', '\(canonicalOwner.id)', '\(escapedPayload)', 1100
            );
            DELETE FROM grdb_migrations
            WHERE identifier = 'v45-repair-smart-inbox-follow-up-collisions';
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        XCTAssertNoThrow(try reopened.migrate())
        let successorID = try XCTUnwrap(queryStrings(
            "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessor.id)'",
            at: url
        ).first)
        XCTAssertNotEqual(successorID, canonicalOwner.id)
        let successor = try reopened.job(id: successorID)
        XCTAssertEqual(successor.kind, .aiOperation)
        XCTAssertEqual(successor.payloadJSON, payload)
        XCTAssertEqual(successor.state, .paused)
        XCTAssertEqual(successor.pauseReason, "smart-inbox-follow-up")
        XCTAssertTrue(successor.idempotencyKey.hasPrefix("\(canonicalKey):repair:"))

        let preservedOwner = try reopened.job(id: canonicalOwner.id)
        XCTAssertEqual(preservedOwner.kind, .searchRebuild)
        XCTAssertEqual(preservedOwner.payloadJSON, plainpostTestSearchRebuildPayloadJSON)
        XCTAssertEqual(preservedOwner.state, .queued)
        XCTAssertEqual(preservedOwner.idempotencyKey, canonicalKey)
        XCTAssertNil(preservedOwner.pauseReason)

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertEqual(
            try queryStrings(
                "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessor.id)'",
                at: url
            ),
            [successorID]
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE '\(canonicalKey):repair:%'",
                at: url
            ),
            1
        )
    }

    func testV44PendingCanonicalCollisionReachesV45RepairWithoutAborting() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .incremental
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        let predecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: "v44-pending-collision-predecessor"
        ))
        let canonicalKey = "ai:recategorizeInbox:follow-up:\(predecessor.id)"
        let owner = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: canonicalKey
        ))
        try executeSQL(
            "UPDATE durable_jobs SET payload_json = '{\"wrong\":\"payload\"}' WHERE id = '\(owner.id)'",
            at: url
        )
        try executeSQL(
            """
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES ('\(predecessor.id)', '\(owner.id)', '\(escapedPayload)', 1150);
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v44-repair-smart-inbox-follow-up-pairs',
                'v45-repair-smart-inbox-follow-up-collisions'
            );
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        XCTAssertNoThrow(try reopened.migrate())
        let successorID = try XCTUnwrap(queryStrings(
            "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessor.id)'",
            at: url
        ).first)
        XCTAssertNotEqual(successorID, owner.id)
        XCTAssertTrue(try reopened.job(id: successorID).idempotencyKey.hasPrefix("\(canonicalKey):repair:"))
        XCTAssertEqual(try reopened.job(id: successorID).payloadJSON, payload)
        XCTAssertEqual(try reopened.job(id: owner.id).payloadJSON, "{\"wrong\":\"payload\"}")
        XCTAssertEqual(try reopened.job(id: owner.id).state, .queued)
    }

    func testV44PendingInvalidPayloadNeverMaterializesARepairSuccessor() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let validInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let validPayload = String(decoding: try JSONEncoder().encode(validInput), as: UTF8.self)
        let predecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "v44-pending-invalid-predecessor"
        ))
        let malformedPayload = "{invalid-v44"
        let reservation = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "ai:recategorizeInbox:follow-up:\(predecessor.id)"
        ))
        try executeSQL(
            """
            UPDATE durable_jobs
            SET payload_json = '\(malformedPayload)', state = 'paused',
                pause_reason = 'smart-inbox-follow-up', progress_phase = 'paused'
            WHERE id = '\(reservation.id)';
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES ('\(predecessor.id)', '\(reservation.id)', '\(malformedPayload)', 1175);
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v44-repair-smart-inbox-follow-up-pairs',
                'v45-repair-smart-inbox-follow-up-collisions'
            );
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()

        XCTAssertEqual(try reopened.job(id: reservation.id).state, .cancelled)
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands", at: url),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE 'ai:recategorizeInbox:follow-up:%:repair:%'",
                at: url
            ),
            0
        )
    }

    func testV45RejectsInvalidDemandPayloadsAndOnlyCancelsIdentifiedReservation() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let validInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .incremental
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let validPayload = String(decoding: try JSONEncoder().encode(validInput), as: UTF8.self)
        let malformedPredecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "v45-malformed-predecessor"
        ))
        let malformedPayload = "{not-json"
        let malformedReservation = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "ai:recategorizeInbox:follow-up:\(malformedPredecessor.id)"
        ))
        let nonincrementalInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "v45-rejected-rerun"
        ).resolvingSmartInboxClassifierIdentity(environment: [:])
        let nonincrementalPayload = String(
            decoding: try JSONEncoder().encode(nonincrementalInput),
            as: UTF8.self
        )
        let escapedNonincrementalPayload = nonincrementalPayload
            .replacingOccurrences(of: "'", with: "''")
        let nonincrementalPredecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "v45-nonincremental-predecessor"
        ))
        let unrelatedTarget = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: validPayload,
            idempotencyKey: "v45-invalid-payload-unrelated"
        ))
        try executeSQL(
            """
            UPDATE durable_jobs
            SET payload_json = '\(malformedPayload)', state = 'paused',
                pause_reason = 'smart-inbox-follow-up', progress_phase = 'paused'
            WHERE id = '\(malformedReservation.id)';
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES
                ('\(malformedPredecessor.id)', '\(malformedReservation.id)', '\(malformedPayload)', 1200),
                ('\(nonincrementalPredecessor.id)', '\(unrelatedTarget.id)', '\(escapedNonincrementalPayload)', 1201);
            DELETE FROM grdb_migrations
            WHERE identifier = 'v45-repair-smart-inbox-follow-up-collisions';
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()

        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands", at: url),
            0
        )
        XCTAssertEqual(try reopened.job(id: malformedReservation.id).state, .cancelled)
        let preservedTarget = try reopened.job(id: unrelatedTarget.id)
        XCTAssertEqual(preservedTarget.kind, unrelatedTarget.kind)
        XCTAssertEqual(preservedTarget.payloadJSON, unrelatedTarget.payloadJSON)
        XCTAssertEqual(preservedTarget.state, .queued)
        XCTAssertEqual(preservedTarget.idempotencyKey, unrelatedTarget.idempotencyKey)
        XCTAssertNil(preservedTarget.pauseReason)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE 'ai:recategorizeInbox:follow-up:%:repair:%'",
                at: url
            ),
            0
        )

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands", at: url),
            0
        )
        XCTAssertEqual(try relaunched.job(id: malformedReservation.id).state, .cancelled)
        XCTAssertEqual(try relaunched.job(id: unrelatedTarget.id).state, .queued)
    }

    func testV44AndV45RejectedDemandsUseLiteralRepairKeyValidation() throws {
        func verify(removingMigrationIdentifiers identifiers: [String]) throws {
            let url = temporarySQLiteURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try migratedStore(at: url)
            let validInput = PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic"
            ).resolvingSmartInboxClassifierIdentity(environment: [:])
            let validPayload = String(decoding: try JSONEncoder().encode(validInput), as: UTF8.self)
            let predecessorIDs = [
                "job_%_literal",
                "job_plain_literal",
                "job_exact_base",
                "job_exact_suffix",
                "job_zero_suffix",
                "job_signed_suffix",
                "job_leading_junk_suffix",
            ]
            for (index, predecessorID) in predecessorIDs.enumerated() {
                let predecessor = try store.enqueueJob(.init(
                    kind: .aiOperation,
                    payloadJSON: validPayload,
                    idempotencyKey: "literal-key-predecessor-\(index)-\(identifiers.count)"
                ))
                try executeSQL(
                    "UPDATE durable_jobs SET id = '\(predecessorID)' WHERE id = '\(predecessor.id)';",
                    at: url
                )
            }

            let malformedPayloads = [
                "{wildcard", "{lookalike", "{bad-base", "{bad-suffix",
                "{zero", "{signed", "{junk",
            ]
            let wildcardKey = "ai:recategorizeInbox:follow-up:job_Xanything_literal:repair:arbitrary"
            let arbitraryPrefixKey = "ai:recategorizeInbox:follow-up:job_plain_literal:repair:not-a-derived-digest"
            let exactBaseKey = "ai:recategorizeInbox:follow-up:job_exact_base:repair:fe3b263174576ff6ddf7285871f149e6a70e7af27c5d0f24cc84b7c40ab56e69"
            let exactSuffixKey = "ai:recategorizeInbox:follow-up:job_exact_suffix:repair:ffd2ae33aa7925ee83409c23dbd71eb2e33a688a207f2101832681d689fca558:1"
            let zeroSuffixKey = "ai:recategorizeInbox:follow-up:job_zero_suffix:repair:7d39ea72490ac16bb0694dff9c06581f8e31f20b9547e5c2ac1a7a581ff1d266:0"
            let signedSuffixKey = "ai:recategorizeInbox:follow-up:job_signed_suffix:repair:e53720b8fc8e8e232677c3a28f70a63701c44adc4bc97922ae1bff6e5599f023:+1"
            let leadingJunkSuffixKey = "ai:recategorizeInbox:follow-up:job_leading_junk_suffix:repair:1846b19da4daeb4f733d9a7e721b1f425eab27a681416adb7555ef1d0373646d:x1"
            let successorKeys = [
                wildcardKey, arbitraryPrefixKey, exactBaseKey, exactSuffixKey,
                zeroSuffixKey, signedSuffixKey, leadingJunkSuffixKey,
            ]
            var successorIDs: [String] = []
            for (index, successorKey) in successorKeys.enumerated() {
                let successor = try store.enqueueJob(.init(
                    kind: .aiOperation,
                    payloadJSON: validPayload,
                    idempotencyKey: successorKey
                ))
                successorIDs.append(successor.id)
                try executeSQL(
                    "UPDATE durable_jobs SET payload_json = \(sqlLiteral(malformedPayloads[index])) WHERE id = '\(successor.id)'",
                    at: url
                )
            }
            let migrationList = identifiers.map { "'\($0)'" }.joined(separator: ", ")
            try executeSQL(
                """
                UPDATE durable_jobs
                SET state = 'paused', pause_reason = 'smart-inbox-follow-up', progress_phase = 'paused'
                WHERE id IN ('\(successorIDs.joined(separator: "', '"))');
                INSERT INTO smart_inbox_incremental_follow_up_demands (
                    predecessor_job_id, successor_job_id, payload_json, created_at
                ) VALUES
                    ('\(predecessorIDs[0])', '\(successorIDs[0])', '\(malformedPayloads[0])', 1300),
                    ('\(predecessorIDs[1])', '\(successorIDs[1])', '\(malformedPayloads[1])', 1301),
                    ('\(predecessorIDs[2])', '\(successorIDs[2])', '\(malformedPayloads[2])', 1302),
                    ('\(predecessorIDs[3])', '\(successorIDs[3])', '\(malformedPayloads[3])', 1303),
                    ('\(predecessorIDs[4])', '\(successorIDs[4])', '\(malformedPayloads[4])', 1304),
                    ('\(predecessorIDs[5])', '\(successorIDs[5])', '\(malformedPayloads[5])', 1305),
                    ('\(predecessorIDs[6])', '\(successorIDs[6])', '\(malformedPayloads[6])', 1306);
                DELETE FROM grdb_migrations WHERE identifier IN (\(migrationList));
                """,
                at: url
            )

            let reopened = try SQLiteMailStore(path: url.path)
            try reopened.migrate()

            XCTAssertEqual(try reopened.job(id: successorIDs[0]).state, .paused)
            XCTAssertEqual(try reopened.job(id: successorIDs[1]).state, .paused)
            XCTAssertEqual(try reopened.job(id: successorIDs[2]).state, .cancelled)
            XCTAssertEqual(try reopened.job(id: successorIDs[3]).state, .cancelled)
            XCTAssertEqual(try reopened.job(id: successorIDs[4]).state, .paused)
            XCTAssertEqual(try reopened.job(id: successorIDs[5]).state, .paused)
            XCTAssertEqual(try reopened.job(id: successorIDs[6]).state, .paused)
            XCTAssertEqual(
                try queryInteger("SELECT COUNT(*) FROM smart_inbox_incremental_follow_up_demands", at: url),
                0
            )

            let relaunched = try SQLiteMailStore(path: url.path)
            try relaunched.migrate()
            XCTAssertEqual(try relaunched.job(id: successorIDs[0]).state, .paused)
            XCTAssertEqual(try relaunched.job(id: successorIDs[1]).state, .paused)
            XCTAssertEqual(try relaunched.job(id: successorIDs[2]).state, .cancelled)
            XCTAssertEqual(try relaunched.job(id: successorIDs[3]).state, .cancelled)
            XCTAssertEqual(try relaunched.job(id: successorIDs[4]).state, .paused)
            XCTAssertEqual(try relaunched.job(id: successorIDs[5]).state, .paused)
            XCTAssertEqual(try relaunched.job(id: successorIDs[6]).state, .paused)
        }

        try verify(removingMigrationIdentifiers: [
            "v45-repair-smart-inbox-follow-up-collisions",
        ])
        try verify(removingMigrationIdentifiers: [
            "v44-repair-smart-inbox-follow-up-pairs",
            "v45-repair-smart-inbox-follow-up-collisions",
        ])
    }

    func testV45RepairKeyCollisionUsesPinnedDigestAndNextFreeCanonicalSuffix() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let predecessorID = "job_collision_%_1"
        let payload = "{\"operation\":\"recategorizeInbox\",\"recordID\":\"\",\"providerID\":\"deterministic\",\"conversation\":[],\"smartInboxRunRequest\":{\"mode\":\"incremental\",\"scope\":{\"allAccounts\":{}}},\"smartInboxClassifierIdentity\":{\"providerID\":\"deterministic\",\"modelID\":\"deterministic-local\",\"promptVersion\":\"2026-07-23\",\"schemaVersion\":\"smart-inbox-triage-labels-v2\"},\"enqueueOnly\":false}"
        let predecessor = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: payload,
            idempotencyKey: "repair-suffix-predecessor"
        ))
        try executeSQL(
            "UPDATE durable_jobs SET id = '\(predecessorID)' WHERE id = '\(predecessor.id)';",
            at: url
        )
        let repairBase = "ai:recategorizeInbox:follow-up:\(predecessorID):repair:4dc7419f32173ff012dde7ae82580000426f28badad5bb9a5c9fa86d0d8fd21f"
        let baseOwner = try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            idempotencyKey: repairBase
        ))
        let suffixOwner = try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            idempotencyKey: "\(repairBase):1"
        ))
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        try executeSQL(
            """
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES ('\(predecessorID)', '\(baseOwner.id)', '\(escapedPayload)', 1400);
            DELETE FROM grdb_migrations
            WHERE identifier = 'v45-repair-smart-inbox-follow-up-collisions';
            """,
            at: url
        )

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()

        let successorID = try XCTUnwrap(queryStrings(
            "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessorID)'",
            at: url
        ).first)
        XCTAssertEqual(try reopened.job(id: successorID).idempotencyKey, "\(repairBase):2")
        XCTAssertEqual(try reopened.job(id: successorID).payloadJSON, payload)
        XCTAssertEqual(try reopened.job(id: baseOwner.id).state, .queued)
        XCTAssertEqual(try reopened.job(id: baseOwner.id).payloadJSON, plainpostTestSearchRebuildPayloadJSON)
        XCTAssertEqual(try reopened.job(id: suffixOwner.id).state, .queued)
        XCTAssertEqual(try reopened.job(id: suffixOwner.id).payloadJSON, plainpostTestSearchRebuildPayloadJSON)

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertEqual(
            try queryStrings(
                "SELECT successor_job_id FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = '\(predecessorID)'",
                at: url
            ),
            [successorID]
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM durable_jobs WHERE idempotency_key LIKE 'ai:recategorizeInbox:follow-up:%:repair:%'",
                at: url
            ),
            3
        )
    }

    func testSmartInboxCompletionAuditMarkerMigrationBackfillsExistingTerminalJobs() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer {
            removeSQLiteAndAuditArtifacts(
                databaseURL: url,
                auditLogURL: initial.auditLogURL
            )
        }
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "pre-v29-terminal-job"
        )
        let job = try initial.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                idempotencyKey: "pre-v29-terminal-\(UUID().uuidString)"
            )
        )
        try executeSQL(
            """
            UPDATE durable_jobs
            SET state = 'completed', smart_inbox_completion_audit_recorded = 0
            WHERE id = '\(job.id)';
            DELETE FROM grdb_migrations
            WHERE identifier = 'v29-smart-inbox-completion-audit-marker';
            """,
            at: url
        )

        _ = try migratedStore(at: url)

        XCTAssertEqual(
            try queryInteger(
                """
                SELECT smart_inbox_completion_audit_recorded
                FROM durable_jobs WHERE id = '\(job.id)'
                """,
                at: url
            ),
            1
        )
    }

    func testSmartInboxUserPauseMigrationDecodesExistingJobsWithPauseRequestDisabled() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer {
            removeSQLiteAndAuditArtifacts(
                databaseURL: url,
                auditLogURL: initial.auditLogURL
            )
        }
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "pre-v30-user-pause-job"
        )
        let job = try initial.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                idempotencyKey: "pre-v30-user-pause-\(UUID().uuidString)"
            )
        )
        try executeSQL(
            """
            ALTER TABLE durable_jobs DROP COLUMN pause_requested;
            DELETE FROM grdb_migrations
            WHERE identifier = 'v30-smart-inbox-user-pause';
            """,
            at: url
        )
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'pause_requested'
                """,
                at: url
            ),
            0
        )

        let migrated = try migratedStore(at: url)
        let migratedJob = try migrated.job(id: job.id)

        XCTAssertEqual(migratedJob.id, job.id)
        XCTAssertEqual(migratedJob.state, job.state)
        XCTAssertEqual(migratedJob.idempotencyKey, job.idempotencyKey)
        XCTAssertFalse(migratedJob.pauseRequested)
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT pause_requested FROM durable_jobs
                WHERE id = '\(job.id)'
                """,
                at: url
            ),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'pause_requested'
                  AND "notnull" = 1 AND dflt_value = '0'
                """,
                at: url
            ),
            1
        )
    }

    func testSmartInboxPauseAttemptCreditMigrationPreservesExistingJobWithZeroDefault() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer {
            removeSQLiteAndAuditArtifacts(
                databaseURL: url,
                auditLogURL: initial.auditLogURL
            )
        }
        let job = try initial.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                idempotencyKey: "pre-v31-pause-credit-\(UUID().uuidString)"
            )
        )
        try executeSQL(
            """
            ALTER TABLE durable_jobs DROP COLUMN pause_attempt_credit;
            DELETE FROM grdb_migrations
            WHERE identifier = 'v31-smart-inbox-pause-attempt-credit';
            """,
            at: url
        )
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'pause_attempt_credit'
                """,
                at: url
            ),
            0
        )

        let migrated = try migratedStore(at: url)
        let migratedJob = try migrated.job(id: job.id)

        XCTAssertEqual(migratedJob.id, job.id)
        XCTAssertEqual(migratedJob.state, job.state)
        XCTAssertEqual(migratedJob.idempotencyKey, job.idempotencyKey)
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT pause_attempt_credit FROM durable_jobs
                WHERE id = '\(job.id)'
                """,
                at: url
            ),
            0
        )
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM pragma_table_info('durable_jobs')
                WHERE name = 'pause_attempt_credit'
                  AND "notnull" = 1 AND dflt_value = '0'
                """,
                at: url
            ),
            1
        )
    }

    func testDiagnosticsTerminalSequenceMigrationBackfillsExistingTerminalJobs() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer {
            removeSQLiteAndAuditArtifacts(
                databaseURL: url,
                auditLogURL: initial.auditLogURL
            )
        }
        let now = Date(timeIntervalSince1970: 1_752_102_500)
        var expectedIDs: [String] = []
        for index in 0..<2 {
            let job = try enqueueActivityJob(store: initial, suffix: "pre-v39-\(index)", mode: .incremental)
            expectedIDs.append(job.id)
            try updateActivityJob(
                id: job.id,
                state: .completed,
                updatedAt: now.addingTimeInterval(-Double(index)),
                at: url
            )
        }
        try executeSQL(
            """
            DROP TRIGGER durable_jobs_assign_terminal_sequence_after_insert;
            DROP TRIGGER durable_jobs_assign_terminal_sequence_after_update;
            DROP INDEX IF EXISTS durable_jobs_terminal_diagnostics;
            DROP INDEX IF EXISTS durable_jobs_terminal_diagnostics_order;
            ALTER TABLE durable_jobs DROP COLUMN terminal_sequence;
            DROP TABLE durable_job_terminal_events;
            DELETE FROM grdb_migrations
            WHERE identifier IN (
                'v39-durable-job-terminal-sequence',
                'v40-durable-job-diagnostics-order-index'
            );
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)
        let page = try migrated.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 20)

        XCTAssertEqual(page.terminalJobs.map(\.id), expectedIDs)
        XCTAssertEqual(page.totalTerminalCount, 2)
        XCTAssertEqual(page.anchor?.maximumTerminalSequence, 2)
    }

    func testRequestingPauseForQueuedSmartInboxJobPausesImmediatelyAndResumeIsIdempotent() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "queued")

        try store.requestJobPause(id: job.id)
        let paused = try store.job(id: job.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.pauseReason, "user-requested")
        XCTAssertFalse(paused.pauseRequested)
        XCTAssertNil(paused.leaseToken)
        XCTAssertNil(paused.leaseExpiresAt)
        XCTAssertEqual(paused.attempt, job.attempt)

        XCTAssertNoThrow(try store.requestJobPause(id: job.id))

        let resumeAt = Date(timeIntervalSince1970: 1_752_000_000)
        try store.resumeUserPausedJob(id: job.id, now: resumeAt)
        let resumed = try store.job(id: job.id)
        XCTAssertEqual(resumed.id, job.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        XCTAssertFalse(resumed.pauseRequested)
        XCTAssertEqual(resumed.availableAt, resumeAt)
        XCTAssertNoThrow(try store.resumeUserPausedJob(id: job.id, now: resumeAt))
        XCTAssertEqual(try store.job(id: job.id).state, .queued)

        let claimed = try XCTUnwrap(store.claimNextJob())
        XCTAssertNoThrow(try store.resumeUserPausedJob(id: job.id, now: resumeAt))
        XCTAssertEqual(try store.job(id: job.id), claimed)
    }

    // Low Power Mode can end before the worker acknowledges its pause request.
    // Lifting the pause then must leave the job running, not strand it paused.
    func testLowPowerPauseLiftedBeforeAcknowledgementKeepsTheJobRunning() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "low-power-fast")
        let claimed = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(claimed.leaseToken)

        try store.requestJobPause(id: job.id, reason: .lowPower)
        let requested = try store.job(id: job.id)
        XCTAssertEqual(requested.state, .running)
        XCTAssertTrue(requested.pauseRequested)
        XCTAssertEqual(requested.pauseReason, "low-power")

        XCTAssertEqual(try store.resumeLowPowerPausedJobs(now: Date()), 1)
        let lifted = try store.job(id: job.id)
        XCTAssertEqual(lifted.state, .running)
        XCTAssertFalse(lifted.pauseRequested)
        XCTAssertNil(lifted.pauseReason)
        XCTAssertEqual(lifted.leaseToken, leaseToken)

        XCTAssertEqual(
            try store.acknowledgeSmartInboxBoundary(
                jobID: job.id, leaseToken: leaseToken,
                priority: claimed.priority, allowedKinds: [.aiOperation]
            ),
            .continueRunning
        )
        XCTAssertEqual(try store.job(id: job.id).state, .running)
    }

    // The worker honors a Low Power pause like the user's, keeps its reason, and
    // the job stays paused across a relaunch until Low Power Mode is off.
    func testLowPowerPausedJobStaysUnclaimableUntilResumedAfterARestart() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "low-power-restart")
        let claimed = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.requestJobPause(id: job.id, reason: .lowPower)
        XCTAssertEqual(
            try store.acknowledgeSmartInboxBoundary(
                jobID: job.id, leaseToken: leaseToken,
                priority: claimed.priority, allowedKinds: [.aiOperation]
            ),
            .yielded
        )
        let paused = try store.job(id: job.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.pauseReason, "low-power")
        XCTAssertNil(try store.claimNextJob())

        let relaunched = try migratedStore(at: url)
        XCTAssertNil(try relaunched.claimNextJob())
        XCTAssertEqual(try relaunched.resumeLowPowerPausedJobs(now: Date()), 1)
        let resumed = try relaunched.job(id: job.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        XCTAssertEqual(resumed.attempt, claimed.attempt - 1)
        XCTAssertEqual(try relaunched.claimNextJob()?.id, job.id)
    }

    // A Re-sort the system already paused (mail sync, interactive AI) is claimable by
    // the worker and re-queued when sync ends. A Low Power pause request moves it to
    // the Low Power pause instead, so neither happens until Low Power Mode is off.
    func testLowPowerPauseTakesOverASystemPausedSmartInboxJob() throws {
        for reason in ["mail-sync", "mail-sync-failed", "interactive-ai"] {
            let url = temporarySQLiteURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try migratedStore(at: url)
            let job = try enqueueSmartInboxPauseJob(store: store, suffix: "system-\(reason)")
            let claimed = try XCTUnwrap(store.claimNextJob())
            try executeSQL(
                """
                UPDATE durable_jobs
                SET state = 'paused', pause_reason = '\(reason)', lease_token = NULL, lease_expires_at = NULL
                WHERE id = '\(job.id)'
                """,
                at: url
            )

            try store.requestJobPause(id: job.id, reason: .lowPower)
            let paused = try store.job(id: job.id)
            XCTAssertEqual(paused.state, .paused, reason)
            XCTAssertEqual(paused.pauseReason, "low-power", reason)
            XCTAssertNil(try store.claimNextJob(), reason)

            XCTAssertEqual(try store.resumeLowPowerPausedJobs(now: Date()), 1, reason)
            let resumed = try store.job(id: job.id)
            XCTAssertEqual(resumed.state, .queued, reason)
            XCTAssertNil(resumed.pauseReason, reason)
            XCTAssertEqual(resumed.attempt, claimed.attempt - 1, reason)
            XCTAssertEqual(try store.claimNextJob()?.id, job.id, reason)
        }
    }

    // Lifting a Low Power pause that took over a 'mail-sync' pause queues the Re-sort
    // while the sync may still be active. The claim must still wait for the sync.
    func testLiftedLowPowerPauseOfAMailSyncPausedJobWaitsForTheActiveSync() throws {
        for syncRunning in [false, true] {
            let url = temporarySQLiteURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try migratedStore(at: url)
            let job = try enqueueSmartInboxPauseJob(store: store, suffix: "sync-active-\(syncRunning)")
            _ = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
            try executeSQL(
                """
                UPDATE durable_jobs
                SET state = 'paused', pause_reason = 'mail-sync', lease_token = NULL, lease_expires_at = NULL
                WHERE id = '\(job.id)'
                """,
                at: url
            )
            let syncInput = PlainpostInboxSyncInput(accountID: PlainpostFixtures.personalAccount.id, trigger: .manual)
            let sync = try store.enqueueJob(.init(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(syncInput), as: UTF8.self),
                priority: 10, idempotencyKey: UUID().uuidString
            ))
            var syncLease: String?
            if syncRunning {
                syncLease = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync])?.leaseToken)
            }

            try store.requestJobPause(id: job.id, reason: .lowPower)
            XCTAssertEqual(try store.job(id: job.id).pauseReason, "low-power")
            XCTAssertEqual(try store.resumeLowPowerPausedJobs(now: Date()), 1)
            XCTAssertEqual(try store.job(id: job.id).state, .queued)
            XCTAssertNil(
                try store.claimNextJob(allowedKinds: [.aiOperation]),
                "the Re-sort ran while sync was \(syncRunning ? "running" : "queued")"
            )

            if syncLease == nil {
                syncLease = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync])?.leaseToken)
            }
            try store.completeJob(id: sync.id, leaseToken: try XCTUnwrap(syncLease), resultArtifactID: nil)
            XCTAssertEqual(try store.claimNextJob(allowedKinds: [.aiOperation])?.id, job.id)
        }
    }

    // Resume tapped just as Low Power Mode ends: the lift may already have queued the
    // job, or the worker claimed it. Either way the Resume succeeds as a no-op.
    func testResumeAfterTheLowPowerLiftAlreadyRequeuedTheJobSucceeds() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "low-power-resume-race")
        try store.requestJobPause(id: job.id, reason: .lowPower)
        XCTAssertEqual(try store.resumeLowPowerPausedJobs(now: Date()), 1)
        let lifted = try store.job(id: job.id)
        XCTAssertEqual(lifted.state, .queued)

        XCTAssertNoThrow(try store.resumeUserPausedJob(id: job.id, now: Date()))
        XCTAssertEqual(try store.job(id: job.id), lifted)

        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        XCTAssertEqual(claimed.id, job.id)
        XCTAssertNoThrow(try store.resumeUserPausedJob(id: job.id, now: Date()))
        XCTAssertEqual(try store.job(id: job.id), claimed)
    }

    // The activity's Resume works for a job still paused for Low Power Mode.
    func testUserResumeAlsoResumesALowPowerPausedJob() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "low-power-user-resume")
        try store.requestJobPause(id: job.id, reason: .lowPower)
        XCTAssertEqual(try store.job(id: job.id).pauseReason, "low-power")

        try store.resumeUserPausedJob(id: job.id, now: Date())
        let resumed = try store.job(id: job.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
    }

    // Lifting Low Power pauses never resumes a job the user paused.
    func testLowPowerResumeLeavesUserPausedJobsAlone() throws {
        for running in [false, true] {
            let url = temporarySQLiteURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try migratedStore(at: url)
            let job = try enqueueSmartInboxPauseJob(store: store, suffix: "user-paused-\(running)")
            if running { _ = try XCTUnwrap(store.claimNextJob()) }
            try store.requestJobPause(id: job.id)
            let before = try store.job(id: job.id)
            XCTAssertEqual(before.pauseReason, "user-requested")

            XCTAssertEqual(try store.resumeLowPowerPausedJobs(now: Date()), 0)
            XCTAssertEqual(try store.job(id: job.id), before)
        }
    }

    func testRunningSmartInboxPauseAcknowledgementPreservesPreparedWorkAndCatalogSnapshot() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "running")
        let claimed = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [.init(ordinal: 0, messageID: "pause-message-running", sourceFingerprint: "pause-running-fingerprint")]
        )
        let summaryBefore = try store.smartInboxWorkSummary(jobID: job.id)
        let snapshotBefore = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: job.id))
        let preparedWorkCountBefore = try queryInteger(
            "SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = '\(job.id)'",
            at: url
        )
        let catalogSnapshotCountBefore = try queryInteger(
            "SELECT COUNT(*) FROM smart_inbox_label_catalog_snapshots WHERE job_id = '\(job.id)'",
            at: url
        )
        let runningBeforePause = try store.job(id: job.id)

        try store.requestJobPause(id: job.id)
        let pauseRequested = try store.job(id: job.id)
        XCTAssertEqual(pauseRequested.state, .running)
        XCTAssertTrue(pauseRequested.pauseRequested)
        XCTAssertEqual(pauseRequested.leaseToken, leaseToken)
        XCTAssertEqual(pauseRequested.attempt, runningBeforePause.attempt)
        XCTAssertEqual(pauseRequested.pauseReason, "user-requested")
        XCTAssertEqual(pauseRequested.progress, runningBeforePause.progress)

        XCTAssertThrowsError(
            try store.acknowledgeJobPause(
                id: job.id,
                leaseToken: "wrong-lease",
                progress: .init(current: 1, total: 1, phase: "paused", label: "Smart Inbox")
            )
        )
        try store.acknowledgeJobPause(
            id: job.id,
            leaseToken: leaseToken,
            progress: .init(current: 1, total: 1, phase: "paused", label: "Smart Inbox")
        )
        let acknowledged = try store.job(id: job.id)
        XCTAssertEqual(acknowledged.state, .paused)
        XCTAssertFalse(acknowledged.pauseRequested)
        XCTAssertEqual(acknowledged.pauseReason, "user-requested")
        XCTAssertEqual(acknowledged.attempt, runningBeforePause.attempt)
        XCTAssertEqual(
            acknowledged.progress,
            .init(current: 1, total: 1, phase: "paused", label: "Smart Inbox")
        )
        XCTAssertNil(acknowledged.leaseToken)
        XCTAssertNil(acknowledged.leaseExpiresAt)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: job.id), summaryBefore)
        XCTAssertEqual(try store.smartInboxLabelCatalogSnapshot(jobID: job.id), snapshotBefore)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = '\(job.id)'",
                at: url
            ),
            preparedWorkCountBefore
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_label_catalog_snapshots WHERE job_id = '\(job.id)'",
                at: url
            ),
            catalogSnapshotCountBefore
        )

        try store.resumeUserPausedJob(id: job.id, now: Date(timeIntervalSince1970: 1_752_000_001))
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: job.id), summaryBefore)
        XCTAssertEqual(try store.smartInboxLabelCatalogSnapshot(jobID: job.id), snapshotBefore)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = '\(job.id)'",
                at: url
            ),
            preparedWorkCountBefore
        )
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM smart_inbox_label_catalog_snapshots WHERE job_id = '\(job.id)'",
                at: url
            ),
            catalogSnapshotCountBefore
        )
    }

    func testManualResumeRestoresTheConsumedAttemptExactlyOnce() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "single-attempt-resume-\(UUID().uuidString)"
        )
        let job = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                maxAttempts: 1,
                idempotencyKey: "single-attempt-resume-\(UUID().uuidString)"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(running.leaseToken)
        XCTAssertEqual(running.attempt, 1)
        XCTAssertEqual(running.maxAttempts, 1)

        try store.requestJobPause(id: job.id)
        try store.acknowledgeJobPause(
            id: job.id,
            leaseToken: leaseToken,
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        let paused = try store.job(id: job.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.attempt, 1)

        let resumeAt = Date()
        try store.resumeUserPausedJob(id: job.id, now: resumeAt)
        let resumed = try store.job(id: job.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertEqual(resumed.attempt, 0)

        try store.resumeUserPausedJob(id: job.id, now: resumeAt)
        XCTAssertEqual(try store.job(id: job.id), resumed)

        let resumedClaim = try XCTUnwrap(store.claimNextJob(now: resumeAt, leaseDuration: 30))
        XCTAssertEqual(resumedClaim.id, job.id)
        XCTAssertEqual(resumedClaim.attempt, paused.attempt)
        XCTAssertEqual(resumedClaim.maxAttempts, 1)
        try store.completeJob(
            id: job.id,
            leaseToken: try XCTUnwrap(resumedClaim.leaseToken),
            resultArtifactID: nil
        )
        let completed = try store.job(id: job.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.attempt, paused.attempt)
    }

    func testQueuedRepauseAfterRunningPauseDoesNotRestoreAttemptTwice() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "queued-repause-\(UUID().uuidString)"
        )
        let job = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                maxAttempts: 2,
                idempotencyKey: "queued-repause-\(UUID().uuidString)"
            )
        )

        try store.requestJobPause(id: job.id)
        let initialQueuedPause = try store.job(id: job.id)
        XCTAssertEqual(initialQueuedPause.state, .paused)
        XCTAssertEqual(initialQueuedPause.pauseReason, "user-requested")
        XCTAssertEqual(initialQueuedPause.attempt, 0)
        try store.resumeUserPausedJob(id: job.id, now: Date())

        let firstClaim = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(firstClaim.attempt, 1)
        try store.failJob(
            id: job.id,
            leaseToken: try XCTUnwrap(firstClaim.leaseToken),
            code: "RETRY",
            message: "Reach the second attempt",
            retryAt: Date()
        )
        let secondClaim = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(secondClaim.attempt, 2)

        try store.requestJobPause(id: job.id)
        try store.acknowledgeJobPause(
            id: job.id,
            leaseToken: try XCTUnwrap(secondClaim.leaseToken),
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        let runningOriginPause = try store.job(id: job.id)
        XCTAssertEqual(runningOriginPause.state, .paused)
        XCTAssertEqual(runningOriginPause.attempt, 2)

        try store.resumeUserPausedJob(id: job.id, now: Date())
        XCTAssertEqual(try store.job(id: job.id).attempt, 1)
        try store.requestJobPause(id: job.id)
        let queuedRepause = try store.job(id: job.id)
        XCTAssertEqual(queuedRepause.state, .paused)
        XCTAssertEqual(queuedRepause.pauseReason, "user-requested")
        XCTAssertEqual(queuedRepause.attempt, 1)
        try store.resumeUserPausedJob(id: job.id, now: Date())
        XCTAssertEqual(try store.job(id: job.id).attempt, 1)

        let resumedClaim = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(resumedClaim.id, job.id)
        XCTAssertEqual(resumedClaim.attempt, runningOriginPause.attempt)
        try store.completeJob(
            id: job.id,
            leaseToken: try XCTUnwrap(resumedClaim.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.job(id: job.id).attempt, 2)
    }

    func testPauseAcknowledgementRequiresPersistedPauseRequestAndCancellationStaysRunning() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try enqueueSmartInboxPauseJob(store: store, suffix: "ack-precondition")
        let claimed = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let progress = PlainpostOperationProgress(current: 0, total: 1, phase: "paused", label: "Smart Inbox")

        XCTAssertThrowsError(try store.acknowledgeJobPause(id: job.id, leaseToken: leaseToken, progress: progress))

        try store.requestJobPause(id: job.id)
        try store.requestJobCancellation(id: job.id)
        let cancellationRequested = try store.job(id: job.id)
        XCTAssertEqual(cancellationRequested.state, .running)
        XCTAssertTrue(cancellationRequested.cancellationRequested)
        XCTAssertTrue(cancellationRequested.pauseRequested)
        XCTAssertEqual(cancellationRequested.leaseToken, leaseToken)
        XCTAssertThrowsError(try store.acknowledgeJobPause(id: job.id, leaseToken: leaseToken, progress: progress))
    }

    func testPeerCompletionBetweenCancellationRequestAndUpdateCannotMutateTerminalJob() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let peer = try migratedStore(at: url)
        let peerCompletion = LockedThrowingAction()
        let requester = try SQLiteMailStore(
            path: url.path,
            busyTimeout: 5,
            onTransientContention: nil,
            onJobCancellationBeforeUpdate: {
                try peerCompletion.run()
            }
        )
        try requester.migrate()
        let job = try requester.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            idempotencyKey: "terminal-cancellation-peer-race"
        ))
        let claimed = try XCTUnwrap(requester.claimNextJob())
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        peerCompletion.set {
            try peer.completeJob(id: job.id, leaseToken: leaseToken, resultArtifactID: nil)
        }

        try requester.requestJobCancellation(id: job.id)

        let terminal = try requester.job(id: job.id)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertFalse(terminal.cancellationRequested)
        XCTAssertNil(terminal.leaseToken)
    }

    func testUserPauseRejectsSchedulerPausedTerminalAndNonSmartInboxJobs() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try cacheOwnedMessage(
            MessageSummary(
                id: MessageID("message-non-smart-inbox"),
                threadID: ThreadID("thread-non-smart-inbox"),
                from: EmailAddress("sender@example.com"),
                subject: "Pause fixture",
                preview: "Pause fixture",
                smartCategory: .unknown
            ),
            store: store,
            uid: 9_202
        )

        let schedulerPaused = try enqueueSmartInboxPauseJob(store: store, suffix: "scheduler-paused")
        let schedulerLease = try XCTUnwrap(try store.claimNextJob()?.leaseToken)
        try store.pauseJob(
            id: schedulerPaused.id,
            leaseToken: schedulerLease,
            reason: "scheduler-preempted",
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        XCTAssertThrowsError(try store.requestJobPause(id: schedulerPaused.id))
        XCTAssertThrowsError(try store.resumeUserPausedJob(id: schedulerPaused.id, now: Date()))

        let terminal = try enqueueSmartInboxPauseJob(store: store, suffix: "terminal")
        let terminalLease = try XCTUnwrap(try store.claimNextJob()?.leaseToken)
        try store.completeJob(id: terminal.id, leaseToken: terminalLease, resultArtifactID: nil)
        XCTAssertThrowsError(try store.requestJobPause(id: terminal.id))
        XCTAssertThrowsError(try store.resumeUserPausedJob(id: terminal.id, now: Date()))

        let nonSmartInboxInput = PlainpostAIOperationInput(
            operation: .summarizeMessage,
            recordID: "message-non-smart-inbox",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "deterministic"
        )
        let nonSmartInbox = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(nonSmartInboxInput), as: UTF8.self),
                idempotencyKey: "non-smart-inbox-pause-\(UUID().uuidString)"
            )
        )
        XCTAssertThrowsError(try store.requestJobPause(id: nonSmartInbox.id))
    }

    func testRecordSmartInboxClassificationCheckpointsUntilAtomicApply() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let providerID = "apple-foundation-models"
        let modelID = "system-language-model"
        let discriminator = SmartInboxClassifierContract.discriminator(
            providerID: providerID,
            modelID: modelID
        )
        let message = MessageSummary(
            id: MessageID("msg_enriched_result"),
            threadID: ThreadID("thr_enriched_result"),
            from: EmailAddress("urgent@example.com"),
            fromDisplayName: "Urgent Sender",
            subject: "Action needed",
            preview: "Please respond today",
            smartCategory: .unknown
        )
        try cacheOwnedMessage(message, store: store, uid: 2_986)
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "enriched-result-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [
                PlainpostSmartInboxWorkSeed(
                    ordinal: 0,
                    messageID: message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: discriminator
                    )
                )
            ]
        )
        let classification = SmartInboxClassification(
            messageID: message.id,
            category: .personal,
            priority: .high,
            requiresAction: true,
            confidence: 0.91
        )

        let summary = try store.recordSmartInboxClassification(
            jobID: job.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: classification,
            providerID: providerID,
            modelID: modelID,
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(
            summary,
            PlainpostSmartInboxWorkSummary(
                total: 1,
                processed: 1,
                categorized: 0,
                unchanged: 0,
                failed: 0
            )
        )
        XCTAssertEqual(
            try queryInteger(
                """
                SELECT COUNT(*) FROM smart_inbox_work_items
                WHERE job_id = '\(job.id)' AND ordinal = 0 AND state = 'completed'
                  AND category = 'personal' AND priority = 'high'
                  AND requires_action = 1 AND confidence = 0.91
                """,
                at: url
            ),
            1
        )
        XCTAssertNil(try store.smartInboxClassificationCache()[message.id])
        XCTAssertEqual(
            try XCTUnwrap(store.smartInboxListMessages().first).smartCategory,
            .unknown
        )
        try executeSQL(
            """
            CREATE TRIGGER retain_smart_inbox_reconcile_audit_for_test
            BEFORE DELETE ON audit_entries
            BEGIN
                SELECT RAISE(ABORT, 'retain smart inbox audit for inspection');
            END;
            """,
            at: url
        )

        let applied = try store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        XCTAssertEqual(applied.categorized, 1)
        XCTAssertEqual(applied.unchanged, 0)
        let cache = try XCTUnwrap(store.smartInboxClassificationCache()[message.id])
        XCTAssertEqual(
            cache.sourceFingerprint,
            SmartInboxClassificationFingerprint.message(
                classificationInput,
                classifierDiscriminator: discriminator
            )
        )
        XCTAssertEqual(cache.category, .personal)
        XCTAssertEqual(cache.priority, .high)
        XCTAssertTrue(cache.requiresAction)
        XCTAssertEqual(cache.confidence, 0.91)
        XCTAssertEqual(cache.providerID, providerID)
        XCTAssertEqual(cache.modelID, modelID)
        let projected = try XCTUnwrap(store.smartInboxListMessages().first)
        XCTAssertEqual(projected.smartCategory, .personal)
        XCTAssertEqual(projected.smartPriority, .high)
        XCTAssertTrue(projected.smartRequiresAction)
        XCTAssertEqual(projected.smartConfidence, 0.91)
        XCTAssertEqual(
            store.auditEntries.filter { $0.targetID == message.id.rawValue }.map(\.action),
            ["smart_inbox.reconcile"]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM audit_entries WHERE action = 'smart_inbox.reconcile' AND target_id = '\(message.id.rawValue)'",
                at: url
            ),
            ["shared:<nil>"]
        )
        try executeSQL("DROP TRIGGER retain_smart_inbox_reconcile_audit_for_test;", at: url)
    }

    func testSmartInboxListMessagesDecodesEnrichedFieldsWithoutReadingBody() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_body_free_triage"),
                threadID: nil,
                from: EmailAddress("body-free@example.com"),
                subject: "Metadata only",
                preview: "No body read",
                body: "must not be selected",
                smartCategory: .newsletter
            )
        )
        try executeSQL(
            """
            UPDATE messages
            SET body_text = x'FF', smart_priority = 'low', smart_requires_action = 1,
                smart_confidence = 0.42
            WHERE id = 'msg_body_free_triage';
            """,
            at: url
        )

        let projected = try XCTUnwrap(store.smartInboxListMessages().first)

        XCTAssertEqual(projected.smartPriority, .low)
        XCTAssertTrue(projected.smartRequiresAction)
        XCTAssertEqual(projected.smartConfidence, 0.42)
    }

    func testNextSmartInboxWorkItemsReturnsOrderedBoundedPendingItems() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "ordered-batch-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        for ordinal in 0..<6 {
            try cacheOwnedMessage(
                MessageSummary(
                    id: MessageID("msg_ordered_\(ordinal)"),
                    threadID: nil,
                    from: EmailAddress("ordered-\(ordinal)@example.com"),
                    subject: "Ordered \(ordinal)",
                    preview: "Ordered Smart Inbox work fixture",
                    smartCategory: .unknown
                ),
                store: store,
                uid: 3_143 + ordinal
            )
        }
        let seeds = (0..<6).map { ordinal in
            PlainpostSmartInboxWorkSeed(
                ordinal: ordinal,
                messageID: "msg_ordered_\(ordinal)",
                sourceFingerprint: "fingerprint_\(ordinal)"
            )
        }
        try store.prepareSmartInboxWork(jobID: job.id, leaseToken: leaseToken, seeds: seeds)

        let items = try store.nextSmartInboxWorkItems(jobID: job.id, leaseToken: leaseToken, limit: 4)

        XCTAssertEqual(items.map(\.ordinal), [0, 1, 2, 3])
        XCTAssertThrowsError(
            try store.nextSmartInboxWorkItems(jobID: job.id, leaseToken: leaseToken, limit: 0)
        ) { error in
            guard case .validationFailed = error as? PlainpostError else {
                return XCTFail("Expected a validation failure, got \(error)")
            }
        }
    }

    func testSmartInboxBatchProfileRoundTripsByFullClassifierIdentity() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let discriminator = SmartInboxClassifierContract.discriminator(
            providerID: "apple-foundation-models",
            modelID: "system-language-model"
        )
        let profile = SmartInboxBatchProfile(
            providerID: "apple-foundation-models",
            modelID: "system-language-model",
            classifierDiscriminator: discriminator,
            maxMessageCount: 24,
            maxPromptCharacters: 48_000,
            memoryCeilingBytes: 1_500_000_000,
            benchmarkedAt: Date(timeIntervalSince1970: 1_753_200_000)
        )

        try store.saveSmartInboxBatchProfile(profile)

        XCTAssertEqual(
            try store.smartInboxBatchProfile(
                providerID: profile.providerID,
                modelID: profile.modelID,
                classifierDiscriminator: profile.classifierDiscriminator
            ),
            profile
        )
        XCTAssertNil(
            try store.smartInboxBatchProfile(
                providerID: profile.providerID,
                modelID: profile.modelID,
                classifierDiscriminator: "\(profile.classifierDiscriminator):prompt-next"
            )
        )
    }

    func testSmartInboxBatchProfileCreatesOnlyItsOwnSchemaInFreshDatabase() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let profile = SmartInboxBatchProfile(
            providerID: "foundation",
            modelID: "apple-foundation-system",
            classifierDiscriminator: "foundation:apple-foundation-system:contract",
            maxMessageCount: 1,
            maxPromptCharacters: 8_000,
            memoryCeilingBytes: 1_073_741_824,
            benchmarkedAt: Date(timeIntervalSince1970: 1_753_200_000)
        )

        try store.saveSmartInboxBatchProfile(profile)

        XCTAssertEqual(
            try queryStrings(
                "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
                at: url
            ),
            ["smart_inbox_batch_profiles"]
        )
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_batch_profiles", at: url),
            1
        )
        XCTAssertEqual(
            try store.smartInboxBatchProfile(
                providerID: profile.providerID,
                modelID: profile.modelID,
                classifierDiscriminator: profile.classifierDiscriminator
            ),
            profile
        )
    }

    func testLegacySmartInboxCacheRowsDecodeNeutralEnrichedDefaults() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try migratedStore(at: url)
            try store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_legacy_cache"),
                    threadID: nil,
                    from: EmailAddress("cache@example.com"),
                    subject: "Legacy cache",
                    preview: "Before enriched results",
                    smartCategory: .notification
                )
            )
        }
        try executeSQL(
            """
            ALTER TABLE smart_inbox_classification_cache DROP COLUMN priority;
            ALTER TABLE smart_inbox_classification_cache DROP COLUMN requires_action;
            ALTER TABLE smart_inbox_classification_cache DROP COLUMN confidence;
            INSERT INTO smart_inbox_classification_cache (
                message_id, source_fingerprint, category, provider_id, model_id, classified_at, updated_at
            ) VALUES (
                'msg_legacy_cache', 'legacy-fingerprint', 'notification', 'legacy-provider', NULL, 123, 123
            );
            DELETE FROM grdb_migrations WHERE identifier = 'v26_smart_inbox_triage';
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)
        let cached = try XCTUnwrap(migrated.smartInboxClassificationCache()[MessageID("msg_legacy_cache")])

        XCTAssertEqual(cached.priority, .normal)
        XCTAssertFalse(cached.requiresAction)
        XCTAssertNil(cached.confidence)
    }

    func testEmptySmartInboxPreparationSurvivesResumeAndMailboxChanges() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "empty-smart-inbox-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let firstLease = try XCTUnwrap(claimed.leaseToken)
        try store.prepareSmartInboxWork(jobID: job.id, leaseToken: firstLease, seeds: [])
        try store.pauseJob(
            id: job.id,
            leaseToken: firstLease,
            reason: "test-preemption",
            progress: .init(current: 0, total: 0, phase: "paused", label: "Smart Inbox")
        )

        let laterMessage = MessageSummary(
            id: MessageID("msg_later"),
            threadID: ThreadID("thr_later"),
            from: EmailAddress("later@example.com"),
            subject: "Later",
            preview: "Arrived after the empty snapshot",
            smartCategory: .unknown
        )
        try store.cacheMessage(laterMessage)
        let resumed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let resumedLease = try XCTUnwrap(resumed.leaseToken)
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: resumedLease,
            seeds: [
                PlainpostSmartInboxWorkSeed(
                    ordinal: 0,
                    messageID: laterMessage.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(laterMessage)
                )
            ]
        )

        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: job.id).total, 0)
        XCTAssertNil(try store.nextSmartInboxWorkItem(jobID: job.id, leaseToken: resumedLease))
    }

    func testSmartInboxPreparationMarkerCascadesWithJobCleanup() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "smart-inbox-marker-cascade-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.prepareSmartInboxWork(jobID: job.id, leaseToken: leaseToken, seeds: [])
        try store.completeJob(id: job.id, leaseToken: leaseToken, resultArtifactID: nil)

        try store.pruneTerminalJobs(before: Date().addingTimeInterval(1))

        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_preparations", at: url),
            0
        )
    }

    func testMessageReplyAncestryRoundTripsThroughSQLite() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let message = MessageSummary(
            id: MessageID("msg_threaded"),
            threadID: ThreadID("thr_project"),
            from: EmailAddress("alice@example.com"),
            fromDisplayName: "Alice",
            subject: "Re: Project update",
            preview: "Latest reply",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Latest reply",
            sentAt: Date(timeIntervalSince1970: 123),
            rfcMessageID: "<reply@example.com>",
            inReplyTo: "<root@example.com>",
            references: ["<root@example.com>"],
            replyTo: EmailAddress("project@example.com"),
            to: [EmailAddress("me@example.com")],
            cc: [EmailAddress("team@example.com")]
        )

        try store.cacheMessageReliably(message)

        let reloaded = try XCTUnwrap(store.messages.first { $0.id == message.id })
        XCTAssertEqual(reloaded, message)
    }

    func testAuditOutboxDrainsToSecureHumanReadableLog() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }

        _ = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)

        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM audit_entries", at: url), 0)
        let contents = try String(contentsOf: store.auditLogURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"action\":\"draft.create\""))
        XCTAssertTrue(contents.contains("\"occurredAt\":"))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.auditLogURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let reopened = try migratedStore(at: url)
        XCTAssertEqual(reopened.auditEntries.map(\.action), ["draft.create"])
    }

    // Troubleshooting's "Last sync": the newest error-free mailbox update of the selected
    // account, or of every cached account, in one query.
    func testLastSuccessfulMailboxSyncIsScopedAndIgnoresFailuresAndUncachedAccounts() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let first = PlainpostFixtures.personalAccount
        let second = Account(
            id: AccountID("last-sync-second"), displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([first, second])
        XCTAssertNil(try store.lastSuccessfulMailboxSyncAt())
        try executeSQL(
            """
            INSERT INTO mailbox_sync_state (account_id, mailbox_path, last_error, updated_at) VALUES
                ('\(first.id.rawValue)', 'INBOX', NULL, 100),
                ('\(first.id.rawValue)', 'Archive', 'boom', 300),
                ('\(second.id.rawValue)', 'INBOX', NULL, 200),
                ('removed-account', 'INBOX', NULL, 900);
            """,
            at: url
        )

        XCTAssertEqual(try store.lastSuccessfulMailboxSyncAt(accountID: first.id), Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.lastSuccessfulMailboxSyncAt(), Date(timeIntervalSince1970: 200))
        XCTAssertNil(try store.lastSuccessfulMailboxSyncAt(accountID: AccountID("removed-account")))
    }

    func testRecentAuditEntriesForDirectAccountFilterBeforeLimitAcrossRotatedAndPendingRecords() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }

        let selected = PlainpostFixtures.personalAccount
        let other = Account(
            id: AccountID("audit-other-account"), displayName: "Other",
            email: EmailAddress("other@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([selected, other])
        for account in [selected, other] {
            _ = try store.replaceMailSource(
                AccountMailSource(
                    accountID: account.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }

        let log = try RotatingAuditLog(
            databaseURL: url, maximumFileBytes: 1_024, archiveCount: 4
        )
        func record(_ id: String, owner: AccountID?) -> PersistedAuditRecord {
            PersistedAuditRecord(
                entry: AuditEntry(
                    id: id, actorID: "local-user", action: "mail.activity",
                    targetType: "account", targetID: String(repeating: "x", count: 360), result: "ok"
                ),
                occurredAt: Date(timeIntervalSince1970: 1),
                ownerAccountID: owner?.rawValue
            )
        }

        try log.drain(load: { [record("aud-selected-rotated", owner: selected.id)] }, didPersist: { _ in })
        for index in 0..<2 {
            try log.drain(
                load: { [record("aud-foreign-rotated-\(index)", owner: other.id)] },
                didPersist: { _ in }
            )
        }
        try log.drain(load: { [record("aud-selected-current", owner: selected.id)] }, didPersist: { _ in })

        try executeSQL(
            """
            INSERT INTO audit_entries
                (id, actor_id, action, target_type, target_id, result, occurred_at,
                 owner_account_id, ownership_kind)
            VALUES
                ('aud-selected-pending', 'local-user', 'mail.activity', 'account', 'selected', 'ok', 2,
                 '\(selected.id.rawValue)', 'account'),
                ('aud-other-pending', 'local-user', 'mail.activity', 'account', 'other', 'ok', 3,
                 '\(other.id.rawValue)', 'account'),
                ('aud-global-pending', 'local-user', 'mail.activity', 'runtime', 'global', 'ok', 4,
                 NULL, 'global');
            """,
            at: url
        )

        let entries = try store.recentAuditEntries(
            limit: 3, accountID: selected.id, sourceGeneration: 1
        )
        XCTAssertEqual(
            Set(entries.map(\.id)),
            Set(["aud-selected-pending", "aud-selected-current", "aud-selected-rotated"])
        )
        XCTAssertEqual(entries.count, 3)

        // The export's query keeps each entry's own time from both the file log and
        // the pending SQLite rows, under the same account filter.
        let timestamped = try store.recentTimestampedAuditEntries(
            limit: 3, accountID: selected.id, sourceGeneration: 1
        )
        XCTAssertEqual(timestamped.map(\.entry), entries)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: timestamped.map { ($0.entry.id, $0.occurredAt) }),
            [
                "aud-selected-pending": Date(timeIntervalSince1970: 2),
                "aud-selected-current": Date(timeIntervalSince1970: 1),
                "aud-selected-rotated": Date(timeIntervalSince1970: 1),
            ]
        )

        let source = try store.mailSource(accountID: selected.id)
        _ = try store.replaceMailSource(
            source.nodeBacked(
                nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: selected.email.rawValue
            ), expectedGeneration: source.generation
        )
        XCTAssertThrowsError(try store.recentAuditEntries(
            limit: 3, accountID: selected.id, sourceGeneration: 1
        ))
    }

    func testMigrationExportsLegacyAuditRowsAndClearsOutbox() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        try executeSQL(
            """
            INSERT INTO audit_entries (id, actor_id, action, target_type, target_id, result, occurred_at)
            VALUES ('aud_legacy', 'local-user', 'draft.create', 'draft', 'drf_legacy', 'ok', NULL);
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)

        XCTAssertEqual(migrated.auditEntries.map(\.id), ["aud_legacy"])
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM audit_entries", at: url), 0)
        let contents = try String(contentsOf: migrated.auditLogURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"occurredAt\":null"))
    }

    func testMigrationDrainsLargeLegacyOutboxInBoundedBatches() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let values = (0..<1_200).map { index in
            "('aud_legacy_\(index)', 'local-user', 'category.change', 'message', 'msg_\(index)', 'ok', NULL)"
        }.joined(separator: ",")
        try executeSQL(
            "INSERT INTO audit_entries (id, actor_id, action, target_type, target_id, result, occurred_at) VALUES \(values);",
            at: url
        )

        let migrated = try migratedStore(at: url)

        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM audit_entries", at: url), 0)
        XCTAssertEqual(migrated.auditEntries.count, 1_200)
    }

    func testAuditLogRotationBoundsFilesAndRetainsReadableRecords() throws {
        let url = temporarySQLiteURL()
        let log = try RotatingAuditLog(databaseURL: url, maximumFileBytes: 1_024, archiveCount: 2)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }

        for batch in 0..<8 {
            let records = (0..<4).map { index in
                PersistedAuditRecord(
                    entry: AuditEntry(
                        id: "aud_\(batch)_\(index)",
                        actorID: "local-user",
                        action: "category.change",
                        targetType: "message",
                        targetID: "msg_\(String(repeating: "x", count: 80))_\(batch)_\(index)",
                        result: "ok"
                    ),
                    occurredAt: Date(timeIntervalSince1970: Double(batch))
                )
            }
            try log.drain(load: { records }, didPersist: { _ in })
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(log.fileURL.path).1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(log.fileURL.path).2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(log.fileURL.path).3"))
        XCTAssertFalse(try log.entries().isEmpty)
    }

    func testAuditLogRepairsIncompleteTailBeforeOutboxRetry() throws {
        let url = temporarySQLiteURL()
        let log = try RotatingAuditLog(databaseURL: url, maximumFileBytes: 4_096, archiveCount: 1)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        try Data("{\"partial\":".utf8).write(to: log.fileURL)
        let record = PersistedAuditRecord(
            entry: AuditEntry(
                id: "aud_retry",
                actorID: "local-user",
                action: "send.request",
                targetType: "send_request",
                targetID: "srq_retry",
                result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 1)
        )

        try log.drain(load: { [record] }, didPersist: { _ in })

        XCTAssertEqual(try log.entries().map(\.id), ["aud_retry"])
        let lines = try Data(contentsOf: log.fileURL).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
    }

    func testAuditLogFilteringRestoresAllRecordsWhenPurgeClosureFails() throws {
        let url = temporarySQLiteURL()
        let log = try RotatingAuditLog(databaseURL: url, maximumFileBytes: 1_024, archiveCount: 4)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        let target = PersistedAuditRecord(
            entry: AuditEntry(
                id: "aud-delete-target", actorID: "local-user", action: "draft.create",
                targetType: "account", targetID: "acc-delete-target", result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        let retained = PersistedAuditRecord(
            entry: AuditEntry(
                id: "aud-retained", actorID: "local-user", action: "draft.create",
                targetType: "account", targetID: "acc-retained", result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 2)
        )
        for record in [target, retained] + auditFixtureFillers() {
            try log.drain(load: { [record] }, didPersist: { _ in })
        }
        let original = try log.entries()

        XCTAssertThrowsError(
            try log.withRecordsRemoved(
                where: { $0.targetID == "acc-delete-target" },
                perform: { throw PlainpostError.validationFailed("Injected database failure.") }
            )
        )

        XCTAssertEqual(try log.entries(), original)
    }

    func testAuditLogFilteringRestoresAllRecordsWhenRewriteFails() throws {
        let url = temporarySQLiteURL()
        var rewriteAttempt = 0
        let log = try RotatingAuditLog(
            databaseURL: url,
            maximumFileBytes: 1_024,
            archiveCount: 1,
            onBeforeRewrite: {
                rewriteAttempt += 1
                guard rewriteAttempt == 2 else { return }
                throw PlainpostError.validationFailed("Injected audit rewrite failure.")
            }
        )
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        let target = PersistedAuditRecord(
            entry: AuditEntry(
                id: "aud-delete-target", actorID: "local-user", action: "draft.create",
                targetType: "account", targetID: "acc-delete-target", result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        let retained = PersistedAuditRecord(
            entry: AuditEntry(
                id: "aud-retained", actorID: "local-user", action: "draft.create",
                targetType: "account", targetID: "acc-retained", result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 2)
        )
        for record in [target, retained] + auditFixtureFillers() {
            try log.drain(load: { [record] }, didPersist: { _ in })
        }
        let original = try log.entries()

        XCTAssertThrowsError(
            try log.withRecordsRemoved(
                where: { $0.targetID == "acc-delete-target" },
                perform: { () }
            )
        )

        XCTAssertEqual(try log.entries(), original)
    }

    func testAuditLogCleansPartialSnapshotsWhenSnapshotCreationFails() throws {
        let url = temporarySQLiteURL()
        var snapshotAttempt = 0
        let log = try RotatingAuditLog(
            databaseURL: url,
            maximumFileBytes: 1_024,
            archiveCount: 2,
            onBeforeSnapshot: {
                snapshotAttempt += 1
                if snapshotAttempt == 2 {
                    throw PlainpostError.validationFailed("Injected snapshot failure.")
                }
            }
        )
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        for record in auditFixtureFillers() {
            try log.drain(load: { [record] }, didPersist: { _ in })
        }
        let original = try log.entries()

        XCTAssertThrowsError(
            try log.withRecordsRemoved(where: { _ in false }, perform: { () })
        )

        XCTAssertEqual(try log.entries(), original)
        XCTAssertTrue(try auditTemporarySiblingNames(log.fileURL).isEmpty)
    }

    func testAuditLogRestoresAndRemovesSnapshotsWhenDisposalFails() throws {
        let url = temporarySQLiteURL()
        var shouldFailDisposal = true
        let log = try RotatingAuditLog(
            databaseURL: url,
            maximumFileBytes: 1_024,
            archiveCount: 2,
            onBeforeSnapshotDiscard: {
                if shouldFailDisposal {
                    shouldFailDisposal = false
                    throw PlainpostError.validationFailed("Injected snapshot disposal failure.")
                }
            }
        )
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        for record in auditFixtureFillers() {
            try log.drain(load: { [record] }, didPersist: { _ in })
        }
        let original = try log.entries()

        XCTAssertThrowsError(
            try log.withRecordsRemoved(where: { $0.id == "aud-filler-0" }, perform: { () })
        )

        XCTAssertEqual(try log.entries(), original)
        XCTAssertTrue(try auditTemporarySiblingNames(log.fileURL).isEmpty)
    }

    func testAuditLogRestoresFromMemoryWhenCompanionCommitFailsAfterFinalization() throws {
        let url = temporarySQLiteURL()
        let log = try RotatingAuditLog(databaseURL: url, maximumFileBytes: 1_024, archiveCount: 2)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: log.fileURL) }
        for record in auditFixtureFillers() {
            try log.drain(load: { [record] }, didPersist: { _ in })
        }
        let original = try log.entries()

        XCTAssertThrowsError(
            try log.withRecordTransaction { removeRecords, finalize in
                try removeRecords { $0.id == "aud-filler-0" }
                try finalize()
                throw PlainpostError.validationFailed("Injected companion commit failure.")
            }
        )

        XCTAssertEqual(try log.entries(), original)
        XCTAssertTrue(try auditTemporarySiblingNames(log.fileURL).isEmpty)
    }

    func testAuditLogRemovesInterruptedHiddenSnapshotsUnderLock() throws {
        let url = temporarySQLiteURL()
        let initial = try RotatingAuditLog(databaseURL: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.fileURL) }
        let staleSnapshot = initial.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(initial.fileURL.lastPathComponent).snapshot.interrupted")
        try Data("sensitive stale snapshot".utf8).write(to: staleSnapshot)

        let reopened = try RotatingAuditLog(databaseURL: url)
        _ = try reopened.entries()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSnapshot.path))
        XCTAssertTrue(try auditTemporarySiblingNames(reopened.fileURL).isEmpty)
    }

    func testAccountDeletionAuditRedactionUsesOnlyAcceptedExplicitOwnerIDs() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO audit_entries (
                id, actor_id, action, target_type, target_id, result, occurred_at,
                owner_account_id, ownership_kind
            ) VALUES (
                'audit-shared-payload-target', 'local-user', 'fixture.shared', 'diagnostic',
                'global-diagnostic', '{"accountID":"acc-delete-target"}', 2, NULL, 'shared'
            );
            """,
            at: url
        )
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()

        try store.deleteAccountData(accountID: fixture.deleted.id)

        XCTAssertFalse(store.auditEntries.contains { $0.id == "audit-delete-target" })
        XCTAssertTrue(store.auditEntries.contains { $0.id == "audit-retained" })
        XCTAssertTrue(store.auditEntries.contains { $0.id == "audit-shared-payload-target" })
    }

    func testAuditRedactionJournalRecoveryPreservesAuditBeforeSQLiteCommit() throws {
        for phase in [
            AuditRedactionFailpoint.beforeJournalWrite,
            .afterJournalWrite,
        ] {
            let url = temporarySQLiteURL()
            let initial = try migratedStore(at: url)
            let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
            let flushed = try SQLiteMailStore(path: url.path)
            try flushed.migrate()
            let crashing = try SQLiteMailStore(
                path: url.path,
                auditRedactionFailpoint: { observed in
                    if observed == phase { throw SimulatedAuditRedactionCrash() }
                }
            )

            XCTAssertThrowsError(try crashing.deleteAccountData(accountID: fixture.deleted.id))

            let recovered = try SQLiteMailStore(path: url.path)
            try recovered.migrate()
            XCTAssertTrue(recovered.accounts.contains { $0.id == fixture.deleted.id })
            XCTAssertTrue(recovered.auditEntries.contains { $0.id == "audit-delete-target" })
            XCTAssertTrue(recovered.auditEntries.contains { $0.id == "audit-retained" })
            XCTAssertTrue(try auditRedactionJournalNames(recovered.auditLogURL).isEmpty)
            removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: recovered.auditLogURL)
        }
    }

    func testAuditRedactionJournalRecoveryFinishesCommittedDeletionAtEveryFilePhase() throws {
        for phase in [
            AuditRedactionFailpoint.afterSQLiteCommit,
            .beforeSegmentRename,
            .afterSegmentRename,
            .beforeJournalCleanup,
            .afterJournalCleanup,
        ] {
            let url = temporarySQLiteURL()
            let initial = try migratedStore(at: url)
            let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
            let flushed = try SQLiteMailStore(path: url.path)
            try flushed.migrate()
            let crashing = try SQLiteMailStore(
                path: url.path,
                auditRedactionFailpoint: { observed in
                    if observed == phase { throw SimulatedAuditRedactionCrash() }
                }
            )

            XCTAssertThrowsError(try crashing.deleteAccountData(accountID: fixture.deleted.id))

            let recovered = try SQLiteMailStore(path: url.path)
            try recovered.migrate()
            XCTAssertFalse(recovered.accounts.contains { $0.id == fixture.deleted.id })
            XCTAssertTrue(recovered.accounts.contains { $0.id == fixture.retained.id })
            XCTAssertFalse(recovered.auditEntries.contains { $0.id == "audit-delete-target" })
            XCTAssertTrue(recovered.auditEntries.contains { $0.id == "audit-retained" })
            XCTAssertTrue(try auditRedactionJournalNames(recovered.auditLogURL).isEmpty)
            try recovered.migrate()
            XCTAssertFalse(recovered.auditEntries.contains { $0.id == "audit-delete-target" })
            XCTAssertTrue(recovered.auditEntries.contains { $0.id == "audit-retained" })
            removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: recovered.auditLogURL)
        }
    }

    func testPostCommitAuditInterruptionKeepsCredentialsDeletedAndSurfacesCleanupPending() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        let flushed = try SQLiteMailStore(path: url.path)
        try flushed.migrate()
        let imapKey = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let vault = InMemoryCredentialVault(records: [
            imapKey: Data("imap-secret".utf8),
            smtpKey: Data("smtp-secret".utf8),
        ])
        let crashing = try SQLiteMailStore(
            path: url.path,
            auditRedactionFailpoint: { phase in
                if phase == .afterSQLiteCommit { throw SimulatedAuditRedactionCrash() }
            }
        )

        do {
            try await crashing.deleteAccountData(accountID: fixture.deleted.id, credentials: vault)
            XCTFail("A committed deletion with pending audit cleanup must surface its state.")
        } catch let error as AccountDeletionCleanupPendingError {
            XCTAssertEqual(error.accountID, fixture.deleted.id)
        }
        let deletedIMAP = try await vault.load(imapKey)
        let deletedSMTP = try await vault.load(smtpKey)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
        XCTAssertFalse(crashing.accounts.contains { $0.id == fixture.deleted.id })

        let recovered = try SQLiteMailStore(path: url.path)
        try recovered.migrate()
        XCTAssertFalse(recovered.auditEntries.contains { $0.id == "audit-delete-target" })
        XCTAssertTrue(recovered.auditEntries.contains { $0.id == "audit-retained" })
    }

    func testPostCommitAuditInterruptionEmitsCommittedDeletionSignalsExactlyOnce() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        let flushed = try SQLiteMailStore(path: url.path)
        try flushed.migrate()
        let recorder = MailStoreChangeScopeRecorder()
        let token = recorder.observe()
        defer { NotificationCenter.default.removeObserver(token) }
        let crashing = try SQLiteMailStore(
            path: url.path,
            auditRedactionFailpoint: { phase in
                if phase == .afterSQLiteCommit { throw SimulatedAuditRedactionCrash() }
            }
        )

        XCTAssertThrowsError(try crashing.deleteAccountData(accountID: fixture.deleted.id))

        XCTAssertEqual(recorder.snapshot(), [
            .accounts: 1,
            .mailbox: 1,
            .operations: 1,
        ])
    }

    func testPreCommitAuditInterruptionEmitsNoDeletionSignals() throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        let flushed = try SQLiteMailStore(path: url.path)
        try flushed.migrate()
        let recorder = MailStoreChangeScopeRecorder()
        let token = recorder.observe()
        defer { NotificationCenter.default.removeObserver(token) }
        let crashing = try SQLiteMailStore(
            path: url.path,
            auditRedactionFailpoint: { phase in
                if phase == .afterJournalWrite { throw SimulatedAuditRedactionCrash() }
            }
        )

        XCTAssertThrowsError(try crashing.deleteAccountData(accountID: fixture.deleted.id))

        XCTAssertEqual(recorder.snapshot(), [:])
    }

    func testPreCommitAuditInterruptionPreservesOriginalErrorWhenVaultCompensationFails() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        let flushed = try SQLiteMailStore(path: url.path)
        try flushed.migrate()
        let imapKey = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let vault = FailingCredentialRestorationVault(records: [
            imapKey: Data("imap-secret".utf8),
            smtpKey: Data("smtp-secret".utf8),
        ])
        let crashing = try SQLiteMailStore(
            path: url.path,
            auditRedactionFailpoint: { phase in
                if phase == .afterJournalWrite { throw SimulatedAuditRedactionCrash() }
            }
        )

        do {
            try await crashing.deleteAccountData(accountID: fixture.deleted.id, credentials: vault)
            XCTFail("Failed compensation must preserve both failure contexts.")
        } catch let error as AccountDeletionCompensationError {
            XCTAssertTrue(error.operationDescription.contains("SimulatedAuditRedactionCrash"))
            XCTAssertTrue(error.compensationDescription.contains("locked"))
        }
        XCTAssertTrue(crashing.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(crashing.auditEntries.contains { $0.id == "audit-delete-target" })
    }

    func testCredentialRemovalCrashIntentCompletesDeletionAfterRestartUnlock() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: url)
        let flushed = try SQLiteMailStore(path: url.path)
        try flushed.migrate()
        let provider = AccountDeletionAcceptanceVaultKeyProvider()
        let targetIMAP = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let targetSMTP = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let retainedIMAP = CredentialRecordKey(rawValue: "account:acc-retained:imap-password")
        let crashing = try SQLiteMailStore(
            path: url.path,
            accountDeletionFailpoint: { phase in
                if phase == .afterCredentialRemovalBeforeSQLiteCommit {
                    throw SimulatedCredentialDeletionCrash()
                }
            }
        )
        let crashingAssembly = SQLiteCredentialVaultAssembly(store: crashing, provider: provider)
        try await crashingAssembly.unlockForeground(prompt: "Crash deletion")
        try await crashingAssembly.vault.store(Data("target-imap-secret".utf8), for: targetIMAP)
        try await crashingAssembly.vault.store(Data("target-smtp-secret".utf8), for: targetSMTP)
        try await crashingAssembly.vault.store(Data("retained-imap-secret".utf8), for: retainedIMAP)

        do {
            try await crashing.deleteAccountData(
                accountID: fixture.deleted.id,
                credentials: crashingAssembly.vault
            )
            XCTFail("Expected the removal-before-commit crash failpoint.")
        } catch is SimulatedCredentialDeletionCrash {}

        XCTAssertTrue(crashing.accounts.contains { $0.id == fixture.deleted.id })
        let removedIMAP = try await crashingAssembly.vault.load(targetIMAP)
        let removedSMTP = try await crashingAssembly.vault.load(targetSMTP)
        XCTAssertNil(removedIMAP)
        XCTAssertNil(removedSMTP)
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM account_deletion_intents", at: url),
            1
        )
        let intentJSON = try XCTUnwrap(queryStrings(
            "SELECT credential_record_keys_json FROM account_deletion_intents",
            at: url
        ).first)
        XCTAssertFalse(intentJSON.contains("target-imap-secret"))
        XCTAssertFalse(intentJSON.contains("target-smtp-secret"))

        let restarted = try SQLiteMailStore(path: url.path)
        try restarted.migrate()
        let restartedAssembly = SQLiteCredentialVaultAssembly(store: restarted, provider: provider)
        try await restartedAssembly.unlockForeground(prompt: "Recover deletion")

        XCTAssertFalse(restarted.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(restarted.accounts.contains { $0.id == fixture.retained.id })
        let retainedSecret = try await restartedAssembly.vault.load(retainedIMAP)
        XCTAssertEqual(retainedSecret, Data("retained-imap-secret".utf8))
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM account_deletion_intents", at: url),
            0
        )

        let secondRestart = try SQLiteMailStore(path: url.path)
        try secondRestart.migrate()
        let secondAssembly = SQLiteCredentialVaultAssembly(store: secondRestart, provider: provider)
        try await secondAssembly.unlockForeground(prompt: "Verify idempotence")
        XCTAssertFalse(secondRestart.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(secondRestart.accounts.contains { $0.id == fixture.retained.id })
    }

    func testDirectDeletionRecoverySkipsPendingNodeIntentAndPreservesItsCredentials() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let node = Account(id: AccountID("pending-node"), displayName: "Node", email: EmailAddress("node@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let direct = Account(id: AccountID("active-direct"), displayName: "Direct", email: EmailAddress("direct@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        for account in [node, direct] {
            try initial.cacheAccountSetup(account: account, inbox: Mailbox(id: MailboxID("inbox-\(account.id.rawValue)"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"), source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1))
        }
        try initial.replaceMailSource(try initial.mailSource(accountID: node.id).nodeBacked(nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA", logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: node.email.rawValue), expectedGeneration: 1)
        let vault = InMemoryCredentialVault()
        let nodeKey = CredentialRecordKey(rawValue: "account:pending-node:imap-password")
        try await vault.store(Data("node-secret".utf8), for: nodeKey)
        let crashing = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            if phase == .afterCredentialRemovalBeforeSQLiteCommit { throw SimulatedCredentialDeletionCrash() }
        })
        do {
            try await crashing.deleteAccountData(accountID: node.id, credentials: vault)
            XCTFail("Expected interrupted legacy deletion")
        } catch is SimulatedCredentialDeletionCrash {}
        try await vault.store(Data("node-secret".utf8), for: nodeKey)

        let restarted = try migratedStore(at: url)
        try await restarted.recoverPendingDirectAccountDeletions(credentials: vault)

        XCTAssertEqual(Set(restarted.accounts.map(\.id)), Set([node.id, direct.id]))
        let retainedNodeKey = try await vault.load(nodeKey)
        XCTAssertEqual(retainedNodeKey, Data("node-secret".utf8))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM account_deletion_intents WHERE account_id = 'pending-node'", at: url), 1)
    }

    func testDirectDeletionRecoveryReplaysAllPersistedDirectIntents() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let accounts = ["direct-one", "direct-two"].map { id in
            Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        for account in accounts {
            try initial.cacheAccountSetup(account: account, inbox: Mailbox(id: MailboxID("inbox-\(account.id.rawValue)"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"), source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1))
        }
        let vault = InMemoryCredentialVault()
        let crashing = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            if phase == .afterCredentialRemovalBeforeSQLiteCommit { throw SimulatedCredentialDeletionCrash() }
        })
        for account in accounts {
            let key = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password")
            try await vault.store(Data("secret".utf8), for: key)
            do {
                try await crashing.deleteDirectAccountData(accountID: account.id, expectedSourceGeneration: 1, credentials: vault)
                XCTFail("Expected interrupted Direct deletion")
            } catch is SimulatedCredentialDeletionCrash {}
        }

        let restarted = try migratedStore(at: url)
        try await restarted.recoverPendingDirectAccountDeletions(credentials: vault)

        XCTAssertTrue(restarted.accounts.isEmpty)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM account_deletion_intents", at: url), 0)
    }

    func testLegacyPendingDeletionWaitsForExplicitDirectRetry() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let account = Account(
            id: AccountID("legacy-direct-delete"), displayName: "Legacy",
            email: EmailAddress("legacy@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try initial.cacheAccountSetup(
            account: account,
            inbox: Mailbox(
                id: MailboxID("legacy-direct-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
            ),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let vault = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "account:legacy-direct-delete:imap-password")
        try await vault.store(Data("retained-secret".utf8), for: key)
        let crashing = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            if phase == .afterCredentialRemovalBeforeSQLiteCommit {
                throw SimulatedCredentialDeletionCrash()
            }
        })
        do {
            try await crashing.deleteAccountData(accountID: account.id, credentials: vault)
            XCTFail("Expected an interrupted legacy deletion")
        } catch is SimulatedCredentialDeletionCrash {}
        try await vault.store(Data("retained-secret".utf8), for: key)

        let restarted = try migratedStore(at: url)
        try await restarted.recoverPendingDirectAccountDeletions(credentials: vault)
        XCTAssertTrue(restarted.accounts.contains { $0.id == account.id })
        let retainedCredential = try await vault.load(key)
        XCTAssertEqual(retainedCredential, Data("retained-secret".utf8))
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM account_deletion_intents WHERE account_id = 'legacy-direct-delete' AND direct_source_generation IS NULL",
                at: url
            ), 1
        )

        try await restarted.deleteDirectAccountData(
            accountID: account.id, expectedSourceGeneration: 1, credentials: vault
        )
        XCTAssertFalse(restarted.accounts.contains { $0.id == account.id })
        let deletedCredential = try await vault.load(key)
        XCTAssertNil(deletedCredential)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM account_deletion_intents", at: url), 0)
    }

    func testLegacyPendingDeletionRetryRejectsForeignKeysAndStaleSource() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let account = Account(
            id: AccountID("legacy-retry-guard"), displayName: "Guard",
            email: EmailAddress("guard@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try initial.cacheAccountSetup(
            account: account,
            inbox: Mailbox(
                id: MailboxID("legacy-guard-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
            ),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let vault = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "account:legacy-retry-guard:imap-password")
        try await vault.store(Data("retained-secret".utf8), for: key)
        let crashing = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            if phase == .afterCredentialRemovalBeforeSQLiteCommit {
                throw SimulatedCredentialDeletionCrash()
            }
        })
        do {
            try await crashing.deleteAccountData(accountID: account.id, credentials: vault)
            XCTFail("Expected an interrupted legacy deletion")
        } catch is SimulatedCredentialDeletionCrash {}
        try await vault.store(Data("retained-secret".utf8), for: key)
        let restarted = try migratedStore(at: url)

        try executeSQL(
            "UPDATE account_deletion_intents SET credential_record_keys_json = '[\"account:foreign:imap-password\"]' WHERE account_id = 'legacy-retry-guard'",
            at: url
        )
        do {
            try await restarted.deleteDirectAccountData(
                accountID: account.id, expectedSourceGeneration: 1, credentials: vault
            )
            XCTFail("A foreign credential key must not be adopted")
        } catch {
            guard case PlainpostError.validationFailed = error else {
                return XCTFail("Expected credential-list validation, received \(error)")
            }
        }
        let retainedAfterForeignKey = try await vault.load(key)
        XCTAssertEqual(retainedAfterForeignKey, Data("retained-secret".utf8))

        try executeSQL(
            "UPDATE account_mail_sources SET generation = 2 WHERE account_id = 'legacy-retry-guard'",
            at: url
        )
        do {
            try await restarted.deleteDirectAccountData(
                accountID: account.id, expectedSourceGeneration: 1, credentials: vault
            )
            XCTFail("A stale selected source must not adopt the intent")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        let retainedAfterStaleSource = try await vault.load(key)
        XCTAssertEqual(retainedAfterStaleSource, Data("retained-secret".utf8))
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM account_deletion_intents WHERE account_id = 'legacy-retry-guard' AND direct_source_generation IS NULL",
                at: url
            ), 1
        )
    }

    func testDirectDeletionRecoveryRejectsStaleSourceGenerationBeforeRemovingCredentials() async throws {
        let url = temporarySQLiteURL()
        let initial = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: initial.auditLogURL) }
        let account = Account(id: AccountID("stale-direct"), displayName: "Direct", email: EmailAddress("direct@example.com"), imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try initial.cacheAccountSetup(account: account, inbox: Mailbox(id: MailboxID("stale-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"), source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1))
        let vault = InMemoryCredentialVault()
        let key = CredentialRecordKey(rawValue: "account:stale-direct:imap-password")
        try await vault.store(Data("secret".utf8), for: key)
        let crashing = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            if phase == .afterCredentialRemovalBeforeSQLiteCommit { throw SimulatedCredentialDeletionCrash() }
        })
        do {
            try await crashing.deleteDirectAccountData(accountID: account.id, expectedSourceGeneration: 1, credentials: vault)
            XCTFail("Expected interrupted Direct deletion")
        } catch is SimulatedCredentialDeletionCrash {}
        try await vault.store(Data("restored-secret".utf8), for: key)
        let nodeSource = try initial.mailSource(accountID: account.id).nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: account.email.rawValue
        )
        XCTAssertThrowsError(try initial.replaceMailSource(nodeSource, expectedGeneration: 1))
        XCTAssertEqual(try initial.mailSource(accountID: account.id).kind, .direct)
        try executeSQL("UPDATE account_mail_sources SET generation = 2 WHERE account_id = 'stale-direct'", at: url)

        let restarted = try migratedStore(at: url)
        do {
            try await restarted.recoverPendingDirectAccountDeletions(credentials: vault)
            XCTFail("Stale source must not authorize deletion")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertTrue(restarted.accounts.contains { $0.id == account.id })
        let retainedKey = try await vault.load(key)
        XCTAssertEqual(retainedKey, Data("restored-secret".utf8))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM account_deletion_intents", at: url), 1)
    }

    func testDeleteAccountDataFailsClosedForMalformedOwnedDraft() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let originalAudit = try auditLogContents(at: store.auditLogURL)
        try executeSQL(
            """
            UPDATE drafts
            SET payload_json = '{"accountID":"acc-delete-target"'
            WHERE id = 'drf-delete-target';
            """,
            at: url
        )

        XCTAssertThrowsError(try store.deleteAccountData(accountID: fixture.deleted.id)) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("An account-owned draft could not be decoded.")
            )
        }
        XCTAssertTrue(store.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertEqual(try store.draft(id: fixture.retainedDraftID).id, fixture.retainedDraftID)
        XCTAssertEqual(try auditLogContents(at: store.auditLogURL), originalAudit)
    }

    func testDeleteAccountDataRejectsAbsentAccountWithoutMutatingRetainedData() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)

        XCTAssertThrowsError(try store.deleteAccountData(accountID: AccountID("acc-missing"))) { error in
            XCTAssertEqual(error as? PlainpostError, .notFound("Account not found."))
        }
        XCTAssertEqual(store.accounts.map(\.id).sorted { $0.rawValue < $1.rawValue }, [fixture.deleted.id, fixture.retained.id])
        XCTAssertEqual(try store.draft(id: fixture.retainedDraftID).id, fixture.retainedDraftID)
    }

    func testDeleteAccountDataPurgesOnlyTargetOwnership() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)

        try store.deleteAccountData(accountID: fixture.deleted.id)

        XCTAssertFalse(store.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(store.accounts.contains { $0.id == fixture.retained.id })
        XCTAssertTrue(try store.mailRules(effectiveFor: fixture.retained.id).contains { $0.id == fixture.globalRule.id })
        XCTAssertEqual(try store.job(id: fixture.retainedJobID).id, fixture.retainedJobID)
        XCTAssertThrowsError(try store.draft(id: fixture.deletedDraftID))
        XCTAssertEqual(try store.draft(id: fixture.retainedDraftID).id, fixture.retainedDraftID)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_labels WHERE id = 'label-global'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_batch_profiles", at: url), 1)
        let deletedOwnershipIDs = [
            fixture.deleted.id.rawValue, fixture.deletedDraftID.rawValue,
            "msg-delete-target", "thr-delete-target", "mbx-delete-inbox",
            "label-delete-target", "rule-delete-target", "schedule-delete-target",
            "artifact-delete-target", "receipt-delete-target",
            "device-compose:receipt-delete-target:recovery-key",
        ]
        XCTAssertNoThrow(try AccountDeletionFixtures.assertNoPersistedReferences(deletedOwnershipIDs, databaseURL: url))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url), 0)
        XCTAssertNoThrow(
            try AccountDeletionFixtures.assertNoAuditReferences(
                deletedOwnershipIDs,
                auditLogURL: store.auditLogURL
            )
        )

        let reopened = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(reopened.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(reopened.accounts.contains { $0.id == fixture.retained.id })
        XCTAssertTrue(try reopened.mailRules(effectiveFor: fixture.retained.id).contains { $0.id == fixture.globalRule.id })
        XCTAssertEqual(try reopened.draft(id: fixture.retainedDraftID).id, fixture.retainedDraftID)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_labels WHERE id = 'label-global'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_batch_profiles", at: url), 1)
        XCTAssertNoThrow(try AccountDeletionFixtures.assertNoPersistedReferences(deletedOwnershipIDs, databaseURL: url))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url), 0)
        XCTAssertNoThrow(
            try AccountDeletionFixtures.assertNoAuditReferences(
                deletedOwnershipIDs,
                auditLogURL: reopened.auditLogURL
            )
        )
    }

    func testDeleteAccountDataNeverSelectsSharedJobFromPayloadScope() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let payload = String(decoding: try JSONEncoder().encode(PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunRequest: .init(
                mode: .incremental,
                scope: .account(fixture.deleted.id),
                requestedLabelID: nil
            )
        )), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt, max_attempts,
                cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            ) VALUES (
                'job-shared-payload-target', 'ai-operation', '\(payload)', 'queued', 0, 1, 0, 1,
                0, 'job-shared-payload-target', 1, 1, NULL, 'shared'
            );
            """,
            at: url
        )

        try store.deleteAccountData(accountID: fixture.deleted.id)

        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE id = 'job-shared-payload-target'", at: url),
            1
        )
    }

    func testDeleteAccountDataRejectsMalformedPersistedAccountOwnedJobPayload() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            "UPDATE durable_jobs SET kind = 'unknown-old-kind', payload_json = '{malformed' WHERE owner_account_id = '\(fixture.deleted.id.rawValue)';",
            at: url
        )

        XCTAssertThrowsError(try store.deleteAccountData(accountID: fixture.deleted.id))
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE owner_account_id = '\(fixture.deleted.id.rawValue)'", at: url),
            1
        )
        XCTAssertEqual(try store.job(id: fixture.retainedJobID).id, fixture.retainedJobID)
    }

    func testGenericMessageAuditUsesAllMailboxMemberships() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id)
            VALUES ('\(fixture.retained.id.rawValue)', 'Archive', 1, 808, 'msg-delete-target');
            CREATE TRIGGER retain_generic_message_audit_for_test
            BEFORE DELETE ON audit_entries
            BEGIN
                SELECT RAISE(ABORT, 'retain generic message audit for inspection');
            END;
            """,
            at: url
        )

        try store.recategorize(
            [.init(messageID: MessageID("msg-delete-target"), category: .personal)],
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(
            try queryStrings(
                "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM audit_entries WHERE action = 'category.change' AND target_id = 'msg-delete-target' ORDER BY occurred_at DESC LIMIT 1",
                at: url
            ),
            ["shared:<nil>"]
        )
        try executeSQL("DROP TRIGGER retain_generic_message_audit_for_test;", at: url)
    }

    func testDeleteAccountDataPreservesSharedContainersAndCanonicalRetainedMessage() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture: AccountDeletionFixtures.AccountDeletionFixture
        do {
            fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        } catch {
            XCTFail("fixture setup failed: \(error)")
            return
        }
        let sharedCatalogJSON = String(
            decoding: try JSONEncoder().encode([fixture.deletedLabel, fixture.retainedLabel]),
            as: UTF8.self
        )

        do {
            try executeSQL(
                """
            UPDATE messages
            SET thread_id = 'thr-delete-target'
            WHERE id = 'msg-retained';
            INSERT INTO drafts (id, payload_json, owner_account_id, ownership_kind)
                VALUES ('drf-ambiguous-malformed', '{"note":"acc-delete-target"', NULL, 'shared');
            INSERT OR REPLACE INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES (
                'acc-delete-target', 'INBOX', 1, 99, 'msg-retained'
            );

            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-shared', kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, 'shared-container', created_at, updated_at,
                NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-shared', 0, 'msg-delete-target', 'target-shared', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-shared', 1, 'msg-retained', 'retained-shared', 'pending', 1,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_work_preparations (job_id, prepared_at)
                VALUES ('job-shared', 1);
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-shared', 'mixed-before-purge', \(sqlLiteral(sharedCatalogJSON)), 1);

            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-shared', 'rule-global', 1, 2, 2);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-shared', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'queued',
                 'acc-delete-target', 'account'),
                ('run-shared', 1, 'msg-retained', 'acc-retained', '[]', '[]', 'queued',
                 'acc-retained', 'account');

            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('artifact-exclusive-result', 'fixture', 'opaque-record', '{"status":"done"}', 1,
                 'acc-delete-target', 'account'),
                ('artifact-shared-result', 'fixture', 'opaque-record',
                    '{"accountID":"acc-delete-target"}', 1, NULL, 'shared');
            UPDATE durable_jobs
            SET result_artifact_id = 'artifact-exclusive-result'
            WHERE id = (SELECT id FROM durable_jobs WHERE idempotency_key = 'sync-delete-target');
            UPDATE durable_jobs
            SET result_artifact_id = 'artifact-shared-result', progress_current = 2, progress_total = 2
            WHERE id = 'job-shared';
            """,
                at: url
            )
        } catch {
            XCTFail("mixed fixture extension failed: \(error)")
            return
        }

        do {
            try store.deleteAccountData(accountID: fixture.deleted.id)
        } catch {
            XCTFail("purge failed: \(error)")
            return
        }

        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM messages WHERE id = 'msg-retained'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mailbox_messages WHERE account_id = 'acc-delete-target'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE id = 'job-shared'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-shared'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT progress_current FROM durable_jobs WHERE id = 'job-shared'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT progress_total FROM durable_jobs WHERE id = 'job-shared'", at: url), 1)
        XCTAssertEqual(
            try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: "job-shared")).labels.map(\.id),
            [fixture.retainedLabel.id]
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_rule_runs WHERE id = 'run-shared'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT total_items FROM mail_rule_runs WHERE id = 'run-shared'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT enqueued_items FROM mail_rule_runs WHERE id = 'run-shared'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_operation_artifacts WHERE id = 'artifact-exclusive-result'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_operation_artifacts WHERE id = 'artifact-shared-result'", at: url), 0)
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE id = 'job-shared' AND result_artifact_id IS NULL", at: url),
            1
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM drafts WHERE id = 'drf-ambiguous-malformed'", at: url), 1)
    }

    func testAccountDeletionPlannerIsImmutableDeterministicAndDoesNotMutateInverseSharedMessages() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            DELETE FROM mailbox_messages
            WHERE account_id = 'acc-retained' AND message_id = 'msg-retained';
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES
                ('acc-retained', 'Archive', 9, 901, 'msg-delete-target'),
                ('acc-delete-target', 'Archive', 9, 902, 'msg-retained');
            """,
            at: url
        )
        let before = try queryInteger("SELECT COUNT(*) FROM mailbox_messages", at: url)

        let first = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        let second = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.accountID, fixture.deleted.id)
        XCTAssertEqual(first.directDeletion.mailboxIDs, ["mbx-delete-inbox"])
        XCTAssertEqual(first.directDeletion.threadIDs, ["thr-delete-target"])
        XCTAssertEqual(first.directDeletion.draftIDs, [fixture.deletedDraftID.rawValue])
        XCTAssertEqual(first.directDeletion.sendRequestIDs.count, 1)
        XCTAssertEqual(first.directDeletion.jobIDs.count, 1)
        XCTAssertEqual(first.directDeletion.scheduleIDs, ["schedule-delete-target"])
        XCTAssertEqual(first.directDeletion.ruleIDs, ["rule-delete-target"])
        XCTAssertEqual(first.directDeletion.labelIDs, ["label-delete-target"])
        XCTAssertEqual(first.directDeletion.artifactIDs, ["artifact-delete-target"])
        XCTAssertEqual(first.directDeletion.auditEntryIDs, ["audit-delete-target"])
        XCTAssertEqual(first.messageSurgeries, [
            .init(
                messageID: "msg-delete-target",
                targetMemberships: [
                    .init(mailboxPath: "INBOX", uidValidity: 1, uid: 1),
                ],
                retainedMemberships: [
                    .init(
                        accountID: fixture.retained.id,
                        mailboxPath: "Archive",
                        uidValidity: 9,
                        uid: 901
                    ),
                ],
                action: .preserveCanonical(
                    accountID: fixture.retained.id,
                    canonicalMailboxPath: "Archive",
                    detachFromThreadID: "thr-delete-target"
                )
            ),
            .init(
                messageID: "msg-retained",
                targetMemberships: [
                    .init(mailboxPath: "Archive", uidValidity: 9, uid: 902),
                ],
                retainedMemberships: [],
                action: .preserveCanonical(
                    accountID: fixture.retained.id,
                    canonicalMailboxPath: "INBOX",
                    detachFromThreadID: nil
                )
            ),
        ])
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mailbox_messages", at: url), before)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM threads WHERE id = 'thr-delete-target'", at: url), 1)
    }

    func testAccountDeletionMessageSurgeryPreservesBothSharingDirectionsAndRetainedSearch() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            DELETE FROM mailbox_messages
            WHERE account_id = 'acc-retained' AND message_id = 'msg-retained';
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES
                ('acc-retained', 'Archive', 9, 901, 'msg-delete-target'),
                ('acc-delete-target', 'Archive', 9, 902, 'msg-retained');
            UPDATE messages SET thread_id = 'thr-delete-target' WHERE id = 'msg-retained';
            """,
            at: url
        )

        try store.deleteAccountData(accountID: fixture.deleted.id)

        XCTAssertEqual(
            try queryStrings(
                "SELECT id || ':' || account_id || ':' || COALESCE(thread_id, '<nil>') || ':' || mailbox_path FROM messages WHERE id IN ('msg-delete-target', 'msg-retained') ORDER BY id",
                at: url
            ),
            [
                "msg-delete-target:acc-retained:<nil>:Archive",
                "msg-retained:acc-retained:<nil>:INBOX",
            ]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT account_id || ':' || mailbox_path || ':' || message_id FROM mailbox_messages WHERE message_id IN ('msg-delete-target', 'msg-retained') ORDER BY message_id, account_id, mailbox_path",
                at: url
            ),
            [
                "acc-retained:Archive:msg-delete-target",
            ]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT message_id || ':' || account_id || ':' || COALESCE(thread_id, '<nil>') FROM mail_search_documents WHERE message_id IN ('msg-delete-target', 'msg-retained') ORDER BY message_id",
                at: url
            ),
            [
                "msg-delete-target:acc-retained:<nil>",
                "msg-retained:acc-retained:<nil>",
            ]
        )
        XCTAssertEqual(try store.searchMessages("Local account fixture"), [MessageID("msg-delete-target")])
        XCTAssertEqual(try store.searchMessages("Retained fixture"), [MessageID("msg-retained")])
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM mail_embedding_chunks WHERE message_id = 'msg-delete-target'", at: url),
            1
        )
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM incoming_message_attachments WHERE message_id = 'msg-delete-target'", at: url),
            1
        )
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM message_translations WHERE message_id = 'msg-delete-target'", at: url),
            1
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM threads WHERE id = 'thr-delete-target'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mailboxes WHERE id = 'mbx-delete-inbox'", at: url), 0)
    }

    func testAccountDeletionMessageSurgeryRejectsDivergedPlanBeforeMutation() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let plan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }

        try executeSQL(
            """
            DELETE FROM mailbox_messages
            WHERE account_id = 'acc-delete-target' AND message_id = 'msg-delete-target';
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES ('acc-delete-target', 'INBOX', 1, 777, 'msg-delete-target');
            """,
            at: url
        )
        let before = try queryStrings(
            "SELECT account_id || ':' || mailbox_path || ':' || uid || ':' || message_id FROM mailbox_messages ORDER BY account_id, mailbox_path, uid",
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeMessageSurgery(plan: plan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted message ownership.")
            )
        }
        XCTAssertEqual(
            try queryStrings(
                "SELECT account_id || ':' || mailbox_path || ':' || uid || ':' || message_id FROM mailbox_messages ORDER BY account_id, mailbox_path, uid",
                at: url
            ),
            before
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM messages WHERE id = 'msg-delete-target'", at: url), 1)
    }

    func testAccountDeletionMessageSurgeryRejectsRetainedMembershipDriftBeforeMutation() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES ('acc-retained', 'Archive', 9, 901, 'msg-delete-target');
            """,
            at: url
        )
        let plan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }

        try executeSQL(
            """
            DELETE FROM mailbox_messages
            WHERE account_id = 'acc-retained' AND message_id = 'msg-delete-target';
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES ('acc-retained', 'Spam', 9, 999, 'msg-delete-target');
            """,
            at: url
        )
        let before = try queryStrings(
            "SELECT account_id || ':' || mailbox_path || ':' || uid || ':' || message_id FROM mailbox_messages ORDER BY account_id, mailbox_path, uid",
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeMessageSurgery(plan: plan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted message ownership.")
            )
        }
        XCTAssertEqual(
            try queryStrings(
                "SELECT account_id || ':' || mailbox_path || ':' || uid || ':' || message_id FROM mailbox_messages ORDER BY account_id, mailbox_path, uid",
                at: url
            ),
            before
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM messages WHERE id = 'msg-delete-target'", at: url), 1)
    }

    func testAccountDeletionPlannerBuildsExplicitSharedSmartInboxAndRuleRunSurgery() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let catalogJSON = String(
            decoding: try JSONEncoder().encode([fixture.deletedLabel, fixture.retainedLabel]),
            as: UTF8.self
        )
        let artifactJSON = String(
            decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(
                    categorizedMessageCount: 2,
                    unchangedMessageCount: 0,
                    failedMessageCount: 0
                )
            ),
            as: UTF8.self
        )
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-plan-shared', kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, 'job-plan-shared', created_at, updated_at,
                NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                was_updated, owner_account_id, ownership_kind
            ) VALUES
                ('job-plan-shared', 0, 'msg-delete-target', 'target', 'pending', 1, NULL,
                 'acc-delete-target', 'account'),
                ('job-plan-shared', 1, 'msg-retained', 'retained', 'applied', 1, 1,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-plan-shared', 'old', \(sqlLiteral(catalogJSON)), 1);
            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind
            ) VALUES (
                'artifact-plan-shared', 'recategorizeInbox', '',
                \(sqlLiteral(artifactJSON)), 1, NULL, 'shared'
            );
            UPDATE durable_jobs SET result_artifact_id = 'artifact-plan-shared'
            WHERE id = 'job-plan-shared';

            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-plan-shared', 'rule-global', 1, 2, 2);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-plan-shared', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'completed',
                 'acc-delete-target', 'account'),
                ('run-plan-shared', 1, 'msg-retained', 'acc-retained', '[]', '[]', 'enqueued',
                 'acc-retained', 'account');
            """,
            at: url
        )

        let plan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }

        let sharedSmart = try XCTUnwrap(
            plan.smartInboxSurgeries.first { $0.jobID == "job-plan-shared" }
        )
        XCTAssertEqual(
            sharedSmart,
            .init(
                jobID: "job-plan-shared",
                parentDisposition: .retain,
                targetWorkOrdinals: [0],
                retainedWorkOrdinals: [1],
                workFingerprint: sharedSmart.workFingerprint,
                progress: .init(total: 1, current: 1, categorized: 1, unchanged: 0, failed: 0),
                retainedLabels: [fixture.retainedLabel],
                sourceCatalogFingerprint: "old",
                retainedCatalogFingerprint: sharedSmart.retainedCatalogFingerprint,
                resultArtifactDisposition: .rebuild(
                    artifact: .init(
                        id: "artifact-plan-shared",
                        kind: "recategorizeInbox",
                        recordID: "",
                        payloadJSON: artifactJSON,
                        createdAt: 1,
                        ownerAccountID: nil,
                        ownershipKind: "shared"
                    ),
                    payload: PlainpostLocalAIArtifactPayload(
                        categorizedMessageCount: 1,
                        unchangedMessageCount: 0,
                        failedMessageCount: 0
                    )
                )
            )
        )
        XCTAssertEqual(sharedSmart.workFingerprint.count, 64)
        XCTAssertEqual(
            plan.smartInboxSurgeries.first { $0.jobID == "job-plan-shared" }?
                .retainedCatalogFingerprint.count,
            64
        )
        let sharedRule = try XCTUnwrap(
            plan.ruleRunSurgeries.first { $0.runID == "run-plan-shared" }
        )
        XCTAssertEqual(
            sharedRule,
            .init(
                runID: "run-plan-shared",
                parentDisposition: .retain,
                targetItemOrdinals: [0],
                retainedItemOrdinals: [1],
                itemFingerprint: sharedRule.itemFingerprint,
                totalItems: 1,
                enqueuedItems: 1
            )
        )
        XCTAssertEqual(sharedRule.itemFingerprint.count, 64)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-plan-shared'", at: url), 2)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_rule_run_items WHERE run_id = 'run-plan-shared'", at: url), 2)
    }

    func testAccountDeletionRuleRunSurgeryRejectsRetainedItemDriftThenRecomputesExactCounters() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-surgery-shared', 'rule-global', 1, 2, 2);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                error_message, owner_account_id, ownership_kind
            ) VALUES
                ('run-surgery-shared', 0, 'msg-delete-target', 'acc-delete-target',
                 '["mark_as_read"]', '[]', 'queued', NULL, 'acc-delete-target', 'account'),
                ('run-surgery-shared', 1, 'msg-retained', 'acc-retained',
                 '["archive"]', '[]', 'completed', NULL, 'acc-retained', 'account');
            """,
            at: url
        )
        let acceptedPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try executeSQL(
            """
            UPDATE mail_rule_run_items SET actions_json = '["flag"]'
            WHERE run_id = 'run-surgery-shared' AND ordinal = 1;
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeRuleRunSurgery(plan: acceptedPlan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted rule-run ownership.")
            )
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_rule_run_items WHERE run_id = 'run-surgery-shared'", at: url), 2)

        let currentPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try store.databasePool.write { database in
            try LocalAccountDeletion.executeRuleRunSurgery(plan: currentPlan, database: database)
        }
        XCTAssertEqual(
            try queryStrings(
                "SELECT CAST(ordinal AS TEXT) || ':' || actions_json FROM mail_rule_run_items WHERE run_id = 'run-surgery-shared' ORDER BY ordinal",
                at: url
            ),
            ["1:[\"flag\"]"]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT CAST(total_items AS TEXT) || ':' || CAST(enqueued_items AS TEXT) FROM mail_rule_runs WHERE id = 'run-surgery-shared'",
                at: url
            ),
            ["1:1"]
        )
    }

    func testAccountDeletionCredentialFailureRestoresVaultAndSQLiteThenRetryDeletesOnlyTarget() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let targetIMAP = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let targetSMTP = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let vault = FailOnceRemovingCredentialVault(
            records: [
                targetIMAP: Data("imap-secret".utf8),
                targetSMTP: Data("smtp-secret".utf8),
            ],
            failingKey: targetSMTP
        )

        do {
            try await store.deleteAccountData(
                accountID: fixture.deleted.id,
                credentials: vault
            )
            XCTFail("Expected the injected credential removal failure.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }
        let restoredIMAP = await vault.load(targetIMAP)
        let restoredSMTP = await vault.load(targetSMTP)
        XCTAssertEqual(restoredIMAP, Data("imap-secret".utf8))
        XCTAssertEqual(restoredSMTP, Data("smtp-secret".utf8))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)

        try await store.deleteAccountData(
            accountID: fixture.deleted.id,
            credentials: vault
        )

        let deletedIMAP = await vault.load(targetIMAP)
        let deletedSMTP = await vault.load(targetSMTP)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 0)
    }

    func testAccountDeletionSQLiteFailureRestoresVaultAndRollsBackBeforeRetry() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let imapKey = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let vault = InMemoryCredentialVault(records: [
            imapKey: Data("imap-secret".utf8),
            smtpKey: Data("smtp-secret".utf8),
        ])
        try executeSQL(
            """
            CREATE TRIGGER fail_target_account_delete_for_test
            BEFORE DELETE ON accounts
            WHEN OLD.id = 'acc-delete-target'
            BEGIN
                SELECT RAISE(ABORT, 'injected account deletion failure');
            END;
            """,
            at: url
        )

        do {
            try await store.deleteAccountData(
                accountID: fixture.deleted.id,
                credentials: vault
            )
            XCTFail("Expected the injected SQLite deletion failure.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected account deletion failure"))
        }
        let restoredIMAP = try await vault.load(imapKey)
        let restoredSMTP = try await vault.load(smtpKey)
        XCTAssertEqual(restoredIMAP, Data("imap-secret".utf8))
        XCTAssertEqual(restoredSMTP, Data("smtp-secret".utf8))
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM drafts WHERE owner_account_id = 'acc-delete-target'", at: url), 1)

        try executeSQL("DROP TRIGGER fail_target_account_delete_for_test;", at: url)
        try await store.deleteAccountData(
            accountID: fixture.deleted.id,
            credentials: vault
        )

        let deletedIMAP = try await vault.load(imapKey)
        let deletedSMTP = try await vault.load(smtpKey)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 0)
    }

    func testConcurrentAccountDeletionSerializesSnapshotThroughCompensationForSameAccount() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let alternatePath = url.deletingLastPathComponent().path + "/./" + url.lastPathComponent
        let competingStore = try SQLiteMailStore(path: alternatePath)
        let imapKey = CredentialRecordKey(rawValue: "account:acc-delete-target:imap-password")
        let smtpKey = CredentialRecordKey(rawValue: "account:acc-delete-target:smtp-password")
        let vault = PausingFirstRemovalCredentialVault(records: [
            imapKey: Data("imap-secret".utf8),
            smtpKey: Data("smtp-secret".utf8),
        ])

        let first = Task {
            try await store.deleteAccountData(
                accountID: fixture.deleted.id,
                credentials: vault
            )
        }
        await vault.waitUntilFirstRemovalPauses()
        let second = Task {
            try await competingStore.deleteAccountData(
                accountID: fixture.deleted.id,
                credentials: vault
            )
        }
        try await Task.sleep(for: .milliseconds(100))

        let loadCountWhilePaused = await vault.loadCount()
        XCTAssertEqual(
            loadCountWhilePaused,
            4,
            "a second same-account deletion must not snapshot credentials while the first saga is active (one load per IMAP, SMTP, Google and Microsoft refresh-token key)"
        )
        await vault.resumeFirstRemoval()
        try await first.value
        do {
            try await second.value
            XCTFail("The serialized retry must observe that the first deletion already committed.")
        } catch {
            XCTAssertEqual(error as? PlainpostError, .notFound("Account not found."))
        }

        let deletedIMAP = await vault.load(imapKey)
        let deletedSMTP = await vault.load(smtpKey)
        XCTAssertNil(deletedIMAP)
        XCTAssertNil(deletedSMTP)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 0)
    }

    func testConcurrentAccountDeletionAllowsDifferentAccountsToCompleteIndependently() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let firstAccount = Account(
            id: AccountID("acc-concurrent-first"),
            displayName: "First",
            email: EmailAddress("first@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let secondAccount = Account(
            id: AccountID("acc-concurrent-second"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([firstAccount, secondAccount])
        let vault = PausingFirstRemovalCredentialVault(records: [
            CredentialRecordKey(rawValue: "account:acc-concurrent-first:imap-password"): Data("first-imap".utf8),
            CredentialRecordKey(rawValue: "account:acc-concurrent-first:smtp-password"): Data("first-smtp".utf8),
            CredentialRecordKey(rawValue: "account:acc-concurrent-second:imap-password"): Data("second-imap".utf8),
            CredentialRecordKey(rawValue: "account:acc-concurrent-second:smtp-password"): Data("second-smtp".utf8),
        ])
        let secondFinished = expectation(description: "different-account deletion completes")

        let first = Task {
            try await store.deleteAccountData(accountID: firstAccount.id, credentials: vault)
        }
        await vault.waitUntilFirstRemovalPauses()
        let second = Task {
            defer { secondFinished.fulfill() }
            try await store.deleteAccountData(accountID: secondAccount.id, credentials: vault)
        }

        // The first deletion stays paused until resumed below, so a second
        // deletion serialized behind it would never finish: the wait only
        // needs to outlast a loaded machine (a whole-account delete took
        // 2-7 s under the full suite, against the earlier 1 s budget).
        await fulfillment(of: [secondFinished], timeout: 30)
        XCTAssertFalse(store.accounts.contains { $0.id == secondAccount.id })
        XCTAssertTrue(store.accounts.contains { $0.id == firstAccount.id })
        await vault.resumeFirstRemoval()
        try await second.value
        try await first.value
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testAccountDeletionSmartInboxSurgeryRebuildsTerminalSharedAggregate() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let catalogJSON = String(
            decoding: try JSONEncoder().encode([fixture.deletedLabel, fixture.retainedLabel]),
            as: UTF8.self
        )
        let artifactJSON = String(
            decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(
                    modelID: "fixture-model",
                    localOnly: false,
                    categorizedMessageCount: 99,
                    unchangedMessageCount: 98,
                    failedMessageCount: 97
                )
            ),
            as: UTF8.self
        )
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-surgery-terminal', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, 'job-surgery-terminal', created_at, updated_at,
                NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                was_updated, owner_account_id, ownership_kind
            ) VALUES
                ('job-surgery-terminal', 0, 'msg-delete-target', 'target-fingerprint', 'pending', 1, NULL,
                 'acc-delete-target', 'account'),
                ('job-surgery-terminal', 1, 'msg-retained', 'retained-one', 'applied', 1, 1,
                 'acc-retained', 'account'),
                ('job-surgery-terminal', 2, 'retained-two', 'retained-two', 'applied', 1, 0,
                 'acc-retained', 'account'),
                ('job-surgery-terminal', 3, 'retained-three', 'retained-three', 'failed', 1, NULL,
                 'acc-retained', 'account'),
                ('job-surgery-terminal', 4, 'retained-four', 'retained-four', 'skipped', 1, NULL,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-surgery-terminal', 'before-delete', \(sqlLiteral(catalogJSON)), 1);
            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind
            ) VALUES (
                'artifact-surgery-terminal', 'recategorizeInbox', '',
                \(sqlLiteral(artifactJSON)), 1, NULL, 'shared'
            );
            UPDATE durable_jobs
            SET result_artifact_id = 'artifact-surgery-terminal', progress_current = 5, progress_total = 5
            WHERE id = 'job-surgery-terminal';
            """,
            at: url
        )
        let acceptedPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try executeSQL(
            "UPDATE durable_operation_artifacts SET record_id = 'drifted-record', created_at = 99 WHERE id = 'artifact-surgery-terminal';",
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeSmartInboxSurgery(plan: acceptedPlan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted Smart Inbox ownership.")
            )
        }
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-surgery-terminal'", at: url),
            5
        )
        let currentPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }

        try store.databasePool.write { database in
            try LocalAccountDeletion.executeSmartInboxSurgery(plan: currentPlan, database: database)
        }

        XCTAssertEqual(
            try queryStrings(
                "SELECT CAST(ordinal AS TEXT) || ':' || source_fingerprint FROM smart_inbox_work_items WHERE job_id = 'job-surgery-terminal' ORDER BY ordinal",
                at: url
            ),
            ["1:retained-one", "2:retained-two", "3:retained-three", "4:retained-four"]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT CAST(progress_current AS TEXT) || ':' || CAST(progress_total AS TEXT) FROM durable_jobs WHERE id = 'job-surgery-terminal'",
                at: url
            ),
            ["4:4"]
        )
        let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: "job-surgery-terminal"))
        XCTAssertEqual(catalog.labels, [fixture.retainedLabel])
        XCTAssertEqual(catalog.fingerprint, try SQLiteMailStore.smartInboxCatalogFingerprint([fixture.retainedLabel]))
        XCTAssertEqual(
            try queryStrings("SELECT result_artifact_id FROM durable_jobs WHERE id = 'job-surgery-terminal'", at: url),
            ["artifact-surgery-terminal"]
        )
        let rebuiltPayloadJSON = try XCTUnwrap(queryStrings(
            "SELECT payload_json FROM durable_operation_artifacts WHERE id = 'artifact-surgery-terminal'",
            at: url
        ).first)
        let rebuiltPayload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(rebuiltPayloadJSON.utf8)
        )
        XCTAssertEqual(rebuiltPayload.modelID, "fixture-model")
        XCTAssertFalse(rebuiltPayload.localOnly)
        XCTAssertEqual(rebuiltPayload.categorizedMessageCount, 1)
        XCTAssertEqual(rebuiltPayload.unchangedMessageCount, 1)
        XCTAssertEqual(rebuiltPayload.failedMessageCount, 1)
    }

    func testAccountDeletionSmartInboxSurgeryDeletesEmptySharedParentAndRejectsWorkDrift() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-surgery-empty', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, pause_requested,
                pause_attempt_credit, 'job-surgery-empty', created_at, updated_at,
                NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES ('job-surgery-empty', 0, 'msg-delete-target', 'accepted-target', 'pending', 1,
                'acc-delete-target', 'account');
            INSERT INTO smart_inbox_work_preparations (job_id, prepared_at)
                VALUES ('job-surgery-empty', 1);
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-surgery-empty', 'empty-before-delete', '[]', 1);
            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind
            ) VALUES ('artifact-surgery-empty', 'recategorizeInbox', '', '{}', 1, NULL, 'shared');
            UPDATE durable_jobs SET result_artifact_id = 'artifact-surgery-empty'
            WHERE id = 'job-surgery-empty';
            """,
            at: url
        )
        let acceptedPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try executeSQL(
            "UPDATE smart_inbox_work_items SET source_fingerprint = 'drifted-target' WHERE job_id = 'job-surgery-empty';",
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeSmartInboxSurgery(plan: acceptedPlan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted Smart Inbox ownership.")
            )
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE id = 'job-surgery-empty'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-surgery-empty'", at: url), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_operation_artifacts WHERE id = 'artifact-surgery-empty'", at: url), 1)

        let currentPlan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try store.databasePool.write { database in
            try LocalAccountDeletion.executeSmartInboxSurgery(plan: currentPlan, database: database)
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE id = 'job-surgery-empty'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-surgery-empty'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_label_catalog_snapshots WHERE job_id = 'job-surgery-empty'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_preparations WHERE job_id = 'job-surgery-empty'", at: url), 0)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_operation_artifacts WHERE id = 'artifact-surgery-empty'", at: url), 0)
    }

    func testAccountDeletionSmartInboxSurgeryRejectsRetainedClassificationDrift() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let catalogJSON = String(
            decoding: try JSONEncoder().encode([fixture.deletedLabel, fixture.retainedLabel]),
            as: UTF8.self
        )
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-surgery-work-drift', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-surgery-work-drift',
                created_at, updated_at, NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, category,
                priority, requires_action, confidence, updated_at, was_updated,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-surgery-work-drift', 0, 'msg-delete-target', 'target', 'pending', NULL,
                 NULL, NULL, NULL, 1, NULL, 'acc-delete-target', 'account'),
                ('job-surgery-work-drift', 1, 'msg-retained', 'retained', 'applied', 'personal',
                 'normal', 0, 0.5, 1, 1, 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-surgery-work-drift', 'before-drift', \(sqlLiteral(catalogJSON)), 1);
            """,
            at: url
        )
        let plan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        try executeSQL(
            """
            UPDATE smart_inbox_work_items
            SET priority = 'high', requires_action = 1, confidence = 0.9, updated_at = 2
            WHERE job_id = 'job-surgery-work-drift' AND ordinal = 1;
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.write { database in
            try LocalAccountDeletion.executeSmartInboxSurgery(plan: plan, database: database)
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion plan no longer matches persisted Smart Inbox ownership.")
            )
        }
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = 'job-surgery-work-drift'", at: url),
            2
        )
    }

    func testAccountDeletionPlannerRejectsResultArtifactLinkedByMultipleJobs() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                result_artifact_id, owner_account_id, ownership_kind
            )
            SELECT 'job-artifact-alias-one', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-artifact-alias-one',
                created_at, updated_at, 'artifact-alias', NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                result_artifact_id, owner_account_id, ownership_kind
            )
            SELECT 'job-artifact-alias-two', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-artifact-alias-two',
                created_at, updated_at, 'artifact-alias', NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind
            ) VALUES (
                'artifact-alias', 'recategorizeInbox', '',
                '{"categorizedMessageCount":1,"failedMessageCount":0}', 1, NULL, 'shared'
            );
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-artifact-alias-one', 0, 'msg-delete-target', 'target', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-artifact-alias-one', 1, 'msg-retained', 'retained', 'applied', 1,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-artifact-alias-one', 'alias', '[]', 1);
            UPDATE smart_inbox_work_items SET was_updated = 1
            WHERE job_id = 'job-artifact-alias-one' AND ordinal = 1;
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A durable result artifact is linked by multiple jobs.")
            )
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM durable_jobs WHERE result_artifact_id = 'artifact-alias'", at: url), 2)
    }

    func testAccountDeletionPlannerRejectsAnyAmbiguousPersistedOwnership() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            "INSERT INTO drafts (id, payload_json, owner_account_id, ownership_kind) VALUES ('drf-plan-ambiguous', '{}', NULL, 'ambiguous');",
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Account deletion is blocked by ambiguous local ownership in drafts.")
            )
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts WHERE id = 'acc-delete-target'", at: url), 1)
    }

    func testAccountDeletionPlannerRejectsMalformedSharedSmartInboxCatalog() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-plan-malformed-catalog', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-plan-malformed-catalog',
                created_at, updated_at, NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-plan-malformed-catalog', 0, 'msg-delete-target', 'target', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-plan-malformed-catalog', 1, 'msg-retained', 'retained', 'pending', 1,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-plan-malformed-catalog', 'old', '{malformed', 1);
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A shared Smart Inbox label catalog could not be decoded.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsTargetOwnedParentsWithRetainedChildren() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-plan-target-parent', kind,
                (SELECT payload_json FROM durable_jobs WHERE idempotency_key = 'sync-delete-target'),
                state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-plan-target-parent',
                created_at, updated_at, 'acc-delete-target', 'account'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-plan-target-parent', 0, 'msg-delete-target', 'target', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-plan-target-parent', 1, 'msg-retained', 'retained', 'pending', 1,
                 'acc-retained', 'account');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("An account-owned Smart Inbox job contains retained work.")
            )
        }

        try executeSQL(
            """
            DELETE FROM smart_inbox_work_items WHERE job_id = 'job-plan-target-parent';
            DELETE FROM durable_jobs WHERE id = 'job-plan-target-parent';
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-plan-target-parent', 'rule-delete-target', 1, 2, 0);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-plan-target-parent', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'pending',
                 'acc-delete-target', 'account'),
                ('run-plan-target-parent', 1, 'msg-retained', 'acc-retained', '[]', '[]', 'pending',
                 'acc-retained', 'account');
            """,
            at: url
        )
        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("An account-scoped mail rule run contains retained items.")
            )
        }
    }

    func testDeleteAccountDataCompletesPlannerPreflightBeforeAnyMutation() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-public-preflight', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-public-preflight',
                created_at, updated_at, NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-public-preflight', 0, 'msg-delete-target', 'target', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-public-preflight', 1, 'msg-retained', 'retained', 'pending', 1,
                 'acc-retained', 'account');
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-public-preflight', 'old', '{malformed', 1);
            """,
            at: url
        )
        let auditBefore = try auditLogContents(at: store.auditLogURL)
        let accountCountBefore = try queryInteger("SELECT COUNT(*) FROM accounts", at: url)
        let workCountBefore = try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items", at: url)

        XCTAssertThrowsError(try store.deleteAccountData(accountID: fixture.deleted.id)) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A shared Smart Inbox label catalog could not be decoded.")
            )
        }

        XCTAssertEqual(try auditLogContents(at: store.auditLogURL), auditBefore)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM accounts", at: url), accountCountBefore)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_work_items", at: url), workCountBefore)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM drafts WHERE id = 'drf-delete-target'", at: url), 1)
    }

    func testAccountDeletionPlannerRejectsRetainedRuleItemReferencingDeletedJob() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let targetJobID = try XCTUnwrap(queryStrings(
            "SELECT id FROM durable_jobs WHERE owner_account_id = 'acc-delete-target' ORDER BY id LIMIT 1",
            at: url
        ).first)
        try executeSQL(
            """
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-plan-dangling-job', 'rule-global', 1, 2, 1);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-plan-dangling-job', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'completed',
                 'acc-delete-target', 'account'),
                ('run-plan-dangling-job', 1, 'msg-retained', 'acc-retained', '[]',
                 \(sqlLiteral("[\"\(targetJobID)\"]")), 'enqueued', 'acc-retained', 'account');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained mail rule run item references a job planned for deletion.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsRetainedJobReferencingDeletedArtifact() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            UPDATE durable_jobs
            SET result_artifact_id = 'artifact-delete-target'
            WHERE id = '\(fixture.retainedJobID)';
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained durable job references an account-owned artifact planned for deletion.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsDeletedJobReferencingRetainedArtifact() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            UPDATE durable_jobs
            SET result_artifact_id = 'artifact-retained'
            WHERE owner_account_id = 'acc-delete-target';
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A durable job result artifact conflicts with its persisted ownership.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsTargetMailboxMembershipWithoutCanonicalMessage() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES ('acc-delete-target', 'INBOX', 1, 999, 'msg-missing-plan');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A target mailbox membership references a missing canonical message.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsMissingOrMismatchedRetainedThread() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id
            ) VALUES ('acc-delete-target', 'Archive', 9, 903, 'msg-retained');
            UPDATE messages SET thread_id = 'thr-missing-plan' WHERE id = 'msg-retained';
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained canonical message references a missing thread.")
            )
        }

        try executeSQL(
            """
            INSERT INTO threads (id, account_id, subject_normalized, participant_emails)
            VALUES ('thr-other-owner', 'zzz-other-owner', 'other', '[]');
            UPDATE messages SET thread_id = 'thr-other-owner' WHERE id = 'msg-retained';
            """,
            at: url
        )
        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained canonical message thread conflicts with its retained owner.")
            )
        }

        try executeSQL(
            """
            DELETE FROM mailbox_messages
            WHERE message_id = 'msg-retained' AND account_id = 'acc-retained';
            UPDATE messages SET thread_id = 'thr-missing-inverse-plan'
            WHERE id = 'msg-retained';
            """,
            at: url
        )
        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained canonical message references a missing thread.")
            )
        }
    }

    func testAccountDeletionPlannerRejectsMissingCatalogAndInvalidSharedWorkState() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt,
                max_attempts, cancellation_requested, idempotency_key, created_at, updated_at,
                owner_account_id, ownership_kind
            )
            SELECT 'job-plan-missing-catalog', kind, payload_json, state, priority, available_at,
                attempt, max_attempts, cancellation_requested, 'job-plan-missing-catalog',
                created_at, updated_at, NULL, 'shared'
            FROM durable_jobs WHERE id = '\(fixture.retainedJobID)';
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES
                ('job-plan-missing-catalog', 0, 'msg-delete-target', 'target', 'pending', 1,
                 'acc-delete-target', 'account'),
                ('job-plan-missing-catalog', 1, 'msg-retained', 'retained', 'pending', 1,
                 'acc-retained', 'account');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A shared Smart Inbox job is missing its label catalog.")
            )
        }

        let catalog = String(decoding: try JSONEncoder().encode([fixture.retainedLabel]), as: UTF8.self)
        try executeSQL(
            """
            INSERT INTO smart_inbox_label_catalog_snapshots (
                job_id, catalog_fingerprint, labels_json, created_at
            ) VALUES ('job-plan-missing-catalog', 'old', \(sqlLiteral(catalog)), 1);
            UPDATE smart_inbox_work_items
            SET state = 'unknown-state'
            WHERE job_id = 'job-plan-missing-catalog' AND ordinal = 1;
            """,
            at: url
        )
        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A shared Smart Inbox work item has invalid persisted state.")
            )
        }
    }

    func testAccountDeletionPlannerPlansExplicitEmptyParentDeletionAndArtifactClear() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            UPDATE durable_jobs
            SET owner_account_id = NULL, ownership_kind = 'shared',
                result_artifact_id = 'artifact-delete-target'
            WHERE owner_account_id = 'acc-delete-target';
            UPDATE durable_operation_artifacts
            SET owner_account_id = NULL, ownership_kind = 'shared'
            WHERE id = 'artifact-delete-target';
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-plan-delete-parent', 'rule-global', 1, 1, 0);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-plan-delete-parent', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'pending',
                 'acc-delete-target', 'account');
            """,
            at: url
        )

        let plan = try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }
        let smart = try XCTUnwrap(plan.smartInboxSurgeries.first)
        XCTAssertEqual(smart.parentDisposition, .delete)
        XCTAssertEqual(smart.resultArtifactDisposition, .clearAndDelete(artifactID: "artifact-delete-target"))
        XCTAssertEqual(plan.ruleRunSurgeries.first?.parentDisposition, .delete)
    }

    func testAccountDeletionPlannerRejectsDanglingRetainedRuleJobReference() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-plan-missing-job', 'rule-global', 1, 2, 1);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES
                ('run-plan-missing-job', 0, 'msg-delete-target', 'acc-delete-target', '[]', '[]', 'completed',
                 'acc-delete-target', 'account'),
                ('run-plan-missing-job', 1, 'msg-retained', 'acc-retained', '[]', '["job-missing"]', 'enqueued',
                 'acc-retained', 'account');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: fixture.deleted.id,
                requiresLiveAccount: true,
                database: database
            )
        }) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("A retained mail rule run item references a missing job.")
            )
        }
    }

    func testDeleteAuditWritersCaptureTypedOwnershipBeforeMutation() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try executeSQL(
            """
            CREATE TRIGGER retain_typed_audit_for_test
            BEFORE DELETE ON audit_entries
            BEGIN
                SELECT RAISE(ABORT, 'retain typed audit rows for inspection');
            END;
            """,
            at: url
        )

        try store.deleteMailLabel(id: fixture.deletedLabel.id)
        try store.deleteMailRule(id: fixture.globalRule.id)

        XCTAssertEqual(
            try queryStrings(
                "SELECT DISTINCT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM audit_entries WHERE target_type = 'mail_label' AND target_id = '\(fixture.deletedLabel.id)'",
                at: url
            ),
            ["account:\(fixture.deleted.id.rawValue)"]
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM audit_entries WHERE action = 'mail_rule.delete' AND target_id = '\(fixture.globalRule.id)'",
                at: url
            ),
            ["shared:<nil>"]
        )
        try executeSQL("DROP TRIGGER retain_typed_audit_for_test;", at: url)
        XCTAssertNoThrow(try store.deleteAccountData(accountID: fixture.deleted.id))
    }

    func testNewJobWritesRejectMalformedAndUnresolvedOwnershipButModelSharedAndGlobal() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }

        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: "{malformed",
            idempotencyKey: "job-malformed-owner"
        )))
        let unresolved = PlainpostMailboxFlagInput(
            messageID: MessageID("msg-missing-owner"),
            desiredSeen: true
        )
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .mailboxFlag,
            payloadJSON: String(decoding: try JSONEncoder().encode(unresolved), as: UTF8.self),
            idempotencyKey: "job-unresolved-owner"
        )))
        let flagAccount = Account(
            id: AccountID("acc-flag-explicit"),
            displayName: "Flag",
            email: EmailAddress("flag@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([flagAccount])
        try store.cacheMessage(PlainpostFixtures.aliceMessage)
        try store.recordCachedUID(
            accountID: flagAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 42,
            messageID: PlainpostFixtures.aliceMessage.id
        )
        let legacyUnscopedFlag = """
            {"messageID":{"rawValue":"\(PlainpostFixtures.aliceMessage.id.rawValue)"},"desiredSeen":true}
            """
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .mailboxFlag,
            payloadJSON: legacyUnscopedFlag,
            idempotencyKey: "job-unscoped-mailbox-flag"
        )))
        let sharedInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        )
        let shared = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(sharedInput), as: UTF8.self),
            idempotencyKey: "job-shared-owner"
        ))
        let global = try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: String(decoding: try JSONEncoder().encode(PlainpostAIOperationInput(
                operation: .rebuildIndex,
                recordID: "",
                providerID: "deterministic"
            )), as: UTF8.self),
            idempotencyKey: "job-global-owner"
        ))
        XCTAssertEqual(
            try queryStrings("SELECT ownership_kind FROM durable_jobs WHERE id = '\(shared.id)'", at: url),
            ["shared"]
        )
        XCTAssertEqual(
            try queryStrings("SELECT ownership_kind FROM durable_jobs WHERE id = '\(global.id)'", at: url),
            ["global"]
        )
    }

    func testHumanMailboxFlagRejectsAmbiguousCanonicalMembership() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        try cacheOwnedMessage(message, store: store, uid: 91)
        try store.recordCachedUID(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 92,
            messageID: message.id
        )

        XCTAssertThrowsError(try store.markSeen(message.id, seen: true, actor: PlainpostFixtures.guiUser)) {
            XCTAssertEqual(
                $0 as? PlainpostError,
                .validationFailed("The canonical mailbox flag membership is unavailable or ambiguous.")
            )
        }
        XCTAssertTrue(try store.jobs(limit: 10).isEmpty)
    }

    func testTypedOperationOwnershipRegistryClassifiesEveryAIOperationKindAndRejectsMismatches() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let owner = fixture.deleted.id.rawValue

        func payload(
            _ operation: PlainpostAIOperationKind,
            recordID: String,
            retrievalScope: MailRetrievalScope? = nil,
            activeConversationKey: String? = nil,
            smartInboxScope: PlainpostSmartInboxRunScope = .allAccounts
        ) throws -> String {
            String(decoding: try JSONEncoder().encode(PlainpostAIOperationInput(
                operation: operation,
                recordID: recordID,
                conversationReferenceKind: operation == .draftReply ? .thread : nil,
                accountID: operation.unambiguousConversationReferenceKind != nil || operation == .draftReply
                    || recordID == "mailbox-account"
                    ? fixture.deleted.id
                    : nil,
                providerID: "deterministic",
                retrievalScope: retrievalScope,
                activeConversationKey: activeConversationKey,
                smartInboxRunRequest: .init(
                    mode: .incremental,
                    scope: smartInboxScope,
                    requestedLabelID: nil
                )
            )), as: UTF8.self)
        }

        let cases: [(PlainpostOperationKind, PlainpostAIOperationKind, String, MailRetrievalScope?, String?, PlainpostSmartInboxRunScope, String)] = [
            (.aiOperation, .summarizeThread, "thr-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .summarizeMessage, "msg-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .translateMessage, "msg-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .answerThreadQuestion, "thr-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .answerMailboxQuestion, "mailbox", .allMail, nil, .allAccounts, "shared:<nil>"),
            (.aiOperation, .answerMailboxQuestion, "mailbox-account", .allMail, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .answerMailboxQuestion, "mailbox", .activeConversation, "thr-delete-target", .allAccounts, "account:\(owner)"),
            (.aiOperation, .draftReply, "thr-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .rewriteDraft, fixture.deletedDraftID.rawValue, nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .classifyMessage, "msg-delete-target", nil, nil, .allAccounts, "account:\(owner)"),
            (.aiOperation, .recategorizeInbox, "", nil, nil, .allAccounts, "shared:<nil>"),
            (.aiOperation, .recategorizeInbox, "", nil, nil, .account(fixture.deleted.id), "account:\(owner)"),
            (.searchRebuild, .rebuildIndex, "", nil, nil, .allAccounts, "global:<nil>"),
        ]

        func artifactPayload(_ operation: PlainpostAIOperationKind, recordID: String) -> PlainpostLocalAIArtifactPayload {
            switch operation {
            case .summarizeThread, .summarizeMessage, .answerThreadQuestion:
                return .init(text: "result", resultRecordID: recordID)
            case .translateMessage:
                return .init(
                    resultRecordID: recordID,
                    translatedBodyKind: "plainText",
                    translatedBody: "result",
                    sourceFingerprint: "fingerprint"
                )
            case .answerMailboxQuestion:
                return .init(text: "result")
            case .draftReply:
                return .init(resultRecordID: fixture.deletedDraftID.rawValue)
            case .rewriteDraft:
                return .init(text: "result", resultRecordID: recordID)
            case .classifyMessage:
                return .init(resultRecordID: recordID, category: "personal")
            case .recategorizeInbox:
                return .init(categorizedMessageCount: 0, failedMessageCount: 0)
            case .rebuildIndex:
                return .init(indexedMessageCount: 0)
            }
        }

        for (index, item) in cases.enumerated() {
            let operationPayload = try payload(
                item.1,
                recordID: item.2,
                retrievalScope: item.3,
                activeConversationKey: item.4,
                smartInboxScope: item.5
            )
            let job = try store.enqueueJob(.init(
                kind: item.0,
                payloadJSON: operationPayload,
                idempotencyKey: "typed-owner-\(index)"
            ))
            XCTAssertEqual(
                try queryStrings(
                    "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM durable_jobs WHERE id = '\(job.id)'",
                    at: url
                ),
                [item.6],
                "unexpected ownership for \(item.1.rawValue)"
            )
            let artifact = DurableOperationArtifact(
                id: "typed-owner-artifact-\(index)",
                kind: item.1.rawValue,
                recordID: item.2,
                payloadJSON: String(decoding: try JSONEncoder().encode(
                    artifactPayload(item.1, recordID: item.2)
                ), as: UTF8.self)
            )
            try store.saveTypedAIOperationArtifact(
                artifact,
                input: try JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(operationPayload.utf8)
                )
            )
            let leaseToken = "typed-owner-lease-\(index)"
            try executeSQL(
                "UPDATE durable_jobs SET state = 'running', lease_token = '\(leaseToken)', lease_expires_at = 4102444800 WHERE id = '\(job.id)';",
                at: url
            )
            try store.completeJob(
                id: job.id,
                leaseToken: leaseToken,
                resultArtifactID: artifact.id
            )
            XCTAssertEqual(try store.job(id: job.id).state, .completed)
        }

        let foreignConversationInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            accountID: fixture.retained.id, providerID: "deterministic",
            retrievalScope: .activeConversation, activeConversationKey: "thr-delete-target")
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(foreignConversationInput), as: UTF8.self),
            idempotencyKey: "typed-owner-foreign-ask-context"
        )))

        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: "{}",
            idempotencyKey: "typed-owner-invalid-empty-search"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: try payload(.recategorizeInbox, recordID: ""),
            idempotencyKey: "typed-owner-search-kind-mismatch"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: try payload(.rebuildIndex, recordID: ""),
            idempotencyKey: "typed-owner-ai-kind-mismatch"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: try payload(.summarizeMessage, recordID: "msg-missing-owner"),
            idempotencyKey: "typed-owner-unresolved-record"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: try payload(.summarizeMessage, recordID: fixture.deletedDraftID.rawValue),
            idempotencyKey: "typed-owner-wrong-message-reference-kind"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: try payload(.rewriteDraft, recordID: "msg-delete-target"),
            idempotencyKey: "typed-owner-wrong-draft-reference-kind"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: try payload(
                .recategorizeInbox,
                recordID: "",
                smartInboxScope: .account(AccountID("acc-missing-smart-inbox"))
            ),
            idempotencyKey: "typed-owner-missing-smart-inbox-account"
        )))
    }

    func testSelectedAccountResolvesLegacySubjectDespiteAnotherAccountWithSameSubject() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let selected = Account(
            id: AccountID("ask-subject-selected"), displayName: "Selected",
            email: EmailAddress("selected@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let foreign = Account(
            id: AccountID("ask-subject-foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try store.cacheAccounts([selected, foreign])
        for (index, account) in [selected, foreign].enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("ask-subject-\(index)"),
                    threadID: ThreadID("ask-shared-thread"),
                    from: EmailAddress("sender@example.com"), subject: "Shared status",
                    preview: "Account-specific answer", smartCategory: .personal),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: index + 1,
                notificationEligible: false)
        }
        let key = "legacy_subject_\(MailThreading.normalizedSubject("Shared status"))"
        let scopedInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            accountID: selected.id, providerID: "deterministic",
            retrievalScope: .activeConversation, activeConversationKey: key)
        let job = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(scopedInput), as: UTF8.self),
            idempotencyKey: "selected-legacy-subject"))
        XCTAssertEqual(
            try queryStrings(
                "SELECT owner_account_id FROM durable_jobs WHERE id = '\(job.id)'", at: url),
            [selected.id.rawValue])

        let unscopedInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            providerID: "deterministic", retrievalScope: .activeConversation,
            activeConversationKey: key)
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(unscopedInput), as: UTF8.self),
            idempotencyKey: "unscoped-ambiguous-legacy-subject")))

        let scopedThreadInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            accountID: selected.id, providerID: "deterministic",
            retrievalScope: .activeConversation, activeConversationKey: "ask-shared-thread")
        let threadJob = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(scopedThreadInput), as: UTF8.self),
            idempotencyKey: "selected-shared-thread"))
        XCTAssertEqual(
            try queryStrings(
                "SELECT owner_account_id FROM durable_jobs WHERE id = '\(threadJob.id)'", at: url),
            [selected.id.rawValue])
        let unscopedThreadInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "mailbox",
            providerID: "deterministic", retrievalScope: .activeConversation,
            activeConversationKey: "ask-shared-thread")
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(unscopedThreadInput), as: UTF8.self),
            idempotencyKey: "unscoped-ambiguous-thread")))
    }

    func testOperationArtifactOwnershipUsesTheTypedOperationRegistry() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let input = PlainpostAIOperationInput(
            operation: .summarizeMessage,
            recordID: "msg-delete-target",
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        )
        let artifact = DurableOperationArtifact(
            id: "artifact-typed-message",
            kind: input.operation.rawValue,
            recordID: "msg-delete-target",
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(text: "summary", resultRecordID: input.recordID)
            ), as: UTF8.self)
        )

        try store.saveTypedAIOperationArtifact(
            artifact,
            input: input
        )

        XCTAssertEqual(
            try queryStrings(
                "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM durable_operation_artifacts WHERE id = 'artifact-typed-message'",
                at: url
            ),
            ["account:\(fixture.deleted.id.rawValue)"]
        )

        XCTAssertThrowsError(try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "artifact-wrong-kind",
                kind: PlainpostAIOperationKind.translateMessage.rawValue,
                recordID: input.recordID,
                payloadJSON: artifact.payloadJSON
            ),
            input: input
        ))
        XCTAssertThrowsError(try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "artifact-wrong-record",
                kind: input.operation.rawValue,
                recordID: "msg-retained",
                payloadJSON: artifact.payloadJSON
            ),
            input: input
        ))
        XCTAssertThrowsError(try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "artifact-malformed-payload",
                kind: input.operation.rawValue,
                recordID: input.recordID,
                payloadJSON: "{}"
            ),
            input: input
        ))

        let replyInput = PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thr-delete-target",
            conversationReferenceKind: .thread,
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        )
        XCTAssertThrowsError(try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "artifact-cross-account-reply",
                kind: replyInput.operation.rawValue,
                recordID: replyInput.recordID,
                payloadJSON: String(decoding: try JSONEncoder().encode(
                    PlainpostLocalAIArtifactPayload(resultRecordID: fixture.retainedDraftID.rawValue)
                ), as: UTF8.self)
            ),
            input: replyInput
        ))
        try store.saveTypedAIOperationArtifact(
            DurableOperationArtifact(
                id: "artifact-owned-reply",
                kind: replyInput.operation.rawValue,
                recordID: replyInput.recordID,
                payloadJSON: String(decoding: try JSONEncoder().encode(
                    PlainpostLocalAIArtifactPayload(resultRecordID: fixture.deletedDraftID.rawValue)
                ), as: UTF8.self)
            ),
            input: replyInput
        )
        XCTAssertEqual(
            try queryStrings(
                "SELECT owner_account_id FROM durable_operation_artifacts WHERE id = 'artifact-owned-reply'",
                at: url
            ),
            [fixture.deleted.id.rawValue]
        )
    }

    func testPersistedDraftReplyJobAcceptsOnlyItsProducedDraftArtifact() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let input = PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thr-delete-target",
            conversationReferenceKind: .thread,
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        )
        let job = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: "exact-produced-draft-artifact"
        ))
        let wrongArtifact = DurableOperationArtifact(
            id: "artifact-wrong-same-account-draft",
            kind: PlainpostAIOperationKind.draftReply.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(resultRecordID: fixture.deletedDraftID.rawValue)
            ), as: UTF8.self)
        )
        XCTAssertThrowsError(try store.saveDurableOperationArtifact(wrongArtifact, forJobID: job.id))

        let producedDraftID = DraftID("drf_ai_\(job.id)")
        _ = try store.createDraft(
            Draft(
                id: producedDraftID,
                accountID: fixture.deleted.id,
                from: fixture.deleted.email,
                to: [EmailAddress("reply@example.com")],
                cc: [],
                bcc: [],
                subject: "Re: Impostor",
                bodyPlain: "Not produced by the operation worker",
                createdBy: PlainpostFixtures.guiUser.id,
                aiGenerated: false,
                sourceThreadID: ThreadID(input.recordID)
            ),
            actor: PlainpostFixtures.guiUser
        )
        let exactIDImpostorArtifact = DurableOperationArtifact(
            id: "artifact-exact-id-impostor",
            kind: PlainpostAIOperationKind.draftReply.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(resultRecordID: producedDraftID.rawValue)
            ), as: UTF8.self)
        )
        XCTAssertThrowsError(
            try store.saveDurableOperationArtifact(exactIDImpostorArtifact, forJobID: job.id)
        )
        _ = try store.createDraft(
            Draft(
                id: producedDraftID,
                accountID: fixture.deleted.id,
                from: fixture.deleted.email,
                to: [EmailAddress("reply@example.com")],
                cc: [],
                bcc: [],
                subject: "Re: Exact",
                bodyPlain: "Exact produced reply",
                createdBy: "local-operation-agent",
                aiGenerated: true,
                sourceThreadID: ThreadID(input.recordID)
            ),
            actor: PlainpostFixtures.guiUser
        )
        let actualArtifact = DurableOperationArtifact(
            id: "artifact-exact-produced-draft",
            kind: PlainpostAIOperationKind.draftReply.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(resultRecordID: producedDraftID.rawValue)
            ), as: UTF8.self)
        )
        try store.saveDurableOperationArtifact(actualArtifact, forJobID: job.id)
        XCTAssertEqual(
            try queryStrings(
                "SELECT draft_id FROM durable_job_produced_drafts WHERE job_id = '\(job.id)'",
                at: url
            ),
            [producedDraftID.rawValue]
        )
    }

    func testAIOperationReferenceSemanticsRejectCollisionsAndResolveMembershipContext() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        try store.cacheMessage(MessageSummary(
            id: MessageID("thr-delete-target"),
            threadID: ThreadID("thr-retained"),
            from: EmailAddress("collision@example.com"),
            subject: "Collision",
            preview: "Collision",
            smartCategory: .personal
        ))

        func enqueue(_ input: PlainpostAIOperationInput, key: String) throws -> PlainpostDurableJob {
            try store.enqueueJob(.init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: key
            ))
        }
        let collision = try enqueue(.init(
            operation: .summarizeThread,
            recordID: "thr-delete-target",
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        ), key: "thread-collision")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(collision.id)'", at: url),
            [fixture.deleted.id.rawValue]
        )
        let legacyAmbiguousReply = """
            {"operation":"draftReply","recordID":"thr-delete-target","providerID":"deterministic"}
            """
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: legacyAmbiguousReply,
            idempotencyKey: "legacy-ambiguous-draft-reply"
        )))
        XCTAssertThrowsError(try enqueue(.init(
            operation: .answerThreadQuestion,
            recordID: "msg-delete-target",
            accountID: fixture.deleted.id,
            providerID: "deterministic",
            question: "Question"
        ), key: "message-is-not-thread"))
        let directMessageReply = try enqueue(.init(
            operation: .draftReply,
            recordID: "msg-delete-target",
            conversationReferenceKind: .message,
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        ), key: "draft-reply-message")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(directMessageReply.id)'", at: url),
            [fixture.deleted.id.rawValue]
        )
        let collisionMessageReply = try enqueue(.init(
            operation: .draftReply,
            recordID: "thr-delete-target",
            conversationReferenceKind: .message,
            accountID: fixture.retained.id,
            providerID: "deterministic"
        ), key: "draft-reply-collision-message")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(collisionMessageReply.id)'", at: url),
            [fixture.retained.id.rawValue]
        )
        let collisionThreadReply = try enqueue(.init(
            operation: .draftReply,
            recordID: "thr-delete-target",
            conversationReferenceKind: .thread,
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        ), key: "draft-reply-collision-thread")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(collisionThreadReply.id)'", at: url),
            [fixture.deleted.id.rawValue]
        )

        try executeSQL(
            "INSERT INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id) VALUES ('\(fixture.retained.id.rawValue)', 'Archive', 1, 404, 'msg-delete-target');",
            at: url
        )
        XCTAssertThrowsError(try enqueue(.init(
            operation: .classifyMessage,
            recordID: "msg-delete-target",
            providerID: "deterministic"
        ), key: "unscoped-shared-message"))
        let scoped = try enqueue(.init(
            operation: .classifyMessage,
            recordID: "msg-delete-target",
            accountID: fixture.deleted.id,
            providerID: "deterministic"
        ), key: "scoped-message")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(scoped.id)'", at: url),
            [fixture.deleted.id.rawValue]
        )
        let retainedScoped = try enqueue(.init(
            operation: .classifyMessage,
            recordID: "msg-delete-target",
            accountID: fixture.retained.id,
            providerID: "deterministic"
        ), key: "retained-message-membership")
        XCTAssertEqual(
            try queryStrings("SELECT owner_account_id FROM durable_jobs WHERE id = '\(retainedScoped.id)'", at: url),
            [fixture.retained.id.rawValue]
        )
    }

    func testNonAIOperationOwnershipUsesExactReferenceKindsAndCompletesTypedArtifacts() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: url)
        let requestID = SendRequestID(try XCTUnwrap(
            queryStrings(
                "SELECT id FROM send_requests WHERE owner_account_id = '\(fixture.deleted.id.rawValue)' ORDER BY id LIMIT 1",
                at: url
            ).first
        ))

        func encoded<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }

        let rebuild = PlainpostAIOperationInput(
            operation: .rebuildIndex,
            recordID: "",
            providerID: "deterministic"
        )
        let valid: [(PlainpostOperationKind, String, String)] = [
            (.inboxSync, try encoded(PlainpostInboxSyncInput(accountID: fixture.deleted.id, trigger: .manual)), "account"),
            (.historicalSync, try encoded(PlainpostInboxSyncInput(accountID: fixture.deleted.id, trigger: .manual, scope: .completeHistory)), "account"),
            (.approvedDelivery, try encoded(PlainpostApprovalDecisionInput(requestID: requestID, actorID: "local-user")), "account"),
            (.denySend, try encoded(PlainpostApprovalDecisionInput(requestID: requestID, actorID: "local-user")), "account"),
            (.mailboxFlag, try encoded(PlainpostMailboxFlagInput(
                messageID: MessageID("msg-delete-target"),
                accountID: fixture.deleted.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                desiredSeen: true
            )), "account"),
            (.mailboxArchive, try encoded(PlainpostMailboxArchiveInput(
                messageID: MessageID("msg-delete-target"),
                accountID: fixture.deleted.id,
                sourceMailboxPath: "INBOX",
                destinationMailboxPath: "Archive",
                uidValidity: 1,
                uid: 1
            )), "account"),
            (.searchRebuild, try encoded(rebuild), "global"),
        ]

        for (index, item) in valid.enumerated() {
            let job = try store.enqueueJob(.init(
                kind: item.0,
                payloadJSON: item.1,
                idempotencyKey: "exact-non-ai-\(index)"
            ))
            let payloadJSON: String
            let artifactKind: String
            let artifactRecordID: String
            switch item.0 {
            case .inboxSync, .historicalSync:
                payloadJSON = try encoded(PlainpostInboxSyncResult(
                    accountID: fixture.deleted.id,
                    syncedMessageCount: 0,
                    jobID: job.id
                ))
                artifactKind = PlainpostOperationKind.inboxSync.rawValue
                artifactRecordID = fixture.deleted.id.rawValue
            case .searchRebuild:
                payloadJSON = try encoded(PlainpostLocalAIArtifactPayload(indexedMessageCount: 0))
                artifactKind = PlainpostAIOperationKind.rebuildIndex.rawValue
                artifactRecordID = ""
            default:
                payloadJSON = "{}"
                artifactKind = item.0.rawValue
                artifactRecordID = job.id
            }
            let artifact = DurableOperationArtifact(
                id: "exact-non-ai-artifact-\(index)",
                kind: artifactKind,
                recordID: artifactRecordID,
                payloadJSON: payloadJSON
            )
            if [.approvedDelivery, .denySend, .mailboxFlag, .mailboxArchive].contains(item.0) {
                XCTAssertThrowsError(try store.saveDurableOperationArtifact(artifact, forJobID: job.id))
                continue
            }
            try store.saveDurableOperationArtifact(artifact, forJobID: job.id)
            XCTAssertEqual(
                try queryStrings(
                    "SELECT ownership_kind || ':' || COALESCE(owner_account_id, '<nil>') FROM durable_operation_artifacts WHERE id = '\(artifact.id)'",
                    at: url
                ),
                ["\(item.2):\(item.2 == "account" ? fixture.deleted.id.rawValue : "<nil>")"]
            )
            let lease = "exact-non-ai-lease-\(index)"
            try executeSQL(
                "UPDATE durable_jobs SET state = 'running', lease_token = '\(lease)', lease_expires_at = 4102444800 WHERE id = '\(job.id)';",
                at: url
            )
            try store.completeJob(id: job.id, leaseToken: lease, resultArtifactID: artifact.id)
            XCTAssertEqual(try store.job(id: job.id).state, .completed)
        }

        for kind in PlainpostOperationKind.allCases where kind != .aiOperation {
            XCTAssertThrowsError(try store.enqueueJob(.init(
                kind: kind,
                payloadJSON: "{}",
                idempotencyKey: "exact-non-ai-malformed-\(kind.rawValue)"
            )), "\(kind.rawValue) must reject an untyped payload")
        }

        let missingAccount = AccountID("acc-missing-exact-owner")
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .inboxSync,
            payloadJSON: try encoded(PlainpostInboxSyncInput(accountID: missingAccount, trigger: .manual)),
            idempotencyKey: "exact-inbox-missing-account"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .historicalSync,
            payloadJSON: try encoded(PlainpostInboxSyncInput(accountID: missingAccount, trigger: .manual, scope: .completeHistory)),
            idempotencyKey: "exact-history-missing-account"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .approvedDelivery,
            payloadJSON: try encoded(PlainpostApprovalDecisionInput(
                requestID: SendRequestID(fixture.deletedDraftID.rawValue), actorID: "local-user"
            )),
            idempotencyKey: "exact-approved-wrong-reference-kind"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .denySend,
            payloadJSON: try encoded(PlainpostApprovalDecisionInput(
                requestID: SendRequestID(fixture.deletedDraftID.rawValue), actorID: "local-user"
            )),
            idempotencyKey: "exact-deny-wrong-reference-kind"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .mailboxFlag,
            payloadJSON: try encoded(PlainpostMailboxFlagInput(
                messageID: MessageID(fixture.deletedDraftID.rawValue), desiredSeen: true
            )),
            idempotencyKey: "exact-flag-wrong-reference-kind"
        )))
        XCTAssertThrowsError(try store.enqueueJob(.init(
            kind: .mailboxArchive,
            payloadJSON: try encoded(PlainpostMailboxArchiveInput(
                messageID: MessageID("msg-retained"),
                accountID: fixture.deleted.id,
                sourceMailboxPath: "INBOX",
                destinationMailboxPath: "Archive",
                uidValidity: 1,
                uid: 2
            )),
            idempotencyKey: "exact-archive-mismatched-account"
        )))

    }

    func testJobCompletionRejectsResultArtifactOwnershipConflict() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let job = try store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: String(decoding: try JSONEncoder().encode(PlainpostAIOperationInput(
                operation: .rebuildIndex,
                recordID: "",
                providerID: "deterministic"
            )), as: UTF8.self),
            idempotencyKey: "job-artifact-conflict"
        ))
        let leased = try XCTUnwrap(try store.claimNextJob(
            now: Date().addingTimeInterval(1),
            leaseDuration: 60,
            allowedKinds: [.searchRebuild]
        ))
        let artifact = DurableOperationArtifact(
            id: "artifact-wrong-owner",
            kind: "search-rebuild",
            recordID: "aggregate",
            payloadJSON: "{}"
        )
        try executeSQL(
            """
            INSERT INTO durable_operation_artifacts (
                id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind
            ) VALUES ('artifact-wrong-owner', 'search-rebuild', 'aggregate', '{}', 0, NULL, 'shared');
            """,
            at: url
        )

        XCTAssertThrowsError(try store.completeJob(
            id: job.id,
            leaseToken: try XCTUnwrap(leased.leaseToken),
            resultArtifactID: artifact.id
        ))
        XCTAssertEqual(try store.job(id: job.id).state, .running)
    }

    func testInternalAccountDeletionPurgesExplicitOrphanOwnerWithoutLiveAccount() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let orphanID = AccountID("acc-orphan")
        let draft = Draft(
            id: DraftID("drf-orphan"), accountID: orphanID,
            from: EmailAddress("from@example.com"), to: [EmailAddress("to@example.com")],
            cc: [], bcc: [], subject: "Orphan", bodyPlain: "Body",
            createdBy: "local-user", aiGenerated: false, sourceThreadID: nil
        )
        try executeSQL(
            """
            INSERT INTO drafts (id, payload_json, owner_account_id, ownership_kind)
            VALUES ('drf-orphan', \(sqlLiteral(String(decoding: try JSONEncoder().encode(draft), as: UTF8.self))), 'acc-orphan', 'account');
            """,
            at: url
        )

        try store.deleteAccountData(accountID: orphanID, requiresLiveAccount: false)

        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM drafts WHERE id = 'drf-orphan'", at: url), 0)
    }

    func testBatchRecategorizationDrainsAuditOutboxImmediately() throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        try cacheOwnedMessage(PlainpostFixtures.aliceMessage, store: store, uid: 8_002)

        try store.recategorize(
            [MessageCategoryUpdate(messageID: PlainpostFixtures.aliceMessage.id, category: .finance)],
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM audit_entries", at: url), 0)
        XCTAssertTrue(try String(contentsOf: store.auditLogURL, encoding: .utf8).contains("category.change"))
    }

    func testMigratesLegacyAccountsTableWithoutSentMailbox() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try executeSQL("""
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            email TEXT NOT NULL,
            username TEXT NOT NULL DEFAULT '',
            imap_host TEXT NOT NULL,
            imap_port INTEGER NOT NULL DEFAULT 993,
            smtp_host TEXT NOT NULL,
            smtp_port INTEGER NOT NULL DEFAULT 587
        );
        """, at: url)
        try executeSQL("""
        INSERT INTO accounts (id, display_name, email, username, imap_host, imap_port, smtp_host, smtp_port)
        VALUES ('acc_me_example_com', 'Personal', 'me@example.com', 'login-id', 'imap.example.com', 993, 'smtp.example.com', 587);
        """, at: url)

        let migrated = try migratedStore(at: url)

        XCTAssertEqual(migrated.accounts.first?.sentMailbox, "Sent")
    }

    func testMigratesCachesAndReloadsMailMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let seed = InMemoryMailStore.seededForStage0()
        let writer = try SQLiteMailStore(path: url.path)
        try writer.migrate()
        try writer.cacheAccounts(seed.accounts)
        try writer.cacheMailboxes(seed.mailboxes)
        try writer.cacheThreads(seed.threads)
        let sentAt = Date(timeIntervalSince1970: 1_783_585_600)
        let seenMessage = MessageSummary(
            id: seed.messages[0].id,
            threadID: seed.messages[0].threadID,
            from: seed.messages[0].from,
            fromDisplayName: "Alice Example",
            subject: seed.messages[0].subject,
            preview: seed.messages[0].preview,
            smartCategory: seed.messages[0].smartCategory,
            labels: seed.messages[0].labels,
            isSeen: true,
            mailboxPath: seed.messages[0].mailboxPath,
            isDeleted: seed.messages[0].isDeleted,
            body: seed.messages[0].body,
            bodyHTML: seed.messages[0].bodyHTML,
            sentAt: sentAt
        )
        try writer.cacheMessage(seenMessage)

        let reader = try SQLiteMailStore(path: url.path)
        try reader.migrate()

        XCTAssertEqual(reader.accounts, seed.accounts)
        XCTAssertEqual(reader.mailboxes, seed.mailboxes)
        XCTAssertEqual(reader.threads, seed.threads)
        XCTAssertEqual(reader.messages, [seenMessage])
    }

    func testMailboxPathsAreAccountScopedAndSortedWithoutLoadingMailboxObjectsInUI() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let first = AccountID("first")
        let second = AccountID("second")
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("z"), accountID: first, name: "Z", path: "Zulu", specialUse: nil),
            Mailbox(id: MailboxID("a"), accountID: first, name: "A", path: "Archive", specialUse: nil),
            Mailbox(id: MailboxID("other"), accountID: second, name: "Other", path: "Other", specialUse: nil),
        ])

        XCTAssertEqual(try store.mailboxPaths(accountID: first), ["Archive", "Zulu"])
    }

    func testPersistsFullMessageBodySeparatelyFromPreview() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let message = MessageSummary(
            id: MessageID("msg_full_body"),
            threadID: ThreadID("thr_full_body"),
            from: EmailAddress("sender@example.com"),
            subject: "Full body",
            preview: "Short preview",
            body: "Complete decoded body with multiple paragraphs.\n\nSecond paragraph.",
            bodyHTML: "<html><body><p>Complete decoded body with multiple paragraphs.</p></body></html>",
            smartCategory: .personal
        )
        try writer.cacheMessage(message)

        let reader = try migratedStore(at: url)
        XCTAssertEqual(reader.messages.first?.preview, "Short preview")
        XCTAssertEqual(reader.messages.first?.body, "Complete decoded body with multiple paragraphs.\n\nSecond paragraph.")
        XCTAssertEqual(
            reader.messages.first?.bodyHTML,
            "<html><body><p>Complete decoded body with multiple paragraphs.</p></body></html>"
        )
    }

    func testPersistsDraftSendRequestAndAuditAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Reply with availability")

        let reader = try migratedStore(at: url)

        XCTAssertEqual(try reader.draft(id: draft.id), draft)
        XCTAssertEqual(try reader.sendRequest(id: request.id), request)
        XCTAssertEqual(reader.approvalQueueRequests, [request])
        XCTAssertEqual(reader.auditEntries.map(\.action), ["draft.create", "send.request"])
    }

    func testConcurrentOptimisticDraftUpdatesAllowExactlyOneWriterAndAuditOnlyTheWinner() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let gate = ConcurrentStartGate(participants: 2)

        let first = Task {
            await gate.arriveAndWait()
            return optimisticDraftUpdateOutcome(
                store: store,
                draft: draft,
                body: "First concurrent body"
            )
        }
        let second = Task {
            await gate.arriveAndWait()
            return optimisticDraftUpdateOutcome(
                store: store,
                draft: draft,
                body: "Second concurrent body"
            )
        }

        let outcomes = await [first.value, second.value]
        let winningBodies = outcomes.compactMap(\.body)
        XCTAssertEqual(winningBodies.count, 1, "Expected exactly one optimistic writer to succeed: \(outcomes)")
        XCTAssertEqual(outcomes.filter(\.isConflict).count, 1, "Expected the stale writer to conflict: \(outcomes)")
        XCTAssertEqual(try store.draft(id: draft.id).bodyPlain, winningBodies.first)
        XCTAssertEqual(
            store.auditEntries.filter { $0.targetID == draft.id.rawValue }.map(\.action),
            ["draft.create", "draft.update"]
        )
    }

    func testConcurrentNoOpOptimisticUpdatesDoNotRecordMutationAudits() async throws {
        let url = temporarySQLiteURL()
        let store = try migratedStore(at: url)
        defer { removeSQLiteAndAuditArtifacts(databaseURL: url, auditLogURL: store.auditLogURL) }
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let gate = ConcurrentStartGate(participants: 2)

        let first = Task {
            await gate.arriveAndWait()
            return optimisticNoOpDraftUpdateOutcome(store: store, draft: draft)
        }
        let second = Task {
            await gate.arriveAndWait()
            return optimisticNoOpDraftUpdateOutcome(store: store, draft: draft)
        }

        let outcomes = await [first.value, second.value]
        XCTAssertEqual(outcomes.compactMap(\.body), [draft.bodyPlain, draft.bodyPlain])
        XCTAssertEqual(try store.draft(id: draft.id), draft)
        XCTAssertEqual(
            store.auditEntries.filter { $0.targetID == draft.id.rawValue }.map(\.action),
            ["draft.create"]
        )
    }

    func testPersistsApprovalSendStatusAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        _ = try writer.claimSendRequestForDelivery(
            id: request.id,
            currentDraftHash: draft.contentHash,
            actor: PlainpostFixtures.guiUser
        )
        let updated = try writer.updateSendRequest(
            id: request.id,
            status: .sent,
            approvedBy: PlainpostFixtures.guiUser.id,
            approvedDraftHash: draft.contentHash
        )

        let reader = try migratedStore(at: url)

        XCTAssertEqual(try reader.sendRequest(id: request.id), updated)
        XCTAssertEqual(try reader.sendRequest(id: request.id).status, .sent)
        XCTAssertEqual(try reader.sendRequest(id: request.id).approvedBy, PlainpostFixtures.guiUser.id)
        XCTAssertEqual(try reader.sendRequest(id: request.id).approvedDraftHash, draft.contentHash)
        XCTAssertEqual(
            reader.auditEntries.map(\.action),
            ["draft.create", "send.request", "send.approved", "send.sending", "send.sent"]
        )
    }

    func testPersistsSendCancellationAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let cancelled = try writer.cancelSendRequest(id: request.id, actor: PlainpostFixtures.codexActor)

        let reader = try migratedStore(at: url)

        XCTAssertEqual(try reader.sendRequest(id: request.id), cancelled)
        XCTAssertEqual(try reader.sendRequest(id: request.id).status, .cancelled)
        XCTAssertEqual(reader.auditEntries.map(\.action), ["draft.create", "send.request", "send.cancel"])
        XCTAssertThrowsError(try reader.sendRequest(id: SendRequestID("srq_missing"))) { error in
            XCTAssertEqual(error as? PlainpostError, .notFound("Send request not found."))
        }
    }

    func testPersistsLocalSentCopyAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let sentMessage = try writer.recordSentMessage(
            draft: draft,
            requestID: request.id,
            actor: PlainpostFixtures.guiUser
        )

        let reader = try migratedStore(at: url)

        XCTAssertEqual(reader.mailboxes.first(where: { $0.path == "Sent" })?.specialUse, "\\Sent")
        XCTAssertEqual(reader.messages, [sentMessage])
        XCTAssertEqual(sentMessage.id, MessageID("msg_sent_\(request.id.rawValue)"))
        XCTAssertEqual(sentMessage.threadID, draft.sourceThreadID)
        XCTAssertEqual(sentMessage.subject, draft.subject)
        XCTAssertEqual(sentMessage.labels, ["Sent"])
        XCTAssertTrue(sentMessage.isSeen)
        XCTAssertEqual(
            reader.auditEntries.map(\.action),
            ["draft.create", "send.request", "mail_label.create", "label.add", "message.sent_copy"]
        )
    }

    func testInMemorySentCopyUpdatesExistingSentMailboxPath() throws {
        let account = Account(
            id: AccountID("acc_me_example_com"),
            displayName: "Personal",
            email: EmailAddress("me@example.com"),
            sentMailbox: "Sent Items",
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let store = InMemoryMailStore(
            accounts: [account],
            mailboxes: [
                Mailbox(
                    id: MailboxID("mbx_acc_me_example_com_sent"),
                    accountID: account.id,
                    name: "Sent",
                    path: "Sent",
                    specialUse: "\\Sent"
                )
            ]
        )
        let draft = Draft(
            id: DraftID("drf_custom_sent"),
            accountID: account.id,
            from: account.email,
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Tuesday works for me.",
            createdBy: "codex",
            aiGenerated: false,
            sourceThreadID: nil
        )

        _ = store.recordSentMessage(
            draft: draft,
            requestID: SendRequestID("srq_custom_sent"),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(store.mailboxes.first(where: { $0.id == MailboxID("mbx_acc_me_example_com_sent") })?.path, "Sent Items")
    }


    func testPersistsRemoteSentAppendFailureWarningAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)

        writer.recordSendWarning(
            requestID: request.id,
            action: "send.remote_sent_append_failed",
            actor: PlainpostFixtures.guiUser
        )

        let reader = try migratedStore(at: url)

        XCTAssertEqual(
            reader.auditEntries.map(\.action),
            ["draft.create", "send.request", "send.remote_sent_append_failed"]
        )
        XCTAssertEqual(reader.auditEntries.last?.targetType, "send_request")
        XCTAssertEqual(reader.auditEntries.last?.targetID, request.id.rawValue)
    }

    func testPersistsMessageMetadataMutationsAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        let sentAt = Date(timeIntervalSince1970: 1_783_585_600)
        let message = MessageSummary(
            id: MessageID("msg_newsletter_1"),
            threadID: nil,
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter,
            sentAt: sentAt
        )
        try cacheOwnedMessage(message, store: writer, uid: 8_003)

        _ = try writer.addLabel("Pinned", to: message.id, actor: PlainpostFixtures.codexActor)
        _ = try writer.recategorize(message.id, as: .notification, actor: PlainpostFixtures.codexActor)
        _ = try writer.markSeen(message.id, seen: true, actor: PlainpostFixtures.codexActor)

        let reader = try migratedStore(at: url)
        let saved = try XCTUnwrap(reader.messages.first { $0.id == message.id })
        XCTAssertEqual(saved.labels, ["Pinned"])
        XCTAssertEqual(saved.smartCategory, .notification)
        XCTAssertEqual(saved.isSeen, true)
        XCTAssertEqual(saved.sentAt, sentAt)
        XCTAssertTrue(reader.auditEntries.contains { $0.action == "label.add" && $0.targetID == message.id.rawValue })
        XCTAssertTrue(reader.auditEntries.contains { $0.action == "category.change" && $0.targetID == message.id.rawValue })
        XCTAssertTrue(reader.auditEntries.contains { $0.action == "message.mark_seen" && $0.targetID == message.id.rawValue })
    }

    func testPersistsMessageMailboxAndDeletedStateAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try migratedStore(at: url)
        try writer.cacheAccounts([PlainpostFixtures.personalAccount])
        try writer.cacheMailboxes([
            PlainpostFixtures.inboxMailbox,
            Mailbox(
                id: MailboxID("mbx_archive"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: "Archive",
                path: "Archive",
                specialUse: "\\Archive"
            ),
        ])
        try writer.cacheThread(PlainpostFixtures.aliceThread)
        try writer.cacheMessage(PlainpostFixtures.aliceMessage)
        _ = try writer.moveMessage(
            PlainpostFixtures.aliceMessage.id,
            toMailboxPath: "Archive",
            actor: PlainpostFixtures.codexActor
        )
        _ = try writer.markDeleted(
            PlainpostFixtures.aliceMessage.id,
            deleted: true,
            actor: PlainpostFixtures.codexActor
        )

        let reader = try migratedStore(at: url)
        let saved = try XCTUnwrap(reader.messages.first { $0.id == PlainpostFixtures.aliceMessage.id })
        XCTAssertEqual(saved.mailboxPath, "Archive")
        XCTAssertEqual(saved.isDeleted, true)
        XCTAssertTrue(reader.auditEntries.contains { $0.action == "message.move" && $0.targetID == saved.id.rawValue })
        XCTAssertTrue(reader.auditEntries.contains { $0.action == "message.delete" && $0.targetID == saved.id.rawValue })
    }

    func testSerializesConcurrentSQLiteReadsAndWrites() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try migratedStore(at: url)
        let seed = InMemoryMailStore.seededForStage0().messages[0]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try store.cacheMessage(seed.withSeen(index.isMultiple(of: 4)))
                    } else {
                        _ = store.messages
                        _ = store.auditEntries
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(store.messages.first?.id, seed.id)
    }

    func testIncomingMessageCommitIsAtomicAndClassifiesDuplicateMembership() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let metadata = IncomingMessageSearchMetadata(
            to: [EmailAddress("me@example.com")],
            cc: [],
            bcc: [],
            attachments: [.init(filename: "agenda.pdf", mimeType: "application/pdf")],
            messageIdentifiers: ["<message@example.com>"]
        )

        let first = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 42,
            notificationEligible: false
        )
        let duplicate = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 42,
            notificationEligible: false
        )

        XCTAssertTrue(first.insertedMembership)
        XCTAssertFalse(duplicate.insertedMembership)
        XCTAssertEqual(try store.cachedUIDs(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7
        ), Set([42]))
        let response = try await SQLiteMailSearchService(store: store).search(
            .init(query: "filename:agenda.pdf", mode: .messages)
        )
        let messageIDs = response.hits.compactMap { hit -> MessageID? in
            guard case .message(let message) = hit else { return nil }
            return message.messageID
        }
        XCTAssertEqual(messageIDs, [message.id])
    }

    func testIncomingMessageCommitAtomicallyPersistsDecodedAttachmentPayloads() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2.1",
            filename: "agenda.pdf",
            mimeType: "application/pdf",
            data: Data("agenda payload".utf8)
        )
        let metadata = IncomingMessageSearchMetadata(
            to: [EmailAddress("me@example.com")],
            cc: [],
            bcc: [],
            attachments: [
                .init(filename: payload.filename, mimeType: payload.mimeType)
            ],
            messageIdentifiers: ["<message@example.com>"]
        )

        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            attachments: [payload],
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 42,
            notificationEligible: false
        )

        XCTAssertEqual(try store.incomingMessageAttachments(messageID: message.id), [payload])
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM incoming_message_attachments WHERE message_id = '\(message.id.rawValue)'",
                at: url
            ),
            1
        )
    }

    func testIncomingAttachmentMetadataAndChunkReadKeepMessageAndPartBoundaries() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let payloads = [
            IncomingMessageAttachmentPayload(
                partPath: "2", filename: "first.txt", mimeType: "text/plain",
                data: Data("first".utf8)
            ),
            IncomingMessageAttachmentPayload(
                partPath: "3", filename: "second.txt", mimeType: "text/plain",
                data: Data("second".utf8)
            )
        ]
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [],
                attachments: payloads.map { .init(filename: $0.filename, mimeType: $0.mimeType) },
                messageIdentifiers: []
            ),
            attachments: payloads, accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )

        let metadata = try store.incomingMessageAttachmentMetadata(messageID: message.id)
        XCTAssertEqual(metadata.map(\.partPath), ["2", "3"])
        XCTAssertEqual(metadata.map(\.byteCount), [5, 6])
        XCTAssertEqual(
            try store.incomingMessageAttachmentChunk(
                messageID: message.id, partPath: "3", offset: 2, length: 3
            )?.data,
            Data("con".utf8)
        )
        XCTAssertNil(try store.incomingMessageAttachmentChunk(
            messageID: message.id, partPath: "4", offset: 0, length: 3
        ))
        XCTAssertNil(try store.incomingMessageAttachmentChunk(
            messageID: MessageID("different-message"), partPath: "3", offset: 0, length: 3
        ))
    }

    func testIncomingAttachmentReadRejectsRawFilenameAndMIMECanonicalizationDrift() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2",
            filename: "agenda.pdf",
            mimeType: "application/pdf",
            data: Data("agenda payload".utf8)
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [.init(filename: payload.filename, mimeType: payload.mimeType)],
                messageIdentifiers: []
            ),
            attachments: [payload],
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 46,
            notificationEligible: false
        )

        try executeSQL(
            """
            UPDATE incoming_message_attachments
            SET filename = 'unsafe/name.pdf',
                mime_type = 'Application/PDF; charset=binary'
            WHERE message_id = '\(message.id.rawValue)';
            """,
            at: url
        )

        XCTAssertThrowsError(try store.incomingMessageAttachments(messageID: message.id))
    }

    func testIncomingAttachmentReadRejectsDuplicateAndGappedOrdinals() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let payloads = [
            IncomingMessageAttachmentPayload(
                partPath: "2",
                filename: "first.bin",
                mimeType: "application/octet-stream",
                data: Data("first".utf8)
            ),
            IncomingMessageAttachmentPayload(
                partPath: "3",
                filename: "second.bin",
                mimeType: "application/octet-stream",
                data: Data("second".utf8)
            )
        ]
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: payloads.map {
                    .init(filename: $0.filename, mimeType: $0.mimeType)
                },
                messageIdentifiers: []
            ),
            attachments: payloads,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 47,
            notificationEligible: false
        )

        try executeSQL(
            "UPDATE incoming_message_attachments SET ordinal = 0 WHERE message_id = '\(message.id.rawValue)';",
            at: url
        )
        XCTAssertThrowsError(try store.incomingMessageAttachments(messageID: message.id))

        try executeSQL(
            """
            UPDATE incoming_message_attachments
            SET ordinal = CASE part_path WHEN '2' THEN 0 ELSE 2 END
            WHERE message_id = '\(message.id.rawValue)';
            """,
            at: url
        )
        XCTAssertThrowsError(try store.incomingMessageAttachments(messageID: message.id))
    }

    func testIncomingAttachmentReadRejectsCollectionCountOverLimitBeforePayloadFetch() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        try store.cacheMessage(message)

        try executeSQL(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 0
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 512
            )
            INSERT INTO incoming_message_attachments (
                message_id, part_path, ordinal, filename, mime_type,
                byte_count, sha256, payload
            )
            SELECT
                '\(message.id.rawValue)',
                printf('%d', value + 1),
                value,
                printf('attachment-%d.bin', value),
                'application/octet-stream',
                0,
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                x''
            FROM sequence;
            """,
            at: url
        )

        XCTAssertThrowsError(try store.incomingMessageAttachments(messageID: message.id))
    }

    func testIncomingAttachmentMetadataMismatchRollsBackWholeMessageCommit() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = MessageSummary(
            id: MessageID("msg_attachment_atomic_rollback"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Atomic attachment",
            preview: "Must not partially commit.",
            smartCategory: .personal
        )
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2",
            filename: "actual.pdf",
            mimeType: "application/pdf",
            data: Data("payload".utf8)
        )
        let inconsistentMetadata = IncomingMessageSearchMetadata(
            to: [],
            cc: [],
            bcc: [],
            attachments: [.init(filename: "different.pdf", mimeType: "application/pdf")],
            messageIdentifiers: []
        )

        XCTAssertThrowsError(try store.commitIncomingMessage(
            message,
            metadata: inconsistentMetadata,
            attachments: [payload],
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 44,
            notificationEligible: false
        ))

        XCTAssertNil(try store.messageSummary(id: message.id))
        XCTAssertTrue(try store.incomingMessageAttachments(messageID: message.id).isEmpty)
        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM mailbox_messages WHERE message_id = '\(message.id.rawValue)'",
                at: url
            ),
            0
        )
    }

    func testIncomingAttachmentRowsCascadeWhenCanonicalMessageIsRemoved() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2",
            filename: "cascade.bin",
            mimeType: "application/octet-stream",
            data: Data([0, 1, 2])
        )
        let metadata = IncomingMessageSearchMetadata(
            to: [],
            cc: [],
            bcc: [],
            attachments: [.init(filename: payload.filename, mimeType: payload.mimeType)],
            messageIdentifiers: []
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            attachments: [payload],
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 45,
            notificationEligible: false
        )

        try executeSQL(
            """
            PRAGMA foreign_keys = ON;
            DELETE FROM mailbox_messages WHERE message_id = '\(message.id.rawValue)';
            DELETE FROM messages WHERE id = '\(message.id.rawValue)';
            """,
            at: url
        )

        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM incoming_message_attachments", at: url),
            0
        )
    }

    func testInboundAttachmentMigrationDoesNotFabricateRowsForExistingMessages() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)

        try store.cacheMessage(PlainpostFixtures.aliceMessage)

        XCTAssertTrue(
            try store.incomingMessageAttachments(
                messageID: PlainpostFixtures.aliceMessage.id
            ).isEmpty
        )
        XCTAssertEqual(
            try queryInteger("SELECT COUNT(*) FROM incoming_message_attachments", at: url),
            0
        )
    }

    func testMessageRefreshesPreserveSourceOwnedLabelStateAndSearchProjection() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let message = MessageSummary(
            id: MessageID("msg_source_owned_refresh"),
            threadID: nil,
            from: EmailAddress("travel@example.com"),
            subject: "Travel plans",
            preview: "A source-owned label must survive refresh.",
            smartCategory: .personal
        )
        let metadata = IncomingMessageSearchMetadata(
            to: [],
            cc: [],
            bcc: [],
            attachments: [],
            messageIdentifiers: []
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 77,
            notificationEligible: false
        )
        try store.saveMailLabel(try MailLabelDefinition.validated(
            id: "travel-refresh",
            title: "Travel",
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        ))
        try store.addUserLabel(
            labelID: "travel-refresh",
            to: message.id,
            actor: PlainpostFixtures.codexActor
        )
        let assignmentsBefore = try store.labelAssignments(for: message.id)

        _ = try store.commitIncomingMessage(
            message.withSeen(true),
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 77,
            notificationEligible: false
        )
        try store.cacheMessageReliably(message.withSeen(false))

        XCTAssertEqual(try store.labelAssignments(for: message.id), assignmentsBefore)
        XCTAssertEqual(
            try XCTUnwrap(store.messages.first { $0.id == message.id }).labels,
            ["Travel"]
        )
        XCTAssertEqual(try store.searchMessages("Travel"), [message.id])
    }

    func testNewIncomingMessageImportsUserVisibleLabelsAsUserOwnedDefinitions() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let message = MessageSummary(
            id: MessageID("msg_remote_label_import"),
            threadID: nil,
            from: EmailAddress("vip@example.com"),
            subject: "Invitation",
            preview: "Import the visible remote label.",
            smartCategory: .personal,
            labels: ["VIP"]
        )

        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 88,
            notificationEligible: false
        )

        let definition = try XCTUnwrap(store.mailLabels(
            effectiveFor: PlainpostFixtures.personalAccount.id
        ).first { $0.normalizedTitle == "vip" })
        XCTAssertFalse(definition.isSmartInboxEnabled)
        XCTAssertEqual(
            try store.labelAssignments(for: message.id).map(\.source),
            [.user]
        )
        XCTAssertEqual(
            try XCTUnwrap(store.messages.first { $0.id == message.id }).labels,
            ["VIP"]
        )
        XCTAssertTrue(store.auditEntries.contains {
            $0.actorID == "mail-ingestion"
                && $0.action == "label.add"
                && $0.targetID == message.id.rawValue
        })
    }

    func testFirstReliableCacheInsertImportsUserVisibleLabelsAsUserOwnership() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        let threadID = ThreadID("thread_reliable_cache_label_import")
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: threadID,
            accountID: account.id,
            subjectNormalized: "invitation",
            participantEmails: [EmailAddress("vip@example.com")]
        ))
        let message = MessageSummary(
            id: MessageID("msg_reliable_cache_label_import"),
            threadID: threadID,
            from: EmailAddress("vip@example.com"),
            subject: "Invitation",
            preview: "Import the reliable-cache label.",
            smartCategory: .personal,
            labels: ["VIP"]
        )

        try store.cacheMessageReliably(message)

        let definition = try XCTUnwrap(
            store.mailLabels(effectiveFor: nil).first { $0.normalizedTitle == "vip" }
        )
        XCTAssertFalse(definition.isSmartInboxEnabled)
        XCTAssertEqual(
            try store.labelAssignments(for: message.id).map(\.source),
            [.user]
        )
        XCTAssertEqual(
            try XCTUnwrap(store.messages.first { $0.id == message.id }).labels,
            ["VIP"]
        )
        XCTAssertEqual(try store.searchMessages("VIP"), [message.id])
        XCTAssertTrue(store.auditEntries.contains {
            $0.actorID == "mail-ingestion"
                && $0.action == "label.add"
                && $0.targetID == message.id.rawValue
        })
    }

    func testThreadAccountFallbackMakesScopedLabelsAccessibleToCacheCreatedMessage() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        let threadID = ThreadID("thread_scoped_label_fallback")
        let messageID = MessageID("msg_scoped_label_fallback")
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: threadID,
            accountID: account.id,
            subjectNormalized: "scoped labels",
            participantEmails: [EmailAddress("sender@example.com")]
        ))
        try store.cacheMessageReliably(MessageSummary(
            id: messageID,
            threadID: threadID,
            from: EmailAddress("sender@example.com"),
            subject: "Scoped labels",
            preview: "Resolve the account through the thread.",
            smartCategory: .personal
        ))
        try store.saveMailLabel(try MailLabelDefinition.validated(
            id: "account-travel",
            title: "Travel",
            description: "",
            isSmartInboxEnabled: false,
            scope: .account(account.id)
        ))
        try store.saveMailLabel(try MailLabelDefinition.validated(
            id: "account-vip",
            title: "VIP",
            description: "",
            isSmartInboxEnabled: false,
            scope: .account(account.id)
        ))

        try store.addUserLabel(
            labelID: "account-travel",
            to: messageID,
            actor: PlainpostFixtures.codexActor
        )
        _ = try store.addLabel(
            "vip",
            to: messageID,
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(
            Set(try store.labelAssignments(for: messageID).map(\.labelID)),
            ["account-travel", "account-vip"]
        )
        XCTAssertEqual(
            try XCTUnwrap(store.messages.first { $0.id == messageID }).labels,
            ["Travel", "VIP"]
        )
    }

    func testIncomingMessageRecommitPreservesCompleteAITupleAndInvalidatesChangedInputs() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accountID = PlainpostFixtures.personalAccount.id
        let metadata = IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        )
        let original = MessageSummary(
            id: MessageID("msg_recommit_ai_tuple"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            fromDisplayName: "Sender",
            subject: "Original subject",
            preview: "Original preview",
            smartCategory: .unknown
        )
        _ = try store.commitIncomingMessage(
            original,
            metadata: metadata,
            accountID: accountID,
            mailboxPath: "INBOX",
            uidValidity: 42,
            uid: 1,
            notificationEligible: false
        )
        let identity = SmartInboxClassifierContract.identity(
            providerID: "deterministic",
            modelID: "deterministic-local"
        )
        let job = try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                idempotencyKey: "recommit-ai-tuple-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: original.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: identity.discriminator
                    )
                ),
            ]
        )
        _ = try store.recordSmartInboxClassification(
            jobID: job.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: .init(
                messageID: original.id,
                category: .finance,
                priority: .high,
                requiresAction: true,
                confidence: 0.73
            ),
            providerID: identity.providerID,
            modelID: identity.modelID,
            classifierDiscriminator: identity.discriminator,
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        let cachedFingerprint = try XCTUnwrap(
            store.smartInboxClassificationCache()[original.id]
        ).sourceFingerprint

        _ = try store.commitIncomingMessage(
            original,
            metadata: metadata,
            accountID: accountID,
            mailboxPath: "INBOX",
            uidValidity: 42,
            uid: 1,
            notificationEligible: false
        )

        var afterUnchanged = try XCTUnwrap(store.smartInboxListMessages().first)
        XCTAssertEqual(afterUnchanged.smartCategory, .finance)
        XCTAssertEqual(afterUnchanged.smartPriority, .high)
        XCTAssertTrue(afterUnchanged.smartRequiresAction)
        XCTAssertEqual(afterUnchanged.smartConfidence, 0.73)
        let afterUnchangedInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        XCTAssertEqual(
            SmartInboxClassificationFingerprint.message(
                afterUnchangedInput,
                classifierDiscriminator: identity.discriminator
            ),
            cachedFingerprint
        )

        let changed = MessageSummary(
            id: original.id,
            threadID: original.threadID,
            from: original.from,
            fromDisplayName: original.fromDisplayName,
            subject: "Changed subject",
            preview: original.preview,
            smartCategory: .security
        )
        _ = try store.commitIncomingMessage(
            changed,
            metadata: metadata,
            accountID: accountID,
            mailboxPath: "INBOX",
            uidValidity: 42,
            uid: 1,
            notificationEligible: false
        )

        afterUnchanged = try XCTUnwrap(store.smartInboxListMessages().first)
        XCTAssertEqual(afterUnchanged.smartCategory, .finance)
        XCTAssertEqual(afterUnchanged.smartPriority, .high)
        XCTAssertTrue(afterUnchanged.smartRequiresAction)
        XCTAssertEqual(afterUnchanged.smartConfidence, 0.73)
        let changedInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        XCTAssertNotEqual(
            SmartInboxClassificationFingerprint.message(
                changedInput,
                classifierDiscriminator: identity.discriminator
            ),
            cachedFingerprint
        )
    }

    func testRankedMailSearchAcceptsNaturalLanguageAndReturnsEvidenceSnippet() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = MessageSummary(
            id: MessageID("msg_contractor_quote"),
            threadID: ThreadID("thr_renovation"),
            from: EmailAddress("builder@example.com"),
            subject: "Final renovation quote",
            preview: "Final numbers attached",
            body: "The contractor quote totals 4,200 euros including materials.",
            smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: .init(
                to: [PlainpostFixtures.personalAccount.email],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let results = try store.rankedMailSearch(
            MailKnowledgeQuery(text: "What did the contractor quote?", limit: 5)
        )

        XCTAssertEqual(results.map { $0.message.id }, [message.id])
        XCTAssertTrue(try XCTUnwrap(results.first).snippet.contains("contractor"))
    }

    func testFilteredMailMessagesAppliesStructuredFilters() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func commit(_ id: String, seen: Bool, category: SmartCategory, mailbox: String,
                    from: String, daysAgo: Double, uid: Int) throws {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress(from), subject: "S \(id)",
                               preview: "P", smartCategory: category, labels: [], isSeen: seen,
                               mailboxPath: mailbox, isDeleted: false,
                               sentAt: now.addingTimeInterval(-daysAgo * 86_400)),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: PlainpostFixtures.personalAccount.id, mailboxPath: mailbox,
                uidValidity: 1, uid: uid, notificationEligible: false)
        }
        try commit("hit", seen: false, category: .notification, mailbox: "INBOX", from: "noreply@github.com", daysAgo: 1, uid: 1)
        try commit("read", seen: true, category: .notification, mailbox: "INBOX", from: "noreply@github.com", daysAgo: 1, uid: 2)
        try commit("sent", seen: false, category: .notification, mailbox: "Sent", from: "noreply@github.com", daysAgo: 1, uid: 3)
        try commit("old", seen: false, category: .notification, mailbox: "INBOX", from: "noreply@github.com", daysAgo: 30, uid: 4)
        try commit("news", seen: false, category: .newsletter, mailbox: "INBOX", from: "noreply@github.com", daysAgo: 1, uid: 5)
        try commit("other", seen: false, category: .notification, mailbox: "INBOX", from: "lena@example.com", daysAgo: 1, uid: 6)

        let filter = MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox, senderContains: "GitHub",
                                         sentAfter: now.addingTimeInterval(-7 * 86_400), sentBefore: nil,
                                         categories: [.notification])
        let result = try store.filteredMailMessages(filter, accountID: PlainpostFixtures.personalAccount.id, limit: 10)
        XCTAssertEqual(result.messages.map(\.id), [MessageID("hit")])
        XCTAssertEqual(result.totalCount, 1)

        let unread = try store.filteredMailMessages(MailKnowledgeFilter(unreadOnly: true), accountID: nil, limit: 2)
        XCTAssertEqual(unread.totalCount, 5)
        XCTAssertEqual(unread.messages.count, 2)
    }

    func testAnyMailboxExcludesMembershipFreeTrashAndJunkFromRowsAndCounts() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        for (id, path, category) in [
            ("legacy-inbox", "INBOX", SmartCategory.personal),
            ("legacy-trash", "Trash", SmartCategory.notification),
            ("legacy-junk", "Junk", SmartCategory.newsletter),
        ] {
            try store.cacheMessageReliably(MessageSummary(
                id: MessageID(id), threadID: nil, from: EmailAddress("sender@example.test"),
                subject: id, preview: "Legacy cached message", smartCategory: category,
                labels: [], isSeen: false, mailboxPath: path, isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 1_790_000_000)
            ))
        }
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mailbox_messages", at: url), 0,
                       "The public legacy cache path has no provider memberships.")

        let filter = MailKnowledgeFilter(unreadOnly: true, mailbox: .any)
        let result = try store.filteredMailMessages(filter, accountID: nil, limit: 10)

        XCTAssertEqual(result.messages.map(\.id), [MessageID("legacy-inbox")])
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(try store.filteredMailCategoryCounts(filter, accountID: nil), [.personal: 1])
    }

    func testAnyMailboxClassifiesMembershipFreeRowsUsingTheirThreadAccountCatalog() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        let threadID = ThreadID("legacy-account-thread")
        try store.cacheAccounts([account])
        try store.cacheThread(MailThread(
            id: threadID, accountID: account.id, subjectNormalized: "legacy",
            participantEmails: [EmailAddress("sender@example.test")]
        ))
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("legacy-marked-trash"), accountID: account.id,
                    name: "Deleted Messages", path: "Deleted Messages", specialUse: "\\Trash"),
            Mailbox(id: MailboxID("legacy-ordinary-trash"), accountID: account.id,
                    name: "Trash", path: "Trash", specialUse: nil),
            Mailbox(id: MailboxID("legacy-marked-junk"), accountID: account.id,
                    name: "Rubbish", path: "Rubbish", specialUse: "\\Junk"),
        ])
        for (id, path, thread, category) in [
            ("legacy-ordinary-trash", "Trash", Optional(threadID), SmartCategory.personal),
            ("legacy-marked-trash", "Deleted Messages", Optional(threadID), SmartCategory.notification),
            ("legacy-marked-junk", "Rubbish", Optional(threadID), SmartCategory.newsletter),
            ("legacy-owned-inbox", "INBOX", Optional(threadID), SmartCategory.personal),
            ("legacy-unknown-trash", "[Gmail]/Papierkorb", nil, SmartCategory.notification),
            ("legacy-unknown-junk", "Junk", nil, SmartCategory.newsletter),
        ] {
            try store.cacheMessageReliably(MessageSummary(
                id: MessageID(id), threadID: thread, from: EmailAddress("sender@example.test"),
                subject: id, preview: "Legacy cached message", smartCategory: category,
                labels: [], isSeen: false, mailboxPath: path, isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 1_790_000_000)
            ))
        }
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("mixed-provider-inbox"), threadID: nil,
                from: EmailAddress("sender@example.test"), subject: "Provider Inbox",
                preview: "Membership-backed message", smartCategory: .personal,
                labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 1_790_000_000)
            ),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mailbox_messages", at: url), 1,
                       "Only the provider Inbox row has a membership; legacy rows coexist with it.")

        let filter = MailKnowledgeFilter(unreadOnly: true, mailbox: .any)
        let expected = Set(["legacy-ordinary-trash", "legacy-owned-inbox", "mixed-provider-inbox"])
        let scopes: [AccountID?] = [nil, account.id]
        for scope in scopes {
            let result = try store.filteredMailMessages(filter, accountID: scope, limit: 10)
            XCTAssertEqual(Set(result.messages.map(\.id.rawValue)), expected)
            XCTAssertEqual(result.totalCount, 3)
            XCTAssertEqual(try store.filteredMailCategoryCounts(filter, accountID: scope), [.personal: 3])
        }
    }

    func testAnyMailboxUsesEachAccountsMarkedTrash() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount.id
        func commit(_ id: String, mailbox: String, uid: Int) throws {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress("noreply@github.com"), subject: "S \(id)",
                               preview: "P", smartCategory: .notification, labels: [], isSeen: false,
                               mailboxPath: mailbox, isDeleted: false, sentAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(uid))),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account, mailboxPath: mailbox, uidValidity: 1, uid: uid, notificationEligible: false)
        }
        // iCloud: "Deleted Messages" is the marked Trash; the legacy "Trash" is an ordinary folder.
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("dm"), accountID: account, name: "Deleted Messages", path: "Deleted Messages", specialUse: "\\Trash"),
            Mailbox(id: MailboxID("legacy"), accountID: account, name: "Trash", path: "Trash", specialUse: nil),
            Mailbox(id: MailboxID("rubbish"), accountID: account, name: "Rubbish", path: "Rubbish", specialUse: "\\Junk"),
        ])
        try commit("inbox", mailbox: "INBOX", uid: 1)
        try commit("trashed", mailbox: "Deleted Messages", uid: 2)
        try commit("legacy", mailbox: "Trash", uid: 3)
        try commit("junk", mailbox: "Rubbish", uid: 4)

        let result = try store.filteredMailMessages(MailKnowledgeFilter(unreadOnly: true), accountID: account, limit: 10)

        XCTAssertEqual(Set(result.messages.map(\.id.rawValue)), ["inbox", "legacy"])
    }

    func testFilteredMailCategoryCountsAndAnyMailboxExcludesTrashAndJunk() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        func commit(_ id: String, category: SmartCategory, mailbox: String, uid: Int) throws {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress("noreply@github.com"), subject: "S \(id)",
                               preview: "P", smartCategory: category, labels: [], isSeen: false,
                               mailboxPath: mailbox, isDeleted: false, sentAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(uid))),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: PlainpostFixtures.personalAccount.id, mailboxPath: mailbox,
                uidValidity: 1, uid: uid, notificationEligible: false)
        }
        for index in 0..<4 { try commit("n\(index)", category: .notification, mailbox: "INBOX", uid: index + 1) }
        try commit("news", category: .newsletter, mailbox: "Archive", uid: 10)
        try commit("trash", category: .notification, mailbox: "Trash", uid: 11)
        try commit("deleted", category: .notification, mailbox: "Deleted Messages", uid: 12)
        try commit("junk", category: .newsletter, mailbox: "Junk", uid: 13)
        try commit("spam", category: .newsletter, mailbox: "[Gmail]/Spam", uid: 14)
        // Trash that only the shared resolver knows: Gmail's Bin and a localized name.
        try commit("bin", category: .notification, mailbox: "[Google Mail]/Bin", uid: 15)
        try commit("papierkorb", category: .notification, mailbox: "[Gmail]/Papierkorb", uid: 16)

        let filter = MailKnowledgeFilter(unreadOnly: true)
        let result = try store.filteredMailMessages(filter, accountID: PlainpostFixtures.personalAccount.id, limit: 2)
        XCTAssertEqual(result.totalCount, 5)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(try store.filteredMailCategoryCounts(filter, accountID: PlainpostFixtures.personalAccount.id),
                       [.notification: 4, .newsletter: 1])
        XCTAssertEqual(try store.filteredMailCategoryCounts(MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox), accountID: nil),
                       [.notification: 4])
    }

    func testConversationMessagesReadsOneThreadWithinTheAccount() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["acct-a", "acct-b"].map { id in
            Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        func commit(_ id: String, thread: String?, account: Account, uid: Int, deleted: Bool = false) throws {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID(id), threadID: thread.map { ThreadID($0) }, from: EmailAddress("x@example.com"),
                               subject: "S", preview: "P", smartCategory: .personal, labels: [], isSeen: false,
                               mailboxPath: "INBOX", isDeleted: deleted, sentAt: Date(timeIntervalSince1970: Double(1_790_000_000 + uid))),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: uid, notificationEligible: false)
        }
        try commit("a1", thread: "thr_x", account: accounts[0], uid: 1)
        try commit("a2", thread: "thr_x", account: accounts[0], uid: 2)
        try commit("b1", thread: "thr_y", account: accounts[1], uid: 3)
        try commit("solo", thread: nil, account: accounts[0], uid: 4)

        XCTAssertEqual(Set(try store.conversationMessages(conversationKey: "thr_x", accountID: accounts[0].id).map(\.id)),
                       Set([MessageID("a1"), MessageID("a2")]))
        XCTAssertEqual(try store.conversationMessages(conversationKey: "thr_y", accountID: accounts[0].id), [])
        XCTAssertEqual(try store.conversationMessages(conversationKey: "message_solo", accountID: accounts[0].id).map(\.id),
                       [MessageID("solo")])
    }

    /// `filteredMailMessages` must apply the same ownership test as `accountMessageIDs`: a message
    /// with mailbox memberships for two different accounts belongs to neither when scoped, even
    /// though `smartInboxMessageAccountExpression` alone would resolve it to one of them.
    func testFilteredMailMessagesExcludesMessagesOwnedByMultipleAccounts() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["acct-a", "acct-b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        let shared = MessageSummary(id: MessageID("shared"), threadID: nil, from: EmailAddress("shared@example.com"),
                                    subject: "Shared", preview: "P", smartCategory: .notification, labels: [],
                                    isSeen: false, mailboxPath: "INBOX", isDeleted: false, sentAt: Date())
        _ = try store.commitIncomingMessage(
            shared, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accounts[0].id, mailboxPath: "INBOX", uidValidity: 1, uid: 1, notificationEligible: false)
        _ = try store.commitIncomingMessage(
            shared, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accounts[1].id, mailboxPath: "INBOX", uidValidity: 1, uid: 2, notificationEligible: false)
        let aOnly = MessageSummary(id: MessageID("a-only"), threadID: nil, from: EmailAddress("solo@example.com"),
                                   subject: "A only", preview: "P", smartCategory: .notification, labels: [],
                                   isSeen: false, mailboxPath: "INBOX", isDeleted: false, sentAt: Date())
        _ = try store.commitIncomingMessage(
            aOnly, metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accounts[0].id, mailboxPath: "INBOX", uidValidity: 1, uid: 3, notificationEligible: false)

        let result = try store.filteredMailMessages(MailKnowledgeFilter(unreadOnly: true), accountID: accounts[0].id, limit: 10)
        XCTAssertEqual(result.messages.map(\.id), [MessageID("a-only")])
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(try store.accountMessageIDs(accountID: accounts[0].id), Set([MessageID("a-only")]))
    }

    func testAccountBoundedMailKnowledgeSearchExcludesForeignEvidence() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        for (index, account) in accounts.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("private-\(index)"), threadID: ThreadID("shared-thread"),
                               from: account.email, subject: "Private quote", preview: "Private quote",
                               body: "The private quote is \(index + 1) euros.", smartCategory: .personal),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1, uid: index + 1,
                notificationEligible: false)
        }
        let scoped = try store.rankedMailSearch(MailKnowledgeQuery(
            text: "private quote", accountID: accounts[1].id))
        XCTAssertEqual(scoped.map { $0.message.id }, [MessageID("private-1")])
        XCTAssertEqual(try store.accountMessageIDs(accountID: accounts[1].id), Set([MessageID("private-1")]))
        XCTAssertEqual(try store.rankedMailSearch(MailKnowledgeQuery(text: "private quote")).count, 2)
    }

    func testDurableMailEmbeddingChunksRoundTripAcrossReopen() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        try store.cacheMessageReliably(PlainpostFixtures.aliceMessage)
        let chunk = StoredMailEmbeddingChunk(
            messageID: PlainpostFixtures.aliceMessage.id,
            providerID: "ollama",
            modelID: "ollama:mxbai-embed-large",
            contentFingerprint: "fingerprint-v1",
            ordinal: 0,
            text: "Availability next Tuesday",
            vector: [0.25, -0.5, 0.75]
        )
        try store.replaceMailEmbeddingChunks(
            messageID: chunk.messageID,
            providerID: chunk.providerID,
            modelID: chunk.modelID,
            contentFingerprint: chunk.contentFingerprint,
            chunks: [chunk]
        )

        let reopened = try migratedStore(at: url)
        let saved = try XCTUnwrap(
            reopened.storedMailEmbeddingChunks(providerID: chunk.providerID, modelID: chunk.modelID).first
        )

        XCTAssertEqual(saved.messageID, chunk.messageID)
        XCTAssertEqual(saved.contentFingerprint, chunk.contentFingerprint)
        XCTAssertEqual(saved.text, chunk.text)
        XCTAssertEqual(saved.vector, chunk.vector)
    }

    func testMailboxReconciliationUpdatesFlagsAndRemovesExpungedMembership() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            uid: 77,
            notificationEligible: false
        )

        try store.reconcileMailboxState(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            states: [IMAPRemoteMessageState(uid: 77, flags: ["\\Seen"])]
        )
        XCTAssertTrue(try XCTUnwrap(store.messages.first).isSeen)

        try store.reconcileMailboxState(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            states: []
        )
        XCTAssertTrue(try XCTUnwrap(store.messages.first).isDeleted)
        XCTAssertTrue(try store.cachedUIDs(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9
        ).isEmpty)
    }

    func testMailboxReconciliationNoOpDoesNotAdvanceSearchRevision() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            uid: 77,
            notificationEligible: false
        )
        let revisionBefore = try queryInteger(
            "SELECT revision FROM mail_search_state WHERE account_id = '\(PlainpostFixtures.personalAccount.id.rawValue)'",
            at: url
        )

        try store.reconcileMailboxState(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            states: [IMAPRemoteMessageState(uid: 77, flags: [])]
        )

        XCTAssertEqual(
            try queryInteger(
                "SELECT revision FROM mail_search_state WHERE account_id = '\(PlainpostFixtures.personalAccount.id.rawValue)'",
                at: url
            ),
            revisionBefore
        )
    }

    func testHumanOpenDesiredSeenSurvivesRestartAndStaleRemoteCacheUpsert() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        do {
            let writer = try migratedStore(at: url)
            try cacheOwnedMessage(message, store: writer, uid: 5_894)
            _ = try writer.openMessageForHuman(message.id, actor: PlainpostFixtures.guiUser)
            XCTAssertEqual(try writer.desiredSeenState(messageID: message.id), true)
        }

        let reopened = try migratedStore(at: url)
        try reopened.cacheMessageReliably(message)

        XCTAssertTrue(try XCTUnwrap(reopened.messageSummary(id: message.id)).isSeen)
        XCTAssertEqual(try reopened.desiredSeenState(messageID: message.id), true)
    }

    func testSelectedDirectHumanOpenChecksOwnerAndGenerationInMutationTransaction() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let account = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("acc_human_open_foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccounts([account, foreign])
        for owner in [account, foreign] {
            _ = try store.replaceMailSource(
                AccountMailSource(
                    accountID: owner.id, kind: .direct, mode: nil,
                    nodeID: nil, logicalMailboxID: nil,
                    providerIdentity: nil, generation: 1
                ), expectedGeneration: 0
            )
        }
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id, mailboxPath: "INBOX",
            uidValidity: 9, uid: 77, notificationEligible: false
        )
        XCTAssertThrowsError(try store.openSelectedDirectMessageForHumanResult(
            message.id, actor: PlainpostFixtures.guiUser,
            accountID: foreign.id, expectedSourceGeneration: 1
        ))
        XCTAssertThrowsError(try store.openSelectedDirectMessageForHumanResult(
            message.id, actor: PlainpostFixtures.guiUser,
            accountID: account.id, expectedSourceGeneration: 3
        ))
        XCTAssertFalse(try XCTUnwrap(store.messageSummary(id: message.id)).isSeen)
        XCTAssertEqual(try store.desiredSeenState(messageID: message.id), nil)

        let opened = try store.openSelectedDirectMessageForHumanResult(
            message.id, actor: PlainpostFixtures.guiUser,
            accountID: account.id, expectedSourceGeneration: 1
        )
        XCTAssertTrue(opened.message.isSeen)
        XCTAssertTrue(opened.scheduledRemoteFlag)

        try forceNodeSourceForStaleJobFixture(
            accountID: account.id, generation: 2, providerIdentity: account.email.rawValue, at: url
        )
        XCTAssertThrowsError(try store.openSelectedDirectMessageForHumanResult(
            message.id, actor: PlainpostFixtures.guiUser,
            accountID: account.id, expectedSourceGeneration: 1
        ), "An already-seen message must still reject a stale source")
    }

    func testMatchingServerObservationAcknowledgesDesiredSeenWithoutRevertingLocalState() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            uid: 77,
            notificationEligible: false
        )
        _ = try store.openMessageForHuman(message.id, actor: PlainpostFixtures.guiUser)

        _ = try store.commitIncomingMessage(
            message.withSeen(true),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            uid: 77,
            notificationEligible: false
        )

        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: message.id)).isSeen)
        XCTAssertNil(try store.desiredSeenState(messageID: message.id))
    }

    func testMailboxReconciliationOverlaysContraryRemoteStateUntilMatchingObservation() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            uid: 77,
            notificationEligible: false
        )
        _ = try store.openMessageForHuman(message.id, actor: PlainpostFixtures.guiUser)

        try store.reconcileMailboxState(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            states: [IMAPRemoteMessageState(uid: 77, flags: [])]
        )
        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: message.id)).isSeen)
        XCTAssertEqual(try store.desiredSeenState(messageID: message.id), true)

        try store.reconcileMailboxState(
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 9,
            states: [IMAPRemoteMessageState(uid: 77, flags: ["\\Seen"])]
        )
        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: message.id)).isSeen)
        XCTAssertNil(try store.desiredSeenState(messageID: message.id))
    }

    func testExplicitContraryHumanSeenActionReplacesPendingDesiredState() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        try cacheOwnedMessage(message, store: store, uid: 5_983)
        _ = try store.openMessageForHuman(message.id, actor: PlainpostFixtures.guiUser)

        _ = try store.markSeen(message.id, seen: false, actor: PlainpostFixtures.guiUser)
        try store.cacheMessageReliably(message.withSeen(true))

        XCTAssertFalse(try XCTUnwrap(store.messageSummary(id: message.id)).isSeen)
        XCTAssertEqual(try store.desiredSeenState(messageID: message.id), false)
    }

    func testDesiredSeenMigrationBackfillsActiveLegacyMailboxFlagJob() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = PlainpostFixtures.aliceMessage.withSeen(false)
        let store = try migratedStore(at: url)
        try cacheOwnedMessage(message, store: store, uid: 5_998)
        let payload = try JSONEncoder().encode(
            PlainpostMailboxFlagInput(
                messageID: message.id,
                accountID: PlainpostFixtures.personalAccount.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 5_998,
                desiredSeen: true
            )
        )
        _ = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                idempotencyKey: "legacy-mailbox-flag"
            )
        )
        try executeSQL(
            """
            UPDATE durable_jobs
            SET payload_json = '{"messageID":"\(message.id.rawValue)","desiredSeen":true}'
            WHERE idempotency_key = 'legacy-mailbox-flag';
            DROP TABLE message_seen_intents;
            DELETE FROM grdb_migrations WHERE identifier = 'v15-durable-desired-seen';
            """,
            at: url
        )

        let migrated = try migratedStore(at: url)

        XCTAssertEqual(try migrated.desiredSeenState(messageID: message.id), true)
        XCTAssertTrue(try XCTUnwrap(migrated.messageSummary(id: message.id)).isSeen)
    }

    func testMailboxMessageQueryExcludesOrphansAndOtherMailboxes() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accountID = PlainpostFixtures.personalAccount.id
        let inbox = MessageSummary(
            id: MessageID("msg_inbox"),
            threadID: nil,
            from: EmailAddress("inbox@example.com"),
            subject: "Inbox",
            preview: "Inbox message",
            smartCategory: .personal,
            labels: [],
            isSeen: false,
            mailboxPath: "INBOX",
            isDeleted: false
        )
        let archive = MessageSummary(
            id: MessageID("msg_archive"),
            threadID: nil,
            from: EmailAddress("archive@example.com"),
            subject: "Archive",
            preview: "Archived message",
            smartCategory: .notification,
            labels: [],
            isSeen: false,
            mailboxPath: "Archive",
            isDeleted: false
        )
        let orphan = MessageSummary(
            id: MessageID("msg_orphan"),
            threadID: nil,
            from: EmailAddress("orphan@example.com"),
            subject: "Orphan",
            preview: "No mailbox membership",
            smartCategory: .newsletter,
            labels: [],
            isSeen: false,
            mailboxPath: "INBOX",
            isDeleted: false
        )
        for (message, path, uid) in [(inbox, "INBOX", 1), (archive, "Archive", 2)] {
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: accountID,
                mailboxPath: path,
                uidValidity: 10,
                uid: uid,
                notificationEligible: false
            )
        }
        try store.cacheMessage(orphan)

        XCTAssertEqual(store.messages(inMailboxPath: "inbox").map(\.id), [inbox.id])
    }

    func testAccountBoundedInboxProjectionKeepsMatchingPathsAndThreadsSeparate() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        try store.cacheMailboxes(accounts.map { account in
            Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: nil)
        })
        for (index, account) in accounts.enumerated() {
            let message = MessageSummary(
                id: MessageID("message-\(account.id.rawValue)"),
                threadID: ThreadID("colliding-thread"), from: account.email,
                subject: "Shared subject", preview: "Account \(account.id.rawValue)",
                smartCategory: index == 0 ? .notification : .personal,
                labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                sentAt: Date(timeIntervalSince1970: Double(index + 1))
            )
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 10,
                uid: index + 1, notificationEligible: false
            )
        }

        XCTAssertEqual(try store.mailboxListMessages(
            inMailboxPath: "INBOX", accountID: accounts[1].id, limit: 1, query: ""
        ).map(\.id), [MessageID("message-b")])
        XCTAssertEqual(try store.mailboxListMessageCount(
            inMailboxPath: "INBOX", accountID: accounts[1].id, query: ""
        ), 1)
        XCTAssertEqual(try store.mailboxUnreadConversationCounts(
            inMailboxPath: "INBOX", accountID: accounts[1].id, query: ""
        ), MailboxUnreadConversationCounts(total: 1, personal: 1, notifications: 0, newsletters: 0))
        XCTAssertEqual(try store.mailboxes(limit: 1, accountID: accounts[1].id).map(\.id),
                       [MailboxID("b-inbox")])
        XCTAssertEqual(try store.mailboxListMessageCount(inMailboxPath: "INBOX", query: ""), 2)
        XCTAssertEqual(store.messages(accountID: accounts[1].id).map(\.id),
                       [MessageID("message-b")])
        XCTAssertEqual(store.messages(inMailboxPath: "INBOX", accountID: accounts[1].id).map(\.id),
                       [MessageID("message-b")])
    }

    func testActiveMessageCountScopesAccountRowsAndExcludesUnownedLegacyRows() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)

        for (index, account) in accounts.enumerated() {
            let message = MessageSummary(
                id: MessageID("count-\(account.id.rawValue)"),
                threadID: ThreadID("count-thread-\(account.id.rawValue)"),
                from: account.email,
                subject: "Count fixture",
                preview: "Account owned",
                smartCategory: .personal,
                labels: [],
                isSeen: false
            )
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: index + 1,
                notificationEligible: false
            )
        }
        try store.cacheMessage(MessageSummary(
            id: MessageID("count-unowned"),
            threadID: nil,
            from: EmailAddress("legacy@example.com"),
            subject: "Unowned legacy row",
            preview: "No mailbox or thread owner",
            smartCategory: .personal,
            labels: [],
            isSeen: false
        ))

        XCTAssertEqual(try store.activeMessageCount(accountID: accounts[0].id), 1)
        XCTAssertEqual(try store.activeMessageCount(accountID: accounts[1].id), 1)
        XCTAssertEqual(try store.activeMessageCount(), 3, "The unscoped Mac aggregate remains global")
    }

    func testAccountBoundedMessageReadsResolvePreMembershipThreadOwnership() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        for account in accounts {
            let threadID = ThreadID("legacy-\(account.id.rawValue)")
            try store.cacheThread(MailThread(
                id: threadID, accountID: account.id, subjectNormalized: "legacy",
                participantEmails: [account.email]
            ))
            try store.cacheMessage(MessageSummary(
                id: MessageID("legacy-\(account.id.rawValue)"),
                threadID: threadID, from: account.email,
                subject: "Legacy", preview: "Legacy inbox",
                smartCategory: .personal, labels: [], isSeen: false,
                mailboxPath: "INBOX", isDeleted: false
            ))
        }

        XCTAssertEqual(store.messages(accountID: accounts[1].id).map(\.id),
                       [MessageID("legacy-b")])
        XCTAssertEqual(store.messages(inMailboxPath: "INBOX", accountID: accounts[1].id).map(\.id),
                       [MessageID("legacy-b")])
        XCTAssertEqual(store.messages(inMailboxPath: "INBOX").map(\.id),
                       [MessageID("legacy-a"), MessageID("legacy-b")])

        try store.recordCachedUID(
            accountID: accounts[1].id, mailboxPath: "INBOX",
            uidValidity: 10, uid: 1, messageID: MessageID("legacy-b")
        )
        XCTAssertEqual(store.messages(inMailboxPath: "INBOX", accountID: accounts[1].id).map(\.id),
                       [MessageID("legacy-b")])
        XCTAssertTrue(store.messages(inMailboxPath: "INBOX", accountID: accounts[0].id).isEmpty,
                      "unlinked legacy rows must be hidden after membership appears")
    }

    func testMailboxListProjectionOmitsBodiesAndReadsOnlyRequestedDetails() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accountID = PlainpostFixtures.personalAccount.id
        let body = String(repeating: "body-sentinel-", count: 65_536)

        for (id, sentAt, uid) in [("msg_a", 20.0, 1), ("msg_b", 10.0, 2)] {
            let message = MessageSummary(
                id: MessageID(id),
                threadID: ThreadID("thread_\(id)"),
                from: EmailAddress("sender@example.com"),
                fromDisplayName: "Sender",
                subject: id,
                preview: "preview-\(id)",
                body: body + id,
                bodyHTML: "<p>\(body)\(id)</p>",
                smartCategory: .personal,
                labels: ["important"],
                isSeen: id == "msg_b",
                sentAt: Date(timeIntervalSince1970: sentAt)
            )
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: accountID,
                mailboxPath: "INBOX",
                uidValidity: 10,
                uid: uid,
                notificationEligible: false
            )
        }

        let rows = try store.mailboxListMessages(inMailboxPath: "inbox")
        let firstPage = try store.mailboxListMessages(
            inMailboxPath: "inbox",
            limit: 1,
            query: ""
        )
        let searchedPage = try store.mailboxListMessages(
            inMailboxPath: "inbox",
            limit: 10,
            query: "msg_b"
        )

        XCTAssertEqual(rows.map(\.id.rawValue), ["msg_a", "msg_b"])
        XCTAssertEqual(firstPage.map(\.id.rawValue), ["msg_a"])
        XCTAssertEqual(searchedPage.map(\.id.rawValue), ["msg_b"])
        XCTAssertEqual(
            try store.mailboxListMessageCount(inMailboxPath: "inbox", query: ""),
            2
        )
        XCTAssertEqual(rows.map(\.preview), ["preview-msg_a", "preview-msg_b"])
        XCTAssertEqual(
            try store.mailboxListMessageIDs(inMailboxPath: "inbox").map(\.rawValue).sorted(),
            ["msg_a", "msg_b"]
        )
        XCTAssertFalse(Mirror(reflecting: rows[0]).children.contains {
            $0.label == "body" || $0.label == "bodyHTML"
        })

        let details = try store.messageSummaries(ids: [MessageID("msg_b")])
        XCTAssertEqual(details.map(\.id.rawValue), ["msg_b"])
        XCTAssertEqual(details.map(\.body), [body + "msg_b"])
        XCTAssertEqual(
            try store.messageSummaries(threadID: ThreadID("thread_msg_b")).map(\.id.rawValue),
            ["msg_b"]
        )
        try store.cacheThreads([
            MailThread(
                id: ThreadID("thread_msg_b"),
                accountID: accountID,
                subjectNormalized: "msg_b",
                participantEmails: [EmailAddress("sender@example.com")]
            )
        ])
        XCTAssertEqual(
            try store.thread(id: ThreadID("thread_msg_b"))?.id,
            ThreadID("thread_msg_b")
        )
        XCTAssertEqual(try store.activeMessageCount(), 2)
    }

    func testMailboxUnreadConversationCountsUseCompleteConversationState() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try migratedStore(at: url)
        let accountID = PlainpostFixtures.personalAccount.id
        let messages: [(MessageSummary, String)] = [
            (MessageSummary(
                id: MessageID("shared_old"),
                threadID: ThreadID("thread_shared"),
                from: EmailAddress("personal@example.com"),
                subject: "Shared topic",
                preview: "Older unread message",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 10)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("shared_new"),
                threadID: ThreadID("thread_shared"),
                from: EmailAddress("newsletter@example.com"),
                subject: "Shared topic",
                preview: "Newer seen message",
                smartCategory: .newsletter,
                labels: [],
                isSeen: true,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 20)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("notification"),
                threadID: ThreadID("thread_notification"),
                from: EmailAddress("alerts@example.com"),
                subject: "Account alert",
                preview: "Unread notification",
                smartCategory: .notification,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 30)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("legacy_old"),
                threadID: ThreadID("thr_uid_INBOX_1_41"),
                from: EmailAddress("legacy@example.com"),
                subject: "Re: Legacy topic",
                preview: "Older legacy unread message",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 40)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("legacy_new"),
                threadID: ThreadID("thr_uid_INBOX_1_42"),
                from: EmailAddress("legacy@example.com"),
                subject: "Legacy topic",
                preview: "Newer legacy seen message",
                smartCategory: .notification,
                labels: [],
                isSeen: true,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 50)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("read_personal"),
                threadID: ThreadID("thread_read"),
                from: EmailAddress("read@example.com"),
                subject: "Read personal",
                preview: "Already read",
                smartCategory: .personal,
                labels: [],
                isSeen: true,
                mailboxPath: "INBOX",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 60)
            ), "INBOX"),
            (MessageSummary(
                id: MessageID("archived_unread"),
                threadID: ThreadID("thread_archive"),
                from: EmailAddress("archive@example.com"),
                subject: "Archived unread",
                preview: "Outside inbox",
                smartCategory: .newsletter,
                labels: [],
                isSeen: false,
                mailboxPath: "Archive",
                isDeleted: false,
                sentAt: Date(timeIntervalSince1970: 70)
            ), "Archive"),
        ]
        for (index, entry) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                entry.0,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: accountID,
                mailboxPath: entry.1,
                uidValidity: 10,
                uid: index + 1,
                notificationEligible: false
            )
        }

        XCTAssertEqual(
            try store.mailboxUnreadConversationCounts(inMailboxPath: "inbox", query: ""),
            MailboxUnreadConversationCounts(
                total: 3,
                personal: 0,
                notifications: 2,
                newsletters: 1
            )
        )
        XCTAssertEqual(
            try store.mailboxUnreadConversationCounts(inMailboxPath: "INBOX", query: "legacy"),
            MailboxUnreadConversationCounts(
                total: 1,
                personal: 0,
                notifications: 1,
                newsletters: 0
            )
        )
    }

    func testMailboxListMigrationAddsNewestFirstPagingIndex() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try migratedStore(at: url)

        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'messages_mailbox_list_page';",
                at: url
            ),
            1
        )
    }

    func testMigrationRepairsMissingLegacySearchTables() throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = MessageSummary(
            id: MessageID("msg_repair_search"),
            threadID: nil,
            from: EmailAddress("repair@example.com"),
            subject: "Repair search tables",
            preview: "Legacy migration drift",
            smartCategory: .unknown
        )
        do {
            let initial = try migratedStore(at: url)
            let account = PlainpostFixtures.personalAccount
            let threadID = ThreadID("thread_repair_search")
            try initial.cacheAccounts([account])
            try initial.cacheThread(MailThread(
                id: threadID,
                accountID: account.id,
                subjectNormalized: "repair search tables",
                participantEmails: [EmailAddress("repair@example.com")]
            ))
            try initial.cacheMessage(MessageSummary(
                id: message.id,
                threadID: threadID,
                from: message.from,
                subject: message.subject,
                preview: message.preview,
                smartCategory: message.smartCategory
            ))
        }
        try executeSQL(
            """
            INSERT INTO durable_jobs (
                id, kind, payload_json, state, priority, available_at, attempt, max_attempts,
                cancellation_requested, idempotency_key, error_code, error_message, created_at, updated_at
            ) VALUES (
                'legacy-credentials-job', 'inbox-sync', '{}', 'failed', 100, 0, 3, 5,
                0, 'legacy-credentials-job', 'VALIDATION_FAILED',
                'IMAP credentials are not available.', 0, 0
            );
            DROP TABLE mail_search_fts;
            DROP TABLE mail_search_documents;
            DROP TABLE mail_search_state;
            DROP TABLE mail_search_maintenance;
            DELETE FROM grdb_migrations WHERE identifier = 'v22-repair-message-search-metadata';
            DELETE FROM grdb_migrations WHERE identifier = 'v32-unified-local-mail-search';
            DELETE FROM grdb_migrations WHERE identifier = 'v33-search-attachment-mime-metadata';
            """,
            at: url
        )

        let repaired = try migratedStore(at: url)

        XCTAssertEqual(
            try queryInteger(
                "SELECT COUNT(*) FROM mail_search_documents WHERE message_id = 'msg_repair_search'",
                at: url
            ),
            1
        )
        XCTAssertEqual(try repaired.searchMessages("repair@example.com"), [message.id])
        let repairedCredentialJob = try repaired.job(id: "legacy-credentials-job")
        XCTAssertEqual(repairedCredentialJob.state, .paused)
        XCTAssertEqual(repairedCredentialJob.pauseReason, "credentials-unavailable")
        XCTAssertEqual(repairedCredentialJob.attempt, 0)
        XCTAssertNil(repairedCredentialJob.errorCode)
        XCTAssertNil(repairedCredentialJob.errorMessage)
    }

    func testPublicJobEnqueuePostsOperationChangeForInsertAndReuse() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enqueue-operation-signal-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let changed = expectation(description: "operation changes")
        changed.expectedFulfillmentCount = 2
        let token = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            if MailStoreChangeSignal.scope(from: notification) == .operations {
                changed.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let request = PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            priority: 100,
            idempotencyKey: "operation-signal"
        )

        let inserted = try store.enqueueJob(request)
        let reused = try store.enqueueJob(request)

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(reused.id, inserted.id)
        XCTAssertEqual(try store.job(id: inserted.id).id, inserted.id)
    }

    private func cacheOwnedMessage(
        _ message: MessageSummary,
        store: SQLiteMailStore,
        uid: Int
    ) throws {
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: uid,
            notificationEligible: false
        )
    }

    private func enqueueSmartInboxPauseJob(
        store: SQLiteMailStore,
        suffix: String
    ) throws -> PlainpostDurableJob {
        let message = MessageSummary(
            id: MessageID("pause-message-\(suffix)"),
            threadID: ThreadID("pause-thread-\(suffix)"),
            from: EmailAddress("pause-\(suffix)@example.com"),
            subject: "Pause \(suffix)",
            preview: "Smart Inbox pause test \(suffix)",
            smartCategory: .unknown
        )
        try cacheOwnedMessage(message, store: store, uid: 6_298)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "pause-request-\(suffix)-\(UUID().uuidString)"
        )
        guard case .job(let job) = try store.enqueueSmartInboxJob(input: input) else {
            throw PlainpostError.validationFailed("Expected Smart Inbox pause test job.")
        }
        return job
    }

    private func enqueueActivityJob(
        store: SQLiteMailStore,
        suffix: String,
        mode: PlainpostSmartInboxRunMode
    ) throws -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            smartInboxRunMode: mode,
            smartInboxRequestID: "activity-\(suffix)-\(UUID().uuidString)"
        )
        return try store.enqueueJob(
            .init(
                kind: .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                idempotencyKey: "activity-\(suffix)-\(UUID().uuidString)"
            )
        )
    }

    private func updateActivityJob(
        id: String,
        state: PlainpostOperationState,
        pauseRequested: Bool = false,
        pauseReason: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date,
        at url: URL
    ) throws {
        let pauseReasonSQL = pauseReason.map { "'\($0)'" } ?? "NULL"
        let errorMessageSQL = errorMessage.map { "'\($0)'" } ?? "NULL"
        try executeSQL(
            """
            UPDATE durable_jobs
            SET state = '\(state.rawValue)',
                pause_requested = \(pauseRequested ? 1 : 0),
                pause_reason = \(pauseReasonSQL),
                error_message = \(errorMessageSQL),
                updated_at = \(updatedAt.timeIntervalSince1970)
            WHERE id = '\(id)';
            """,
            at: url
        )
    }

    private func temporarySQLiteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-\(UUID().uuidString).sqlite")
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func auditFixtureFillers() -> [PersistedAuditRecord] {
        (0 ..< 14).map { index in
            PersistedAuditRecord(
                entry: AuditEntry(
                    id: "aud-filler-\(index)",
                    actorID: "local-user",
                    action: "fixture.audit",
                    targetType: "account",
                    targetID: "acc-retained",
                    result: "retained filler \(index)"
                ),
                occurredAt: Date(timeIntervalSince1970: Double(index + 10))
            )
        }
    }

    private func auditLogContents(at auditLogURL: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for index in 0 ... 4 {
            let url = index == 0
                ? auditLogURL
                : URL(fileURLWithPath: "\(auditLogURL.path).\(index)")
            if FileManager.default.fileExists(atPath: url.path) {
                contents[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return contents
    }

    private func auditTemporarySiblingNames(_ auditLogURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: auditLogURL.deletingLastPathComponent().path
        ).filter { name in
            name.contains(".snapshot.") || name.contains(".rewrite.")
        }
    }

    private func auditRedactionJournalNames(_ auditLogURL: URL) throws -> [String] {
        let baseName = auditLogURL.lastPathComponent.replacingOccurrences(
            of: ".audit.log",
            with: ""
        )
        let journalPrefix = ".\(baseName).audit.redaction-journal"
        return try FileManager.default.contentsOfDirectory(
            atPath: auditLogURL.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(journalPrefix) }
    }

    private func migratedStore(at url: URL) throws -> SQLiteMailStore {
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return store
    }

    /// These fixtures deliberately model a source change that happened outside
    /// the guarded CAS path, so the tests can verify stale-job fences even when
    /// an unresolved job is present. Production source changes must use CAS.
    private func forceNodeSourceForStaleJobFixture(
        accountID: AccountID,
        generation: Int64,
        providerIdentity: String,
        at url: URL
    ) throws {
        try executeSQL("""
            UPDATE account_mail_sources SET kind = 'node_backed', mode = 'node',
                node_id = '00112233-4455-6677-8899-aabbccddeeff',
                logical_mailbox_id = '\(String(repeating: "A", count: 43))',
                provider_identity = '\(providerIdentity)', generation = \(generation)
            WHERE account_id = '\(accountID.rawValue)';
            """, at: url)
    }

    private func forceDirectSourceForStaleJobFixture(
        accountID: AccountID,
        generation: Int64,
        at url: URL
    ) throws {
        try executeSQL("""
            UPDATE account_mail_sources SET kind = 'direct', mode = NULL,
                node_id = NULL, logical_mailbox_id = NULL, provider_identity = NULL,
                generation = \(generation)
            WHERE account_id = '\(accountID.rawValue)';
            """, at: url)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
            throw PlainpostError.validationFailed("Could not execute SQLite statement: \(message)")
        }
    }

    private func queryInteger(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PlainpostError.validationFailed("SQLite query returned no row.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func queryStrings(_ sql: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else {
                throw PlainpostError.validationFailed("SQLite query returned a non-text value.")
            }
            values.append(String(cString: value))
        }
        return values
    }

    private func queryPlanDetails(_ sql: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query plan.")
        }
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let detail = sqlite3_column_text(statement, 3) else {
                throw PlainpostError.validationFailed("SQLite query plan detail is missing.")
            }
            details.append(String(cString: detail))
        }
        return details
    }

    private func removeSQLiteAndAuditArtifacts(databaseURL: URL, auditLogURL: URL) {
        _ = Darwin.unlink(databaseURL.path)
        _ = Darwin.unlink(auditLogURL.path)
        for index in 1...4 {
            _ = Darwin.unlink("\(auditLogURL.path).\(index)")
        }
        let lockURL = auditLogURL.deletingLastPathComponent()
            .appendingPathComponent(auditLogURL.lastPathComponent.replacingOccurrences(of: ".log", with: ".lock"))
        _ = Darwin.unlink(lockURL.path)
    }
}

private final class LockedThrowingAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?

    func set(_ action: @escaping @Sendable () throws -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func run() throws {
        lock.lock()
        let action = self.action
        lock.unlock()
        try action?()
    }
}

private final class TranslationCacheRaceGate: @unchecked Sendable {
    let saveObservedActive = DispatchSemaphore(value: 0)
    let resumeSave = DispatchSemaphore(value: 0)
    let deleteReady = DispatchSemaphore(value: 0)
    let continueDelete = DispatchSemaphore(value: 0)
    let saveCompleted = DispatchSemaphore(value: 0)
    let deleteCompleted = DispatchSemaphore(value: 0)
}

private final class TranslationCacheRaceWorker: Thread {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    override func main() {
        action()
    }
}

private final class SQLiteWriteLock: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(databaseURL: URL) throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite writer connection.")
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func beginImmediate() throws {
        try execute("BEGIN IMMEDIATE")
    }

    func rollback() throws {
        try execute("ROLLBACK")
    }

    private func execute(_ sql: String) throws {
        try lock.withLock {
            guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw PlainpostError.validationFailed("Could not execute SQLite writer statement.")
            }
        }
    }
}

private enum OptimisticDraftUpdateOutcome: CustomStringConvertible, Sendable {
    case success(body: String)
    case conflict
    case unexpected(String)

    var body: String? {
        guard case .success(let body) = self else { return nil }
        return body
    }

    var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .success(let body):
            return "success(\(body))"
        case .conflict:
            return "conflict"
        case .unexpected(let error):
            return "unexpected(\(error))"
        }
    }
}

private actor AccountDeletionAcceptanceVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x5A, count: 32)

    func createIfMissing() async throws {}

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        key
    }

    func countMatchingItems() async throws -> Int {
        1
    }
}

private final class MailStoreChangeScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [MailStoreChangeScope: Int] = [:]

    func observe() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let scope = MailStoreChangeSignal.scope(from: notification)
            lock.withLock { counts[scope, default: 0] += 1 }
        }
    }

    func snapshot() -> [MailStoreChangeScope: Int] {
        lock.withLock { counts }
    }
}

private struct SimulatedAuditRedactionCrash: Error {}
private struct SimulatedCredentialDeletionCrash: Error {}

private actor ConcurrentStartGate {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participants {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor FailOnceRemovingCredentialVault: CredentialVault {
    private var records: [CredentialRecordKey: Data]
    private let failingKey: CredentialRecordKey
    private var hasFailed = false

    init(
        records: [CredentialRecordKey: Data],
        failingKey: CredentialRecordKey
    ) {
        self.records = records
        self.failingKey = failingKey
    }

    func store(_ secret: Data, for key: CredentialRecordKey) {
        records[key] = secret
    }

    func load(_ key: CredentialRecordKey) -> Data? {
        records[key]
    }

    func remove(_ key: CredentialRecordKey) throws {
        if key == failingKey, !hasFailed {
            hasFailed = true
            throw CredentialVaultError.locked
        }
        records.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        let current = keys.map { records[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard created.count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) {
            records[key] = value
        }
        return created.map(Optional.some)
    }
}

private actor FailingCredentialRestorationVault: CredentialVault {
    private var records: [CredentialRecordKey: Data]

    init(records: [CredentialRecordKey: Data]) {
        self.records = records
    }

    func store(_: Data, for _: CredentialRecordKey) throws {
        throw CredentialVaultError.locked
    }

    func load(_ key: CredentialRecordKey) -> Data? {
        records[key]
    }

    func remove(_ key: CredentialRecordKey) {
        records.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        let current = keys.map { records[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard created.count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) {
            records[key] = value
        }
        return created.map(Optional.some)
    }
}

private actor PausingFirstRemovalCredentialVault: CredentialVault {
    private var records: [CredentialRecordKey: Data]
    private var loads = 0
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var removalContinuation: CheckedContinuation<Void, Never>?

    init(records: [CredentialRecordKey: Data]) {
        self.records = records
    }

    func store(_ secret: Data, for key: CredentialRecordKey) {
        records[key] = secret
    }

    func load(_ key: CredentialRecordKey) -> Data? {
        loads += 1
        return records[key]
    }

    func remove(_ key: CredentialRecordKey) async {
        if !didPause {
            didPause = true
            pauseWaiters.forEach { $0.resume() }
            pauseWaiters.removeAll()
            await withCheckedContinuation { removalContinuation = $0 }
        }
        records.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        let current = keys.map { records[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard created.count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) {
            records[key] = value
        }
        return created.map(Optional.some)
    }

    func waitUntilFirstRemovalPauses() async {
        if didPause { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resumeFirstRemoval() {
        removalContinuation?.resume()
        removalContinuation = nil
    }

    func loadCount() -> Int {
        loads
    }
}

private func optimisticDraftUpdateOutcome(
    store: SQLiteMailStore,
    draft: Draft,
    body: String
) -> OptimisticDraftUpdateOutcome {
    do {
        let updated = try store.updateDraft(
            id: draft.id,
            expectedHash: draft.contentHash,
            patch: DraftPatch(bodyPlain: body, bodyMarkdown: body),
            actor: PlainpostFixtures.codexActor
        )
        return .success(body: updated.bodyPlain)
    } catch DraftOptimisticUpdateError.conflict {
        return .conflict
    } catch {
        return .unexpected(String(describing: error))
    }
}

private func optimisticNoOpDraftUpdateOutcome(
    store: SQLiteMailStore,
    draft: Draft
) -> OptimisticDraftUpdateOutcome {
    do {
        let unchanged = try store.updateDraft(
            id: draft.id,
            expectedHash: draft.contentHash,
            patch: DraftPatch(bodyPlain: draft.bodyPlain),
            actor: PlainpostFixtures.codexActor
        )
        return .success(body: unchanged.bodyPlain)
    } catch DraftOptimisticUpdateError.conflict {
        return .conflict
    } catch {
        return .unexpected(String(describing: error))
    }
}


extension SQLiteMailStoreTests {
    func testLegacySubjectMatchPreservesExactSwiftNormalizationAndUnicodeEquality() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-subject-equality-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let cases: [(String, String, Bool)] = [
            (" \tRe [12]: Fw:\n CAFÉ \n", "café", true),
            ("cafe\u{301}", "café", true),
            ("RE: Café", "cafe\u{301}", true),
            ("Cafe", "café", false),
            ("Revolution: café", "café", false),
            ("Straße", "strasse", false),
            ("Fw:   ", "", true),
            ("Re: useful", "Useful", false)
        ]
        for (subject, normalized, expected) in cases {
            let result = try store.databasePool.read { db in
                try Bool.fetchOne(db, sql: "SELECT plainpost_subject_matches(?, ?)", arguments: [subject, normalized])
            }
            XCTAssertEqual(result, expected)
        }
        // Function registration is connection-local; reopened readers receive
        // the same predicate without changing the persisted schema.
        let reopened = try SQLiteMailStore(path: url.path)
        let result = try reopened.databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT plainpost_subject_matches('Re: Topic', 'topic')")
        }
        XCTAssertEqual(result, true)
    }
}
