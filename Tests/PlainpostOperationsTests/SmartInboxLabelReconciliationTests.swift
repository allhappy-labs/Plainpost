import Foundation
import SQLite3
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport

private enum SmartInboxLabelTestActors {
    static let user = Actor(
        id: "smart-inbox-label-test-user",
        kind: .user,
        displayName: "Smart Inbox Label Test User",
        permissions: .agentRequested(
            readBody: true,
            createDrafts: true,
            requestSend: true
        )
    )
}

final class SmartInboxLabelReconciliationTests: XCTestCase {
    func testSmartInboxAccountResolutionUsesMembershipThenMessageThenThreadEverywhere() async throws {
        let fixture = try SmartInboxLabelRuntimeFixture(
            seedDefaultLabels: false,
            seedMessage: false
        )
        let accountA = fixture.accountID
        let accountB = Account(
            id: AccountID("account-b"),
            displayName: "Account B",
            email: EmailAddress("b@example.com"),
            imapHost: "imap-b.example.com",
            smtpHost: "smtp-b.example.com"
        )
        try fixture.store.cacheAccounts([accountB])
        try fixture.store.cacheThreads([
            MailThread(
                id: ThreadID("thread-account-a"),
                accountID: accountA,
                subjectNormalized: "thread a",
                participantEmails: []
            ),
            MailThread(
                id: ThreadID("thread-account-b"),
                accountID: accountB.id,
                subjectNormalized: "thread b",
                participantEmails: []
            ),
        ])
        for (id, title, scope) in [
            ("label-a", "Account A Label", MailLabelScope.account(accountA)),
            ("label-b", "Account B Label", MailLabelScope.account(accountB.id)),
        ] {
            try fixture.saveLabel(
                id: id,
                title: title,
                description: "\(title) classification",
                isSmartInboxEnabled: true,
                scope: scope
            )
        }

        try fixture.store.cacheMessageReliably(MessageSummary(
            id: MessageID("thread-only"),
            threadID: ThreadID("thread-account-a"),
            from: EmailAddress("thread@example.com"),
            subject: "Thread fallback",
            preview: "No membership or message account.",
            smartCategory: .unknown
        ))
        _ = try fixture.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("message-only"),
                threadID: nil,
                from: EmailAddress("message@example.com"),
                subject: "Message fallback",
                preview: "No membership or thread account.",
                smartCategory: .unknown
            ),
            metadata: .init(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: accountB.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )
        _ = try fixture.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("membership-wins"),
                threadID: ThreadID("thread-account-b"),
                from: EmailAddress("membership@example.com"),
                subject: "Membership precedence",
                preview: "Membership must override message and thread accounts.",
                smartCategory: .unknown
            ),
            metadata: .init(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: accountA,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 3,
            notificationEligible: false
        )
        try fixture.executeSQL(
            """
            DELETE FROM mailbox_messages WHERE message_id = 'message-only';
            UPDATE messages
            SET account_id = 'account-b'
            WHERE id = 'membership-wins';
            """
        )

        let allInputs = try fixture.store.smartInboxClassificationInputs(scope: .allAccounts)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: allInputs.map {
                ($0.message.id.rawValue, $0.accountID.rawValue)
            }),
            [
                "membership-wins": accountA.rawValue,
                "message-only": accountB.id.rawValue,
                "thread-only": accountA.rawValue,
            ]
        )
        XCTAssertEqual(
            try fixture.store.smartInboxClassificationInputs(scope: .account(accountA))
                .map(\.message.id.rawValue),
            ["membership-wins", "thread-only"]
        )
        XCTAssertEqual(
            try fixture.store.smartInboxClassificationInputs(scope: .account(accountB.id))
                .map(\.message.id.rawValue),
            ["message-only"]
        )

        let catalog = try fixture.store.smartInboxLabelCatalogSnapshot()
        let requests = try SmartInboxBatchBuilder.makeRequests(
            inputs: allInputs,
            catalog: catalog,
            limits: .init(maxMessages: 10, maxPromptCharacters: 20_000)
        )
        let promptMessages = requests.flatMap(\.messages)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: promptMessages.map {
                ($0.id.rawValue, $0.eligibleLabelIDs)
            }),
            [
                "membership-wins": ["label-a"],
                "message-only": ["label-b"],
                "thread-only": ["label-a"],
            ]
        )

        let previewA = try await fixture.store.previewMailLabelReclassification(id: "label-a")
        let previewB = try await fixture.store.previewMailLabelReclassification(id: "label-b")
        XCTAssertEqual(previewA.affectedMessageCount, 2)
        XCTAssertEqual(previewB.affectedMessageCount, 1)

        // The fallback assertions above intentionally begin with no direct message owner.
        // Durable work rows require the resolved owner to be materialized explicitly.
        try fixture.executeSQL(
            "UPDATE messages SET account_id = '\(accountA.rawValue)' WHERE id = 'thread-only'"
        )

        let identity = SmartInboxClassifierContract.identity(
            providerID: "local-test",
            modelID: "local-model"
        )
        let job = try fixture.store.enqueueJob(.init(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            idempotencyKey: "account-resolution-\(UUID().uuidString)"
        ))
        let claimed = try XCTUnwrap(
            fixture.store.claimNextJob(allowedKinds: [.searchRebuild])
        )
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try fixture.store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: allInputs.enumerated().map { ordinal, input in
                .init(
                    ordinal: ordinal,
                    messageID: input.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        input,
                        classifierDiscriminator: identity.discriminator
                    )
                )
            },
            catalogSnapshot: catalog
        )
        for (ordinal, input) in allInputs.enumerated() {
            let labelID = input.message.id == MessageID("message-only")
                ? "label-b"
                : "label-a"
            _ = try fixture.store.recordSmartInboxClassification(
                jobID: job.id,
                leaseToken: leaseToken,
                ordinal: ordinal,
                classification: .init(
                    messageID: input.message.id,
                    category: .travel,
                    priority: .normal,
                    requiresAction: false,
                    confidence: 0.9,
                    labelMatches: [.init(labelID: labelID, confidence: 0.8)]
                ),
                providerID: identity.providerID,
                modelID: identity.modelID,
                classifierDiscriminator: identity.discriminator,
                actor: PlainpostFixtures.guiUser
            )
        }
        let summary = try fixture.store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(summary.categorized, 3, "Commit-time fallback must not mark inputs stale.")
        for (messageID, labelID) in [
            (MessageID("membership-wins"), "label-a"),
            (MessageID("message-only"), "label-b"),
            (MessageID("thread-only"), "label-a"),
        ] {
            XCTAssertEqual(
                try fixture.store.labelAssignments(for: messageID)
                    .filter { $0.source == .smartInbox }
                    .map(\.labelID),
                [labelID]
            )
        }
    }

    func testApprovedSmartInboxLabelAcceptanceFlow() async throws {
        let fixture = try SmartInboxLabelRuntimeFixture(
            seedDefaultLabels: false,
            seedMessage: false
        )

        // 1. Create global and account labels with descriptions.
        try fixture.saveLabel(
            id: "travel",
            title: "Travel",
            description: "Flights, hotels, and itinerary updates.",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )
        try fixture.saveLabel(
            id: "vip",
            title: "VIP",
            description: "Important travel messages for Account A.",
            isSmartInboxEnabled: true,
            scope: .account(fixture.accountID)
        )
        try fixture.saveLabel(
            id: "manual",
            title: "Manual",
            description: "Manually retained messages.",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        )
        try fixture.saveLabel(
            id: "obsolete",
            title: "Obsolete",
            description: "Temporary classification used by a label-only rule.",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        )

        // 2. Classify future new mail with one category and eligible labels.
        try fixture.seedMessage(subject: "Upcoming journey")
        let first = try fixture.checkpointApplyAndComplete(
            category: .travel,
            labelMatches: [
                .init(labelID: "travel", confidence: 0.95),
                .init(labelID: "vip", confidence: 0.92),
                .init(labelID: "obsolete", confidence: 0.90),
            ]
        )
        XCTAssertEqual(first.categorized, 1)
        XCTAssertEqual(try fixture.message().smartCategory, .travel)
        XCTAssertEqual(
            try fixture.smartOwnedLabelIDs(),
            ["obsolete", "travel", "vip"]
        )

        // 3. Apply multiple labels from one rule.
        let multipleLabelsRule = try MailRule.validated(
            id: "travel-rule",
            name: "Travel rule",
            scope: .account(fixture.accountID),
            conditions: [
                .init(field: .from, operator: .domainIs, value: "example.com")
            ],
            actions: [],
            labelIDs: ["travel", "vip"]
        )
        let labelOnlyRule = try MailRule.validated(
            id: "obsolete-only-rule",
            name: "Obsolete only",
            scope: .account(fixture.accountID),
            conditions: [
                .init(field: .from, operator: .domainIs, value: "example.com")
            ],
            actions: [],
            labelIDs: ["obsolete"]
        )
        try fixture.store.saveMailRule(multipleLabelsRule)
        try fixture.store.saveMailRule(labelOnlyRule)
        _ = try MailRuleProcessor(store: fixture.store).processNewMessages(
            [fixture.messageID],
            accountID: fixture.accountID
        )
        XCTAssertEqual(
            Set(try fixture.sources(for: "travel")),
            [.rule(ruleID: "travel-rule"), .smartInbox]
        )
        XCTAssertEqual(
            Set(try fixture.sources(for: "vip")),
            [.rule(ruleID: "travel-rule"), .smartInbox]
        )

        // 4. Reconcile and confirm manual/rule ownership survives.
        try fixture.store.addUserLabel(
            labelID: "manual",
            to: fixture.messageID,
            actor: SmartInboxLabelTestActors.user
        )
        _ = try fixture.checkpointApplyAndComplete(
            category: .travel,
            labelMatches: [
                .init(labelID: "travel", confidence: 0.96),
                .init(labelID: "vip", confidence: 0.93),
                .init(labelID: "obsolete", confidence: 0.91),
            ]
        )
        XCTAssertEqual(try fixture.sources(for: "manual"), [.user])
        XCTAssertTrue(
            try fixture.sources(for: "travel").contains(.rule(ruleID: "travel-rule"))
        )
        XCTAssertTrue(
            try fixture.sources(for: "obsolete").contains(.rule(ruleID: "obsolete-only-rule"))
        )

        // 5. Remove an AI label and confirm exclusion survives reclassification.
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: fixture.messageID,
            actor: SmartInboxLabelTestActors.user
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: fixture.messageID).map(\.labelID),
            ["travel"]
        )
        _ = try fixture.checkpointApplyAndComplete(
            category: .travel,
            labelMatches: [
                .init(labelID: "travel", confidence: 0.97),
                .init(labelID: "vip", confidence: 0.94),
                .init(labelID: "obsolete", confidence: 0.92),
            ]
        )
        XCTAssertEqual(
            Set(try fixture.sources(for: "travel")),
            [.rule(ruleID: "travel-rule")]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: fixture.messageID).map(\.labelID),
            ["travel"]
        )

        // 6. Re-add manually and confirm exclusion clears.
        try fixture.store.establishUserLabel(
            labelID: "travel",
            on: fixture.messageID,
            actor: SmartInboxLabelTestActors.user
        )
        XCTAssertEqual(
            Set(try fixture.sources(for: "travel")),
            [.user, .rule(ruleID: "travel-rule")]
        )
        XCTAssertTrue(
            try fixture.store.labelExclusions(for: fixture.messageID).isEmpty
        )

        // 7. Edit description and confirm no automatic existing-mail job starts.
        let existingJobCount = try fixture.aiJobCount()
        try fixture.updateTravelDescription("Updated travel and itinerary definition.")
        XCTAssertEqual(try fixture.aiJobCount(), existingJobCount)

        // 8. Preview and explicitly run existing-mail reclassification.
        let preview = try await fixture.store.previewMailLabelReclassification(id: "travel")
        XCTAssertEqual(preview.scope, .allAccounts)
        XCTAssertEqual(preview.affectedMessageCount, 1)
        let explicit = try fixture.runExplicitReclassification(
            labelMatches: [
                .init(labelID: "travel", confidence: 0.98),
                .init(labelID: "vip", confidence: 0.95),
                .init(labelID: "obsolete", confidence: 0.93),
            ]
        )
        XCTAssertEqual(explicit.summary.total, 1)
        XCTAssertEqual(explicit.summary.processed, 1)
        XCTAssertEqual(explicit.summary.categorized, 1)
        XCTAssertEqual(explicit.summary.failed, 0)

        // 9. Rename and confirm stable assignments/rule references.
        let travel = try XCTUnwrap(fixture.store.mailLabel(id: "travel"))
        try fixture.store.saveMailLabel(
            try MailLabelDefinition.validated(
                id: travel.id,
                title: "Journeys",
                description: travel.description,
                isSmartInboxEnabled: travel.isSmartInboxEnabled,
                scope: travel.scope,
                createdAt: travel.createdAt,
                updatedAt: travel.updatedAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(
            try fixture.store.mailRule(id: "travel-rule")?.labelIDs,
            ["travel", "vip"]
        )
        XCTAssertEqual(
            try fixture.store.searchMessages("Journeys"),
            [fixture.messageID]
        )
        XCTAssertTrue(try fixture.store.searchMessages("Travel").isEmpty)

        // 10. Delete a referenced label and confirm cleanup plus label-only rule disabling.
        let deletion = try fixture.store.previewMailLabelDeletion(id: "obsolete")
        XCTAssertEqual(deletion.affectedMessageCount, 1)
        XCTAssertEqual(deletion.affectedRuleCount, 1)
        try fixture.store.deleteMailLabel(id: "obsolete")
        XCTAssertNil(try fixture.store.mailLabel(id: "obsolete"))
        XCTAssertFalse(try XCTUnwrap(
            fixture.store.mailRule(id: "obsolete-only-rule")
        ).isEnabled)
        XCTAssertEqual(
            try fixture.store.mailRule(id: "obsolete-only-rule")?.labelIDs,
            []
        )

        // 11. Reopen SQLite and confirm definitions, ownership, exclusions,
        // effective/search projections, and durable progress.
        try fixture.reopenStore()
        XCTAssertEqual(try fixture.store.mailLabel(id: "travel")?.title, "Journeys")
        XCTAssertEqual(
            try fixture.store.mailLabel(id: "vip")?.scope,
            .account(fixture.accountID)
        )
        XCTAssertNil(try fixture.store.mailLabel(id: "obsolete"))
        XCTAssertEqual(
            Set(try fixture.sources(for: "travel")),
            [.user, .rule(ruleID: "travel-rule"), .smartInbox]
        )
        XCTAssertEqual(
            Set(try fixture.sources(for: "vip")),
            [.rule(ruleID: "travel-rule"), .smartInbox]
        )
        XCTAssertTrue(
            try fixture.store.labelExclusions(for: fixture.messageID).isEmpty
        )
        XCTAssertEqual(
            try fixture.message().labels,
            ["Journeys", "Manual", "VIP"]
        )
        XCTAssertEqual(
            try fixture.store.searchMessages("Journeys"),
            [fixture.messageID]
        )
        XCTAssertEqual(
            try fixture.store.searchMessages("Manual"),
            [fixture.messageID]
        )
        XCTAssertTrue(try fixture.store.searchMessages("Obsolete").isEmpty)
        XCTAssertEqual(try fixture.store.job(id: explicit.jobID).state, .completed)
        XCTAssertEqual(
            try fixture.store.smartInboxWorkSummary(jobID: explicit.jobID),
            explicit.summary
        )
    }

    func testExplicitReclassificationAuditsCanonicalSafeStartAndCompletion() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        let input = fixture.explicitInput(requestID: "explicit-audit-request")
        try fixture.makeSmartInboxReady()

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(input: input) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let start = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.start"
            }
        )
        XCTAssertEqual(
            start.result,
            """
            {"jobID":"\(job.id)","messageCount":1,"modelID":"local-model","providerID":"local-test","requestedLabelID":"travel","scope":"allAccounts"}
            """
        )

        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let catalog = try XCTUnwrap(
            fixture.store.smartInboxLabelCatalogSnapshot(jobID: job.id)
        )
        let classificationInput = try XCTUnwrap(
            fixture.store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        _ = try fixture.store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [
                PlainpostSmartInboxWorkSeed(
                    ordinal: 0,
                    messageID: "m1",
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: fixture.classifierDiscriminator
                    )
                )
            ],
            catalogSnapshot: catalog
        )
        _ = try fixture.store.recordSmartInboxClassification(
            jobID: job.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: SmartInboxClassification(
                messageID: MessageID("m1"),
                category: .travel,
                priority: .normal,
                requiresAction: false,
                confidence: 0.9,
                labelMatches: [
                    SmartInboxLabelMatch(labelID: "travel", confidence: 0.91)
                ]
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: fixture.classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )
        _ = try fixture.store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try fixture.store.completeJob(
            id: job.id,
            leaseToken: leaseToken,
            resultArtifactID: nil
        )

        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete"
            }
        )
        XCTAssertEqual(
            completion.result,
            """
            {"failed":0,"jobID":"\(job.id)","modelID":"local-model","providerID":"local-test","requestedLabelID":"travel","scope":"allAccounts","status":"completed","unchanged":0,"updated":1}
            """
        )
        for forbidden in [
            "Travel plans",
            "sender@example.com",
            "A short preview",
            "Plain body",
            "Classify every input email",
        ] {
            XCTAssertFalse(start.result.contains(forbidden))
            XCTAssertFalse(completion.result.contains(forbidden))
        }
    }

    func testExplicitReclassificationTerminalFailureAndCancellationAuditOnlySafeClass() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()

        guard case .job(let failedJob) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-failure-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        try fixture.store.failJob(
            id: failedJob.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            code: "AI_PROVIDER_UNAVAILABLE",
            message: "SECRET-RAW-PROVIDER-OUTPUT Travel plans sender@example.com",
            retryAt: nil
        )
        let failedAudit = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == failedJob.id
            }
        )
        XCTAssertEqual(
            failedAudit.result,
            """
            {"errorClass":"provider-unavailable","failed":0,"jobID":"\(failedJob.id)","modelID":"local-model","providerID":"local-test","requestedLabelID":"travel","scope":"allAccounts","status":"failed","unchanged":0,"updated":0}
            """
        )
        XCTAssertFalse(failedAudit.result.contains("SECRET-RAW-PROVIDER-OUTPUT"))
        XCTAssertFalse(failedAudit.result.contains("Travel plans"))
        XCTAssertFalse(failedAudit.result.contains("sender@example.com"))

        guard case .job(let cancelledJob) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-cancel-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        try fixture.store.requestJobCancellation(id: cancelledJob.id)
        let cancelledAudit = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == cancelledJob.id
            }
        )
        XCTAssertTrue(cancelledAudit.result.contains("\"errorClass\":\"cancelled\""))
        XCTAssertTrue(cancelledAudit.result.contains("\"status\":\"cancelled\""))
    }

    func testAllAccountsLifecycleAuditsUseSharedJobOwnershipAndDoNotBlockAccountDeletion() async throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()
        try fixture.executeSQL(
            """
            CREATE TRIGGER retain_lifecycle_audits_for_test
            BEFORE DELETE ON audit_entries
            BEGIN
                SELECT RAISE(ABORT, 'retain lifecycle audits');
            END;
            """
        )

        guard case .job(let completed) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "shared-completed")
        ) else { return XCTFail("Expected completed lifecycle job.") }
        let completedClaim = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        try fixture.store.completeJob(
            id: completed.id,
            leaseToken: try XCTUnwrap(completedClaim.leaseToken),
            resultArtifactID: nil
        )

        guard case .job(let failed) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "shared-failed")
        ) else { return XCTFail("Expected failed lifecycle job.") }
        let failedClaim = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        try fixture.store.failJob(
            id: failed.id,
            leaseToken: try XCTUnwrap(failedClaim.leaseToken),
            code: "AI_PROVIDER_UNAVAILABLE",
            message: "unavailable",
            retryAt: nil
        )

        guard case .job(let cancelled) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "shared-cancelled")
        ) else { return XCTFail("Expected cancelled lifecycle job.") }
        try fixture.store.requestJobCancellation(id: cancelled.id)

        XCTAssertEqual(
            try fixture.lifecycleAuditCount(
                action: "smart_inbox.reclassification.start",
                ownershipKind: "shared"
            ),
            3
        )
        XCTAssertEqual(
            try fixture.lifecycleAuditCount(
                action: "smart_inbox.reclassification.complete",
                ownershipKind: "shared"
            ),
            3
        )
        XCTAssertEqual(try fixture.lifecycleAuditCountWithOwner(), 0)

        try fixture.executeSQL("DROP TRIGGER retain_lifecycle_audits_for_test;")
        try await fixture.store.deleteAccountData(
            accountID: fixture.accountID,
            credentials: InMemoryCredentialVault()
        )
    }

    func testCancellationAfterFirstApplyRetainsDurableUpdatedCountAndCommittedMessage() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        let run = try partiallyAppliedRun(
            fixture: fixture,
            requestID: "cancel-after-first-apply"
        )

        try fixture.store.requestJobCancellation(id: run.jobID)
        try fixture.store.acknowledgeJobCancellation(
            id: run.jobID,
            leaseToken: run.leaseToken
        )

        XCTAssertEqual(try fixture.store.job(id: run.jobID).state, .cancelled)
        XCTAssertEqual(
            try fixture.store.smartInboxWorkSummary(jobID: run.jobID),
            .init(total: 2, processed: 1, categorized: 1, unchanged: 0, failed: 0)
        )
        XCTAssertEqual(
            try fixture.store.smartInboxListMessages().first {
                $0.id == run.appliedMessageID
            }?.smartCategory,
            .travel
        )
        XCTAssertEqual(
            try fixture.store.smartInboxListMessages().first {
                $0.id == run.pendingMessageID
            }?.smartCategory,
            .personal
        )
        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 30).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == run.jobID
            }
        )
        XCTAssertTrue(completion.result.contains("\"status\":\"cancelled\""))
        XCTAssertTrue(completion.result.contains("\"updated\":1"))
    }

    func testFailureAfterFirstApplyRetainsDurableUpdatedCountAndCommittedMessage() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        let run = try partiallyAppliedRun(
            fixture: fixture,
            requestID: "failure-after-first-apply"
        )

        try fixture.store.failJob(
            id: run.jobID,
            leaseToken: run.leaseToken,
            code: "AI_PROVIDER_UNAVAILABLE",
            message: "Provider stopped after one committed message.",
            retryAt: nil
        )

        XCTAssertEqual(try fixture.store.job(id: run.jobID).state, .failed)
        XCTAssertEqual(
            try fixture.store.smartInboxWorkSummary(jobID: run.jobID),
            .init(total: 2, processed: 1, categorized: 1, unchanged: 0, failed: 0)
        )
        XCTAssertEqual(
            try fixture.store.smartInboxListMessages().first {
                $0.id == run.appliedMessageID
            }?.smartCategory,
            .travel
        )
        XCTAssertEqual(
            try fixture.store.smartInboxListMessages().first {
                $0.id == run.pendingMessageID
            }?.smartCategory,
            .personal
        )
        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 30).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == run.jobID
            }
        )
        XCTAssertTrue(completion.result.contains("\"status\":\"failed\""))
        XCTAssertTrue(completion.result.contains("\"updated\":1"))
    }

    func testExplicitFailureAuditMapsUnknownCodeToUnknownWithoutLeakingIt() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-secret-code-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        let secretCode = "SECRET_RAW_CODE_sender@example.com"
        try fixture.store.failJob(
            id: job.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            code: secretCode,
            message: "A separate localized provider failure.",
            retryAt: nil
        )

        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }
        )
        XCTAssertTrue(completion.result.contains("\"errorClass\":\"unknown\""))
        XCTAssertFalse(completion.result.contains("SECRET"))
        XCTAssertFalse(completion.result.contains("sender"))
        XCTAssertFalse(completion.result.contains("localized"))
    }

    func testExplicitAllFailedAuditUsesBoundedKnownClass() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-all-failed-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        try fixture.store.failJob(
            id: job.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            code: "SMART_INBOX_ALL_FAILED",
            message: "Every message failed with localized details.",
            retryAt: nil
        )

        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }
        )
        XCTAssertTrue(completion.result.contains("\"errorClass\":\"all-failed\""))
        XCTAssertFalse(completion.result.contains("localized"))
    }

    func testRecoveryAuditsExpiredExplicitCancellationAcrossReopen() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()
        let startedAt = Date().addingTimeInterval(1)

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-recovery-cancel-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(
            fixture.store.claimNextJob(
                now: startedAt,
                leaseDuration: 10,
                allowedKinds: [.aiOperation]
            )
        )
        XCTAssertEqual(claimed.id, job.id)
        try fixture.store.requestJobCancellation(id: job.id)
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)

        try fixture.reopenStore()
        _ = try fixture.store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: startedAt.addingTimeInterval(11)
        )

        XCTAssertEqual(try fixture.store.job(id: job.id).state, .cancelled)
        let completion = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 30).first {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }
        )
        XCTAssertEqual(
            completion.result,
            """
            {"errorClass":"cancelled","failed":0,"jobID":"\(job.id)","modelID":"local-model","providerID":"local-test","requestedLabelID":"travel","scope":"allAccounts","status":"cancelled","unchanged":0,"updated":0}
            """
        )
    }

    func testClaimAuditsExpiredExplicitCancellationBeforeSelectingNextJob() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()
        let startedAt = Date().addingTimeInterval(1)

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-claim-cancel-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        _ = try XCTUnwrap(
            fixture.store.claimNextJob(
                now: startedAt,
                leaseDuration: 10,
                allowedKinds: [.aiOperation]
            )
        )
        try fixture.store.requestJobCancellation(id: job.id)

        XCTAssertNil(
            try fixture.store.claimNextJob(
                now: startedAt.addingTimeInterval(11),
                leaseDuration: 10,
                allowedKinds: [.aiOperation]
            )
        )
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .cancelled)
        XCTAssertEqual(
            fixture.store.auditEntries.filter {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }.count,
            1
        )
    }

    func testExpiredCancellationRecoveryRollsBackWhenCompletionAuditFails() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()
        let startedAt = Date().addingTimeInterval(1)

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-recovery-rollback-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        _ = try XCTUnwrap(
            fixture.store.claimNextJob(
                now: startedAt,
                leaseDuration: 10,
                allowedKinds: [.aiOperation]
            )
        )
        try fixture.store.requestJobCancellation(id: job.id)
        try fixture.executeSQL(
            """
            CREATE TRIGGER reject_recovered_reclassification_completion
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'smart_inbox.reclassification.complete'
            BEGIN
                SELECT RAISE(ABORT, 'forced recovered completion audit failure');
            END;
            """
        )

        XCTAssertThrowsError(
            try fixture.store.recoverBackgroundAgentJobs(
                allowedKinds: [.aiOperation],
                now: startedAt.addingTimeInterval(11)
            )
        )
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)

        try fixture.executeSQL("DROP TRIGGER reject_recovered_reclassification_completion;")
        _ = try fixture.store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: startedAt.addingTimeInterval(11)
        )
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .cancelled)
        XCTAssertEqual(
            fixture.store.auditEntries.filter {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }.count,
            1
        )
    }

    func testCompletionAuditMarkerSurvivesDrainReopenAndConcurrentRetry() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-durable-marker-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        try fixture.store.requestJobCancellation(id: job.id)
        XCTAssertEqual(
            fixture.store.auditEntries.filter {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }.count,
            1
        )

        try fixture.reopenStore()
        XCTAssertEqual(try fixture.pendingAuditCount(), 0)
        let peerA = try fixture.makePeerStore()
        let peerB = try fixture.makePeerStore()
        let errors = ConcurrentErrorRecorder()
        let group = DispatchGroup()
        for peer in [peerA, peerB] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try peer.requestJobCancellation(id: job.id)
                } catch {
                    errors.record(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.messages.isEmpty, errors.messages.joined(separator: "\n"))
        XCTAssertEqual(
            fixture.store.auditEntries.filter {
                $0.action == "smart_inbox.reclassification.complete"
                    && $0.targetID == job.id
            }.count,
            1
        )
    }

    func testCompletedAuditMarkerSurvivesDrainReopenAndRepeatedCompletion() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()

        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "explicit-repeat-completion-request")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        try fixture.store.completeJob(
            id: job.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            resultArtifactID: nil
        )

        try fixture.reopenStore()
        XCTAssertEqual(try fixture.pendingAuditCount(), 0)
        try fixture.executeSQL(
            """
            UPDATE durable_jobs
            SET state = 'running', cancellation_requested = 0,
                lease_token = 'repeat-completion-lease', lease_expires_at = 4102444800
            WHERE id = '\(job.id)';
            """
        )
        try fixture.store.completeJob(
            id: job.id,
            leaseToken: "repeat-completion-lease",
            resultArtifactID: nil
        )

        let completions = fixture.store.auditEntries.filter {
            $0.action == "smart_inbox.reclassification.complete"
                && $0.targetID == job.id
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertTrue(completions[0].result.contains("\"status\":\"completed\""))
    }

    func testExplicitLifecycleStateRollsBackWhenAuditInsertionFails() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.makeSmartInboxReady()
        try fixture.executeSQL(
            """
            CREATE TRIGGER reject_reclassification_start_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'smart_inbox.reclassification.start'
            BEGIN
                SELECT RAISE(ABORT, 'forced start audit failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "start-audit-rollback")
        ))
        XCTAssertTrue(
            try fixture.store.jobs(limit: 100)
                .filter { $0.kind == .aiOperation }
                .isEmpty
        )

        try fixture.executeSQL(
            """
            DROP TRIGGER reject_reclassification_start_audit;
            CREATE TRIGGER reject_reclassification_completion_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'smart_inbox.reclassification.complete'
            BEGIN
                SELECT RAISE(ABORT, 'forced completion audit failure');
            END;
            """
        )
        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: "completion-audit-rollback")
        ) else {
            return XCTFail("Explicit reclassification must enqueue work.")
        }
        let claimed = try XCTUnwrap(fixture.store.claimNextJob(allowedKinds: [.aiOperation]))
        XCTAssertThrowsError(try fixture.store.failJob(
            id: job.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            code: "AI_PROVIDER_UNAVAILABLE",
            message: "Safe user-facing message",
            retryAt: nil
        ))
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)
        XCTAssertNil(try fixture.store.job(id: job.id).errorCode)
    }

    func testLegacyDurableInputAndSummaryDecodeWithAllAccountsAndZeroUnchanged() throws {
        let input = try JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data(
                """
                {
                  "operation":"recategorizeInbox",
                  "recordID":"",
                  "providerID":"foundation"
                }
                """.utf8
            )
        )
        XCTAssertEqual(
            input.smartInboxRunRequest,
            PlainpostSmartInboxRunRequest(
                mode: .incremental,
                scope: .allAccounts,
                requestedLabelID: nil
            )
        )

        let summary = try JSONDecoder().decode(
            PlainpostSmartInboxWorkSummary.self,
            from: Data(
                """
                {"total":2,"processed":2,"categorized":1,"failed":1}
                """.utf8
            )
        )
        XCTAssertEqual(summary.unchanged, 0)

        let legacyArtifact = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(
                """
                {"categorizedMessageCount":1,"failedMessageCount":1}
                """.utf8
            )
        )
        XCTAssertEqual(legacyArtifact.unchangedMessageCount, 0)
    }

    func testClassificationInputUsesRecipientsAndBoundedPlainTextInFingerprint() throws {
        let fixture = try SmartInboxLabelRuntimeFixture(
            body: String(repeating: "p", count: 3_500),
            bodyHTML: "<html>HTML-MUST-NOT-BE-READ</html>"
        )

        let input = try XCTUnwrap(
            fixture.store.smartInboxClassificationInputs(scope: .allAccounts).first
        )

        XCTAssertEqual(
            input.recipients.map(\.rawValue),
            ["to@example.com", "cc@example.com"]
        )
        XCTAssertEqual(input.bodyExcerpt.count, 3_000)
        XCTAssertFalse(input.bodyExcerpt.contains("HTML-MUST-NOT-BE-READ"))

        let original = SmartInboxClassificationFingerprint.message(
            input,
            classifierDiscriminator: fixture.classifierDiscriminator
        )
        try fixture.replaceBody(with: "changed plain body")
        let changed = try XCTUnwrap(
            fixture.store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        XCTAssertNotEqual(
            original,
            SmartInboxClassificationFingerprint.message(
                changed,
                classifierDiscriminator: fixture.classifierDiscriminator
            )
        )
    }

    func testCheckpointDoesNotMutateMailBeforeApply() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["old-ai"],
            on: MessageID("m1"),
            actor: PlainpostFixtures.guiUser
        )
        let prepared = try fixture.prepare()

        _ = try fixture.store.recordSmartInboxClassification(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            ordinal: 0,
            classification: SmartInboxClassification(
                messageID: MessageID("m1"),
                category: .travel,
                priority: .high,
                requiresAction: true,
                confidence: 0.94,
                labelMatches: [
                    SmartInboxLabelMatch(labelID: "new-ai", confidence: 0.91)
                ]
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: fixture.classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )

        let message = try XCTUnwrap(
            fixture.store.smartInboxListMessages().first { $0.id == MessageID("m1") }
        )
        XCTAssertEqual(message.smartCategory, .personal)
        XCTAssertEqual(
            try fixture.smartOwnedLabelIDs(),
            ["old-ai"]
        )
        XCTAssertNil(try fixture.store.smartInboxClassificationCache()[MessageID("m1")])
    }

    func testApplyReconcilesOnlySmartInboxOwnershipAndFiltersConcurrentChanges() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        try fixture.store.addUserLabel(
            labelID: "manual",
            to: MessageID("m1"),
            actor: SmartInboxLabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "rule",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: PlainpostFixtures.guiUser
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["old-ai"],
            on: MessageID("m1"),
            actor: PlainpostFixtures.guiUser
        )
        let prepared = try fixture.prepare()
        _ = try fixture.store.recordSmartInboxClassification(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            ordinal: 0,
            classification: SmartInboxClassification(
                messageID: MessageID("m1"),
                category: .travel,
                priority: .high,
                requiresAction: true,
                confidence: 0.94,
                labelMatches: [
                    SmartInboxLabelMatch(labelID: "travel", confidence: 0.94),
                    SmartInboxLabelMatch(labelID: "vip", confidence: 0.92),
                    SmartInboxLabelMatch(labelID: "new-ai", confidence: 0.91),
                ]
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: fixture.classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )

        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: PlainpostFixtures.guiUser
        )
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: SmartInboxLabelTestActors.user
        )
        try fixture.store.deleteMailLabel(id: "vip")

        let summary = try fixture.store.applySmartInboxWork(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(summary.categorized, 1)
        XCTAssertEqual(summary.unchanged, 0)
        let message = try XCTUnwrap(
            fixture.store.smartInboxListMessages().first { $0.id == MessageID("m1") }
        )
        XCTAssertEqual(message.smartCategory, .travel)
        XCTAssertEqual(message.smartPriority, .high)
        XCTAssertTrue(message.smartRequiresAction)
        XCTAssertEqual(message.smartConfidence, 0.94)
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map {
                "\($0.labelID):\(sourceDescription($0.source))"
            }.sorted(),
            ["manual:user", "new-ai:smartInbox", "travel:rule:rule"]
        )
        XCTAssertEqual(
            try fixture.store.smartInboxClassificationCache()[MessageID("m1")]?.labelMatches,
            [SmartInboxLabelMatch(labelID: "new-ai", confidence: 0.91)]
        )
        let audit = try XCTUnwrap(
            fixture.store.recentAuditEntries(limit: 10).first {
                $0.action == "smart_inbox.reconcile"
            }
        )
        XCTAssertTrue(audit.result.contains("\"category\":\"travel\""))
        XCTAssertTrue(audit.result.contains("\"addedLabelIDs\":[\"new-ai\"]"))
        XCTAssertTrue(audit.result.contains("\"removedLabelIDs\":[]"))
        XCTAssertFalse(audit.result.contains("A short preview"))
        XCTAssertFalse(audit.result.contains("Plain body"))
    }

    func testPreparedJobReusesItsFrozenCatalogAfterDefinitionEdit() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        let prepared = try fixture.prepare()
        let frozen = try XCTUnwrap(
            fixture.store.smartInboxLabelCatalogSnapshot(jobID: prepared.jobID)
        )

        try fixture.updateTravelDescription("Changed after preparation")
        try fixture.reopenStore()
        let current = try fixture.store.smartInboxLabelCatalogSnapshot()
        XCTAssertNotEqual(current.fingerprint, frozen.fingerprint)

        _ = try fixture.store.prepareSmartInboxWork(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            seeds: [],
            catalogSnapshot: current
        )
        XCTAssertEqual(
            try fixture.store.smartInboxLabelCatalogSnapshot(jobID: prepared.jobID),
            frozen
        )
    }

    func testCatalogEditDoesNotEnqueueIncrementalButExplicitRunFreezesNewFingerprint() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        let prepared = try fixture.prepare()
        _ = try fixture.store.recordSmartInboxClassification(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            ordinal: 0,
            classification: SmartInboxClassification(
                messageID: MessageID("m1"),
                category: .travel,
                priority: .normal,
                requiresAction: false,
                confidence: 0.9,
                labelMatches: []
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: fixture.classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )
        _ = try fixture.store.applySmartInboxWork(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try fixture.store.completeJob(
            id: prepared.jobID,
            leaseToken: prepared.leaseToken,
            resultArtifactID: nil
        )
        let oldFingerprint = try XCTUnwrap(
            fixture.store.smartInboxClassificationCache()[MessageID("m1")]
        ).catalogFingerprint

        try fixture.updateTravelDescription("Updated travel definition")
        let incremental = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "local-test",
            modelID: "local-model"
        )
        guard case .upToDate = try fixture.store.enqueueSmartInboxJob(input: incremental) else {
            XCTFail("A catalog-only edit must not enqueue incremental work.")
            return
        }

        let explicit = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "local-test",
            modelID: "local-model",
            smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                mode: .rerunAll,
                scope: .allAccounts,
                requestedLabelID: "travel"
            ),
            smartInboxRequestID: UUID().uuidString
        )
        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(input: explicit) else {
            XCTFail("Explicit reclassification must enqueue work.")
            return
        }
        XCTAssertNotEqual(
            oldFingerprint,
            try fixture.store.smartInboxLabelCatalogSnapshot(jobID: job.id)?.fingerprint
        )
    }

    func testApplyCountsAnIdenticalTriageAndSmartLabelSetAsUnchanged() throws {
        let fixture = try SmartInboxLabelRuntimeFixture()
        _ = try fixture.checkpointApplyAndComplete(
            category: .travel,
            labelMatches: [
                SmartInboxLabelMatch(labelID: "new-ai", confidence: 0.91)
            ]
        )

        let second = try fixture.checkpointApplyAndComplete(
            category: .travel,
            labelMatches: [
                SmartInboxLabelMatch(labelID: "new-ai", confidence: 0.91)
            ]
        )

        XCTAssertEqual(second.categorized, 0)
        XCTAssertEqual(second.unchanged, 1)
        XCTAssertEqual(second.failed, 0)
    }

    private func partiallyAppliedRun(
        fixture: SmartInboxLabelRuntimeFixture,
        requestID: String
    ) throws -> (
        jobID: String,
        leaseToken: String,
        appliedMessageID: MessageID,
        pendingMessageID: MessageID
    ) {
        let pendingMessageID = MessageID("m2")
        _ = try fixture.store.commitIncomingMessage(
            MessageSummary(
                id: pendingMessageID,
                threadID: nil,
                from: EmailAddress("second@example.com"),
                subject: "Second message",
                preview: "This message remains pending.",
                smartCategory: .personal
            ),
            metadata: .init(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: fixture.accountID,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )
        try fixture.makeSmartInboxReady()
        guard case .job(let job) = try fixture.store.enqueueSmartInboxJob(
            input: fixture.explicitInput(requestID: requestID)
        ) else {
            throw PlainpostError.validationFailed("Explicit reclassification did not enqueue.")
        }
        let claimed = try XCTUnwrap(
            fixture.store.claimNextJob(allowedKinds: [.aiOperation])
        )
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let catalog = try XCTUnwrap(
            fixture.store.smartInboxLabelCatalogSnapshot(jobID: job.id)
        )
        let inputs = try fixture.store.smartInboxClassificationInputs(scope: .allAccounts)
        XCTAssertEqual(inputs.map(\.message.id), [fixture.messageID, pendingMessageID])
        try fixture.store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: inputs.enumerated().map { ordinal, input in
                .init(
                    ordinal: ordinal,
                    messageID: input.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        input,
                        classifierDiscriminator: fixture.classifierDiscriminator
                    )
                )
            },
            catalogSnapshot: catalog
        )
        _ = try fixture.store.recordSmartInboxClassification(
            jobID: job.id,
            leaseToken: leaseToken,
            ordinal: 0,
            classification: .init(
                messageID: fixture.messageID,
                category: .travel,
                priority: .high,
                requiresAction: true,
                confidence: 0.9,
                labelMatches: [.init(labelID: "travel", confidence: 0.9)]
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: fixture.classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )
        let applied = try fixture.store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        XCTAssertEqual(applied.categorized, 1)

        return (job.id, leaseToken, fixture.messageID, pendingMessageID)
    }

    private func sourceDescription(_ source: MailLabelAssignmentSource) -> String {
        switch source {
        case .user:
            return "user"
        case .rule(let ruleID):
            return "rule:\(ruleID)"
        case .smartInbox:
            return "smartInbox"
        }
    }
}

private final class SmartInboxLabelRuntimeFixture {
    private(set) var store: SQLiteMailStore!
    let classifierDiscriminator = SmartInboxClassifierContract.discriminator(
        providerID: "local-test",
        modelID: "local-model"
    )

    private let databaseURL: URL
    private let account = Account(
        id: AccountID("account-a"),
        displayName: "Account A",
        email: EmailAddress("me@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )

    init(
        body: String = "Plain body",
        bodyHTML: String? = "<p>Plain body</p>",
        seedDefaultLabels: Bool = true,
        seedMessage: Bool = true
    ) throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-label-runtime-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([account])
        if seedDefaultLabels {
            for label in [
                try makeLabel(id: "manual", title: "Manual"),
                try makeLabel(id: "travel", title: "Travel"),
                try makeLabel(id: "old-ai", title: "Old AI"),
                try makeLabel(id: "new-ai", title: "New AI"),
                try makeLabel(id: "vip", title: "VIP"),
            ] {
                try store.saveMailLabel(label)
            }
        }
        if seedMessage {
            try self.seedMessage(body: body, bodyHTML: bodyHTML)
        }
    }

    var accountID: AccountID { account.id }
    let messageID = MessageID("m1")

    func seedMessage(
        body: String = "Plain body",
        bodyHTML: String? = "<p>Plain body</p>",
        subject: String = "Travel plans"
    ) throws {
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: messageID,
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                fromDisplayName: "Sender",
                subject: subject,
                preview: "A short preview",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                body: body,
                bodyHTML: bodyHTML,
                to: [EmailAddress("to@example.com")],
                cc: [EmailAddress("cc@example.com")]
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [EmailAddress("to@example.com")],
                cc: [EmailAddress("cc@example.com")],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
    }

    deinit {
        let auditLogURL = store.auditLogURL
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: auditLogURL)
    }

    func reopenStore() throws {
        store = nil
        store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
    }

    func prepare() throws -> (jobID: String, leaseToken: String) {
        let request = PlainpostSmartInboxRunRequest(
            mode: .rerunAll,
            scope: .allAccounts,
            requestedLabelID: "travel"
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "local-test",
            modelID: "local-model",
            smartInboxRunRequest: request,
            smartInboxRequestID: UUID().uuidString
        )
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: payload,
                priority: input.operation.priority,
                idempotencyKey: "label-runtime-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let snapshot = try store.smartInboxLabelCatalogSnapshot()
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        _ = try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: [
                PlainpostSmartInboxWorkSeed(
                    ordinal: 0,
                    messageID: "m1",
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: classifierDiscriminator
                    )
                )
            ],
            catalogSnapshot: snapshot
        )
        return (job.id, leaseToken)
    }

    func explicitInput(requestID: String) -> PlainpostAIOperationInput {
        PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "local-test",
            modelID: "local-model",
            smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                mode: .rerunAll,
                scope: .allAccounts,
                requestedLabelID: "travel"
            ),
            smartInboxRequestID: requestID
        )
    }

    func makeSmartInboxReady() throws {
        let input = PlainpostInboxSyncInput(
            accountID: account.id,
            trigger: .manual,
            scope: .recent
        )
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                idempotencyKey: "label-runtime-sync-\(UUID().uuidString)"
            )
        )
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimed.id, job.id)
        try store.completeJob(
            id: claimed.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            resultArtifactID: nil
        )
    }

    func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not execute SQLite statement.")
        }
    }

    func pendingAuditCount() throws -> Int {
        try queryInteger("SELECT COUNT(*) FROM audit_entries")
    }

    func lifecycleAuditCount(action: String, ownershipKind: String) throws -> Int {
        try queryInteger(
            "SELECT COUNT(*) FROM audit_entries WHERE action = '\(action)' AND ownership_kind = '\(ownershipKind)' AND owner_account_id IS NULL"
        )
    }

    func lifecycleAuditCountWithOwner() throws -> Int {
        try queryInteger(
            "SELECT COUNT(*) FROM audit_entries WHERE action LIKE 'smart_inbox.reclassification.%' AND owner_account_id IS NOT NULL"
        )
    }

    func makePeerStore() throws -> SQLiteMailStore {
        let peer = try SQLiteMailStore(path: databaseURL.path)
        try peer.migrate()
        return peer
    }

    private func queryInteger(_ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PlainpostError.validationFailed("SQLite query returned no row.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func replaceBody(with body: String) throws {
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("m1"),
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                fromDisplayName: "Sender",
                subject: "Travel plans",
                preview: "A short preview",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                body: body,
                bodyHTML: "<p>changed html</p>",
                to: [EmailAddress("to@example.com")],
                cc: [EmailAddress("cc@example.com")]
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [EmailAddress("to@example.com")],
                cc: [EmailAddress("cc@example.com")],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
    }

    func smartOwnedLabelIDs() throws -> [String] {
        try store.labelAssignments(for: messageID)
            .filter { $0.source == .smartInbox }
            .map(\.labelID)
            .sorted()
    }

    func sources(for labelID: String) throws -> [MailLabelAssignmentSource] {
        try store.labelAssignments(for: messageID)
            .filter { $0.labelID == labelID }
            .map(\.source)
    }

    func message() throws -> MailboxListMessage {
        try XCTUnwrap(
            store.smartInboxListMessages().first { $0.id == messageID }
        )
    }

    func saveLabel(
        id: String,
        title: String,
        description: String,
        isSmartInboxEnabled: Bool,
        scope: MailLabelScope
    ) throws {
        try store.saveMailLabel(
            try MailLabelDefinition.validated(
                id: id,
                title: title,
                description: description,
                isSmartInboxEnabled: isSmartInboxEnabled,
                scope: scope,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func aiJobCount() throws -> Int {
        try store.jobs(limit: 1_000).filter { $0.kind == .aiOperation }.count
    }

    func runExplicitReclassification(
        labelMatches: [SmartInboxLabelMatch]
    ) throws -> (jobID: String, summary: PlainpostSmartInboxWorkSummary) {
        try makeSmartInboxReady()
        guard case .job(let job) = try store.enqueueSmartInboxJob(
            input: explicitInput(requestID: "approved-acceptance-reclassification")
        ) else {
            throw PlainpostError.validationFailed(
                "Explicit acceptance reclassification did not enqueue."
            )
        }
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.aiOperation])
        )
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        let catalog = try XCTUnwrap(
            store.smartInboxLabelCatalogSnapshot(jobID: job.id)
        )
        let inputs = try store.smartInboxClassificationInputs(scope: .allAccounts)
        _ = try store.prepareSmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            seeds: inputs.enumerated().map { ordinal, input in
                PlainpostSmartInboxWorkSeed(
                    ordinal: ordinal,
                    messageID: input.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        input,
                        classifierDiscriminator: classifierDiscriminator
                    )
                )
            },
            catalogSnapshot: catalog
        )
        for (ordinal, input) in inputs.enumerated() {
            _ = try store.recordSmartInboxClassification(
                jobID: job.id,
                leaseToken: leaseToken,
                ordinal: ordinal,
                classification: SmartInboxClassification(
                    messageID: input.message.id,
                    category: .travel,
                    priority: .high,
                    requiresAction: true,
                    confidence: 0.99,
                    labelMatches: labelMatches
                ),
                providerID: "local-test",
                modelID: "local-model",
                classifierDiscriminator: classifierDiscriminator,
                actor: PlainpostFixtures.guiUser
            )
        }
        let summary = try store.applySmartInboxWork(
            jobID: job.id,
            leaseToken: leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try store.completeJob(
            id: job.id,
            leaseToken: leaseToken,
            resultArtifactID: nil
        )
        return (job.id, summary)
    }

    func updateTravelDescription(_ description: String) throws {
        let existing = try XCTUnwrap(store.mailLabel(id: "travel"))
        try store.saveMailLabel(
            try MailLabelDefinition.validated(
                id: existing.id,
                title: existing.title,
                description: description,
                isSmartInboxEnabled: existing.isSmartInboxEnabled,
                scope: existing.scope,
                createdAt: existing.createdAt,
                updatedAt: existing.updatedAt.addingTimeInterval(1)
            )
        )
    }

    func checkpointApplyAndComplete(
        category: SmartCategory,
        labelMatches: [SmartInboxLabelMatch]
    ) throws -> PlainpostSmartInboxWorkSummary {
        let prepared = try prepare()
        _ = try store.recordSmartInboxClassification(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            ordinal: 0,
            classification: SmartInboxClassification(
                messageID: MessageID("m1"),
                category: category,
                priority: .normal,
                requiresAction: false,
                confidence: 0.9,
                labelMatches: labelMatches
            ),
            providerID: "local-test",
            modelID: "local-model",
            classifierDiscriminator: classifierDiscriminator,
            actor: PlainpostFixtures.guiUser
        )
        let summary = try store.applySmartInboxWork(
            jobID: prepared.jobID,
            leaseToken: prepared.leaseToken,
            actor: PlainpostFixtures.guiUser
        )
        try store.completeJob(
            id: prepared.jobID,
            leaseToken: prepared.leaseToken,
            resultArtifactID: nil
        )
        return summary
    }

    private func makeLabel(id: String, title: String) throws -> MailLabelDefinition {
        try MailLabelDefinition.validated(
            id: id,
            title: title,
            description: "\(title) classification",
            isSmartInboxEnabled: true,
            scope: .allAccounts,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private final class ConcurrentErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func record(_ error: Error) {
        lock.withLock {
            storage.append(String(describing: error))
        }
    }
}
