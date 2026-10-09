import Foundation
import PlainpostCore
import XCTest

final class MailIntentGuardTests: XCTestCase {
    private func record(
        _ state: MailIntentState,
        _ route: MailIntentRoute?,
        kind: MailIntentKind = .send
    ) -> MailIntentRecord {
        MailIntentRecord(operationID: "00000000-0000-4000-8000-000000000001", accountID: AccountID("acc"), kind: kind,
                         route: route, state: state, messageID: nil, draftID: DraftID("d1"), createdAt: .distantPast, updatedAt: .distantPast)
    }

    func testNodeAdmittedOrUncertainWorkIsNeverReplayedDirectly() {
        for state in [MailIntentState.dispatching, .admitted, .uncertain, .confirmed, .unconfirmedAfterRemoval, .unconfirmed] {
            XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(state, .node)), "\(state)")
            XCTAssertFalse(MailIntentGuard.mayResend(record(state, .node)), "\(state)")
        }
        XCTAssertTrue(MailIntentGuard.mayDispatchDirect(record(.pending, nil)))
        XCTAssertTrue(MailIntentGuard.waitsForNode(record(.admitted, .node)))
        XCTAssertTrue(MailIntentGuard.waitsForNode(record(.uncertain, .node)))
        XCTAssertFalse(MailIntentGuard.waitsForNode(record(.confirmed, .node)))
    }

    func testDirectDispatchNeedsUnstartedMailWork() {
        // Only a route-nil pending mail intent never left toward the Node.
        XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(.pending, .node)))
        XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(.pending, .direct)))
        for state in [MailIntentState.dispatching, .confirmed, .failed] {
            XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(state, .direct)), "\(state)")
        }
        XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(.failed, .node)))
        // The guard checks the state itself, not only the route the schema pairs with it.
        for state in MailIntentState.allCases where state != .pending {
            XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(state, nil)), "\(state)(nil)")
        }
        // Credential pushes only ever go to the Node.
        XCTAssertFalse(MailIntentGuard.mayDispatchDirect(record(.pending, nil, kind: .credentialPush)))
        for kind in [MailIntentKind.markRead, .markUnread, .archive, .delete, .saveDraft, .send] {
            XCTAssertTrue(MailIntentGuard.mayDispatchDirect(record(.pending, nil, kind: kind)), "\(kind)")
        }
    }

    func testResendIsAllowedOnlyForUnstartedOrFailedWork() {
        XCTAssertTrue(MailIntentGuard.mayResend(record(.pending, nil)))
        XCTAssertTrue(MailIntentGuard.mayResend(record(.failed, .node)))
        XCTAssertTrue(MailIntentGuard.mayResend(record(.failed, .direct)))
        XCTAssertFalse(MailIntentGuard.mayResend(record(.dispatching, .direct)))
        XCTAssertFalse(MailIntentGuard.mayResend(record(.confirmed, .direct)))
        XCTAssertFalse(MailIntentGuard.mayResend(record(.unconfirmed, .node)), "it may have taken effect")
        XCTAssertTrue(MailIntentGuard.mayResend(record(.failed, nil)), "a refused, unrouted row")
    }

    func testWaitingForNodeCoversOnlyAdmittedAndUncertain() {
        let waiting: Set<MailIntentState> = [.admitted, .uncertain]
        for state in MailIntentState.allCases {
            XCTAssertEqual(MailIntentGuard.waitsForNode(record(state, .node)), waiting.contains(state), "\(state)")
            XCTAssertFalse(MailIntentGuard.waitsForNode(record(state, .direct)), "\(state)")
        }
    }

    func testOutcomeTransitionTableIsExplicitAndMonotone() {
        let allowed: [MailIntentState: [MailIntentRoute: Set<MailIntentState>]] = [
            .dispatching: [.node: [.admitted, .confirmed, .uncertain, .failed], .direct: [.confirmed, .failed]],
            .admitted: [.node: [.confirmed, .uncertain, .failed]],
            // Spec amendment (Task 16 review): exact replay `rejected` → failed,
            // `conflicted` → unconfirmed.
            .uncertain: [.node: [.confirmed, .failed, .unconfirmed]],
        ]
        for from in MailIntentState.allCases {
            for route in [MailIntentRoute?.none, .node, .direct] {
                for to in MailIntentState.allCases {
                    let expected = route.flatMap { allowed[from]?[$0]?.contains(to) } ?? false
                    XCTAssertEqual(MailIntentTransition.mayRecordOutcome(from: from, to: to, route: route), expected,
                                   "\(from)(\(route.map(\.rawValue) ?? "nil")) -> \(to)")
                }
            }
        }
    }

    func testOperationIDsMustBeLowercaseCanonicalUUIDs() {
        XCTAssertTrue(MailIntentRecord.isValidOperationID("00000000-0000-4000-8000-000000000001"))
        XCTAssertTrue(MailIntentRecord.isValidOperationID(UUID().uuidString.lowercased()))
        XCTAssertFalse(MailIntentRecord.isValidOperationID(UUID().uuidString.uppercased()))
        XCTAssertFalse(MailIntentRecord.isValidOperationID("0000000000000000000000000000000000001"))
        XCTAssertFalse(MailIntentRecord.isValidOperationID(" 0000000-0000-4000-8000-000000000001"))
        XCTAssertFalse(MailIntentRecord.isValidOperationID(""))
    }

    func testRawValuesMatchTheJournalSchema() {
        XCTAssertEqual(MailIntentKind.allCases.map(\.rawValue),
                       ["mark_read", "mark_unread", "archive", "delete", "flag", "unflag", "move", "save_draft", "send", "credential_push"])
        XCTAssertEqual(MailIntentState.allCases.map(\.rawValue),
                       ["pending", "dispatching", "admitted", "confirmed", "uncertain", "failed", "unconfirmed_after_removal",
                        "unconfirmed"])
    }
}
