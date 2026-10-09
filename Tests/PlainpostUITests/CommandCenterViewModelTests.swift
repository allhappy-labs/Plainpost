import XCTest
@testable import PlainpostUI

final class CommandCenterViewModelTests: XCTestCase {
    @MainActor
    func testDefaultCommandsCoverMVPCommandCenterSurface() {
        let viewModel = CommandCenterViewModel.preview()

        XCTAssertEqual(
            viewModel.commands.map(\.title),
            [
                "Search mail",
                "Go to Smart Inbox",
                "Go to Drafts",
                "Open Settings",
                "Open agent approvals",
                "Create new draft",
                "Open AI Index Status"
            ]
        )
        XCTAssertEqual(viewModel.commands.first?.keyboardShortcut, "⌘F")
        XCTAssertEqual(viewModel.commands.first?.category, .search)
    }

    @MainActor
    func testDefaultCommandsExposeNativeMacShortcuts() {
        let shortcuts = Dictionary(
            uniqueKeysWithValues: CommandCenterViewModel.defaultCommands.map { ($0.id, $0.keyboardShortcut) }
        )

        XCTAssertEqual(shortcuts["search_mail"] ?? nil, "⌘F")
        XCTAssertEqual(shortcuts["go_smart_inbox"] ?? nil, "⌘1")
        XCTAssertEqual(shortcuts["open_approval_queue"] ?? nil, "⌘2")
        XCTAssertEqual(shortcuts["open_settings"] ?? nil, "⌘,")
        XCTAssertEqual(shortcuts["create_new_draft"] ?? nil, "⌘N")
    }

    @MainActor
    func testCommandFilteringIsCaseInsensitiveAndStable() {
        let viewModel = CommandCenterViewModel.preview()

        viewModel.query = "DRAFT"

        XCTAssertEqual(
            viewModel.filteredCommands.map(\.title),
            ["Go to Drafts", "Create new draft", "Search mail"]
        )
        XCTAssertEqual(viewModel.selectedCommandID, "go_drafts")
    }

    @MainActor
    func testKeyboardSelectionWrapsAndSubmitExecutesSelectedCommand() throws {
        let viewModel = CommandCenterViewModel.preview()

        viewModel.open()
        XCTAssertEqual(viewModel.selectedCommandID, "search_mail")

        viewModel.moveSelection(.up)
        XCTAssertEqual(viewModel.selectedCommandID, "open_ai_index_status")

        viewModel.moveSelection(.down)
        XCTAssertEqual(viewModel.selectedCommandID, "search_mail")

        let command = try viewModel.submitSelected()
        XCTAssertEqual(command.id, "search_mail")
        XCTAssertEqual(viewModel.lastExecutedCommandID, "search_mail")
        XCTAssertFalse(viewModel.isPresented)
    }

    @MainActor
    func testUnknownCommandQueryFallsBackToMailSearch() {
        let viewModel = CommandCenterViewModel.preview()

        viewModel.open()
        viewModel.query = "no matching command"

        XCTAssertEqual(viewModel.filteredCommands.map(\.id), ["search_mail"])
        XCTAssertEqual(viewModel.selectedCommandID, "search_mail")
        XCTAssertEqual(try? viewModel.submitSelected().id, "search_mail")
        XCTAssertEqual(viewModel.query, "no matching command")
    }

    @MainActor
    func testOpenExecuteAndCloseUpdatesLocalCommandState() {
        let viewModel = CommandCenterViewModel.preview()

        viewModel.open()
        XCTAssertTrue(viewModel.isPresented)

        try? viewModel.execute(commandID: "open_approval_queue")

        XCTAssertEqual(viewModel.lastExecutedCommandID, "open_approval_queue")
        XCTAssertEqual(viewModel.statusMessage, "Open agent approvals")
        XCTAssertFalse(viewModel.isPresented)

        viewModel.open()
        viewModel.close()
        XCTAssertFalse(viewModel.isPresented)
    }

    func testAppCommandNotificationRoundTripsThroughNotificationPayload() {
        let notification = Notification(
            name: .plainpostAppCommand,
            object: PlainpostAppCommand.commandCenter.rawValue
        )

        XCTAssertEqual(notification.plainpostAppCommand, .commandCenter)
    }

    @MainActor
    func testCommandCenterPanelExecutionCallbackReceivesSelectedCommand() {
        let viewModel = CommandCenterViewModel.preview()
        var executedCommand: CommandCenterCommand?
        let panel = CommandCenterPanel(viewModel: viewModel) { command in
            executedCommand = command
        }

        try? viewModel.execute(commandID: "open_settings")
        panel.onExecute(CommandCenterViewModel.defaultCommands.first { $0.id == "open_settings" }!)

        XCTAssertEqual(executedCommand?.id, "open_settings")
    }
}
