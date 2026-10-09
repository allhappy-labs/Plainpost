import PlainpostCore

/// Whether all, some, or none of a section's action messages are currently selected.
public enum AskMailSectionCheckState: Equatable, Sendable { case all, some, none }

/// Which messages of an `AskMailMessageListBlock` are ticked for a bulk action.
/// Everything is selected by default; toggling tracks only the deselected messages.
public struct AskMailListSelection: Equatable {
    private var sectionIDs: [String: [MessageID]]
    private var deselected: Set<MessageID> = []

    public init(block: AskMailMessageListBlock) {
        sectionIDs = Dictionary(block.sections.map { ($0.id, $0.actionMessageIDs) }, uniquingKeysWith: { first, _ in first })
    }

    public func isSelected(_ id: MessageID) -> Bool { !deselected.contains(id) }

    public mutating func toggleRow(_ id: MessageID, in sectionID: String) {
        if deselected.contains(id) { deselected.remove(id) } else { deselected.insert(id) }
    }

    public mutating func toggleSection(_ sectionID: String) {
        let ids = sectionIDs[sectionID] ?? []
        if sectionState(sectionID) == .none { deselected.subtract(ids) } else { deselected.formUnion(ids) }
    }

    public func selectedMessageIDs(in sectionID: String) -> [MessageID] {
        (sectionIDs[sectionID] ?? []).filter { !deselected.contains($0) }
    }

    public func selectedCount(in sectionID: String) -> Int { selectedMessageIDs(in: sectionID).count }

    public func sectionState(_ sectionID: String) -> AskMailSectionCheckState {
        let total = sectionIDs[sectionID]?.count ?? 0
        let count = selectedCount(in: sectionID)
        return count == 0 ? .none : count == total ? .all : .some
    }

    public var totalSelected: Int { sectionIDs.keys.reduce(0) { $0 + selectedCount(in: $1) } }
}
