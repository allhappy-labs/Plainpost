import SwiftUI
#if os(iOS)
import QuickLook
#endif
import PlainpostAccountProtocol
import PlainpostAccountRuntime

private struct PlainpostNotificationRootModifier: ViewModifier {
    let request: PlainpostNotificationOpenRequest?
    let selectedMessageID: String?
    let destination: PlainpostDestination
    let route: MailboxWorkspaceRoute
    let appear: () -> Void
    let disappear: () -> Void
    let open: (PlainpostNotificationOpenRequest) -> Void
    let attentionChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                appear()
                if let request { open(request) }
            }
            .onDisappear(perform: disappear)
            .onChange(of: request) { _, request in
                guard let request else { return }
                open(request)
            }
            .onChange(of: selectedMessageID) { _, _ in attentionChanged() }
            .onChange(of: destination) { _, _ in attentionChanged() }
            .onChange(of: route) { _, _ in attentionChanged() }
    }
}

public struct PlainpostAttachmentEvent: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case saved(PlainpostAttachmentArtifact)
        case failed(String)
    }

    public let accountID: String?
    public let attachmentID: String
    public let operationToken: UUID
    public let outcome: Outcome

    public init(accountID: String?, attachmentID: String, operationToken: UUID, outcome: Outcome) {
        self.accountID = accountID
        self.attachmentID = attachmentID
        self.operationToken = operationToken
        self.outcome = outcome
    }
}

/// Runtime-owned, account-scoped attachment result state. This deliberately
/// avoids process-global notifications: a result is accepted only for the
/// runtime's account and the attachment operation it started.
@MainActor
public final class PlainpostAttachmentState: ObservableObject {
    public let accountID: String?
    @Published public private(set) var event: PlainpostAttachmentEvent?
    private var expectedOperation: (attachmentID: String, token: UUID)?

    public init(accountID: String?) {
        self.accountID = accountID
    }

    @discardableResult
    public func begin(attachmentID: String) -> UUID {
        try? event?.artifact?.cleanup()
        event = nil
        let token = UUID()
        expectedOperation = (attachmentID, token)
        return token
    }

    public func publish(_ event: PlainpostAttachmentEvent) {
        guard event.accountID == accountID,
              let expectedOperation,
              event.attachmentID == expectedOperation.attachmentID,
              event.operationToken == expectedOperation.token else {
            try? event.artifact?.cleanup()
            return
        }
        try? self.event?.artifact?.cleanup()
        self.event = event
        self.expectedOperation = nil
    }

    public func clear() {
        try? event?.artifact?.cleanup()
        event = nil
        expectedOperation = nil
    }
}

private extension PlainpostAttachmentEvent {
    var artifact: PlainpostAttachmentArtifact? {
        guard case let .saved(artifact) = outcome else { return nil }
        return artifact
    }
}
import PlainpostAI
import PlainpostCore
import PlainpostOperations

struct PlainpostRootDestinationTransition: Equatable {
    let destination: PlainpostDestination
    let settingsSection: PlainpostSettingsSection
    let dismissesSearch: Bool

    var workAreaKind: PlainpostWorkAreaKind {
        destination.workAreaKind
    }

    static func resolve(
        selectedDestination: PlainpostDestination,
        currentSettingsSection: PlainpostSettingsSection,
        isAccountSetupRequired: Bool
    ) -> PlainpostRootDestinationTransition {
        if isAccountSetupRequired, selectedDestination != .settings {
            return PlainpostRootDestinationTransition(
                destination: .settings,
                settingsSection: .accounts,
                dismissesSearch: true
            )
        }
        return PlainpostRootDestinationTransition(
            destination: selectedDestination,
            settingsSection: selectedDestination.settingsSection ?? currentSettingsSection,
            dismissesSearch: selectedDestination.workAreaKind != .mailbox
        )
    }
}

public struct MessageLabelMenuItem: Equatable, Identifiable, Sendable {
    public let label: MailLabelDefinition
    public let sources: Set<MailLabelAssignmentSource>
    public let isExcluded: Bool
    private let ruleNames: [String: String]

    public var id: String { label.id }
    public var title: String { label.title }
    public var isEffective: Bool { !sources.isEmpty }

    public var hasUserOrSmartInboxOwnership: Bool {
        sources.contains(.user) || sources.contains(.smartInbox)
    }

    public var ruleOwnershipNames: [String] {
        sources.compactMap { source -> String? in
            guard case .rule(let ruleID) = source else { return nil }
            return ruleNames[ruleID] ?? ruleID
        }
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    public var ownershipHelp: String? {
        var descriptions: [String] = []
        if sources.contains(.user) {
            descriptions.append("Added manually")
        }
        if sources.contains(.smartInbox) {
            descriptions.append("Added by Smart Inbox")
        }
        let ruleDescriptions = sources.compactMap { source -> String? in
            guard case .rule(let ruleID) = source else { return nil }
            return "Added by rule: \(ruleNames[ruleID] ?? ruleID)"
        }
        descriptions.append(contentsOf: ruleDescriptions.sorted())
        return descriptions.isEmpty ? nil : descriptions.joined(separator: ", ")
    }

    init(
        label: MailLabelDefinition,
        sources: Set<MailLabelAssignmentSource>,
        isExcluded: Bool,
        ruleNames: [String: String]
    ) {
        self.label = label
        self.sources = sources
        self.isExcluded = isExcluded
        self.ruleNames = ruleNames
    }
}

public struct MessageLabelActionErrorEvent: Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let message: String
}

public enum MessageLabelMenuContent: Equatable, Sendable {
    case loading
    case loadFailed
    case empty
    case items([MessageLabelMenuItem])
}

public struct MessageLabelAppearanceToken: Equatable, Hashable, Sendable {
    public let messageID: String
    fileprivate let surfaceSessionID: UInt64
    fileprivate let appearanceID: UInt64
}

private actor MessageLabelMutationSerializer {
    private struct Tail {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private var tails: [MessageLabelAppearanceToken: Tail] = [:]
    private var nextID: UInt64 = 0

    func enqueue(
        for appearance: MessageLabelAppearanceToken,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let predecessor = tails[appearance]?.task
        nextID &+= 1
        let id = nextID
        let task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tails[appearance] = Tail(id: id, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if tails[appearance]?.id == id {
            tails[appearance] = nil
        }
    }
}

@MainActor
public final class MessageLabelActions: ObservableObject {
    typealias ItemLoader = @Sendable (MessageID) async throws -> [MessageLabelMenuItem]
    typealias Mutation = @Sendable (
        String,
        MessageID,
        Bool
    ) async throws -> Void

    @Published private var itemsByMessageID: [String: [MessageLabelMenuItem]] = [:]
    @Published public private(set) var pendingMessageIDs: Set<String> = []
    @Published public private(set) var errorEvent: MessageLabelActionErrorEvent?
    @Published public private(set) var revision: UInt64 = 0

    private let loadItems: ItemLoader
    private let mutate: Mutation
    private var activeSurfaceDestination: String?
    private var activeSurfaceSessionID: UInt64?
    private var activeAppearances: [String: MessageLabelAppearanceToken] = [:]
    @Published private var loadingMessageIDs: Set<String> = []
    @Published private var failedInitialLoadMessageIDs: Set<String> = []
    private var refreshGenerationByAppearance: [MessageLabelAppearanceToken: UInt64] = [:]
    private var pendingMutationCountByAppearance: [MessageLabelAppearanceToken: Int] = [:]
    private let mutationSerializer = MessageLabelMutationSerializer()
    private var nextErrorID: UInt64 = 0
    private var nextRefreshGeneration: UInt64 = 0
    private var nextSurfaceSessionID: UInt64 = 0
    private var nextAppearanceID: UInt64 = 0

    public init(
        snapshots: any MessageLabelActionSnapshotRepository,
        assignments: any MessageLabelAssignmentRepository,
        actor: Actor = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )
    ) {
        self.loadItems = { messageID in
            try await Self.loadMenuItems(snapshots: snapshots, messageID: messageID)
        }
        self.mutate = { labelID, messageID, selected in
            try Task.checkCancellation()
            if selected {
                try assignments.establishUserLabel(
                    labelID: labelID,
                    on: messageID,
                    actor: actor
                )
            } else {
                try assignments.removeUserOrSmartInboxLabel(
                    labelID: labelID,
                    from: messageID,
                    actor: actor
                )
            }
            try Task.checkCancellation()
        }
    }

    init(snapshots: any MessageLabelActionSnapshotRepository, mutate: @escaping Mutation) {
        self.loadItems = { messageID in
            try await Self.loadMenuItems(snapshots: snapshots, messageID: messageID)
        }
        self.mutate = mutate
    }

    init(loadItems: @escaping ItemLoader, mutate: @escaping Mutation) {
        self.loadItems = loadItems
        self.mutate = mutate
    }

    public func menuItems(for messageID: String) -> [MessageLabelMenuItem] {
        itemsByMessageID[messageID] ?? []
    }

    public func menuContent(for messageID: String) -> MessageLabelMenuContent {
        if let items = itemsByMessageID[messageID] {
            return items.isEmpty ? .empty : .items(items)
        }
        if loadingMessageIDs.contains(messageID) {
            return .loading
        }
        return failedInitialLoadMessageIDs.contains(messageID) ? .loadFailed : .empty
    }

    public func isEffectivelySelected(_ labelID: String, on messageID: String) -> Bool {
        menuItems(for: messageID).first { $0.id == labelID }?.isEffective == true
    }

    public func isPending(messageID: String) -> Bool {
        pendingMessageIDs.contains(messageID)
    }

    public var cachedMessageCount: Int {
        itemsByMessageID.count
    }

    public var trackedMessageCount: Int {
        Set(itemsByMessageID.keys)
            .union(activeAppearances.keys)
            .union(loadingMessageIDs)
            .union(pendingMutationCountByAppearance.keys.map(\.messageID))
            .count
    }

    public func transitionMailboxSurface(to destination: String?) {
        guard activeSurfaceDestination != destination else { return }
        nextSurfaceSessionID &+= 1
        activeSurfaceDestination = destination
        activeSurfaceSessionID = destination == nil ? nil : nextSurfaceSessionID
        clearAppearanceState()
        errorEvent = nil
        revision &+= 1
    }

    public func beginAppearance(messageID: String) -> MessageLabelAppearanceToken? {
        guard let surfaceSessionID = activeSurfaceSessionID else { return nil }
        let previous = activeAppearances[messageID]
        if let previous {
            refreshGenerationByAppearance[previous] = nil
            pendingMutationCountByAppearance[previous] = nil
        }
        nextAppearanceID &+= 1
        let appearance = MessageLabelAppearanceToken(
            messageID: messageID,
            surfaceSessionID: surfaceSessionID,
            appearanceID: nextAppearanceID
        )
        activeAppearances[messageID] = appearance
        if previous == nil {
            itemsByMessageID[messageID] = nil
            failedInitialLoadMessageIDs.remove(messageID)
        }
        loadingMessageIDs.insert(messageID)
        publishPendingMessageIDs()
        return appearance
    }

    public func endAppearance(_ appearance: MessageLabelAppearanceToken) {
        guard activeAppearances[appearance.messageID] == appearance else { return }
        activeAppearances[appearance.messageID] = nil
        itemsByMessageID[appearance.messageID] = nil
        loadingMessageIDs.remove(appearance.messageID)
        failedInitialLoadMessageIDs.remove(appearance.messageID)
        refreshGenerationByAppearance[appearance] = nil
        pendingMutationCountByAppearance[appearance] = nil
        publishPendingMessageIDs()
    }

    public func currentAppearance(for messageID: String) -> MessageLabelAppearanceToken? {
        activeAppearances[messageID]
    }

    public func runAppearanceTask(messageID: String) async {
        guard let appearance = beginAppearance(messageID: messageID) else { return }
        defer { endAppearance(appearance) }
        await refresh(appearance)
        guard !Task.isCancelled, isCurrentAppearance(appearance) else { return }
        do {
            try await Task.sleep(for: .seconds(31_536_000))
        } catch {
            return
        }
    }

    public func invalidate() {
        guard activeSurfaceSessionID != nil else { return }
        revision &+= 1
        for appearance in activeAppearances.values {
            refreshGenerationByAppearance[appearance] = makeRefreshGeneration()
        }
    }

    public func consumeError(id: UInt64) {
        guard errorEvent?.id == id else { return }
        errorEvent = nil
    }

    public func refresh(messageID: String) async {
        guard let appearance = activeAppearances[messageID] else { return }
        _ = await refresh(
            appearance,
            failureMessage: "Unable to load labels. Try again."
        )
    }

    public func refresh(_ appearance: MessageLabelAppearanceToken) async {
        _ = await refresh(
            appearance,
            failureMessage: "Unable to load labels. Try again."
        )
    }

    public func retry(messageID: String) async {
        guard let appearance = activeAppearances[messageID] else { return }
        failedInitialLoadMessageIDs.remove(messageID)
        loadingMessageIDs.insert(messageID)
        _ = await refresh(
            appearance,
            failureMessage: "Unable to load labels. Try again."
        )
    }

    public func setLabel(
        _ labelID: String,
        on messageID: String,
        selected: Bool
    ) async {
        guard let appearance = activeAppearances[messageID] else { return }
        pendingMutationCountByAppearance[appearance, default: 0] += 1
        publishPendingMessageIDs()
        defer {
            decrementPendingMutationCount(for: appearance)
            publishPendingMessageIDs()
        }
        await mutationSerializer.enqueue(for: appearance) { [weak self] in
            await self?.performSetLabel(
                labelID,
                selected: selected,
                appearance: appearance
            )
        }
    }

    private func performSetLabel(
        _ labelID: String,
        selected: Bool,
        appearance: MessageLabelAppearanceToken
    ) async {
        guard isCurrentAppearance(appearance) else { return }
        let startingRevision = revision

        let mutationSucceeded: Bool
        do {
            try await mutate(labelID, MessageID(appearance.messageID), selected)
            mutationSucceeded = true
        } catch is CancellationError {
            return
        } catch {
            mutationSucceeded = false
            if isCurrentAppearance(appearance, revision: startingRevision),
               !Self.isStaleDefinition(error) {
                publishError("Unable to update label. Try again.")
            }
        }
        _ = await refresh(
            appearance,
            failureMessage: mutationSucceeded
                ? "Label updated, but its latest state could not be loaded. Try again."
                : nil
        )
    }

    public static func preview() -> MessageLabelActions {
        MessageLabelActions(loadItems: { _ in [] }, mutate: { _, _, _ in })
    }

    private static func loadMenuItems(
        snapshots: any MessageLabelActionSnapshotRepository, messageID: MessageID
    ) async throws -> [MessageLabelMenuItem] {
        let snapshot = try await snapshots.messageLabelActionSnapshot(for: messageID)
        guard let accountID = snapshot.accountID else { return [] }
        let sourcesByLabelID = Dictionary(grouping: snapshot.assignments, by: \.labelID).mapValues {
            Set($0.map(\.source))
        }
        let exclusions = Set(snapshot.exclusions.map(\.labelID))
        return snapshot.labels.filter { $0.scope.includes(accountID) }.map { label in
            MessageLabelMenuItem(
                label: label, sources: sourcesByLabelID[label.id] ?? [],
                isExcluded: exclusions.contains(label.id), ruleNames: snapshot.ruleNames)
        }.sorted {
            let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    @discardableResult private func refresh(
        _ appearance: MessageLabelAppearanceToken, failureMessage: String?
    ) async -> Bool {
        guard isCurrentAppearance(appearance) else { return false }
        let generation = makeRefreshGeneration()
        refreshGenerationByAppearance[appearance] = generation
        let startingRevision = revision
        do {
            let items = try await loadItems(MessageID(appearance.messageID))
            guard isCurrent(
                appearance: appearance,
                generation: generation,
                revision: startingRevision
            ) else {
                return false
            }
            itemsByMessageID[appearance.messageID] = items
            loadingMessageIDs.remove(appearance.messageID)
            failedInitialLoadMessageIDs.remove(appearance.messageID)
            return true
        } catch is CancellationError {
            if isCurrentAppearance(appearance, revision: startingRevision) {
                loadingMessageIDs.remove(appearance.messageID)
            }
            return false
        } catch {
            guard isCurrent(
                appearance: appearance,
                generation: generation,
                revision: startingRevision
            ) else {
                return false
            }
            loadingMessageIDs.remove(appearance.messageID)
            if itemsByMessageID[appearance.messageID] == nil {
                failedInitialLoadMessageIDs.insert(appearance.messageID)
            }
            if let failureMessage {
                publishError(failureMessage)
            }
            return false
        }
    }

    private func isCurrent(
        appearance: MessageLabelAppearanceToken,
        generation: UInt64,
        revision: UInt64
    ) -> Bool {
        !Task.isCancelled
            && isCurrentAppearance(appearance, revision: revision)
            && refreshGenerationByAppearance[appearance] == generation
    }

    private func isCurrentAppearance(
        _ appearance: MessageLabelAppearanceToken,
        revision: UInt64? = nil
    ) -> Bool {
        activeSurfaceSessionID == appearance.surfaceSessionID
            && activeAppearances[appearance.messageID] == appearance
            && (revision == nil || self.revision == revision)
    }

    private func clearAppearanceState() {
        activeAppearances.removeAll()
        itemsByMessageID.removeAll()
        loadingMessageIDs.removeAll()
        failedInitialLoadMessageIDs.removeAll()
        refreshGenerationByAppearance.removeAll()
        pendingMutationCountByAppearance.removeAll()
        pendingMessageIDs.removeAll()
    }

    private func decrementPendingMutationCount(
        for appearance: MessageLabelAppearanceToken
    ) {
        guard let count = pendingMutationCountByAppearance[appearance] else { return }
        if count > 1 {
            pendingMutationCountByAppearance[appearance] = count - 1
        } else {
            pendingMutationCountByAppearance[appearance] = nil
        }
    }

    private func publishPendingMessageIDs() {
        pendingMessageIDs = Set(
            pendingMutationCountByAppearance.compactMap { appearance, count in
                count > 0 && isCurrentAppearance(appearance)
                    ? appearance.messageID
                    : nil
            }
        )
    }

    private func makeRefreshGeneration() -> UInt64 {
        nextRefreshGeneration &+= 1
        return nextRefreshGeneration
    }

    private func publishError(_ message: String) {
        nextErrorID &+= 1
        errorEvent = MessageLabelActionErrorEvent(id: nextErrorID, message: message)
    }

    private static func isStaleDefinition(_ error: Error) -> Bool {
        if let validationError = error as? MailLabelValidationError {
            return validationError == .unknownLabel || validationError == .outOfScopeLabel
        }
        if case .notFound = error as? PlainpostError {
            return true
        }
        return false
    }
}

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct PlainpostMailboxInitialPresentation: Equatable, Sendable {
    static let persistedModeKey = "Plainpost.inbox.displayMode"

    let mode: InboxDisplayMode
    let context: MailboxListContext

    static func production(
        destination: PlainpostDestination,
        requestedMode: String?,
        persistedMode: String?,
        fallbackMode: InboxDisplayMode
    ) -> Self {
        let mode = mode(
            for: requestedMode
                ?? persistedMode
                ?? fallbackMode.rawValue
        )
        return Self(
            mode: mode,
            context: context(
                destination: destination,
                mode: mode,
                smartInboxBundle: nil
            )
        )
    }

    static func designPreview(
        mode: InboxDisplayMode,
        smartInboxBundle: SmartInboxDisplayBundle?
    ) -> Self {
        Self(
            mode: mode,
            context: context(
                destination: .smartInbox,
                mode: mode,
                smartInboxBundle: smartInboxBundle
            )
        )
    }

    static func mode(for value: String) -> InboxDisplayMode {
        switch value {
        case "Smart":
            .focusedList
        case "Classic":
            .simpleList
        default:
            InboxDisplayMode(rawValue: value) ?? .focusedList
        }
    }

    private static func context(
        destination: PlainpostDestination,
        mode: InboxDisplayMode,
        smartInboxBundle: SmartInboxDisplayBundle?
    ) -> MailboxListContext {
        if destination == .smartInbox, mode == .focusedList {
            return smartInboxBundle.map {
                .smartInboxBundle($0)
            } ?? .smartInboxOverview
        }
        return .mailbox(destination: destination, mode: mode)
    }
}

struct PlainpostDesignPreviewMailboxSelection: Equatable, Sendable {
    let selectedMessageID: String?
    let readerMessageID: String?

    static func resolve(
        initialReaderMessageID: String?,
        initialListSelectedMessageID: String?
    ) -> Self {
        let selectedMessageID = initialReaderMessageID
            ?? initialListSelectedMessageID
        return Self(
            selectedMessageID: selectedMessageID,
            readerMessageID: initialReaderMessageID
        )
    }
}

enum MailboxToolbarActionPlacement: Equatable, Sendable {
    case automatic

    var nativeToolbarPlacement: ToolbarItemPlacement {
        .automatic
    }
}

struct MailboxToolbarSpacingPlan: Equatable, Sendable {
    let backToIdentity: Bool
    let identityToLayout: Bool
    let leadingToActions: Bool
    let messageActionsToGlobal: Bool

    var identifiers: [String] {
        [
            backToIdentity ? "back_to_identity" : nil,
            identityToLayout ? "identity_to_layout" : nil,
            leadingToActions ? "leading_to_actions" : nil,
            messageActionsToGlobal
                ? "message_actions_to_global"
                : nil,
        ]
        .compactMap { $0 }
    }
}

private struct ScopedLabelSourceInvalidationModifier: ViewModifier {
    let contentRevision: UInt64
    let availableMessageIDs: Set<String>
    let invalidate: (Set<String>) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: contentRevision) { _, _ in
            invalidate(availableMessageIDs)
        }
    }
}

public struct PlainpostRootView: View {
    private static let standardMinimumWindowWidth: CGFloat = 900

    private static var composerWidth: CGFloat? {
        #if os(iOS)
        nil
        #else
        620
        #endif
    }

    private static var composerTrailingPadding: CGFloat {
        #if os(iOS)
        0
        #else
        56
        #endif
    }

    /// The Mac composer floats above the window's bottom edge. On iOS it fills
    /// the space above the keyboard, so its Send bar stays in
    /// view while typing.
    static var composerBottomPadding: CGFloat {
        #if os(iOS)
        0
        #else
        96
        #endif
    }

    /// The Mac window's minimum height. An iOS screen is its own size: a
    /// minimum taller than the space above the keyboard, or than an iPhone in
    /// landscape, pushed the navigation bar and composer actions off screen.
    static var mailboxRootMinimumHeight: CGFloat? {
        #if os(iOS)
        nil
        #else
        640
        #endif
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides
    @Environment(\.calendar) private var currentCalendar
    @Environment(\.locale) private var currentLocale
    @Environment(\.plainpostSettingsHost) private var settingsHost
    private let notificationOpenRequest: PlainpostNotificationOpenRequest?
    private let notificationOpenHandled: (UUID) -> Void
    private let calendarAuthority: PlainpostCalendarAuthority?
    private let calendarAppDataRoot: URL
    private let notificationAccountInboxTokens: Set<String>
    private let notificationMessageToken: (String) -> String?
    private let notificationInboxScope: (String) -> PlainpostNotificationInboxScope?
    private let designNow: Date?
    /// The mail UI's controllers and view models. The objects below come from it, each held as
    /// its own state object so the view observes exactly what it did before the session existed.
    @StateObject private var session: MailSession
    @StateObject private var accountSetup: AccountSetupViewModel
    @StateObject private var mailSearch: MailSearchViewModel
    @StateObject private var approvalQueue: ApprovalQueueViewModel
    @StateObject private var composer: ComposerViewModel
    @StateObject private var undoSendCoordinator: UndoSendCoordinator
    @StateObject private var auditLog: AuditLogViewModel
    @StateObject private var commandCenter: CommandCenterViewModel
    @StateObject private var commandSurfaces: MailboxCommandSurfaceLifecycle
    @StateObject private var aiAssistant: ThreadAIAssistantViewModel
    /// Session-owned: pending bulk actions live in its coordinator and survive the panel closing,
    /// but if this root view (and so the runtime) is replaced, e.g. on an account switch, a bulk
    /// action still inside its 5 s Undo window is dropped with it and never runs.
    @StateObject private var askMail: AskMailViewModel
    @StateObject private var aiProviderSettings: AIProviderSettingsViewModel
    @StateObject private var translationSettings: TranslationLanguageSettingsViewModel
    @StateObject private var threadTranslation: ThreadTranslationViewModel
    @StateObject private var inboxMailActions: InboxMailActionViewModel
    /// The calendar capability probe of the current authority's Node.
    @State private var calendarAvailability: CalendarAvailability = .unknown
    @StateObject private var searchIndexRebuild: MailSearchIndexRebuildController
    @StateObject private var mailRules: MailRulesViewModel
    @StateObject private var mailLabels: MailLabelsViewModel
    @StateObject private var messageLabelActions: MessageLabelActions
    @StateObject private var storeChangeMonitor: MailStoreChangeMonitor
    @StateObject private var messageActions: MessageActionController
    @StateObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @StateObject var smartInboxActivityCoordinator: SmartInboxActivityCoordinator
    @StateObject var mailMaintenance: MailMaintenanceViewModel
    #if os(macOS)
    @StateObject private var notificationPermission = NotificationPermissionModel()
    #endif

    @StateObject private var mailbox: MailboxController
    /// The open sidebar folder's rows, when the mail list is narrowed to one account folder.
    @StateObject private var folderRows = FolderRowsModel()
    @StateObject private var refreshBus: MailboxRefreshBus
    @StateObject private var compose: ComposeCoordinator
    @StateObject private var searchController: SearchController
    @StateObject private var activity: MailActivityCoordinator
    @State private var selectedSettingsDestination: PlainpostSettingsDestination?
    @State private var selectedApprovalFilter: ApprovalQueueFilter
    @State private var selectedApprovalRequestID: String?
    #if os(iOS)
    @State private var compactMailboxColumn: NavigationSplitViewColumn = .detail
    #endif
    @State private var enablingMailboxPath: String?
    @State private var isAIInspectorPresented = false
    /// Which pane the one inspector shows; see `MailInspectorSlot`.
    @State private var inspectorSlot: MailInspectorSlot = .askMail
    /// iPad: the ✦ popover, opened from the reader toolbar and anchored to the detail column.
    @State private var conversationAIPopoverState = ConversationAIPopoverState()
    /// iPad: Edit in Compose waits for the popover to close.
    @State private var pendingConversationAICompose: ComposeRequest?
    @State private var isAccountSetupRequired: Bool
    @State private var messageOpenDiagnostic: String?
    @State private var attachmentArtifact: PlainpostAttachmentArtifact?
    @State private var notificationAttentionSourceID = UUID()
    @State private var notificationAccountInboxScope: PlainpostNotificationInboxScope?
    /// Thread context retained while an invitation's occurrence is shown in Calendar.
    @State private var calendarReturn: ThreadCalendarReturn?
    @State private var invitationScrollMessageID: String?
    @StateObject private var attachmentState: PlainpostAttachmentState
    @StateObject private var nodeMailModeStatus: NodeMailModeStatusModel

    private var configureAIAssistant: (ThreadAIAssistantViewModel, String) -> Void { session.configureAIAssistant }
    private var configureAskMail: (AskMailViewModel, String) -> Void { session.configureAskMail }
    private var configureThreadTranslation: (ThreadTranslationViewModel, String) -> Void {
        session.configureThreadTranslation
    }
    private var aiGenerationAvailable: () -> Bool { session.aiGenerationAvailable }
    private var invalidateInboxSnapshotHandler: () -> Void { session.invalidateInboxSnapshot }
    private var openAttachment: (MailAttachment) async -> Void { session.openAttachment }
    private var accountSessionModel: AccountSessionViewModel? { session.accountSessionModel }
    private var nodeSettings: SyncNodeSettingsViewModel? { session.nodeSettings }

    private var reduceMotion: Bool {
        previewOverrides.reduceMotion ?? systemReduceMotion
    }

    /// The root's own inputs, none of which needs the session: its first-render view state and
    /// the values its parent recomputes on every render (the calendar authority, notification
    /// scoping). Building them never builds a session.
    struct Inputs {
        var settingsSection: PlainpostSettingsSection = .smartInbox
        var approvalFilter: ApprovalQueueFilter = .pending
        var isAccountSetupRequired = false
        var showsAIInspector = false
        var designNow: Date?
        var calendarAuthority: PlainpostCalendarAuthority?
        var calendarAppDataRoot: URL = PlainpostAppRuntimeConfiguration.defaultDatabaseURL().deletingLastPathComponent()
        var notificationAccountInboxTokens: Set<String> = []
        var notificationMessageToken: (String) -> String? = {
            NotificationOpaqueIdentities.messageToken(for: $0)
        }
        var notificationInboxScope: (String) -> PlainpostNotificationInboxScope? = { _ in nil }

        /// The settings section the root opens on.
        static func settingsSection(
            initial: PlainpostSettingsSection?,
            destination: PlainpostDestination?,
            requiresLegacyAccountSetup: Bool
        ) -> PlainpostSettingsSection {
            initial
                ?? destination?.settingsSection
                ?? (requiresLegacyAccountSetup ? .accounts : .smartInbox)
        }
    }

    /// Owns `session`, which is built only when SwiftUI first installs this view: a parent
    /// re-render that re-creates the root never builds another.
    init(
        session: @autoclosure @escaping () -> MailSession,
        notificationOpenRequest: PlainpostNotificationOpenRequest? = nil,
        notificationOpenHandled: @escaping (UUID) -> Void = { _ in },
        inputs: Inputs = Inputs()
    ) {
        // Lazy, so the session is built when SwiftUI installs the first of these state objects,
        // and every other one shares it. A re-init evaluates none of them.
        lazy var s = session()
        self._session = StateObject(wrappedValue: s)
        self._mailbox = StateObject(wrappedValue: s.mailbox)
        self._refreshBus = StateObject(wrappedValue: s.refreshBus)
        self._messageActions = StateObject(wrappedValue: s.actions)
        self._compose = StateObject(wrappedValue: s.compose)
        self._searchController = StateObject(wrappedValue: s.search)
        self._activity = StateObject(wrappedValue: s.activity)
        self._inboxSnapshot = StateObject(wrappedValue: s.inboxSnapshot)
        self._accountSetup = StateObject(wrappedValue: s.accountSetup)
        self._mailSearch = StateObject(wrappedValue: s.mailSearch)
        self._approvalQueue = StateObject(wrappedValue: s.approvalQueue)
        self._composer = StateObject(wrappedValue: s.composer)
        self._undoSendCoordinator = StateObject(wrappedValue: s.undoSend)
        self._auditLog = StateObject(wrappedValue: s.auditLog)
        self._commandCenter = StateObject(wrappedValue: s.commandCenter)
        self._commandSurfaces = StateObject(wrappedValue: s.commandSurfaces)
        self._aiAssistant = StateObject(wrappedValue: s.aiAssistant)
        self._askMail = StateObject(wrappedValue: s.askMail)
        self._aiProviderSettings = StateObject(wrappedValue: s.aiProviderSettings)
        self._translationSettings = StateObject(wrappedValue: s.translationSettings)
        self._threadTranslation = StateObject(wrappedValue: s.threadTranslation)
        self._inboxMailActions = StateObject(wrappedValue: s.inboxMailActions)
        self._searchIndexRebuild = StateObject(wrappedValue: s.searchIndexRebuild)
        self._mailRules = StateObject(wrappedValue: s.mailRules)
        self._mailLabels = StateObject(wrappedValue: s.mailLabels)
        self._messageLabelActions = StateObject(wrappedValue: s.messageLabelActions)
        self._storeChangeMonitor = StateObject(wrappedValue: s.storeChangeMonitor)
        self._smartInboxActivityCoordinator = StateObject(wrappedValue: s.smartInboxActivity)
        self._mailMaintenance = StateObject(wrappedValue: s.maintenance)
        self._attachmentState = StateObject(wrappedValue: s.attachmentState)
        self._nodeMailModeStatus = StateObject(wrappedValue: s.nodeStatus)
        self.notificationOpenRequest = notificationOpenRequest
        self.notificationOpenHandled = notificationOpenHandled
        self.calendarAuthority = inputs.calendarAuthority
        self.calendarAppDataRoot = inputs.calendarAppDataRoot
        self.notificationAccountInboxTokens = inputs.notificationAccountInboxTokens
        self.notificationMessageToken = inputs.notificationMessageToken
        self.notificationInboxScope = inputs.notificationInboxScope
        self.designNow = inputs.designNow
        self._selectedSettingsDestination = State(initialValue: .section(inputs.settingsSection))
        self._selectedApprovalFilter = State(initialValue: inputs.approvalFilter)
        self._selectedApprovalRequestID = State(initialValue: nil)
        self._isAIInspectorPresented = State(initialValue: inputs.showsAIInspector)
        self._isAccountSetupRequired = State(initialValue: inputs.isAccountSetupRequired)
        self._messageOpenDiagnostic = State(initialValue: nil)
    }

    public init(
        viewModel: InboxViewModel = .preview(),
        accountSetup: AccountSetupViewModel = .preview(),
        accountSessionModel: AccountSessionViewModel? = nil,
        mailSearch: MailSearchViewModel = .designTips(),
        approvalQueue: ApprovalQueueViewModel = .preview(),
        composer: ComposerViewModel = .preview(),
        undoSendCoordinator: UndoSendCoordinator? = nil,
        auditLog: AuditLogViewModel = .preview(),
        commandCenter: CommandCenterViewModel = .preview(),
        aiAssistant: ThreadAIAssistantViewModel = .preview(),
        askMail: AskMailViewModel = .preview(),
        aiProviderSettings: AIProviderSettingsViewModel = .production(),
        translationSettings: TranslationLanguageSettingsViewModel? = nil,
        threadTranslation: ThreadTranslationViewModel? = nil,
        inboxMailActions: InboxMailActionViewModel = .preview(),
        nodeSettings: SyncNodeSettingsViewModel? = nil,
        nodeMailModeStatus: NodeMailModeStatusModel? = nil,
        attachmentState: PlainpostAttachmentState? = nil,
        mailRules: MailRulesViewModel = .preview(),
        mailLabels: MailLabelsViewModel = .preview(),
        messageLabelActions: MessageLabelActions = .preview(),
        openMessage: @escaping (String) async throws -> Void = { _ in },
        openAttachment: @escaping (MailAttachment) async -> Void = { _ in },
        loadForwardAttachments: @escaping (String) async -> (attachments: [DraftAttachment], unavailable: [String]) = { _ in ([], []) },
        initialDestination: PlainpostDestination? = nil,
        initialSettingsSection: PlainpostSettingsSection? = nil,
        initialInboxMode: String? = nil,
        initialApprovalFilter: ApprovalQueueFilter = .pending,
        initialSelectedMessageID: String? = nil,
        notificationOpenRequest: PlainpostNotificationOpenRequest? = nil,
        notificationOpenHandled: @escaping (UUID) -> Void = { _ in },
        onAccountSetupConnected: @escaping (AccountID) -> Void = { _ in },
        notificationAccountInboxTokens: Set<String> = [],
        notificationMessageToken: @escaping (String) -> String? = {
            NotificationOpaqueIdentities.messageToken(for: $0)
        },
        notificationInboxScope: @escaping (String) -> PlainpostNotificationInboxScope? = { _ in nil },
        showsSearch: Bool = false,
        showsComposer: Bool = false,
        showsAIInspector: Bool = false,
        composerPresentationPolicy: ComposerPresentationPolicy = .embedded,
        viewModelProvider: ((String?) async -> InboxViewModel)? = nil,
        loadMoreViewModelProvider: ((String?) async -> InboxViewModel)? = nil,
        invalidateInboxSnapshot: @escaping () -> Void = {},
        configureAIAssistant: @escaping (ThreadAIAssistantViewModel, String) -> Void = { _, _ in },
        configureAskMail: @escaping (AskMailViewModel, String) -> Void = { _, _ in },
        configureThreadTranslation: @escaping (ThreadTranslationViewModel, String) -> Void = { _, _ in },
        searchIndexState: @escaping () async -> MailSearchIndexState = { .unavailable },
        rebuildSearchIndex: @escaping () async throws -> Void = {},
        allowsSearchIndexRebuild: Bool = true,
        refreshMailSearchMailboxes: @escaping (Bool) async -> Void = { _ in },
        refreshSmartInbox: @escaping (
            String,
            PlainpostSmartInboxRunMode,
            String?
        ) async throws -> String = { _, _, _ in "Up to date" },
        aiGenerationAvailable: (() -> Bool)? = nil,
        allowsMailboxMutations: @escaping () -> Bool = { true },
        mailSyncCoordinator: MailSyncCoordinator = MailSyncCoordinator(),
        smartInboxActivityJob: @escaping () -> PlainpostDurableJob? = { nil },
        activeSmartInboxRerunJob: (() -> PlainpostDurableJob?)? = nil,
        pauseSmartInboxJob: @escaping (String) throws -> Void = { _ in },
        resumeSmartInboxJob: @escaping (String) async throws -> Void = { _ in },
        calendarAuthority: PlainpostCalendarAuthority? = nil,
        calendarAppDataRoot: URL = PlainpostAppRuntimeConfiguration.defaultDatabaseURL().deletingLastPathComponent(),
        composerActivity: PlainpostComposerActivity? = nil
    ) {
        self.init(
            session: MailSession.make(
                viewModel: viewModel,
                accountSetup: accountSetup,
                accountSessionModel: accountSessionModel,
                mailSearch: mailSearch,
                approvalQueue: approvalQueue,
                composer: composer,
                undoSendCoordinator: undoSendCoordinator,
                auditLog: auditLog,
                commandCenter: commandCenter,
                aiAssistant: aiAssistant,
                askMail: askMail,
                aiProviderSettings: aiProviderSettings,
                translationSettings: translationSettings,
                threadTranslation: threadTranslation,
                inboxMailActions: inboxMailActions,
                nodeSettings: nodeSettings,
                nodeMailModeStatus: nodeMailModeStatus,
                attachmentState: attachmentState,
                mailRules: mailRules,
                mailLabels: mailLabels,
                messageLabelActions: messageLabelActions,
                openMessage: openMessage,
                openAttachment: openAttachment,
                loadForwardAttachments: loadForwardAttachments,
                initialDestination: initialDestination,
                initialInboxMode: initialInboxMode,
                initialSelectedMessageID: initialSelectedMessageID,
                onAccountSetupConnected: onAccountSetupConnected,
                showsSearch: showsSearch,
                showsComposer: showsComposer,
                composerPresentationPolicy: composerPresentationPolicy,
                commitDelay: .zero,
                viewModelProvider: viewModelProvider,
                loadMoreViewModelProvider: loadMoreViewModelProvider,
                invalidateInboxSnapshot: invalidateInboxSnapshot,
                configureAIAssistant: configureAIAssistant,
                configureAskMail: configureAskMail,
                configureThreadTranslation: configureThreadTranslation,
                searchIndexState: searchIndexState,
                rebuildSearchIndex: rebuildSearchIndex,
                allowsSearchIndexRebuild: allowsSearchIndexRebuild,
                refreshMailSearchMailboxes: refreshMailSearchMailboxes,
                refreshSmartInbox: refreshSmartInbox,
                aiGenerationAvailable: aiGenerationAvailable,
                allowsMailboxMutations: allowsMailboxMutations,
                mailSyncCoordinator: mailSyncCoordinator,
                smartInboxActivityJob: smartInboxActivityJob,
                activeSmartInboxRerunJob: activeSmartInboxRerunJob,
                pauseSmartInboxJob: pauseSmartInboxJob,
                resumeSmartInboxJob: resumeSmartInboxJob,
                composerActivity: composerActivity
            ),
            notificationOpenRequest: notificationOpenRequest,
            notificationOpenHandled: notificationOpenHandled,
            inputs: Inputs(
                settingsSection: Inputs.settingsSection(
                    initial: initialSettingsSection,
                    destination: initialDestination,
                    requiresLegacyAccountSetup: viewModel.shouldPresentLegacyAccountSetup
                ),
                approvalFilter: initialApprovalFilter,
                isAccountSetupRequired: viewModel.shouldPresentLegacyAccountSetup,
                showsAIInspector: showsAIInspector,
                calendarAuthority: calendarAuthority,
                calendarAppDataRoot: calendarAppDataRoot,
                notificationAccountInboxTokens: notificationAccountInboxTokens,
                notificationMessageToken: notificationMessageToken,
                notificationInboxScope: notificationInboxScope
            )
        )
    }

    @_spi(DesignPreview)
    public init(
        viewModel: InboxViewModel,
        aiAssistant: ThreadAIAssistantViewModel,
        initialSelectedMessageID: String? = nil,
        initialListSelectedMessageID: String? = nil,
        initialInboxMode: InboxDisplayMode = .focusedList,
        initialSmartInboxBundle: SmartInboxDisplayBundle? = nil,
        composerPresentationPolicy: ComposerPresentationPolicy = .embedded,
        designNow: Date?,
        smartInboxActivityPresentation: SmartInboxActivityPresentation? = nil
    ) {
        self.init(
            session: Self.makeDesignPreviewSession(
                viewModel: viewModel,
                aiAssistant: aiAssistant,
                initialSelectedMessageID: initialSelectedMessageID,
                initialListSelectedMessageID: initialListSelectedMessageID,
                initialInboxMode: initialInboxMode,
                initialSmartInboxBundle: initialSmartInboxBundle,
                composerPresentationPolicy: composerPresentationPolicy,
                smartInboxActivityPresentation: smartInboxActivityPresentation
            ),
            inputs: Inputs(
                settingsSection: Inputs.settingsSection(
                    initial: nil,
                    destination: nil,
                    requiresLegacyAccountSetup: viewModel.shouldPresentLegacyAccountSetup
                ),
                isAccountSetupRequired: viewModel.shouldPresentLegacyAccountSetup,
                designNow: designNow
            )
        )
    }

    /// The design preview's session: preview view models around the requested list selection
    /// and reader route, a preview Smart Inbox activity, and maintenance that never runs.
    private static func makeDesignPreviewSession(
        viewModel: InboxViewModel,
        aiAssistant: ThreadAIAssistantViewModel,
        initialSelectedMessageID: String?,
        initialListSelectedMessageID: String?,
        initialInboxMode: InboxDisplayMode,
        initialSmartInboxBundle: SmartInboxDisplayBundle?,
        composerPresentationPolicy: ComposerPresentationPolicy,
        smartInboxActivityPresentation: SmartInboxActivityPresentation?
    ) -> MailSession {
        let selection = PlainpostDesignPreviewMailboxSelection.resolve(
            initialReaderMessageID: initialSelectedMessageID,
            initialListSelectedMessageID: initialListSelectedMessageID
        )
        let presentation = PlainpostMailboxInitialPresentation.designPreview(
            mode: initialInboxMode,
            smartInboxBundle: initialSmartInboxBundle
        )
        var navigation = MailboxWorkspaceNavigationState(
            initialContext: presentation.context
        )
        if let readerMessageID = selection.readerMessageID {
            navigation.openReader(
                messageID: readerMessageID,
                from: presentation.context
            )
        }
        let aiProviderSettings = AIProviderSettingsViewModel.production()
        let fallbackProviderIdentity = Self.translationProviderIdentity(
            providerID: aiProviderSettings.selectedProviderID
        )
        let smartInboxActivity = SmartInboxActivityCoordinator(
            previewPresentation: smartInboxActivityPresentation
        )
        return MailSession(
            inbox: viewModel,
            inboxProvider: nil,
            loadMoreInboxProvider: nil,
            initialDestination: viewModel.shouldPresentLegacyAccountSetup ? .settings : .smartInbox,
            initialInboxMode: presentation.mode.rawValue,
            initialSelectedMessageID: selection.selectedMessageID,
            initialNavigation: navigation,
            directory: MailboxDirectoryModel(load: { [] }),
            recipientSuggestions: RecipientSuggestionProvider(contacts: .unavailable(), correspondents: { [] }),
            accountSetup: .preview(),
            accountSessionModel: nil,
            mailSearch: .designTips(),
            searchIndexRebuild: MailSearchIndexRebuildController(),
            approvalQueue: .preview(),
            composer: .preview(),
            undoSend: UndoSendCoordinator(sender: UnconfiguredDirectComposerSender()),
            auditLog: .preview(),
            commandCenter: .preview(),
            aiAssistant: aiAssistant,
            askMail: .preview(),
            conversationAskMail: .preview(),
            aiProviderSettings: aiProviderSettings,
            translationSettings: TranslationLanguageSettingsViewModel(
                options: [
                    TranslationLanguageOption(
                        id: TranslationLanguageCatalog.defaultLanguageID,
                        localizedName: "English"
                    ),
                ]
            ),
            threadTranslation: ThreadTranslationViewModel(
                handler: UnconfiguredThreadTranslationHandler(
                    providerID: fallbackProviderIdentity.providerID,
                    modelID: fallbackProviderIdentity.modelID
                )
            ),
            inboxMailActions: .preview(),
            nodeSettings: nil,
            nodeStatus: .inactive(),
            attachmentState: PlainpostAttachmentState(accountID: nil),
            mailRules: .preview(),
            mailLabels: .preview(),
            messageLabelActions: .preview(),
            smartInboxActivity: smartInboxActivity,
            maintenance: MailMaintenanceViewModel(
                accountSetup: .connectedPreview(),
                smartInboxActivity: smartInboxActivity,
                activeRerunJob: {
                    smartInboxActivity.isRerunActive
                        ? smartInboxActivity.job
                        : nil
                },
                selectedProviderID: { "foundation" },
                rerun: { _, _, _ in "Up to date" }
            ),
            composerActivity: nil,
            composerPresentationPolicy: composerPresentationPolicy,
            commitDelay: .zero,
            showsComposer: false,
            showsSearch: false,
            ownAddresses: { [] },
            loadForwardAttachments: { _ in ([], []) },
            openMessage: { _ in },
            openAttachment: { _ in },
            invalidateInboxSnapshot: {},
            refreshMailSearchMailboxes: { _ in },
            runSmartInbox: { _, _, _ in "Up to date" },
            aiGenerationAvailable: { PlainpostAIGenerationPolicy.current },
            allowsMailboxMutations: { true },
            configureAIAssistant: { _, _ in },
            configureAskMail: { _, _ in },
            configureThreadTranslation: { _, _ in },
            onAccountSetupConnected: { _ in },
            accountForMessage: { _ in nil },
            loadFolderRows: { _, _, _ in [] }
        )
    }

    private var isSmartInboxRerunActive: Bool {
        mailMaintenance.isRerunActive
    }

    public var body: some View {
        let combined = notificationAccountInboxScope?.apply(to: inboxSnapshot.model)
            ?? inboxSnapshot.model
        // A sidebar folder narrows the list to that account folder's rows.
        let viewModel = mailbox.selectedFolder == nil
            ? combined
            : combined.narrowed(
                toFolderRows: folderRows.listRows(
                    for: mailbox.selectedFolder, hiding: session.actions.overlayState.overlays
                ),
                hasMore: folderRows.hasMore
            )
        let availableMessageIDs = Set(
            viewModel.rows(for: mailbox.selectedDestination).map(\.id)
        )

        ZStack(alignment: .bottomTrailing) {
            Group {
                if searchController.isPresented {
                    MailSearchWorkspace(
                        viewModel: mailSearch,
                        close: searchController.close,
                        openResult: { searchController.open($0, closesSearch: true) },
                        askMail: searchController.askMailAction,
                        rebuildIndex: searchController.rebuildAction
                    )
                    .id(searchController.presentationGeneration)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.995))
                    )
                } else {
                    mailboxSplitView(viewModel: viewModel)
                }
            }
            .disabled(commandSurfaces.isPresented)
            .accessibilityHidden(commandSurfaces.isPresented)

            if compose.isPresented {
                ComposerWindow(
                    viewModel: composer,
                    close: { compose.isPresented = false }
                )
                .alert("This account was removed", isPresented: Binding(
                    get: { compose.asksToDiscardRemovedAccountDraft },
                    set: { if !$0 { compose.asksToDiscardRemovedAccountDraft = false } }
                )) {
                    Button("Discard Draft", role: .destructive) { compose.discardRemovedAccountDraft() }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text("This draft can't be sent from an account that's no longer on this device.")
                }
                .frame(width: Self.composerWidth)
                .padding(.trailing, Self.composerTrailingPadding)
                .padding(.bottom, Self.composerBottomPadding)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
                .onChange(of: composer.isSendScheduled) { _, isScheduled in
                    if isScheduled {
                        compose.isPresented = false
                    }
                }
            }

            if let snackbarState = undoSendCoordinator.snackbarState {
                undoSendSnackbar(for: snackbarState)
                    .frame(maxWidth: 360)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }

            if undoSendCoordinator.snackbarState == nil, let notice = nodeMailModeStatus.notice {
                NodeSendOutcomeNoticeView(notice: notice) {
                    nodeMailModeStatus.dismissNotice()
                }
                .frame(maxWidth: 420)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }

            notificationPermissionCallout

            if commandCenter.isPresented {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture {
                        commandCenter.close()
                    }
                    .zIndex(20)

                CommandCenterPanel(
                    viewModel: commandCenter,
                    onExecute: handleCommandCenterCommand
                )
                .shadow(color: .black.opacity(0.38), radius: 42, x: 0, y: 18)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .zIndex(21)
            }

            if commandSurfaces.labelCommandCenter.isPresented {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture {
                        commandSurfaces.closeLabels(restoringFocus: true)
                    }
                    .zIndex(20)

                MessageLabelCommandCenterPanel(
                    viewModel: commandSurfaces.labelCommandCenter,
                    labelActions: messageLabelActions,
                    reduceMotion: reduceMotion,
                    onClose: {
                        commandSurfaces.closeLabels(restoringFocus: true)
                    }
                )
                .transition(
                    MailboxCommandSurfaceTransition
                        .resolve(reduceMotion: reduceMotion)
                        .swiftUITransition
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .zIndex(21)
            }

        }
        .frame(
            minWidth: Self.minimumWindowWidth(showsAIInspector: isAIInspectorPresented),
            maxWidth: Self.mailboxRootMaximumWidth,
            minHeight: Self.mailboxRootMinimumHeight,
            maxHeight: Self.mailboxRootMaximumHeight,
            alignment: .topLeading
        )
        .toolbarRole(.editor)
        .environment(\.mailMoveDestinations, { [session, mailbox] messageID in
            session.moveDestinations(forMessageID: messageID, excluding: mailbox.selectedFolder?.path ?? "INBOX")
        })
        .onAppear {
            connectCompose()
            messageLabelActions.transitionMailboxSurface(
                to: Self.messageLabelSurfaceDestination(for: mailbox.selectedDestination)
            )
        }
        .onDisappear {
            messageLabelActions.transitionMailboxSurface(to: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .plainpostAppCommand)) { notification in
            handleAppCommand(notification.plainpostAppCommand)
        }
        .modifier(
            PlainpostNotificationRootModifier(
                request: notificationOpenRequest,
                selectedMessageID: mailbox.selectedMessageID,
                destination: mailbox.selectedDestination,
                route: mailbox.mailboxNavigation.route,
                appear: publishNotificationAttentionContext,
                disappear: {
                    PlainpostNotificationAttentionUpdate.remove(
                        sourceID: notificationAttentionSourceID
                    ).post()
                },
                open: handleNotificationOpenRequest,
                attentionChanged: publishNotificationAttentionContext
            )
        )
        #if os(macOS)
        .notificationPermission(notificationPermission)
        #endif
        .onChange(of: accountSetup.status) { _, status in
            if case .connected = status {
                invalidateInboxSnapshotHandler()
                Task {
                    await inboxSnapshot.refresh(selectedMessageID: mailbox.selectedMessageID)
                }
                isAccountSetupRequired = false
                if mailbox.selectedDestination == .settings && selectedSettingsDestination == .section(.accounts) {
                    mailbox.setDestination(.smartInbox)
                }
                refreshSmartInboxActivity()
                if Self.shouldRefreshSmartInboxAfterAccountConnection(
                    isRerunActive: isSmartInboxRerunActive,
                    aiGenerationAvailable: aiGenerationAvailable()
                ) {
                    Task {
                        await refreshSmartInbox(
                            using: aiProviderSettings.selectedProviderID,
                            mode: .incremental
                        )
                    }
                }
            }
        }
        .onChange(of: mailSearch.accessibilityAnnouncement) { _, announcement in
            announceMailSearchScopeChange(announcement)
        }
        .onChange(of: messageLabelActions.errorEvent?.id) { _, _ in
            guard let event = messageLabelActions.errorEvent else { return }
            messageOpenDiagnostic = event.message
            messageLabelActions.consumeError(id: event.id)
        }
        .onChange(of: mailbox.selectedInboxMode) { _, mode in
            mailbox.recordNavigationIntent()
            UserDefaults.standard.set(
                mode,
                forKey: PlainpostMailboxInitialPresentation.persistedModeKey
            )
            guard mailbox.selectedDestination.workAreaKind == .mailbox else { return }
            let resolvedMode = InboxDisplayMode(rawValue: mode) ?? .focusedList
            mailbox.mailboxNavigation.remember(resolvedMode, for: mailbox.selectedDestination)
            let context = mailbox.currentListContext()
            if !mailbox.readerRouteMatches(context) {
                mailbox.showList(context)
            }
        }
        .task(id: calendarAuthority?.accountID) {
            await probeCalendarAvailability()
        }
        .alert(
            "Unable to update message",
            isPresented: Binding(
                get: { messageOpenDiagnostic != nil },
                set: {
                    if !$0 {
                        messageOpenDiagnostic = nil
                        attachmentState.clear()
                        attachmentArtifact = nil
                    }
                }
            )
        ) {
            Button("OK") { dismissMessageOpenDiagnostic() }
        } message: {
            Text(messageOpenDiagnostic ?? "")
        }
        #if os(iOS)
        .quickLookPreview(Binding(
            get: { attachmentArtifact?.url },
            set: { presentedURL in
                if presentedURL == nil {
                    attachmentState.clear()
                    attachmentArtifact = nil
                }
            }
        ))
        #endif
        .onChange(of: approvalQueue.pendingItemCount) { _, _ in
            // `activity` refreshes the snapshot; the selection follows the queue here.
            let filteredItems = approvalQueue.items.filter { selectedApprovalFilter.matches($0) }
            if !filteredItems.contains(where: { $0.id == selectedApprovalRequestID }) {
                selectedApprovalRequestID = filteredItems.first?.id
            }
        }
        .onChange(of: mailbox.selectedDestination) { previousDestination, destination in
            if previousDestination.workAreaKind == .calendar { calendarReturn = nil }
            else if destination.workAreaKind != .calendar { invitationScrollMessageID = nil }
            commandSurfaces.invalidateMailboxSource()
            mailbox.recordNavigationIntent()
            let currentSettingsSection: PlainpostSettingsSection? =
                if case .section(let section) = selectedSettingsDestination { section } else { nil }
            let transition = PlainpostRootDestinationTransition.resolve(
                selectedDestination: destination,
                currentSettingsSection: currentSettingsSection ?? .accounts,
                isAccountSetupRequired: isAccountSetupRequired
            )
            messageLabelActions.transitionMailboxSurface(
                to: Self.messageLabelSurfaceDestination(for: transition.destination)
            )
            if transition.destination != destination {
                mailbox.selectedDestination = transition.destination
                return
            }
            // Only a destination that names a section (Labels) moves Settings; an account page
            // stays selected otherwise.
            if destination.settingsSection != nil {
                selectedSettingsDestination = .section(transition.settingsSection)
            }
            if transition.dismissesSearch {
                searchController.isPresented = false
            }
            guard transition.destination.workAreaKind == .mailbox else {
                if !mailbox.mailboxNavigation.leave(for: transition.destination) { mailbox.selectedMessageID = nil }
                return
            }
            let fallback = InboxDisplayMode(rawValue: mailbox.selectedInboxMode) ?? .focusedList
            let rememberedMode = mailbox.mailboxNavigation.rememberedMode(
                for: transition.destination,
                fallback: fallback
            )
            mailbox.selectedInboxMode = rememberedMode.rawValue
            let preservedContext = previousDestination.workAreaKind == .calendar
                ? mailbox.mailboxNavigation.calendarReturnContext(destination: transition.destination, mode: rememberedMode)
                : nil
            let context = preservedContext ?? mailbox.listContext(
                destination: transition.destination,
                mode: rememberedMode,
                preserveActiveBundle: false
            )
            if !mailbox.readerRouteMatches(context) {
                mailbox.showList(context)
            }
        }
        .onChange(of: storeChangeMonitor.mailboxRevision) { _, _ in
            // `activity` bumps the refresh bus.
            messageLabelActions.invalidate()
        }
        .modifier(
            ScopedLabelSourceInvalidationModifier(
                contentRevision: viewModel.contentRevision,
                availableMessageIDs: availableMessageIDs,
                invalidate: commandSurfaces.invalidateMailboxSource
            )
        )
        #if os(iOS)
        .task {
            // iPad only now: the old compact column is re-asserted after route changes.
            reassertCompactMailboxDetailOnRouteChange()
        }
        #endif
        .modifier(MailSessionLifecycle(session: session, hooks: lifecycleHooks))
        // An open folder loads when chosen and again whenever the mailbox changes.
        // An open folder loads when chosen and again on every mailbox change. The Mac and iPad
        // read folders from the store, already current when the refresh bus moves.
        .task(id: FolderListLoadKey(folder: mailbox.selectedFolder, refreshRevision: refreshBus.revision)) {
            guard let folder = mailbox.selectedFolder else { return }
            await folderRows.load(folder, using: session.loadFolderRows)
        }
        .onAppear {
            // A committed action applies to the folder's rows before its overlay clears, so a
            // row never flashes back while the folder reloads.
            session.actions.didCommit = { [weak folderRows] messageID, action in
                folderRows?.applyCommitted(messageID, action)
            }
        }
        .onChange(of: mailbox.selectedFolder) { _, _ in publishNotificationAttentionContext() }
        // The pane follows the selection, and it alone prepares the reader's summary.
        .onChange(of: conversationAIContext(viewModel: viewModel), initial: true) { _, context in
            session.conversationAI.setConversation(context)
        }
        .onChange(of: conversationAIPopoverState.isPresented) { _, presented in
            guard !presented, let request = pendingConversationAICompose else { return }
            pendingConversationAICompose = nil
            presentCompose(request)
        }
        .inspector(isPresented: $isAIInspectorPresented) {
            Group {
                switch inspectorSlot {
                case .askMail:
                    AskMailInspectorWorkspace(
                        viewModel: askMail,
                        activeContext: askMailContext(viewModel: viewModel),
                        close: { isAIInspectorPresented = false }
                    )
                    .onAppear(perform: session.attachAskMailHost)
                case .conversationAI:
                    ConversationAIPane(
                        model: session.conversationAI,
                        translationLanguage: translationSettings.selectedOption,
                        readOnlyReason: conversationAIReadOnlyReason,
                        // The Mac inspector stays open: the translated bodies show beside it.
                        dismissAfterTranslate: nil,
                        openCompose: { presentCompose($0) },
                        close: { isAIInspectorPresented = false }
                    )
                    .onAppear {
                        // Replies and drafts open Compose beside the open message, as Edit in
                        // Compose does, rather than navigating to the cited mailbox first.
                        session.attachConversationAskMailHost(
                            beforeOpening: {},
                            openCompose: { presentCompose($0) }
                        )
                    }
                }
            }
            .mailInspectorColumnWidth()
        }
        .environment(\.inlineImageParts, InlineImagePartsLoader(load: session.loadInlineImages))
    }

    @ViewBuilder
    private var notificationPermissionCallout: some View {
        #if os(macOS)
        if mailbox.selectedDestination.workAreaKind == .mailbox,
           notificationPermission.shouldShowEnablementCallout {
            MacNotificationEnablementCallout(model: notificationPermission)
                .frame(maxWidth: 620)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(15)
        }
        #endif
    }

    private func dismissMessageOpenDiagnostic() {
        messageOpenDiagnostic = nil
        attachmentState.clear()
        attachmentArtifact = nil
    }

    private func handleNotificationOpen(
        _ destination: PlainpostNotificationOpenDestination
    ) {
        searchController.isPresented = false
        switch destination {
        case .message(let messageID):
            let mode = InboxDisplayMode.focusedList
            let context = MailboxListContext.mailbox(
                destination: .allInboxes,
                mode: mode
            )
            openMailboxMessage(
                messageID,
                destination: .allInboxes,
                from: context
            )
        case .accountInbox(let accountID):
            mailbox.setDestination(
                .allInboxes,
                displayMode: InboxDisplayMode.focusedList.rawValue
            )
            notificationAccountInboxScope = notificationInboxScope(accountID)
            mailbox.recordNavigationIntent()
            mailbox.showList(
                .mailbox(destination: .allInboxes, mode: .focusedList)
            )
        case .allInboxes, .messageUnavailable:
            mailbox.setDestination(
                .allInboxes,
                displayMode: InboxDisplayMode.focusedList.rawValue
            )
            mailbox.recordNavigationIntent()
            mailbox.showList(
                .mailbox(destination: .allInboxes, mode: .focusedList)
            )
        }
    }

    private func handleNotificationOpenRequest(
        _ request: PlainpostNotificationOpenRequest
    ) {
        handleNotificationOpen(request.destination)
        notificationOpenHandled(request.id)
    }

    /// Search covers every account, or only the account whose folder is open.
    private var searchAccountScope: [AccountID] {
        mailbox.selectedFolder.map { [$0.accountID] } ?? []
    }

    /// The account inboxes the user can see right now, whose new mail needs no banner: every
    /// account's in the All Inboxes list, one account's when a notification scoped the list or
    /// its Inbox folder is open, none in any other folder or view.
    static func visibleAccountInboxTokens(
        destination: PlainpostDestination,
        route: MailboxWorkspaceRoute,
        scopeAccountID: String?,
        folder: MailFolderRef?,
        allTokens: Set<String>,
        token: (String) -> String
    ) -> Set<String> {
        guard destination == .allInboxes, case .list = route else { return [] }
        if let folder {
            return folder.role == .inbox ? [token(folder.accountID.rawValue)] : []
        }
        if let scopeAccountID { return [token(scopeAccountID)] }
        return allTokens
    }

    private func publishNotificationAttentionContext() {
        let visibleMessageToken: String?
        if case .reader(let messageID, _) = mailbox.mailboxNavigation.route {
            visibleMessageToken = notificationMessageToken(messageID)
        } else {
            visibleMessageToken = nil
        }
        let visibleAccountTokens = Self.visibleAccountInboxTokens(
            destination: mailbox.selectedDestination,
            route: mailbox.mailboxNavigation.route,
            scopeAccountID: notificationAccountInboxScope?.accountID,
            folder: mailbox.selectedFolder,
            allTokens: notificationAccountInboxTokens,
            token: NotificationOpaqueIdentities.accountInboxToken(for:)
        )
        PlainpostNotificationAttentionUpdate.set(
            sourceID: notificationAttentionSourceID,
            context: PlainpostNotificationAttentionContext(
                visibleMessageToken: visibleMessageToken,
                visibleAccountInboxTokens: visibleAccountTokens
            )
        ).post()
    }

    @ViewBuilder
    private func mailboxSplitView(viewModel: InboxViewModel) -> some View {
        switch PlainpostRootWorkspacePresentation.resolve(
            for: mailbox.selectedDestination.workAreaKind
        ) {
        case .sidebarAndWorkspace:
            #if os(iOS)
            NavigationSplitView(preferredCompactColumn: $compactMailboxColumn) {
                mailboxSidebar(viewModel: viewModel)
            } detail: {
                mailboxWorkspace(viewModel: viewModel)
            }
            .navigationSplitViewStyle(.balanced)
            #else
            NavigationSplitView {
                mailboxSidebar(viewModel: viewModel)
            } detail: {
                mailboxWorkspace(viewModel: viewModel)
            }
            .navigationSplitViewStyle(.balanced)
            #endif
        case .sidebarContentAndDetail:
            NavigationSplitView {
                mailboxSidebar(viewModel: viewModel)
            } content: {
                primaryColumn(viewModel: viewModel)
            } detail: {
                detailColumn(viewModel: viewModel)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private func mailboxSidebar(viewModel: InboxViewModel) -> some View {
        AccountDirectorySidebar(directory: session.directory, mailbox: mailbox) { sections in
            PlainpostSidebar(
                selection: sidebarDestinationSelection,
                viewModel: viewModel,
                smartInboxActivity: smartInboxActivityCoordinator.presentation,
                smartInboxActivityActionInFlight: smartInboxActivityCoordinator.isActionInFlight,
                smartInboxActivityActionMessage: smartInboxActivityCoordinator.actionMessage,
                pauseSmartInbox: { jobID in
                    smartInboxActivityCoordinator.pause(jobID, locale: currentLocale)
                },
                resumeSmartInbox: { jobID in
                    Task {
                        await smartInboxActivityCoordinator.resume(jobID, locale: currentLocale)
                    }
                },
                showsCalendar: calendarAvailability.showsCalendar,
                smartInboxEnabled: aiProviderSettings.smartInboxEnabled,
                accountSections: sections,
                selectedFolder: mailbox.selectedFolder,
                openFolder: { folder in
                    notificationAccountInboxScope = nil
                    mailbox.openFolder(folder)
                    #if os(iOS)
                    compactMailboxColumn = .detail
                    #endif
                }
            )
        }
    }

    @ViewBuilder
    private func mailboxWorkspace(viewModel: InboxViewModel) -> some View {
        #if os(iOS)
        NavigationStack {
            primaryColumn(viewModel: viewModel)
                .navigationDestination(
                    isPresented: Binding(
                        get: {
                            if case .reader = mailbox.mailboxNavigation.route { return true }
                            return false
                        },
                        set: { isPresented in
                            if !isPresented { mailbox.returnToList() }
                        }
                    )
                ) {
                    workArea(viewModel: viewModel)
                        .navigationTitle(mailbox.selectedDestination.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    if Self.showsMailboxToolbar(showsAIInspector: isAIInspectorPresented) {
                        mailboxToolbar(viewModel: viewModel)
                    }
                }
        }
        #else
        Group {
            switch mailbox.mailboxNavigation.route {
            case .list:
                primaryColumn(viewModel: viewModel)
            case .reader:
                workArea(viewModel: viewModel)
            }
        }
        .toolbar {
            if Self.showsMailboxToolbar(showsAIInspector: isAIInspectorPresented) {
                mailboxToolbar(viewModel: viewModel)
            }
        }
        #endif
    }

    static func messageLabelSurfaceDestination(
        for destination: PlainpostDestination
    ) -> String? {
        destination.workAreaKind == .mailbox ? destination.rawValue : nil
    }

    static func mailboxSyncPath(for destination: PlainpostDestination, account: Account?) -> String? {
        destination == .sent ? account?.sentMailbox ?? destination.syncMailboxPath : destination.syncMailboxPath
    }

    static func minimumWindowWidth(showsAIInspector: Bool) -> CGFloat {
        #if os(iOS)
        0
        #else
        standardMinimumWindowWidth
        #endif
    }

    static func smartInboxCalendar(designNow: Date?, current: Calendar) -> Calendar {
        guard designNow != nil else { return current }

        var calendar = Calendar(identifier: .gregorian)
        if let zurich = TimeZone(identifier: "Europe/Zurich") {
            calendar.timeZone = zurich
        }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func smartInboxLocale(designNow: Date?, current: Locale) -> Locale {
        designNow == nil ? current : Locale(identifier: "en_US_POSIX")
    }

    static func shouldRefreshSmartInboxAfterAccountConnection(
        isRerunActive: Bool,
        aiGenerationAvailable: Bool
    ) -> Bool {
        !isRerunActive && aiGenerationAvailable
    }

    @ViewBuilder
    private func primaryColumn(viewModel: InboxViewModel) -> some View {
        if isAccountSetupRequired {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 0) {
                if accountSetup.selectedProvider == nil {
                    Text("Connect an account")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                AccountSetupWorkspace(viewModel: accountSetup)
            }
            .navigationTitle("Welcome")
            #else
            ContentUnavailableView(
                "Connect an account",
                systemImage: "envelope.badge",
                description: Text("Complete account setup to unlock mailboxes and agent workflows.")
            )
            .navigationTitle("Welcome")
            #endif
        } else {
            switch mailbox.selectedDestination.workAreaKind {
            case .calendar:
                calendarWorkspace
            case .mailbox:
                let mailboxPath = Self.mailboxSyncPath(
                    for: mailbox.selectedDestination, account: accountSetup.account
                )
                let isMailboxSyncDisabled = mailboxPath.map(accountSetup.isMailboxSyncDisabled(path:)) ?? false
                let isMailboxSyncEnabling = mailboxPath == enablingMailboxPath
                let disabledMailboxSync = DisabledMailboxSyncPresentation.make(
                    destination: mailbox.selectedDestination,
                    isDisabled: (isMailboxSyncDisabled || isMailboxSyncEnabling)
                        && !(mailbox.selectedDestination == .sent && !viewModel.sentRows.isEmpty),
                    isEnabling: isMailboxSyncEnabling
                )
                VStack(spacing: 0) {
                if let failure = viewModel.mailboxLoadFailure {
                    HStack(spacing: 12) {
                        Text(failure)
                            .font(.footnote)
                        Spacer(minLength: 0)
                        Button("Retry") {
                            Task {
                                invalidateInboxSnapshotHandler()
                                await inboxSnapshot.refresh(selectedMessageID: mailbox.selectedMessageID)
                            }
                        }
                        .accessibilityIdentifier("mailbox.retry-load")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.12))
                    .accessibilityIdentifier("mailbox.load-failure")
                }
                MailMessageListColumn(
                    viewModel: viewModel,
                    destination: mailbox.selectedDestination,
                    selectedInboxMode: mailboxDisplayModeSelection,
                    searchQuery: "",
                    selectedMessageID: $mailbox.selectedMessageID,
                    mailActions: inboxMailActions,
                    labelActions: messageLabelActions,
                    quickActionFocus: commandSurfaces.quickActionFocus,
                    openLabelCommandCenter: commandSurfaces.openLabels,
                    performMessageAction: { messageActions.perform($0, messageID: $1) },
                    isLoadingMore: inboxSnapshot.isLoadingMore,
                    loadMore: {
                        Task {
                            if mailbox.selectedFolder != nil {
                                await folderRows.loadMore(using: session.loadFolderRows)
                                return
                            }
                            await inboxSnapshot.loadMore(
                                selectedMessageID: mailbox.selectedMessageID,
                                destination: mailbox.selectedDestination
                            )
                        }
                    },
                    disabledMailboxSync: disabledMailboxSync,
                    enableMailboxSync: {
                        guard let mailboxPath else { return }
                        Task {
                            enablingMailboxPath = mailboxPath
                            await accountSetup.enableMailboxSync(path: mailboxPath)
                            enablingMailboxPath = nil
                            refreshBus.bump()
                            invalidateInboxSnapshotHandler()
                            await inboxSnapshot.refresh(selectedMessageID: mailbox.selectedMessageID)
                        }
                    },
                    activeContext: mailbox.currentListContext(),
                    activeSmartInboxBundle: activeSmartInboxBundle,
                    openMessage: openListMessage,
                    openBundle: mailbox.showSmartInboxBundle,
                    closeBundle: mailbox.showSmartInboxOverview,
                    reportOrderedScrollItems: { items in
                        mailbox.currentMailboxScrollItems = items
                    },
                    reportScrollLocation: { context, location in
                        mailbox.saveScrollLocation(location, for: context)
                    },
                    resolveRestoration: mailbox.resolveRestoration,
                    scrollRuntime: mailbox.scrollRuntime
                )
                .id(mailbox.currentListContext())
                .environment(
                    \.plainpostNow,
                    { [designNow] in designNow ?? Date() }
                )
                .environment(
                    \.calendar,
                    Self.smartInboxCalendar(designNow: designNow, current: currentCalendar)
                )
                .environment(
                    \.locale,
                    Self.smartInboxLocale(designNow: designNow, current: currentLocale)
                )
                }
            case .approvalQueue:
                ApprovalQueueListColumn(
                    viewModel: approvalQueue,
                    selectedFilter: $selectedApprovalFilter,
                    selectedRequestID: $selectedApprovalRequestID
                )
            case .settings:
                SettingsRootList(
                    selection: $selectedSettingsDestination,
                    accountRows: settingsAccountRows,
                    navigation: .selection
                )
            case .aiIndexStatus:
                List {
                    Section("On-device index") {
                        LabeledContent("State", value: viewModel.aiIndexStatus.title)
                        LabeledContent("Coverage", value: viewModel.aiIndexStatus.detail)
                        #if os(iOS)
                        LabeledContent("Privacy", value: "On this device")
                        #else
                        LabeledContent("Privacy", value: "On this Mac")
                        #endif
                    }
                }
                .navigationTitle("AI Index")
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            }
        }
    }

    private var settingsAccountRows: [SettingsAccountRow] {
        SettingsAccountRow.rows(accountSetup: accountSetup, host: settingsHost)
    }

    /// Drops an account page whose account is gone, or an empty selection, for the default page.
    private func reconcileSettingsDestination() {
        let reconciled = SettingsAccountRow.reconciledDestination(
            current: selectedSettingsDestination,
            rows: settingsAccountRows
        )
        if reconciled != selectedSettingsDestination { selectedSettingsDestination = reconciled }
    }

    @ViewBuilder
    private func detailColumn(viewModel: InboxViewModel) -> some View {
        Group {
            if isAccountSetupRequired {
                AccountSetupWorkspace(viewModel: accountSetup)
            } else {
                switch mailbox.selectedDestination.workAreaKind {
                case .calendar:
                    calendarWorkspace
                case .mailbox:
                    workArea(viewModel: viewModel)
                case .approvalQueue:
                    ApprovalDetailPane(
                        item: selectedApprovalItem,
                        viewModel: approvalQueue
                    )
                case .settings:
                    // Account pages push Folders and Server Settings.
                    let settingsDestination = selectedSettingsDestination
                        ?? SettingsAccountRow.reconciledDestination(current: nil, rows: settingsAccountRows)
                    NavigationStack {
                        SettingsDetailWorkspace(
                            destination: settingsDestination,
                            accountSetup: accountSetup,
                            accountSessionModel: accountSessionModel,
                            nodeSettings: nodeSettings,
                            aiProviderSettings: aiProviderSettings,
                            translationSettings: translationSettings,
                            aiIndexStatus: viewModel.aiIndexStatus,
                            auditLog: auditLog,
                            mailRules: mailRules,
                            mailLabels: mailLabels,
                            maintenance: mailMaintenance,
                            searchIndexRebuild: searchIndexRebuild,
                            selection: $selectedSettingsDestination
                        )
                        #if os(iOS)
                        // On iPad the stack owns the detail column's navigation bar, so the
                        // column's toolbar and bar background go on the stack's root.
                        .toolbar {
                            if Self.showsMailboxToolbar(showsAIInspector: isAIInspectorPresented) {
                                mailboxToolbar(viewModel: viewModel)
                            }
                        }
                        .toolbarBackground(MailDesign.workArea, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                        #endif
                    }
                    // A new page starts a new stack, so a pushed Folders page doesn't outlive its account.
                    .id(settingsDestination)
                    .environment(\.plainpostCalendarAuthority, calendarAuthority)
                    .onChange(of: settingsAccountRows.map(\.destination), initial: true) {
                        reconcileSettingsDestination()
                    }
                case .aiIndexStatus:
                    AIIndexStatusWorkspace(status: viewModel.aiIndexStatus)
                }
            }
        }
        .toolbar {
            if Self.showsMailboxToolbar(showsAIInspector: isAIInspectorPresented), !settingsStackOwnsToolbar {
                mailboxToolbar(viewModel: viewModel)
            }
        }
        #if os(iOS)
        // The ✦ popover points at the column's top trailing corner, under the toolbar, so it
        // shows even when ✦ itself sits in the navigation bar's More menu.
        .popover(
            isPresented: Binding(
                get: { conversationAIPopoverState.isPresented },
                set: { if !$0 { conversationAIPopoverState.close() } }
            ),
            attachmentAnchor: .point(.topTrailing),
            arrowEdge: .top
        ) {
            conversationAIPopover
        }
        .onChange(of: conversationAIReaderMessageID(in: viewModel)) { _, messageID in
            conversationAIPopoverState.readerDidShow(messageID)
        }
        .onDisappear { conversationAIPopoverState.close() }
        .toolbarBackground(MailDesign.workArea, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    /// On iOS the Settings detail sits in its own NavigationStack, which carries the toolbar
    /// itself (see `detailColumn`); macOS keeps the column toolbar.
    private var settingsStackOwnsToolbar: Bool {
        #if os(iOS)
        !isAccountSetupRequired && mailbox.selectedDestination.workAreaKind == .settings
        #else
        false
        #endif
    }

    static func showsMailboxToolbar(showsAIInspector: Bool) -> Bool {
        true
    }

    static let mailboxToolbarMessageActionIdentifiers = [
        "reply",
        "reply_all",
        "forward",
        "archive",
        "read_state",
        "delete",
    ]

    static let mailboxToolbarGlobalActionIdentifiers = [
        "compose",
        "ask_mail",
        "command_center",
    ]
    static let mailboxToolbarActionPlacement = MailboxToolbarActionPlacement.automatic

    static let mailboxToolbarIdentitySharedBackgroundVisibility: Visibility = .hidden
    static let mailboxToolbarControlSize: ControlSize = .regular
    static let mailboxRootMaximumWidth: CGFloat = .infinity
    static let mailboxRootMaximumHeight: CGFloat = .infinity

    static func mailboxToolbarGroupedItemIdentifiers(
        hasActionableMessage: Bool
    ) -> [[String]] {
        var groups: [[String]] = []
        if hasActionableMessage {
            groups.append(mailboxToolbarMessageActionIdentifiers)
        }
        groups.append(mailboxToolbarGlobalActionIdentifiers)
        return groups
    }

    static func mailboxToolbarTrailingItemIdentifiers(
        hasActionableMessage: Bool
    ) -> [String] {
        mailboxToolbarGroupedItemIdentifiers(
            hasActionableMessage: hasActionableMessage
        )
        .flatMap { $0 }
    }

    static func mailboxToolbarSpacingPlan(
        isReader: Bool,
        hasActionableMessage: Bool,
        hasMailboxCluster: Bool
    ) -> MailboxToolbarSpacingPlan {
        MailboxToolbarSpacingPlan(
            backToIdentity: isReader && hasMailboxCluster,
            identityToLayout: hasMailboxCluster,
            leadingToActions: hasMailboxCluster,
            messageActionsToGlobal: hasActionableMessage
        )
    }

    static let mailboxToolbarLeadingItemIdentifiers = [
        "mailbox_identity",
        "inbox_layout",
    ]

    #if os(iOS)
    static let showsReaderLayoutPicker = false
    #else
    static let showsReaderLayoutPicker = true
    #endif

    private func mailboxHeaderPresentation(
        in viewModel: InboxViewModel
    ) -> MailboxHeaderPresentation {
        let mode = InboxDisplayMode(rawValue: mailbox.selectedInboxMode) ?? .focusedList
        return MailboxHeaderPresentation.make(
            title: mailbox.selectedDestination.title,
            availableRows: viewModel.rows(
                for: mailbox.selectedDestination,
                matching: ""
            ),
            mode: mode,
            destination: mailbox.selectedDestination,
            statusLine: nodeMailModeStatus.statusLine
        )
    }

    @ToolbarContentBuilder
    private func mailboxToolbar(viewModel: InboxViewModel) -> some ToolbarContent {
        let actionableMessageID = self.actionableMessageID(in: viewModel)
        let selectedThread = viewModel.thread(for: mailbox.selectedDestination)
        let canReply = SourceVerifiedReplyTarget.recipient(
            selectedMessageID: actionableMessageID,
            thread: selectedThread
        ) != nil
        let isReader = if case .reader = mailbox.mailboxNavigation.route {
            true
        } else {
            false
        }
        let hasMailboxCluster = mailbox.selectedDestination.workAreaKind == .mailbox
        let hasActionableMessage = isReader && actionableMessageID != nil
        let spacingPlan = Self.mailboxToolbarSpacingPlan(
            isReader: isReader,
            hasActionableMessage: hasActionableMessage,
            hasMailboxCluster: hasMailboxCluster
        )

        #if os(macOS)
        if isReader {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    mailbox.returnToList()
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to message list (⌘[)")
                .accessibilityIdentifier("mailbox.reader.back-to-list")
            }
            if spacingPlan.backToIdentity {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
        }
        #endif

        if hasMailboxCluster {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                MailboxHeaderIdentity(
                    presentation: mailboxHeaderPresentation(in: viewModel)
                )
            }
            .sharedBackgroundVisibility(
                Self.mailboxToolbarIdentitySharedBackgroundVisibility
            )
            #else
            if !isReader {
                ToolbarItem(placement: .navigation) {
                    MailboxHeaderIdentity(
                        presentation: mailboxHeaderPresentation(in: viewModel)
                    )
                }
            }
            #endif

            #if os(macOS)
            if spacingPlan.identityToLayout {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
            #endif

            if !isReader || Self.showsReaderLayoutPicker {
                ToolbarItem(placement: .navigation) {
                    MailboxHeaderModePicker(
                        selectedInboxMode: mailboxDisplayModeSelection
                    )
                    .controlSize(Self.mailboxToolbarControlSize)
                }
            }
        }

        #if os(macOS)
        if spacingPlan.leadingToActions {
            ToolbarSpacer(
                .flexible,
                placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement
            )
        }
        #endif

        #if os(iOS)
        // iOS gets plain toolbar buttons. A `ControlGroup` that lacks the room
        // (the reader on iPad beside its sidebar, or on iPhone) collapses into
        // an empty, unlabelled button, which hid these actions. Plain buttons
        // keep their icons and labels, and any that don't fit move into the
        // navigation bar's labelled More menu.
        if isReader, let actionableMessageID {
            ToolbarItemGroup(placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement) {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    presentReply(to: actionableMessageID, in: selectedThread)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Reply (⌘R)")
                .disabled(!canReply)

                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                    presentCompose(.replyAll(messageID: actionableMessageID))
                }
                .help("Reply All")
                .disabled(!canReply)
                .accessibilityIdentifier("mailbox.reader.reply-all")

                Button("Forward", systemImage: "arrowshape.turn.up.right") {
                    presentCompose(.forward(messageID: actionableMessageID))
                }
                .help("Forward")
                .accessibilityIdentifier("mailbox.reader.forward")

                Button("Archive", systemImage: "archivebox") {
                    messageActions.perform(.archive, messageID: actionableMessageID)
                }
                .help("Archive")
                .disabled(inboxMailActions.isPending(messageID: actionableMessageID))

                Button(
                    selectedMessageIsUnread(in: viewModel)
                        ? "Mark as Read"
                        : "Mark as Unread",
                    systemImage: selectedMessageIsUnread(in: viewModel)
                        ? "envelope.open"
                        : "envelope.badge"
                ) {
                    messageActions.perform(
                        selectedMessageIsUnread(in: viewModel) ? .markRead : .markUnread,
                        messageID: actionableMessageID
                    )
                }
                .help(
                    selectedMessageIsUnread(in: viewModel)
                        ? "Mark as Read"
                        : "Mark as Unread"
                )
                .disabled(inboxMailActions.isPending(messageID: actionableMessageID))

                Button("Delete", systemImage: "trash") {
                    messageActions.perform(.delete, messageID: actionableMessageID)
                }
                .help("Delete")
                .disabled(inboxMailActions.isPending(messageID: actionableMessageID))

                flagButton(actionableMessageID: actionableMessageID, in: viewModel)
                moveMenu(actionableMessageID: actionableMessageID)

                // The popover hangs off the detail column, not this button: the button can
                // overflow into More and leave it without an anchor (Ruling 17).
                Button("Conversation AI", systemImage: "sparkles") {
                    conversationAIPopoverState.open(over: actionableMessageID)
                }
                .help("AI for this conversation")
                .accessibilityIdentifier("mailbox.reader.conversation-ai")
            }
        }

        ToolbarItemGroup(placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement) {
            Button("Compose", systemImage: "square.and.pencil", action: { presentCompose(.new) })
                .help("Compose a new message")
                .accessibilityIdentifier("mailbox.toolbar.compose")
            Button("Ask Mail", systemImage: "sparkles") {
                toggleInspector(.askMail)
            }
            .help("Ask questions across your local mail")
            .accessibilityIdentifier("mailbox.toolbar.ask-mail")
            Button("Command Center", systemImage: "command", action: commandSurfaces.openGlobalCommandCenter)
                .help("Command Center (⌘K)")
                .accessibilityIdentifier("mailbox.toolbar.command-center")
        }
        #else
        if isReader, let actionableMessageID {
            ToolbarItem(placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement) {
                ControlGroup {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                        presentReply(to: actionableMessageID, in: selectedThread)
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .help("Reply (⌘R)")
                    .disabled(!canReply)
                    .mailboxToolbarActionPadding(outerEdge: .leading)
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                        presentCompose(.replyAll(messageID: actionableMessageID))
                    }
                    .help("Reply All")
                    .disabled(!canReply)
                    .accessibilityIdentifier("mailbox.reader.reply-all")
                    .mailboxToolbarActionPadding()
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    Button("Forward", systemImage: "arrowshape.turn.up.right") {
                        presentCompose(.forward(messageID: actionableMessageID))
                    }
                    .help("Forward")
                    .accessibilityIdentifier("mailbox.reader.forward")
                    .mailboxToolbarActionPadding()
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    Button("Archive", systemImage: "archivebox") {
                        messageActions.perform(.archive, messageID: actionableMessageID)
                    }
                    .help("Archive")
                    .disabled(inboxMailActions.isPending(messageID: actionableMessageID))
                    .mailboxToolbarActionPadding()
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    Button(
                        selectedMessageIsUnread(in: viewModel)
                            ? "Mark as Read"
                            : "Mark as Unread",
                        systemImage: selectedMessageIsUnread(in: viewModel)
                            ? "envelope.open"
                            : "envelope.badge"
                    ) {
                        messageActions.perform(
                            selectedMessageIsUnread(in: viewModel) ? .markRead : .markUnread,
                            messageID: actionableMessageID
                        )
                    }
                    .help(
                        selectedMessageIsUnread(in: viewModel)
                            ? "Mark as Read"
                            : "Mark as Unread"
                    )
                    .disabled(inboxMailActions.isPending(messageID: actionableMessageID))
                    .mailboxToolbarActionPadding()
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    Button("Delete", systemImage: "trash") {
                        messageActions.perform(.delete, messageID: actionableMessageID)
                    }
                    .help("Delete")
                    .disabled(inboxMailActions.isPending(messageID: actionableMessageID))
                    .mailboxToolbarActionPadding()
                    .buttonStyle(MailboxToolbarCircleButtonStyle())

                    flagButton(actionableMessageID: actionableMessageID, in: viewModel)
                        .mailboxToolbarActionPadding()
                        .buttonStyle(MailboxToolbarCircleButtonStyle())

                    moveMenu(actionableMessageID: actionableMessageID)
                        .mailboxToolbarActionPadding()

                    Button("Conversation AI", systemImage: "sparkles") {
                        toggleInspector(.conversationAI)
                    }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .help("AI for this conversation (⌥⌘A)")
                    .accessibilityIdentifier("mailbox.reader.conversation-ai")
                    .mailboxToolbarActionPadding(outerEdge: .trailing)
                    .buttonStyle(MailboxToolbarCircleButtonStyle())
                }
                .labelStyle(.iconOnly)
                .controlSize(Self.mailboxToolbarControlSize)
                .fixedSize()
            }
        }

        #if os(macOS)
        if spacingPlan.messageActionsToGlobal {
            ToolbarSpacer(
                .fixed,
                placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement
            )
        }
        #endif

        ToolbarItem(placement: Self.mailboxToolbarActionPlacement.nativeToolbarPlacement) {
            MailboxGlobalActionGroup(
                controlSize: Self.mailboxToolbarControlSize,
                compose: { presentCompose(.new) },
                toggleAskMail: { toggleInspector(.askMail) },
                openCommandCenter: commandSurfaces.openGlobalCommandCenter
            )
        }
        #endif

    }

    private var selectedApprovalItem: ApprovalQueueItemModel? {
        let filtered = approvalQueue.items.filter { selectedApprovalFilter.matches($0) }
        return filtered.first { $0.id == selectedApprovalRequestID } ?? filtered.first
    }

    private func handleAppCommand(_ command: PlainpostAppCommand?) {
        guard let command else {
            return
        }

        if isAccountSetupRequired && command != .settings {
            mailbox.setDestination(.settings)
            selectedSettingsDestination = .section(.accounts)
            return
        }

        switch command {
        case .compose:
            presentCompose(.new)
        case .commandCenter:
            commandSurfaces.openGlobalCommandCenter()
        case .focusSearch:
            searchController.present(query: nil, accountScope: searchAccountScope)
        case .smartInbox:
            mailbox.setDestination(.smartInbox)
        case .approvalQueue:
            mailbox.setDestination(.approvalQueue)
        case .settings:
            mailbox.setDestination(.settings)
        }
    }

    private func handleCommandCenterCommand(_ command: CommandCenterCommand) {
        switch command.id {
        case "search_mail":
            searchController.present(query: commandCenter.query, accountScope: searchAccountScope)
        case "go_smart_inbox":
            handleAppCommand(.smartInbox)
        case "go_drafts":
            mailbox.setDestination(
                .drafts,
                displayMode: InboxDisplayMode.simpleList.rawValue
            )
        case "open_approval_queue":
            handleAppCommand(.approvalQueue)
        case "open_settings":
            handleAppCommand(.settings)
        case "create_new_draft":
            presentCompose(.new)
        case "open_ai_index_status":
            mailbox.setDestination(.aiIndexStatus)
        default:
            break
        }
    }

    private var mailboxDisplayModeSelection: Binding<String> {
        Binding(
            get: { mailbox.selectedInboxMode },
            set: { mode in
                mailbox.setDisplayMode(mode)
            }
        )
    }

    private var sidebarDestinationSelection: Binding<PlainpostDestination> {
        Binding(
            get: { mailbox.selectedDestination },
            set: { destination in
                notificationAccountInboxScope = nil
                mailbox.setDestination(destination)
                #if os(iOS)
                compactMailboxColumn = .detail
                #endif
            }
        )
    }

    #if os(iOS)
    private func reassertCompactMailboxDetailOnRouteChange() {
        let compactMailboxColumn = $compactMailboxColumn
        mailbox.onRouteChange = { _ in
            // The collapsed split view can choose its sidebar while SwiftUI
            // replaces the reader with the list. Reassert the source detail
            // after that replacement has been scheduled.
            Task { @MainActor in
                await Task.yield()
                compactMailboxColumn.wrappedValue = .detail
            }
        }
    }
    #endif

    private var activeSmartInboxBundle: SmartInboxDisplayBundle? {
        guard case let .list(.smartInboxBundle(bundle)) = mailbox.mailboxNavigation.route else {
            return nil
        }
        return bundle
    }

    /// The controller's open, after retiring the macOS command surfaces' mailbox source.
    private func openMailboxMessage(
        _ messageID: String,
        destination: PlainpostDestination,
        from context: MailboxListContext
    ) {
        session.openMailboxMessage(messageID, destination: destination, from: context)
    }

    /// A row in the mail list: the open folder, if any, stays open.
    private func openListMessage(_ messageID: String, from context: MailboxListContext) {
        session.openMailboxMessage(
            messageID, destination: mailbox.selectedDestination, from: context, keepingFolder: true
        )
    }

    private func openMailboxMessage(
        _ messageID: String,
        from context: MailboxListContext
    ) {
        openMailboxMessage(
            messageID,
            destination: mailbox.selectedDestination,
            from: context
        )
    }

    private func announceMailSearchScopeChange(_ announcement: String?) {
        guard let announcement, !announcement.isEmpty else { return }
#if os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
#elseif canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: announcement)
#endif
    }

    /// Calendar UI follows the Node's capability; a known enabled Node stays
    /// available through transient probe failures.
    private func probeCalendarAvailability() async {
        guard let calendarAuthority else { calendarAvailability = .unknown; return }
        let cache = CalendarSnapshotCache(accountID: calendarAuthority.accountID, appDataRoot: calendarAppDataRoot)
        let availability = await CalendarAvailability.probe(calendarAuthority, lastKnownEnabled: cache.loadAvailability())
        guard !Task.isCancelled else { return }
        switch availability {
        case .enabled: cache.saveAvailability(true)
        case .disabled, .updateRequired: cache.saveAvailability(false)
        case .unknown: break
        }
        calendarAvailability = availability
        mailbox.selectedDestination = CalendarAvailability.destination(mailbox.selectedDestination, availability: availability)
    }

    @ViewBuilder private var calendarWorkspace: some View {
        #if os(macOS)
        if let calendarAuthority {
            CalendarWorkspace(authority: calendarAuthority, appDataRoot: calendarAppDataRoot, openSettings: {
                selectedSettingsDestination = .section(.calendars); mailbox.selectedDestination = .settings
            }, openThread: { _, messageID in
                guard !messageID.isEmpty else { return }
                mailbox.selectedDestination = .allInboxes
                openMailboxMessage(messageID, from: .mailbox(destination: .allInboxes, mode: .focusedList))
            }, selection: calendarReturn?.selection, backToThread: calendarReturn.map { context in
                { returnToThread(context) }
            })
            .id(calendarAuthority.accountID)
        } else {
            ContentUnavailableView {
                Label("Calendar unavailable", systemImage: "calendar")
            } description: {
                Text("Connect your Sync Node to set up Google Calendar or CalDAV.")
            } actions: {
                Button("Retry Calendar") { Task { await accountSessionModel?.prepareCalendarAuthority() } }
            }
        }
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private func workArea(viewModel: InboxViewModel) -> some View {
        if isAccountSetupRequired {
            AccountSetupWorkspace(viewModel: accountSetup)
        } else {
            switch mailbox.selectedDestination.workAreaKind {
            case .calendar:
                calendarWorkspace
            case .settings:
                SettingsWorkspace(
                    selection: $selectedSettingsDestination,
                    accountSetup: accountSetup,
                    accountSessionModel: accountSessionModel,
                    nodeSettings: nodeSettings,
                    aiProviderSettings: aiProviderSettings,
                    translationSettings: translationSettings,
                    aiIndexStatus: viewModel.aiIndexStatus,
                    auditLog: auditLog,
                    mailRules: mailRules,
                    mailLabels: mailLabels,
                    maintenance: mailMaintenance,
                    searchIndexRebuild: searchIndexRebuild
                )
                .environment(\.plainpostCalendarAuthority, calendarAuthority)
            case .aiIndexStatus:
                AIIndexStatusWorkspace(status: viewModel.aiIndexStatus)
            case .approvalQueue:
                EmptyView()
            case .mailbox:
                if mailbox.selectedDestination.showsThreadReader {
                    let thread = viewModel.thread(for: mailbox.selectedDestination)
                    #if os(macOS)
                    if let calendarAuthority, calendarAvailability.showsCalendar {
                        ThreadInvitationHost(authority: calendarAuthority, appDataRoot: calendarAppDataRoot) { invitations in
                            threadReader(thread: thread, invitations: invitations)
                        }
                        .id(calendarAuthority.accountID)
                    } else {
                        threadReader(thread: thread, invitations: nil)
                    }
                    #else
                    threadReader(thread: thread, invitations: nil)
                    #endif
                } else {
                    #if os(macOS)
                    if mailbox.selectedDestination == .drafts {
                        SavedDraftsWorkspace(
                            accounts: accountSetup.accounts,
                            actions: session.localDrafts,
                            openDraft: { presentCompose(.restore($0)) },
                            openComposer: { presentCompose(.new) }
                        )
                    } else {
                        MailboxDestinationWorkspace(
                            destination: mailbox.selectedDestination,
                            openComposer: { presentCompose(.new) }
                        )
                    }
                    #else
                    MailboxDestinationWorkspace(
                        destination: mailbox.selectedDestination,
                        openComposer: { presentCompose(.new) }
                    )
                    #endif
                }
            }
        }
    }

    private func threadReader(thread: ThreadDetailModel, invitations: ThreadInvitationViewModel?) -> some View {
        ThreadReaderWorkspace(
            thread: thread,
            translation: threadTranslation,
            translationLanguage: translationSettings.selectedOption,
            translationProviderID: translationProviderIdentity.providerID,
            translationModelID: translationProviderIdentity.modelID,
            openComposer: { presentReply(to: mailbox.selectedMessageID, in: thread) },
            openAttachment: { attachment in await openAttachment(attachment) },
            selectedMessageID: mailbox.selectedMessageID,
            mailActions: inboxMailActions,
            dismissReader: mailbox.returnToList,
            performMessageAction: { messageActions.perform($0, messageID: $1) },
            invitations: invitations,
            showInCalendar: { selection, messageID in
                #if os(macOS)
                calendarReturn = ThreadCalendarReturn(selection: selection, destination: mailbox.selectedDestination, messageID: messageID)
                invitationScrollMessageID = nil
                mailbox.selectedDestination = .calendar
                #endif
            },
            invitationScrollMessageID: invitationScrollMessageID
        )
    }

    /// Back to thread restores the mailbox destination; the retained reader
    /// route and list scroll context come from mailbox navigation, and the
    /// reader scrolls back to the invitation's message.
    private func returnToThread(_ context: ThreadCalendarReturn) {
        invitationScrollMessageID = context.messageID
        calendarReturn = nil
        mailbox.selectedDestination = context.destination
    }

    private func selectedMessageIsFlagged(in viewModel: InboxViewModel) -> Bool {
        guard let selectedMessageID = mailbox.selectedMessageID else { return false }
        return viewModel.classicRows.first(where: { $0.id == selectedMessageID })?.isFlagged
            ?? session.isMessageFlagged(selectedMessageID)
    }

    private func flagButton(actionableMessageID: String, in viewModel: InboxViewModel) -> some View {
        let flagged = selectedMessageIsFlagged(in: viewModel)
        return Button(flagged ? "Unflag" : "Flag", systemImage: flagged ? "flag.slash" : "flag") {
            messageActions.perform(flagged ? .unflag : .flag, messageID: actionableMessageID)
        }
        .help(flagged ? "Unflag" : "Flag")
        .disabled(inboxMailActions.isPending(messageID: actionableMessageID))
        .accessibilityIdentifier("mailbox.reader.flag")
    }

    /// Move to: the message's own account's folders.
    private func moveMenu(actionableMessageID: String) -> some View {
        let folders = session.moveDestinations(forMessageID: actionableMessageID, excluding: mailbox.selectedFolder?.path ?? "INBOX")
        return Menu("Move to", systemImage: "folder") {
            ForEach(folders, id: \.path) { folder in
                Button(folder.name, systemImage: MailboxFolder.systemImage(for: folder.role)) {
                    messageActions.perform(.move(to: folder.path), messageID: actionableMessageID,
                                           shownIn: mailbox.selectedFolder?.path)
                }
            }
        }
        .help("Move to a folder")
        .disabled(folders.isEmpty || inboxMailActions.isPending(messageID: actionableMessageID))
        .accessibilityIdentifier("mailbox.reader.move")
    }

    private func selectedMessageIsUnread(in viewModel: InboxViewModel) -> Bool {
        guard let selectedMessageID = mailbox.selectedMessageID else {
            return false
        }
        return viewModel.classicRows.first(where: { $0.id == selectedMessageID })?.isUnread ?? false
    }

    private var translationProviderIdentity: (providerID: String, modelID: String) {
        Self.translationProviderIdentity(
            providerID: aiProviderSettings.selectedProviderID
        )
    }

    static func applyAIProviderChange(
        providerID: String,
        aiAssistant: ThreadAIAssistantViewModel,
        askMail: AskMailViewModel,
        threadTranslation: ThreadTranslationViewModel,
        configureAIAssistant: (ThreadAIAssistantViewModel, String) -> Void,
        configureAskMail: (AskMailViewModel, String) -> Void,
        configureThreadTranslation: (ThreadTranslationViewModel, String) -> Void
    ) {
        configureAIAssistant(aiAssistant, providerID)
        configureAskMail(askMail, providerID)
        configureThreadTranslation(threadTranslation, providerID)
    }

    static func applyTranslationLanguageChange(
        threadTranslation: ThreadTranslationViewModel
    ) {
        threadTranslation.configurationDidChange()
    }

    static func translationProviderIdentity(
        providerID: String
    ) -> (providerID: String, modelID: String) {
        let resolvedProviderID = AIProviderSelection.resolvedProviderID(providerID)
        let provider = (
            try? LocalAIProviderResolver.resolve(
                LocalAIProviderSelection(providerID: resolvedProviderID)
            )
        ) ?? DisabledAIProvider()
        return (provider.id, provider.chatModelID)
    }

    static func actionableMessageID(
        in viewModel: InboxViewModel,
        selectedDestination: PlainpostDestination,
        selectedMessageID: String?
    ) -> String? {
        guard selectedDestination.workAreaKind == .mailbox,
              let selectedMessageID,
              viewModel.rows(for: selectedDestination).contains(where: { $0.id == selectedMessageID })
        else {
            return nil
        }
        return selectedMessageID
    }

    private func actionableMessageID(in viewModel: InboxViewModel) -> String? {
        Self.actionableMessageID(
            in: viewModel,
            selectedDestination: mailbox.selectedDestination,
            selectedMessageID: mailbox.selectedMessageID
        )
    }

    /// Asks the compose coordinator for `request` and opens a composer window when it answers one.
    private func presentCompose(_ request: ComposeRequest) {
        Task {
            await openCompose(request)
        }
    }

    /// `presentCompose` for callers already in a task, so nothing can change between their
    /// checks and the request.
    private func openCompose(_ request: ComposeRequest) async {
        if case let .window(windowRequest) = await compose.request(request) {
            openWindow(value: windowRequest)
        }
    }

    /// Replies to the selected message in `thread`, or to its last message.
    private func presentReply(to selectedMessageID: String?, in thread: ThreadDetailModel) {
        guard let sourceMessageID = ComposeCoordinator.replySourceMessageID(
            selectedMessageID: selectedMessageID,
            in: thread
        ) else { return }
        presentCompose(.reply(messageID: sourceMessageID))
    }

    @ViewBuilder
    private func undoSendSnackbar(for state: UndoSendSnackbarState) -> some View {
        UndoSendSnackbar(
            state: state,
            undo: { presentCompose(.undoLatestSend) },
            openDraft: { presentCompose(.restoreFailedSend) }
        )
    }

    nonisolated static func summaryContext(
        selectedMessageID: String?,
        thread: ThreadDetailModel
    ) -> EmailSummaryContext? {
        guard let selectedMessageID,
              thread.messages.contains(where: { $0.id == selectedMessageID })
        else {
            return nil
        }
        // Full message bodies can be hundreds of kilobytes. IDs, body sizes,
        // and short edge samples invalidate the thread cache without copying
        // every complete body on the main actor whenever selection changes.
        let fingerprint = ([thread.subject] + thread.messages.flatMap { threadMessage in
            let body = threadMessage.safeBodyText
            return [
                threadMessage.id,
                threadMessage.sender,
                String(body.utf8.count),
                String(body.prefix(160)),
                String(body.suffix(160))
            ]
        })
            .joined(separator: "\u{1F}")
        return EmailSummaryContext(
            messageID: MessageID(selectedMessageID),
            contentFingerprint: fingerprint
        )
    }

    private func askMailContext(viewModel: InboxViewModel) -> AskMailActiveContext? {
        guard let selectedMessageID = mailbox.selectedMessageID else { return nil }
        return Self.askMailContext(selectedMessageID: selectedMessageID, thread: viewModel.selectedThread)
    }

    /// The open conversation, for the ✦ pane. It follows the selection.
    private func conversationAIContext(viewModel: InboxViewModel) -> ConversationAIContext? {
        guard let selectedMessageID = mailbox.selectedMessageID else { return nil }
        return ConversationAIContext.make(selectedMessageID: selectedMessageID, thread: viewModel.selectedThread)
    }

    private var conversationAIReadOnlyReason: String? {
        session.allowsMailboxMutations() ? nil : Optional<MobileReadOnlyReason>.none.sendingLine
    }

    private func toggleInspector(_ requested: MailInspectorSlot) {
        let next = MailInspectorSlot.toggled(requested, isPresented: isAIInspectorPresented, current: inspectorSlot)
        inspectorSlot = next.slot
        isAIInspectorPresented = next.isPresented
    }

    #if os(iOS)
    /// The message the reader shows, while ✦ can open over it; nil without a reader.
    private func conversationAIReaderMessageID(in viewModel: InboxViewModel) -> String? {
        guard case .reader = mailbox.mailboxNavigation.route else { return nil }
        return actionableMessageID(in: viewModel)
    }

    private var conversationAIPopover: some View {
        ConversationAIPane(
            model: session.conversationAI,
            translationLanguage: translationSettings.selectedOption,
            readOnlyReason: conversationAIReadOnlyReason,
            dismissAfterTranslate: { conversationAIPopoverState.close() },
            openCompose: closeConversationAIPopoverThenCompose
        )
        .frame(width: 380, height: 540)
        .onAppear {
            // Ask's replies and drafts take Edit in Compose's path: the popover closes first.
            session.attachConversationAskMailHost(
                beforeOpening: { conversationAIPopoverState.close() },
                openCompose: closeConversationAIPopoverThenCompose
            )
        }
    }

    /// Opens Compose with `request` once the ✦ popover has closed.
    private func closeConversationAIPopoverThenCompose(_ request: ComposeRequest) {
        pendingConversationAICompose = request
        conversationAIPopoverState.close()
    }
    #endif

    /// Ask Mail's scope for the conversation `thread`, with `selectedMessageID` selected: its
    /// conversation key, subject and message IDs. Nil when the thread doesn't hold the message.
    nonisolated static func askMailContext(selectedMessageID: String, thread: ThreadDetailModel) -> AskMailActiveContext? {
        guard let selected = thread.messages.first(where: { $0.id == selectedMessageID }) else { return nil }
        let conversationKey: String
        if let rawThreadID = selected.sourceThreadID?.rawValue {
            conversationKey = rawThreadID.hasPrefix("thr_uid_")
                ? "legacy_subject_\(MailThreading.normalizedSubject(thread.subject))"
                : rawThreadID
        } else {
            conversationKey = "message_\(selectedMessageID)"
        }
        return AskMailActiveContext(
            conversationKey: conversationKey,
            subject: thread.subject,
            messageIDs: thread.messages.map { MessageID($0.id) }
        )
    }

    /// This root's side of the shared session wiring: its alert, its Ask Mail inspector, its
    /// approval selection, and its design-preview and setup gates.
    private var lifecycleHooks: MailSessionLifecycleHooks {
        let diagnostic = $messageOpenDiagnostic
        let inspector = $isAIInspectorPresented
        let slot = $inspectorSlot
        let selectedApprovalRequestID = $selectedApprovalRequestID
        let isAccountSetupRequired = $isAccountSetupRequired
        let attachmentArtifact = $attachmentArtifact
        let designNow = designNow
        return MailSessionLifecycleHooks(
            reportFailure: { diagnostic.wrappedValue = $0 },
            presentAskMail: { _ in
                slot.wrappedValue = .askMail
                inspector.wrappedValue = true
            },
            didRefreshApprovals: { [weak approvalQueue] in
                selectedApprovalRequestID.wrappedValue = approvalQueue?.items.first?.id
            },
            allowsSmartInboxRefreshOnAppear: {
                designNow == nil && !isAccountSetupRequired.wrappedValue
            },
            markReadFailed: {
                diagnostic.wrappedValue = "Plainpost could not mark this message as read. Try selecting it again."
            },
            attachmentEvent: { event in
                switch event.outcome {
                case let .saved(artifact):
                    attachmentArtifact.wrappedValue = artifact
                    #if os(macOS)
                    diagnostic.wrappedValue = "Attachment saved to \(artifact.filename)."
                    #endif
                case let .failed(message):
                    diagnostic.wrappedValue = "Plainpost could not save the attachment: \(message)"
                }
            }
        )
    }

    /// Points compose at the thread the reader shows (the notification inbox scope applied),
    /// opens composer windows for the session, and drops that scope when Ask Mail shows a message.
    private func connectCompose() {
        let scope = $notificationAccountInboxScope
        compose.thread = { [weak inboxSnapshot, weak mailbox] in
            guard let inboxSnapshot, let mailbox else { return nil }
            let viewModel = scope.wrappedValue?.apply(to: inboxSnapshot.model)
                ?? inboxSnapshot.model
            return viewModel.thread(for: mailbox.selectedDestination)
        }
        session.openComposerWindow = { [openWindow] in openWindow(value: $0) }
        session.willShowAskMailMessage = { scope.wrappedValue = nil }
    }

    private func refreshSmartInbox(
        using providerID: String,
        mode: PlainpostSmartInboxRunMode
    ) async {
        await session.refreshSmartInbox(using: providerID, mode: mode, locale: currentLocale)
    }

    private func refreshSmartInboxActivity() {
        smartInboxActivityCoordinator.refresh(locale: currentLocale)
    }

}

/// Keeps the account directory loaded while the sidebar shows it, hands its sections to the
/// sidebar, and returns the mail list to All Inboxes when the open folder's account is gone.
private struct AccountDirectorySidebar<Content: View>: View {
    @ObservedObject var directory: MailboxDirectoryModel
    let mailbox: MailboxController
    @ViewBuilder let content: ([MailboxAccountSection]) -> Content

    var body: some View {
        content(directory.sections)
            .onAppear { directory.setVisible(true) }
            .onDisappear { directory.setVisible(false) }
            .onChange(of: directory.sections) { _, sections in
                mailbox.reconcileFolder(withDirectory: sections)
            }
    }
}

/// When the Mac's open folder list reloads: on choosing it and on every mailbox change.
private struct FolderListLoadKey: Equatable {
    let folder: MailFolderRef?
    let refreshRevision: Int
}
