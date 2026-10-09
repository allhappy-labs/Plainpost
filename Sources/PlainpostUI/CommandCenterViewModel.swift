import Foundation
import SwiftUI

public enum CommandCenterMoveDirection: Sendable {
    case up
    case down
}

public enum CommandCenterCategory: String, CaseIterable, Equatable, Sendable {
    case search
    case navigation
    case ai
    case mailAction
    case label
    case compose
    case maintenance

    public var displayName: String {
        switch self {
        case .search:
            "Search"
        case .navigation:
            "Navigation"
        case .ai:
            "AI"
        case .mailAction:
            "Mail"
        case .label:
            "Labels"
        case .compose:
            "Compose"
        case .maintenance:
            "Maintenance"
        }
    }
}

public struct CommandCenterCommand: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: CommandCenterCategory
    public let systemImage: String
    public let keyboardShortcut: String?

    public init(
        id: String,
        title: String,
        category: CommandCenterCategory,
        systemImage: String,
        keyboardShortcut: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.systemImage = systemImage
        self.keyboardShortcut = keyboardShortcut
    }
}

public enum CommandCenterError: Error, Equatable, Sendable {
    case commandNotFound
    case noCommandSelected
}

@MainActor
public final class CommandCenterViewModel: ObservableObject {
    @Published public var query: String {
        didSet { synchronizeSelection() }
    }
    @Published public private(set) var isPresented: Bool
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var lastExecutedCommandID: String?
    @Published public private(set) var selectedCommandID: String?

    @Published public var smartInboxEnabled = true {
        didSet { synchronizeSelection() }
    }
    public let commands: [CommandCenterCommand]

    public init(commands: [CommandCenterCommand] = CommandCenterViewModel.defaultCommands) {
        self.commands = commands
        self.query = ""
        self.isPresented = false
        self.selectedCommandID = commands.first?.id
    }

    public var filteredCommands: [CommandCenterCommand] {
        let commands = commands.filter { smartInboxEnabled || $0.id != "go_smart_inbox" }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return commands
        }

        let matchingCommands = commands.filter { command in
            command.id != "search_mail"
                && (command.title.lowercased().contains(normalized)
                || command.category.displayName.lowercased().contains(normalized)
                )
        }
        let mailSearch = commands.first { $0.id == "search_mail" }
        return matchingCommands + [mailSearch].compactMap { $0 }
    }

    public func open() {
        query = ""
        selectedCommandID = filteredCommands.first?.id
        isPresented = true
    }

    public func close() {
        isPresented = false
    }

    public func select(commandID: String) {
        guard filteredCommands.contains(where: { $0.id == commandID }) else {
            return
        }
        selectedCommandID = commandID
    }

    public func moveSelection(_ direction: CommandCenterMoveDirection) {
        let availableCommands = filteredCommands
        guard !availableCommands.isEmpty else {
            selectedCommandID = nil
            return
        }

        guard let selectedCommandID,
              let currentIndex = availableCommands.firstIndex(where: { $0.id == selectedCommandID }) else {
            self.selectedCommandID = availableCommands.first?.id
            return
        }

        switch direction {
        case .down:
            self.selectedCommandID = availableCommands[(currentIndex + 1) % availableCommands.count].id
        case .up:
            self.selectedCommandID = availableCommands[(currentIndex - 1 + availableCommands.count) % availableCommands.count].id
        }
    }

    @discardableResult
    public func submitSelected() throws -> CommandCenterCommand {
        guard let selectedCommandID else {
            throw CommandCenterError.noCommandSelected
        }
        guard let command = commands.first(where: { $0.id == selectedCommandID }) else {
            throw CommandCenterError.commandNotFound
        }
        try execute(commandID: selectedCommandID)
        return command
    }

    public func execute(commandID: String) throws {
        guard smartInboxEnabled || commandID != "go_smart_inbox" else {
            throw CommandCenterError.commandNotFound
        }
        guard let command = commands.first(where: { $0.id == commandID }) else {
            throw CommandCenterError.commandNotFound
        }
        lastExecutedCommandID = command.id
        statusMessage = command.title
        close()
    }

    private func synchronizeSelection() {
        let availableCommands = filteredCommands
        guard !availableCommands.isEmpty else {
            selectedCommandID = nil
            return
        }
        selectedCommandID = availableCommands.first?.id
    }

    public static func preview() -> CommandCenterViewModel {
        CommandCenterViewModel()
    }

    public static let defaultCommands: [CommandCenterCommand] = [
        CommandCenterCommand(id: "search_mail", title: "Search mail", category: .search, systemImage: "magnifyingglass", keyboardShortcut: "⌘F"),
        CommandCenterCommand(id: "go_smart_inbox", title: "Go to Smart Inbox", category: .navigation, systemImage: "tray.full", keyboardShortcut: "⌘1"),
        CommandCenterCommand(id: "go_drafts", title: "Go to Drafts", category: .navigation, systemImage: "doc.text"),
        CommandCenterCommand(id: "open_settings", title: "Open Settings", category: .navigation, systemImage: "gearshape", keyboardShortcut: "⌘,"),
        CommandCenterCommand(id: "open_approval_queue", title: "Open agent approvals", category: .navigation, systemImage: "checkmark.seal", keyboardShortcut: "⌘2"),
        CommandCenterCommand(id: "create_new_draft", title: "Create new draft", category: .compose, systemImage: "square.and.pencil", keyboardShortcut: "⌘N"),
        CommandCenterCommand(id: "open_ai_index_status", title: "Open AI Index Status", category: .navigation, systemImage: "chart.bar")
    ]
}
