import Foundation

enum PlainpostRootWorkspacePresentation: Equatable, Sendable {
    case sidebarAndWorkspace
    case sidebarContentAndDetail

    static func resolve(for kind: PlainpostWorkAreaKind) -> Self {
        (kind == .mailbox || kind == .calendar) ? .sidebarAndWorkspace : .sidebarContentAndDetail
    }
}

enum MailboxListContext: Hashable, Sendable {
    case mailbox(destination: PlainpostDestination, mode: InboxDisplayMode)
    case smartInboxOverview
    case smartInboxBundle(SmartInboxDisplayBundle)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.mailbox(lhsDestination, lhsMode), .mailbox(rhsDestination, rhsMode)):
            lhsDestination.rawValue == rhsDestination.rawValue
                && lhsMode.rawValue == rhsMode.rawValue
        case (.smartInboxOverview, .smartInboxOverview):
            true
        case let (.smartInboxBundle(lhsBundle), .smartInboxBundle(rhsBundle)):
            lhsBundle.rawValue == rhsBundle.rawValue
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .mailbox(destination, mode):
            hasher.combine(0)
            hasher.combine(destination.rawValue)
            hasher.combine(mode.rawValue)
        case .smartInboxOverview:
            hasher.combine(1)
        case let .smartInboxBundle(bundle):
            hasher.combine(2)
            hasher.combine(bundle.rawValue)
        }
    }
}

enum MailboxScrollSectionID: Hashable, Sendable {
    case mailbox
    case unreadCard(String)
    case smartInboxToday
    case smartInboxHistorical(SmartInboxHistoricalSectionID)
    case smartInboxBundle(SmartInboxDisplayBundle)
}

struct MailboxScrollItem: Equatable, Hashable, Sendable {
    let id: String
    let sectionID: MailboxScrollSectionID
}

struct MailboxScrollLocation: Equatable, Sendable {
    let anchorID: String?
    let anchorViewportOffset: Double
    let contentOffsetY: Double
    let orderedItems: [MailboxScrollItem]
    let selectedMessageID: String?

    var orderedIDs: [String] {
        orderedItems.map(\.id)
    }

    init(
        anchorID: String?,
        anchorViewportOffset: Double,
        contentOffsetY: Double,
        orderedItems: [MailboxScrollItem],
        selectedMessageID: String?
    ) {
        self.anchorID = anchorID
        self.anchorViewportOffset = anchorViewportOffset
        self.contentOffsetY = contentOffsetY
        self.orderedItems = orderedItems
        self.selectedMessageID = selectedMessageID
    }

    init(
        anchorID: String?,
        anchorViewportOffset: Double,
        contentOffsetY: Double,
        orderedIDs: [String],
        selectedMessageID: String?
    ) {
        self.init(
            anchorID: anchorID,
            anchorViewportOffset: anchorViewportOffset,
            contentOffsetY: contentOffsetY,
            orderedItems: orderedIDs.map {
                MailboxScrollItem(id: $0, sectionID: .mailbox)
            },
            selectedMessageID: selectedMessageID
        )
    }

    static let top = Self(
        anchorID: nil,
        anchorViewportOffset: 0,
        contentOffsetY: 0,
        orderedItems: [],
        selectedMessageID: nil
    )
}

enum MailboxScrollRestoration: Equatable, Sendable {
    case exact(contentOffsetY: Double, selectedMessageID: String?)
    case anchor(id: String, viewportOffset: Double, selectedMessageID: String?)
    case top(selectedMessageID: String?)
}

enum MailboxWorkspaceRoute: Equatable, Sendable {
    case list(MailboxListContext)
    case reader(messageID: String, returnContext: MailboxListContext)
}

struct MailboxNavigationIntent: Equatable, Sendable {
    let destination: PlainpostDestination
    let mode: InboxDisplayMode
    let route: MailboxWorkspaceRoute
    let selectedMessageID: String?
    let revision: UInt64
}

struct MailboxOptimisticNavigationTransition: Equatable, Sendable {
    let optimisticIntent: MailboxNavigationIntent

    func shouldRestoreNavigation(
        currentIntent: MailboxNavigationIntent
    ) -> Bool {
        currentIntent == optimisticIntent
    }
}

@MainActor
enum MailboxNavigationBoundarySetter {
    static func setDisplayMode(
        from currentMode: String,
        to newMode: String,
        runtime: MailboxScrollRuntime,
        selectedMessageID: String?,
        capture: (MailboxScrollLocation) -> Void,
        assign: (String) -> Void
    ) {
        setValue(
            from: currentMode,
            to: newMode,
            runtime: runtime,
            selectedMessageID: selectedMessageID,
            capture: capture,
            assign: assign
        )
    }

    static func setDestination(
        from currentDestination: PlainpostDestination,
        to newDestination: PlainpostDestination,
        runtime: MailboxScrollRuntime,
        selectedMessageID: String?,
        capture: (MailboxScrollLocation) -> Void,
        assign: (PlainpostDestination) -> Void
    ) {
        setValue(
            from: currentDestination,
            to: newDestination,
            runtime: runtime,
            selectedMessageID: selectedMessageID,
            capture: capture,
            assign: assign
        )
    }

    static func setDestinationAndDisplayMode(
        from currentDestination: PlainpostDestination,
        currentDisplayMode: String,
        to newDestination: PlainpostDestination,
        displayMode newDisplayMode: String,
        runtime: MailboxScrollRuntime,
        selectedMessageID: String?,
        capture: (MailboxScrollLocation) -> Void,
        assign: (PlainpostDestination, String) -> Void
    ) {
        guard currentDestination != newDestination
                || currentDisplayMode != newDisplayMode
        else {
            return
        }
        captureLocation(
            runtime: runtime,
            selectedMessageID: selectedMessageID,
            capture: capture
        )
        assign(newDestination, newDisplayMode)
    }

    private static func setValue<Value: Equatable>(
        from currentValue: Value,
        to newValue: Value,
        runtime: MailboxScrollRuntime,
        selectedMessageID: String?,
        capture: (MailboxScrollLocation) -> Void,
        assign: (Value) -> Void
    ) {
        guard currentValue != newValue else { return }
        captureLocation(
            runtime: runtime,
            selectedMessageID: selectedMessageID,
            capture: capture
        )
        assign(newValue)
    }

    private static func captureLocation(
        runtime: MailboxScrollRuntime,
        selectedMessageID: String?,
        capture: (MailboxScrollLocation) -> Void
    ) {
        if let location = runtime.capture(
            reason: .navigationBoundary,
            selectedMessageID: selectedMessageID
        ) {
            capture(location)
        }
    }
}

struct MailboxWorkspaceNavigationState: Equatable, Sendable {
    private(set) var route: MailboxWorkspaceRoute
    private var locations: [MailboxListContext: MailboxScrollLocation] = [:]
    private var pendingRestorations: [MailboxListContext: MailboxScrollRestoration] = [:]
    private var displayModesByDestination: [String: String] = [:]
    private var contextsNeedingRestoration: Set<MailboxListContext> = []

    init(initialContext: MailboxListContext) {
        route = .list(initialContext)
        switch initialContext {
        case let .mailbox(destination, mode):
            remember(mode, for: destination)
        case .smartInboxOverview, .smartInboxBundle:
            remember(.focusedList, for: .smartInbox)
        }
    }

    func location(for context: MailboxListContext) -> MailboxScrollLocation {
        locations[context] ?? .top
    }

    mutating func save(_ location: MailboxScrollLocation, for context: MailboxListContext) {
        locations[context] = location
    }

    mutating func remember(
        _ mode: InboxDisplayMode,
        for destination: PlainpostDestination
    ) {
        displayModesByDestination[destination.rawValue] = mode.rawValue
    }

    func rememberedMode(
        for destination: PlainpostDestination,
        fallback: InboxDisplayMode
    ) -> InboxDisplayMode {
        displayModesByDestination[destination.rawValue]
            .flatMap(InboxDisplayMode.init(rawValue:))
            ?? fallback
    }

    mutating func showList(_ context: MailboxListContext) {
        route = .list(context)
        if locations[context] != nil {
            contextsNeedingRestoration.insert(context)
        }
    }

    mutating func prepareListRestoration(
        for context: MailboxListContext,
        availableScrollIDs: [String],
        availableMessageIDs: [String]
    ) {
        prepareListRestoration(
            for: context,
            availableItems: availableScrollIDs.map {
                MailboxScrollItem(id: $0, sectionID: .mailbox)
            },
            availableMessageIDs: availableMessageIDs
        )
    }

    mutating func prepareListRestoration(
        for context: MailboxListContext,
        availableItems: [MailboxScrollItem],
        availableMessageIDs: [String]
    ) {
        guard contextsNeedingRestoration.remove(context) != nil else { return }
        pendingRestorations[context] = restoration(
            for: context,
            availableItems: availableItems,
            availableMessageIDs: availableMessageIDs
        )
    }

    mutating func prepareRefreshRestoration(
        for context: MailboxListContext,
        availableScrollIDs: [String],
        availableMessageIDs: [String]
    ) {
        prepareRefreshRestoration(
            for: context,
            availableItems: availableScrollIDs.map {
                MailboxScrollItem(id: $0, sectionID: .mailbox)
            },
            availableMessageIDs: availableMessageIDs
        )
    }

    mutating func prepareRefreshRestoration(
        for context: MailboxListContext,
        availableItems: [MailboxScrollItem],
        availableMessageIDs: [String]
    ) {
        guard route == .list(context), locations[context] != nil else { return }
        pendingRestorations[context] = restoration(
            for: context,
            availableItems: availableItems,
            availableMessageIDs: availableMessageIDs
        )
    }

    mutating func openReader(messageID: String, from context: MailboxListContext) {
        route = .reader(messageID: messageID, returnContext: context)
    }

    func calendarReturnContext(destination: PlainpostDestination, mode: InboxDisplayMode) -> MailboxListContext? {
        let context: MailboxListContext
        switch route { case .list(let value), .reader(_, let value): context = value }
        switch context {
        case .mailbox(let storedDestination, let storedMode):
            return storedDestination == destination && storedMode == mode ? context : nil
        case .smartInboxOverview, .smartInboxBundle:
            return destination == .smartInbox && mode == .focusedList ? context : nil
        }
    }

    /// Leaving for Calendar retains the reader and its list/scroll context.
    /// Other utilities retain their existing list-only return behavior.
    mutating func leave(for destination: PlainpostDestination) -> Bool {
        if destination.workAreaKind == .calendar { return true }
        if case let .reader(_, context) = route { showList(context) }
        return false
    }

    mutating func returnFromReader() {
        guard case let .reader(_, returnContext) = route else { return }
        pendingRestorations.removeValue(forKey: returnContext)
        contextsNeedingRestoration.insert(returnContext)
        route = .list(returnContext)
    }

    private func restoration(
        for context: MailboxListContext,
        availableItems: [MailboxScrollItem],
        availableMessageIDs: [String]
    ) -> MailboxScrollRestoration {
        let saved = location(for: context)
        let availableScrollIDs = availableItems.map(\.id)
        let availableMessages = Set(availableMessageIDs)
        let selected = saved.selectedMessageID.flatMap {
            availableMessages.contains($0) ? $0 : nil
        }

        if saved.orderedItems == availableItems {
            return .exact(
                contentOffsetY: saved.contentOffsetY,
                selectedMessageID: selected
            )
        } else if let anchorID = saved.anchorID,
                  availableScrollIDs.contains(anchorID) {
            return .anchor(
                id: anchorID,
                viewportOffset: saved.anchorViewportOffset,
                selectedMessageID: selected
            )
        } else if let neighbor = nearestSurvivingID(
            to: saved.anchorID,
            savedItems: saved.orderedItems,
            availableItems: availableItems
        ) {
            return .anchor(
                id: neighbor,
                viewportOffset: saved.anchorViewportOffset,
                selectedMessageID: selected
            )
        } else {
            return .top(selectedMessageID: selected)
        }
    }

    mutating func consumeRestoration(
        for context: MailboxListContext
    ) -> MailboxScrollRestoration? {
        pendingRestorations.removeValue(forKey: context)
    }

    private func nearestSurvivingID(
        to anchorID: String?,
        savedItems: [MailboxScrollItem],
        availableItems: [MailboxScrollItem]
    ) -> String? {
        let available = Set(availableItems.map(\.id))
        let availableSections = Dictionary(
            availableItems.map { ($0.id, $0.sectionID) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard let anchorID,
              let index = savedItems.firstIndex(where: { $0.id == anchorID })
        else {
            return availableItems.first?.id
        }
        let anchorSection = savedItems[index].sectionID
        for distance in 1...max(savedItems.count, 1) {
            let following = index + distance
            if savedItems.indices.contains(following),
               savedItems[following].sectionID == anchorSection,
               availableSections[savedItems[following].id] == anchorSection {
                return savedItems[following].id
            }
            let preceding = index - distance
            if savedItems.indices.contains(preceding),
               savedItems[preceding].sectionID == anchorSection,
               availableSections[savedItems[preceding].id] == anchorSection {
                return savedItems[preceding].id
            }
        }
        for distance in 1...max(savedItems.count, 1) {
            let following = index + distance
            if savedItems.indices.contains(following),
               available.contains(savedItems[following].id) {
                return savedItems[following].id
            }
            let preceding = index - distance
            if savedItems.indices.contains(preceding),
               available.contains(savedItems[preceding].id) {
                return savedItems[preceding].id
            }
        }
        return availableItems.first?.id
    }
}
