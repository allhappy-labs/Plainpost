import XCTest
import PlainpostOperations
@testable import PlainpostUI

final class SmartInboxActivityPresentationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")

    @MainActor
    func testPausedDiagnosticsRowNeverShowsIndeterminateProgress() {
        for state in [PlainpostOperationState.queued, .running, .paused, .completed] {
            let row = OperationActivityRowModel(
                id: "spinner-fixture", title: "Synthetic operation", state: state, phase: state.rawValue,
                detail: nil, providerID: nil, modelID: nil, accountEmail: nil, resultDetail: nil,
                current: 0, total: nil, createdAt: .distantPast, updatedAt: .distantPast
            )
            XCTAssertEqual(
                OperationActivityRow(operation: row).showsIndeterminateProgress,
                state == .queued || state == .running,
                "Only queued/running work may show an indeterminate spinner"
            )
            let knownProgress = OperationActivityRowModel(
                id: row.id, title: row.title, state: state, phase: row.phase,
                detail: nil, providerID: nil, modelID: nil, accountEmail: nil, resultDetail: nil,
                current: 3, total: 10, createdAt: row.createdAt, updatedAt: row.updatedAt
            )
            XCTAssertFalse(OperationActivityRow(operation: knownProgress).showsIndeterminateProgress)
            XCTAssertEqual(knownProgress.progressFraction, 0.3)
        }
    }

    func testNoJobAndTerminalJobsHaveNoPresentation() {
        XCTAssertNil(SmartInboxActivityPresentation(job: nil, locale: locale))
        XCTAssertNil(SmartInboxActivityPresentation(job: job(state: .completed), locale: locale))
        XCTAssertNil(SmartInboxActivityPresentation(job: job(state: .cancelled), locale: locale))
    }

    // Low Power Mode resumes this job itself, so it offers no Resume.
    func testLowPowerPausedJobSaysSoAndOffersNoResume() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(job: job(state: .paused, pauseReason: "low-power"), locale: locale)
        )
        XCTAssertEqual(presentation.title, "Paused in Low Power Mode")
        XCTAssertNil(presentation.control)
    }

    // Once Low Power Mode is off, a job still paused for it (its lift failed) offers
    // Resume so the user is never stuck.
    func testLowPowerPausedJobOffersResumeOnceWorkIsAllowedAgain() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(state: .paused, pauseReason: "low-power"),
                lowPowerAllowsWork: true,
                locale: locale
            )
        )
        XCTAssertEqual(presentation.title, "Smart Inbox paused")
        XCTAssertEqual(presentation.control, .resume)
    }

    @MainActor
    func testCoordinatorOffersResumeForALowPowerPauseOnlyWhenWorkIsAllowed() {
        var allowsWork = false
        let paused = job(state: .paused, pauseReason: "low-power")
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { paused },
            pause: { _ in },
            resume: { _ in },
            lowPowerAllowsWork: { allowsWork }
        )
        XCTAssertNil(coordinator.presentation?.control)
        allowsWork = true
        coordinator.refresh(locale: locale)
        XCTAssertEqual(coordinator.presentation?.control, .resume)
    }

    func testQueuedWithoutTotalIsPreparingAndIndeterminate() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(job: job(state: .queued), locale: locale)
        )

        XCTAssertEqual(presentation.title, "Preparing Smart Inbox...")
        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.processed, 0)
        XCTAssertNil(presentation.total)
        XCTAssertNil(presentation.remaining)
        XCTAssertNil(presentation.fraction)
        XCTAssertEqual(presentation.control, .pause)
        XCTAssertEqual(presentation.accessibilityLabel, "Preparing Smart Inbox...")
    }

    func testQueuedWithTotalWaitsWithCountsAndPause() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .queued,
                    progress: .init(current: 2, total: 10, phase: "queued", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Waiting to organize")
        XCTAssertEqual(presentation.detail, "2 processed · 8 left")
        XCTAssertEqual(presentation.processed, 2)
        XCTAssertEqual(presentation.total, 10)
        XCTAssertEqual(presentation.remaining, 8)
        XCTAssertEqual(presentation.fraction, 0.2)
        XCTAssertEqual(presentation.control, .pause)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Waiting to organize, 2 of 10 processed, 8 left"
        )
    }

    func testRunningMapsCountsFractionAndPause() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(current: 2_340, total: 9_256, phase: "classifying", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Organizing Smart Inbox")
        XCTAssertEqual(presentation.detail, "2,340 processed · 6,916 left")
        XCTAssertEqual(presentation.fraction, 2_340.0 / 9_256.0)
        XCTAssertEqual(presentation.control, .pause)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Organizing Smart Inbox, 2,340 of 9,256 processed, 6,916 left"
        )
    }

    func testRunningPauseRequestMapsToDisabledPausingControl() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    pauseRequested: true,
                    progress: .init(current: 12, total: 20, phase: "classifying", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Pausing Smart Inbox...")
        XCTAssertEqual(presentation.detail, "12 processed · 8 left")
        XCTAssertEqual(presentation.control, .pausing)
    }

    func testRunningAutomaticPreemptionPhaseMapsToPausingWithoutManualRequest() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(current: 12, total: 20, phase: "pausing", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Pausing Smart Inbox...")
        XCTAssertEqual(presentation.detail, "12 processed · 8 left")
        XCTAssertEqual(presentation.control, .pausing)
    }

    func testManualPauseMapsToResume() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .paused,
                    pauseReason: "user-requested",
                    progress: .init(current: 12, total: 20, phase: "paused", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Smart Inbox paused")
        XCTAssertEqual(presentation.detail, "12 processed · 8 left")
        XCTAssertEqual(presentation.control, .resume)
    }

    func testEveryAISchedulerPauseReasonUsesSafeSpecificCopyAndNoControl() throws {
        let cases: [(PlainpostAIOperationKind, String, String)] = [
            (.summarizeThread, "thread-summary", "Paused for a thread summary"),
            (.summarizeMessage, "thread-summary", "Paused for a thread summary"),
            (.translateMessage, "message-translation", "Paused for message translation"),
            (.answerThreadQuestion, "thread-question", "Paused for a thread question"),
            (.answerMailboxQuestion, "mailbox-question", "Paused for a mailbox question"),
            (.draftReply, "ai-draft", "Paused for an AI draft"),
            (.rewriteDraft, "draft-rewrite", "Paused for an AI draft rewrite"),
            (.classifyMessage, "message-classification", "Paused for message classification"),
            (.recategorizeInbox, "interactive-ai", "Paused for interactive AI work"),
            (.rebuildIndex, "interactive-ai", "Paused for interactive AI work"),
        ]
        XCTAssertEqual(cases.map(\.0), PlainpostAIOperationKind.allCases)

        for (operation, reason, title) in cases {
            XCTAssertEqual(operation.schedulerPauseReason, reason, operation.rawValue)
            let presentation = try XCTUnwrap(
                SmartInboxActivityPresentation(
                    job: job(
                        state: .paused,
                        pauseReason: reason,
                        progress: .init(current: 3, total: 7, phase: "paused", label: "Smart Inbox")
                    ),
                    locale: locale
                )
            )
            XCTAssertEqual(presentation.title, title, operation.rawValue)
            XCTAssertEqual(presentation.detail, "3 processed · 4 left", operation.rawValue)
            XCTAssertNil(presentation.control, operation.rawValue)
            XCTAssertFalse(presentation.accessibilityLabel.contains(reason), operation.rawValue)
        }
    }

    func testLegacyMailSyncFailedPauseUsesCompatibilityCopyAndNoControl() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .paused,
                    pauseReason: "mail-sync-failed",
                    progress: .init(current: 3, total: 7, phase: "paused", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Waiting for successful mail sync")
        XCTAssertEqual(presentation.detail, "3 processed · 4 left")
        XCTAssertNil(presentation.control)
        XCTAssertFalse(presentation.accessibilityLabel.contains("mail-sync-failed"))
    }

    func testNonAILiveSchedulerPausesAndUnknownReasonsUseSafeCopyAndNoControl() throws {
        let cases = [
            ("mail-sync", "Waiting for mail sync"),
            ("credentials-unavailable", "Waiting for Mail Keychain"),
            ("provider-internal-secret", "Paused for interactive AI work"),
        ]

        for (reason, title) in cases {
            let presentation = try XCTUnwrap(
                SmartInboxActivityPresentation(
                    job: job(
                        state: .paused,
                        pauseReason: reason,
                        progress: .init(current: 3, total: 7, phase: "paused", label: "Smart Inbox")
                    ),
                    locale: locale
                )
            )
            XCTAssertEqual(presentation.title, title, reason)
            XCTAssertEqual(presentation.detail, "3 processed · 4 left", reason)
            XCTAssertNil(presentation.control, reason)
            XCTAssertFalse(presentation.accessibilityLabel.contains(reason), reason)
        }
    }

    func testFailedUsesConciseSafeCopyWithoutRawProviderDetails() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .failed,
                    errorCode: "PROVIDER_SECRET_427",
                    errorMessage: "Provider host 10.0.0.8 rejected api-key=secret",
                    progress: .init(current: 3, total: 7, phase: "failed", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.title, "Smart Inbox stopped")
        XCTAssertEqual(presentation.errorDetail, "Smart Inbox couldn't finish. Try again.")
        XCTAssertEqual(presentation.detail, "3 processed before stopping")
        XCTAssertEqual(presentation.compactDetail, "3 processed")
        XCTAssertNil(presentation.control)
        XCTAssertFalse(presentation.accessibilityLabel.contains("10.0.0.8"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("PROVIDER_SECRET_427"))
    }

    func testFailureAtFullProgressDoesNotDescribeSuccessfulCompletion() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .failed,
                    progress: .init(current: 199, total: 199, phase: "classifying", label: "Smart Inbox")
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.detail, "199 processed before stopping")
        XCTAssertEqual(presentation.compactDetail, "199 processed")
        XCTAssertFalse(presentation.accessibilityLabel.contains("0 left"))
    }

    func testProgressClampsNegativeAboveTotalAndZeroTotal() throws {
        let negative = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(current: -4, total: 10, phase: "classifying")
                ),
                locale: locale
            )
        )
        XCTAssertEqual(negative.processed, 0)
        XCTAssertEqual(negative.remaining, 10)
        XCTAssertEqual(negative.fraction, 0)

        let above = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(current: 12, total: 10, phase: "classifying")
                ),
                locale: locale
            )
        )
        XCTAssertEqual(above.processed, 12)
        XCTAssertEqual(above.remaining, 0)
        XCTAssertEqual(above.fraction, 1)

        let zero = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(current: 4, total: 0, phase: "classifying")
                ),
                locale: locale
            )
        )
        XCTAssertEqual(zero.remaining, 0)
        XCTAssertNil(zero.fraction)
    }

    func testLargeNumbersUseInjectedLocale() throws {
        let presentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    state: .running,
                    progress: .init(
                        current: 123_456,
                        total: 777_777,
                        phase: "classifying",
                        label: "Smart Inbox"
                    )
                ),
                locale: locale
            )
        )

        XCTAssertEqual(presentation.detail, "123,456 processed · 654,321 left")
        XCTAssertEqual(presentation.compactDetail, "123,456/777,777")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Organizing Smart Inbox, 123,456 of 777,777 processed, 654,321 left"
        )
    }

    @MainActor
    func testDiagnosticsUsesSidebarProgressSnapshotForMatchingSmartInboxJob() throws {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let diagnosticsRow = OperationActivityRowModel(
            id: "shared-smart-inbox-job",
            title: "Organizing Smart Inbox",
            state: .running,
            phase: "Classifying",
            detail: "Smart Inbox",
            providerID: "foundation",
            modelID: "apple-foundation-system",
            accountEmail: nil,
            resultDetail: nil,
            current: 65,
            total: 316,
            createdAt: now,
            updatedAt: now
        )
        let sidebarPresentation = try XCTUnwrap(
            SmartInboxActivityPresentation(
                job: job(
                    id: diagnosticsRow.id,
                    state: .running,
                    progress: .init(current: 60, total: 316, phase: "classifying")
                ),
                locale: locale
            )
        )

        let rows = TroubleshootingSettingsPage.reconciledActiveOperations(
            [diagnosticsRow],
            smartInboxActivity: sidebarPresentation
        )

        XCTAssertEqual(rows.map(\.current), [60])
        XCTAssertEqual(rows.map(\.total), [316])
    }

    private func job(
        id: String? = nil,
        state: PlainpostOperationState,
        pauseRequested: Bool = false,
        pauseReason: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        progress: PlainpostOperationProgress? = nil
    ) -> PlainpostDurableJob {
        PlainpostDurableJob(
            id: id ?? "activity-\(state.rawValue)",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: state,
            pauseRequested: pauseRequested,
            idempotencyKey: "activity-\(state.rawValue)",
            pauseReason: pauseReason,
            progress: progress,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }
}
