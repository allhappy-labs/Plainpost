import Foundation
import SwiftUI

struct MessageLabelCommandCenterContext: Equatable, Sendable {
    let messageID: String
    let sender: String
    let subject: String
}

struct MessageLabelCommand: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case add
        case remove
        case ruleOwned(ruleNames: [String])
    }

    let labelID: String
    let labelTitle: String
    let kind: Kind
    let ownershipHelp: String?

    var id: String { labelID }

    var isActionable: Bool {
        if case .ruleOwned = kind {
            false
        } else {
            true
        }
    }

    var title: String {
        switch kind {
        case .add:
            "Add “\(labelTitle)”"
        case .remove:
            "Remove “\(labelTitle)”"
        case .ruleOwned(let ruleNames):
            "Applied by rule: \(ruleNames.joined(separator: ", "))"
        }
    }

    func accessibilitySelectionValue(highlighted: Bool) -> String? {
        guard isActionable else { return nil }
        return highlighted ? "Selected" : "Not selected"
    }
}

struct MessageLabelCommandPresentation: Equatable, Sendable {
    let assigned: [MessageLabelCommand]
    let available: [MessageLabelCommand]
    let effectiveLabelCount: Int

    var actionableCommands: [MessageLabelCommand] {
        (assigned + available).filter(\.isActionable)
    }
}

@MainActor
final class MessageLabelCommandCenterViewModel: ObservableObject {
    @Published private(set) var context: MessageLabelCommandCenterContext?
    @Published var query = ""
    @Published private(set) var selectedLabelID: String?

    var isPresented: Bool { context != nil }

    static func labelActionTitle(hasEffectiveLabels: Bool) -> String {
        hasEffectiveLabels ? "Add or remove labels" : "Add a label"
    }

    func open(context: MessageLabelCommandCenterContext) {
        self.context = context
        query = ""
        selectedLabelID = nil
    }

    func close() {
        context = nil
        query = ""
        selectedLabelID = nil
    }

    func presentation(items: [MessageLabelMenuItem]) -> MessageLabelCommandPresentation {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleItems = normalizedQuery.isEmpty
            ? items
            : items.filter {
                $0.title.localizedCaseInsensitiveContains(normalizedQuery)
            }
        let commands = visibleItems.map(Self.command)
        return MessageLabelCommandPresentation(
            assigned: commands
                .filter { $0.kind != .add }
                .sorted(by: Self.commandOrdering),
            available: commands
                .filter { $0.kind == .add }
                .sorted(by: Self.commandOrdering),
            effectiveLabelCount: items.filter(\.isEffective).count
        )
    }

    func reconcileSelection(in presentation: MessageLabelCommandPresentation) {
        let commands = presentation.actionableCommands
        if let selectedLabelID,
           commands.contains(where: { $0.labelID == selectedLabelID }) {
            return
        }
        selectedLabelID = commands.first?.labelID
    }

    func moveSelection(
        _ direction: MailboxRowMoveDirection,
        in presentation: MessageLabelCommandPresentation
    ) {
        let ids = presentation.actionableCommands.map(\.labelID)
        selectedLabelID = MailboxRowKeyboardNavigation.nextID(
            current: selectedLabelID,
            direction: direction,
            orderedIDs: ids
        )
    }

    private static func command(for item: MessageLabelMenuItem) -> MessageLabelCommand {
        let kind: MessageLabelCommand.Kind
        if item.hasUserOrSmartInboxOwnership {
            kind = .remove
        } else if item.isEffective {
            kind = .ruleOwned(ruleNames: item.ruleOwnershipNames)
        } else {
            kind = .add
        }
        return MessageLabelCommand(
            labelID: item.id,
            labelTitle: item.title,
            kind: kind,
            ownershipHelp: item.ownershipHelp
        )
    }

    private static func commandOrdering(
        _ lhs: MessageLabelCommand,
        _ rhs: MessageLabelCommand
    ) -> Bool {
        let comparison = lhs.labelTitle.localizedCaseInsensitiveCompare(rhs.labelTitle)
        return comparison == .orderedSame
            ? lhs.labelID < rhs.labelID
            : comparison == .orderedAscending
    }
}

enum MailboxCommandSurfaceTransition: Equatable, Sendable {
    case opacityOnly
    case scaleAndOpacity

    static func resolve(reduceMotion: Bool) -> Self {
        reduceMotion ? .opacityOnly : .scaleAndOpacity
    }

    var swiftUITransition: AnyTransition {
        switch self {
        case .opacityOnly:
            .opacity
        case .scaleAndOpacity:
            .scale(scale: 0.98).combined(with: .opacity)
        }
    }
}

@MainActor
final class MailboxCommandSurfaceLifecycle: ObservableObject {
    let globalCommandCenter: CommandCenterViewModel
    let labelCommandCenter: MessageLabelCommandCenterViewModel
    let quickActionFocus: MailboxRowQuickActionFocusCoordinator
    private var sourceMessageID: String?

    init(
        globalCommandCenter: CommandCenterViewModel,
        labelCommandCenter: MessageLabelCommandCenterViewModel,
        quickActionFocus: MailboxRowQuickActionFocusCoordinator
    ) {
        self.globalCommandCenter = globalCommandCenter
        self.labelCommandCenter = labelCommandCenter
        self.quickActionFocus = quickActionFocus
    }

    var isPresented: Bool {
        globalCommandCenter.isPresented || labelCommandCenter.isPresented
    }

    func openLabels(for row: MessageRowModel) {
        objectWillChange.send()
        globalCommandCenter.close()
        sourceMessageID = row.id
        labelCommandCenter.open(
            context: MessageLabelCommandCenterContext(
                messageID: row.id,
                sender: row.senderDisplayName ?? row.sender,
                subject: row.subject
            )
        )
    }

    func closeLabels(restoringFocus: Bool) {
        objectWillChange.send()
        let sourceMessageID = sourceMessageID
        labelCommandCenter.close()
        self.sourceMessageID = nil
        if restoringFocus, let sourceMessageID {
            quickActionFocus.requestLabelFocus(for: sourceMessageID)
        }
    }

    func openGlobalCommandCenter() {
        objectWillChange.send()
        closeLabels(restoringFocus: false)
        globalCommandCenter.open()
    }

    func invalidateMailboxSource() {
        guard labelCommandCenter.isPresented || sourceMessageID != nil else {
            return
        }
        closeLabels(restoringFocus: false)
    }

    func invalidateMailboxSource(availableMessageIDs: Set<String>) {
        guard let sourceMessageID,
              !availableMessageIDs.contains(sourceMessageID)
        else {
            return
        }
        closeLabels(restoringFocus: false)
    }
}
