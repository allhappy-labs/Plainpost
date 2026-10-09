import PlainpostCore
import PlainpostRuntimeTestSupport
import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor final class MessageLabelCommandCenterViewModelTests: XCTestCase {
    func testCurrentLabelCommandUsesDistinctServiceOperation() async throws {
        let client = RuntimeServiceClientFake()
        let adapter = PlainpostServiceMessageLabelMutationAdapter(serviceClient: client)

        try await adapter.command(
            labelID: "important", messageID: MessageID("message-1"), selected: true)

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.foregroundOperationKinds, [.labelCommand])
    }

    func testOnlyActionableCommandsExposeSelectionAccessibilityValue() {
        let add = MessageLabelCommand(
            labelID: "add",
            labelTitle: "Add",
            kind: .add,
            ownershipHelp: nil
        )
        let ruleOwned = MessageLabelCommand(
            labelID: "rule",
            labelTitle: "Rule",
            kind: .ruleOwned(ruleNames: ["Travel"]),
            ownershipHelp: nil
        )

        XCTAssertEqual(add.accessibilitySelectionValue(highlighted: true), "Selected")
        XCTAssertEqual(add.accessibilitySelectionValue(highlighted: false), "Not selected")
        XCTAssertNil(ruleOwned.accessibilitySelectionValue(highlighted: false))
    }

    func testPresentationSeparatesRemovableAssignedAvailableAndRuleOwnedLabels() throws {
        let model = MessageLabelCommandCenterViewModel()
        model.open(
            context: .init(
                messageID: "m1",
                sender: "Platformatic",
                subject: "Your Bug Fix Will Never Reach the Runs That Need It"
            )
        )

        let presentation = model.presentation(items: [
            try item(id: "available", title: "Important", sources: []),
            try item(id: "manual", title: "Newsletters", sources: [.user]),
            try item(id: "smart", title: "Receipts", sources: [.smartInbox]),
            try item(
                id: "rule",
                title: "Automation",
                sources: [.rule(ruleID: "r1")],
                ruleNames: ["r1": "Travel alerts"]
            ),
        ])

        XCTAssertEqual(
            presentation.assigned.map(\.title),
            [
                "Applied by rule: Travel alerts",
                "Remove “Newsletters”",
                "Remove “Receipts”",
            ]
        )
        XCTAssertEqual(presentation.available.map(\.title), ["Add “Important”"])
        XCTAssertFalse(presentation.assigned[0].isActionable)
        XCTAssertEqual(presentation.effectiveLabelCount, 3)
    }

    func testMixedRuleAndUserOwnershipRemainsRemovableWithoutClaimingRuleRemoval() throws {
        let model = MessageLabelCommandCenterViewModel()
        let presentation = model.presentation(items: [
            try item(
                id: "mixed",
                title: "Travel",
                sources: [.user, .rule(ruleID: "r1")],
                ruleNames: ["r1": "Travel alerts"]
            ),
        ])

        XCTAssertEqual(presentation.assigned.map(\.title), ["Remove “Travel”"])
        XCTAssertEqual(presentation.assigned.first?.kind, .remove)
        XCTAssertEqual(
            presentation.assigned.first?.ownershipHelp,
            "Added manually, Added by rule: Travel alerts"
        )
    }

    func testSearchFiltersBothSectionsCaseInsensitivelyAfterTrimmingWhitespace() throws {
        let model = MessageLabelCommandCenterViewModel()
        model.open(context: .init(messageID: "m1", sender: "A", subject: "B"))
        model.query = "  NEWS  "

        let presentation = model.presentation(items: [
            try item(id: "news", title: "Newsletters", sources: [.user]),
            try item(id: "receipt", title: "Receipts", sources: []),
        ])

        XCTAssertEqual(presentation.assigned.map(\.labelID), ["news"])
        XCTAssertTrue(presentation.available.isEmpty)
    }

    func testLabelActionTitleReflectsWhetherAnyLabelIsEffective() {
        XCTAssertEqual(
            MessageLabelCommandCenterViewModel.labelActionTitle(hasEffectiveLabels: false),
            "Add a label"
        )
        XCTAssertEqual(
            MessageLabelCommandCenterViewModel.labelActionTitle(hasEffectiveLabels: true),
            "Add or remove labels"
        )
    }

    func testSelectionSkipsRuleOwnedRowsAndMovesWithoutWrapping() throws {
        let model = MessageLabelCommandCenterViewModel()
        let presentation = model.presentation(items: [
            try item(
                id: "rule",
                title: "Automation",
                sources: [.rule(ruleID: "r1")],
                ruleNames: ["r1": "Travel alerts"]
            ),
            try item(id: "manual", title: "Newsletters", sources: [.user]),
            try item(id: "available", title: "Receipts", sources: []),
        ])

        model.reconcileSelection(in: presentation)
        XCTAssertEqual(model.selectedLabelID, "manual")

        model.moveSelection(.down, in: presentation)
        XCTAssertEqual(model.selectedLabelID, "available")

        model.moveSelection(.down, in: presentation)
        XCTAssertEqual(model.selectedLabelID, "available")

        model.moveSelection(.up, in: presentation)
        XCTAssertEqual(model.selectedLabelID, "manual")
    }

    func testSelectionStaysOnSameLabelWhenItMovesBetweenSections() throws {
        let model = MessageLabelCommandCenterViewModel()
        let before = model.presentation(items: [
            try item(id: "travel", title: "Travel", sources: []),
        ])
        model.reconcileSelection(in: before)
        XCTAssertEqual(model.selectedLabelID, "travel")

        let after = model.presentation(items: [
            try item(id: "travel", title: "Travel", sources: [.user]),
        ])
        model.reconcileSelection(in: after)

        XCTAssertEqual(model.selectedLabelID, "travel")
        XCTAssertEqual(after.assigned.map(\.labelID), ["travel"])
    }

    func testOnlyRuleOwnedResultsClearActionableSelection() throws {
        let model = MessageLabelCommandCenterViewModel()
        let actionable = model.presentation(items: [
            try item(id: "travel", title: "Travel", sources: []),
        ])
        model.reconcileSelection(in: actionable)
        XCTAssertEqual(model.selectedLabelID, "travel")

        let informational = model.presentation(items: [
            try item(
                id: "travel",
                title: "Travel",
                sources: [.rule(ruleID: "r1")],
                ruleNames: ["r1": "Travel alerts"]
            ),
        ])
        model.reconcileSelection(in: informational)

        XCTAssertNil(model.selectedLabelID)
    }

    func testCloseClearsContextQueryAndSelection() throws {
        let model = MessageLabelCommandCenterViewModel()
        model.open(context: .init(messageID: "m1", sender: "A", subject: "B"))
        model.query = "news"
        let presentation = model.presentation(items: [
            try item(id: "news", title: "Newsletters", sources: []),
        ])
        model.reconcileSelection(in: presentation)

        model.close()

        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.context)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.selectedLabelID)
    }
}

private func item(
    id: String,
    title: String,
    sources: Set<MailLabelAssignmentSource>,
    ruleNames: [String: String] = [:]
) throws -> MessageLabelMenuItem {
    MessageLabelMenuItem(
        label: try .validated(
            id: id,
            title: title,
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        ),
        sources: sources,
        isExcluded: false,
        ruleNames: ruleNames
    )
}
