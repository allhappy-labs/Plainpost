#if os(iOS)
import SwiftUI
import PlainpostCore

/// One mailbox's conversations, or one account folder's messages. The whole row opens the
/// conversation; pull to refresh runs the app's sync.
struct MobileMailboxListScreen: View {
    let session: MailSession
    let kind: MobileMailbox
    @ObservedObject var environment: MobileMailEnvironment
    @ObservedObject var folderRows: FolderRowsModel
    @ObservedObject private var mailbox: MailboxController
    @ObservedObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @ObservedObject private var overlayState: MailboxOverlayProjectionState
    @ObservedObject private var refreshBus: MailboxRefreshBus
    @ObservedObject private var activity: MailActivityCoordinator
    @ObservedObject private var composeCoordinator: ComposeCoordinator
    let openMessage: (String) -> Void
    let openDraft: (ComposerRestoreSnapshot) -> Void
    let compose: () -> Void
    let openSearch: () -> Void
    let askMail: () -> Void
    @State private var moreRow: MessageRowModel?
    /// The row whose Move to… sheet is open.
    @State private var moveRow: MessageRowModel?
    @State private var flashedID: String?
    /// Drafts saved in this app's composer, listed above the server's Drafts folder.
    @State private var savedDrafts: [Draft] = []
    @State private var draftFailure: String?

    init(
        session: MailSession,
        kind: MobileMailbox,
        environment: MobileMailEnvironment,
        folderRows: FolderRowsModel,
        openMessage: @escaping (String) -> Void,
        openDraft: @escaping (ComposerRestoreSnapshot) -> Void = { _ in },
        compose: @escaping () -> Void,
        openSearch: @escaping () -> Void,
        askMail: @escaping () -> Void
    ) {
        self.session = session
        self.kind = kind
        self.environment = environment
        self.folderRows = folderRows
        _mailbox = ObservedObject(wrappedValue: session.mailbox)
        _inboxSnapshot = ObservedObject(wrappedValue: session.inboxSnapshot)
        _overlayState = ObservedObject(wrappedValue: session.actions.overlayState)
        _refreshBus = ObservedObject(wrappedValue: session.refreshBus)
        _activity = ObservedObject(wrappedValue: session.activity)
        _composeCoordinator = ObservedObject(wrappedValue: session.compose)
        self.openMessage = openMessage
        self.openDraft = openDraft
        self.compose = compose
        self.openSearch = openSearch
        self.askMail = askMail
    }

    private var rows: [MessageRowModel] {
        if case .folder = kind { return mailbox.visibleRows(folderRows.visible(hiding: overlayState.overlays)) }
        return mailbox.visibleRows(inboxSnapshot.model.rows(for: kind.destination))
    }

    private var unreadCount: Int { rows.filter(\.isUnread).count }

    /// A mixed list names each row's account; one account's folder doesn't.
    private func rowAccountLabel(_ row: MessageRowModel) -> String? {
        if case .folder = kind { return nil }
        return MessageRowAccountLabel.label(for: row.accountID, accounts: session.accountSetup.accounts)
    }

    private var subtitle: String {
        var accounts = session.accountSetup.accounts
        if case let .folder(ref) = kind { accounts = accounts.filter { $0.id == ref.accountID } }
        return MobileMailbox.subtitle(accountTitles: accounts.map(\.email.rawValue), unread: unreadCount)
    }

    private func markAllRead() {
        guard allowsMutations else { return }
        let ids = rows.filter(\.isUnread).map(\.id)
        Task { await session.actions.markAllRead(ids) }
    }

    var body: some View {
        List {
            if let failure = activity.activities.first(where: { $0.kind == .syncFailure }) {
                HStack {
                    Label(failure.failureMessage, systemImage: "exclamationmark.triangle").font(.footnote)
                    Spacer()
                    Button("Retry") {
                        Task { await session.retry(failure, environment: environment) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("direct-mail.retry-sync")
                }
            }
            if folderFailure != nil, !rows.isEmpty {
                HStack {
                    Label("Couldn't refresh this folder", systemImage: "exclamationmark.triangle").font(.footnote)
                    Spacer()
                    Button("Retry", action: retryFolder)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("mailbox.folder.retry")
                }
            }
            if !allowsMutations {
                // The host's reason: offline lease, reauthorization or offline.
                Label(environment.readOnlyReason.changesLine, systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mailbox.read-only")
            }
            if !savedDrafts.isEmpty {
                Section {
                    ForEach(savedDrafts, id: \.id) { draft in
                        Button { openDraft(session.localDrafts.snapshot(draft)) } label: {
                            MobileSavedDraftRow(draft: draft)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mailbox.saved-draft.\(draft.id.rawValue)")
                        .listRowInsets(.leading, MobileMessageRow.leadingListInset)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if allowsMutations {
                                Button(role: .destructive) { discard(draft) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Saved on This iPhone")
                }
            }
            if rows.isEmpty, !isLoaded {
                ForEach(0..<6, id: \.self) { index in
                    MobileMessageRow(row: .mobilePlaceholder(index)).redacted(reason: .placeholder)
                        .listRowInsets(.leading, MobileMessageRow.leadingListInset)
                }
            }
            ForEach(rows) { row in
                let text = MobileRowText(row: row)
                // The account shows in the conversation; VoiceOver still names it here.
                let accountLabel = rowAccountLabel(row)
                Button { openMessage(row.id) } label: { MobileMessageRow(row: row, text: text) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accountLabel.map { "\(text.accessibilityLabel), account \($0)" } ?? text.accessibilityLabel)
                    .accessibilityValue([row.isUnread ? "Unread" : nil, row.isFlagged ? "Flagged" : nil].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("mailbox.row.\(row.id)")
                    .listRowInsets(.leading, MobileMessageRow.leadingListInset)
                    .listRowBackground(flashedID == row.id ? Color(uiColor: .systemFill) : Color.clear)
                    .onAppear { loadMoreIfLast(row) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if allowsMutations {
                            Button { act(row.isUnread ? .markRead : .markUnread, row.id) } label: {
                                Label(row.isUnread ? "Read" : "Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge")
                            }
                            .tint(.blue)
                            Button { act(row.isFlagged ? .unflag : .flag, row.id) } label: {
                                Label(row.isFlagged ? "Unflag" : "Flag", systemImage: row.isFlagged ? "flag.slash" : "flag")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if allowsMutations {
                            let primary = removalActions(row)[0]
                            Button(role: .destructive) { act(primary, row.id) } label: {
                                Label(kind.removalTitle(for: primary), systemImage: MailRemovalPolicy.systemImage(for: primary))
                            }
                            Button { moreRow = row } label: { Label("More", systemImage: "ellipsis.circle") }
                                .tint(.gray)
                        }
                    }
                    .contextMenu {
                        rowActions(row, includesPrimary: true)
                    } preview: {
                        MobileMessagePreview(row: row)
                    }
            }
        }
        .listStyle(.plain)
        .onChange(of: mailbox.mailboxNavigation.route) { old, new in
            // Returning from a conversation flashes its row once; nothing stays highlighted.
            guard case let .reader(messageID, _) = old, case .list = new else { return }
            flashedID = messageID
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.easeOut(duration: 0.5)) { flashedID = nil }
            }
        }
        .overlay {
            if rows.isEmpty, let folderFailure {
                ContentUnavailableView {
                    Label("Couldn't Load Folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(folderFailure)
                } actions: {
                    Button("Retry", action: retryFolder)
                        .accessibilityIdentifier("mailbox.folder.retry")
                }
                .accessibilityIdentifier("mailbox.folder-failure")
            } else if rows.isEmpty, isLoaded, savedDrafts.isEmpty {
                ContentUnavailableView(emptyState.title, systemImage: "tray", description: Text(emptyState.detail))
                    .accessibilityIdentifier("mailbox.empty")
            }
        }
        .navigationTitle(kind.title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { environment.banner }
        // A bar, not an inset on an opaque background: the chips share the navigation bar's
        // glass edge and the list scrolls under both.
        .safeAreaBar(edge: .top, spacing: 0) {
            if kind == .smartInbox {
                MobileCategoryChips(
                    selection: $mailbox.selectedCategory,
                    available: SmartInboxDisplayBundle.chips(for: inboxSnapshot.model.rows(for: .smartInbox))
                )
                .padding(.vertical, 4)
            }
        }
        .refreshable { await refresh() }
        .task(id: MobileFolderLoadKey(
            kind: kind,
            refreshRevision: refreshBus.revision,
            completedSnapshotRefreshes: inboxSnapshot.completedRefreshes
        )) {
            guard case let .folder(ref) = kind else { return }
            await folderRows.load(ref, using: session.loadFolderRows)
        }
        .task(id: SavedDraftsLoadKey(
            accountID: draftsAccountID,
            composerOpen: composeCoordinator.isPresented,
            refreshRevision: refreshBus.revision
        )) {
            reloadSavedDrafts()
        }
        .alert("Couldn't Delete Draft", isPresented: Binding(
            get: { draftFailure != nil },
            set: { if !$0 { draftFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(draftFailure ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if kind != .unread {
                        Toggle(isOn: Binding(get: { mailbox.unreadOnly }, set: { mailbox.setUnreadOnly($0) })) {
                            Label("Unread Only", systemImage: "line.3.horizontal.decrease")
                        }
                    }
                    Button("Mark All as Read", systemImage: "envelope.open", action: markAllRead)
                        .disabled(unreadCount == 0 || !allowsMutations)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("mailbox.toolbar.more")
            }
            if kind != .unread {
                ToolbarItem(placement: .bottomBar) {
                    Button { mailbox.setUnreadOnly(!mailbox.unreadOnly) } label: {
                        Label("Unread Only", systemImage: mailbox.unreadOnly
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityValue(mailbox.unreadOnly ? "On" : "Off")
                    .accessibilityIdentifier("mailbox.toolbar.filter")
                }
            }
            MobileMailBottomBar.searchAskMailCompose(
                openSearch: openSearch,
                askMail: askMail,
                compose: compose,
                allowsMutations: allowsMutations
            )
        }
        .confirmationDialog(
            moreRow.map { MobileRowText(row: $0).subject } ?? "",
            isPresented: Binding(get: { moreRow != nil }, set: { if !$0 { moreRow = nil } }),
            titleVisibility: .visible,
            presenting: moreRow
        ) { row in
            rowActions(row, includesPrimary: false, showsIcons: false)
        }
        .sheet(item: $moveRow) { row in
            MoveToFolderSheet(
                folders: session.moveDestinations(forMessageID: row.id, excluding: kind.shownMailboxPath ?? "INBOX"),
                choose: { folder in act(.move(to: folder.path), row.id) }
            )
        }
    }

    private func refresh() async {
        await environment.sync()
        // Node accounts have no host sync: reloading the snapshot is their refresh.
        session.refreshBus.bump()
    }

    /// The shown folder's load failure; nil for the inbox mailboxes.
    private var folderFailure: String? {
        guard case let .folder(ref) = kind, folderRows.folder == ref else { return nil }
        return folderRows.failure
    }

    private func retryFolder() {
        guard case let .folder(ref) = kind else { return }
        Task { await folderRows.load(ref, using: session.loadFolderRows) }
    }

    private func loadMoreIfLast(_ row: MessageRowModel) {
        guard row.id == rows.last?.id else { return }
        if case .folder = kind {
            Task { await folderRows.loadMore(using: session.loadFolderRows) }
            return
        }
        Task { await inboxSnapshot.loadMore(selectedMessageID: mailbox.selectedMessageID, destination: kind.destination) }
    }

    private var allowsMutations: Bool { session.allowsMailboxMutations() }

    /// The account whose saved drafts this list shows: only an account's Drafts folder has any.
    private var draftsAccountID: AccountID? {
        guard case let .folder(ref) = kind, ref.role == .drafts else { return nil }
        return ref.accountID
    }

    private func reloadSavedDrafts() {
        // An open composer may still be saving; the list catches up when it closes.
        guard !composeCoordinator.isPresented else { return }
        savedDrafts = draftsAccountID.map(session.localDrafts.load) ?? []
    }

    private func discard(_ draft: Draft) {
        do {
            try session.localDrafts.discard(draft)
        } catch {
            draftFailure = error.localizedDescription
        }
        reloadSavedDrafts()
    }

    /// The row's removal actions, primary first; an archive folder offers no Archive.
    private func removalActions(_ row: MessageRowModel) -> [InboxMailAction] {
        kind.removalActions(primary: session.removalAction(forMessageID: row.id), offersPermanentDelete: session.offersPermanentDelete)
    }

    /// False until the first snapshot (or, for a folder, its first load) has arrived.
    private var isLoaded: Bool {
        if case .folder = kind { return folderRows.isLoaded }
        return inboxSnapshot.hasRefreshed
    }

    private var emptyState: (title: String, detail: String) {
        kind.emptyState(unreadOnly: mailbox.unreadOnly, categoryTitle: mailbox.selectedCategory?.title)
    }

    private func act(_ action: InboxMailAction, _ messageID: String) {
        guard allowsMutations else { return }
        session.actions.perform(action, messageID: messageID, shownIn: kind.shownMailboxPath)
    }

    /// The row's actions. The context menu shows them with icons; the More dialog lists titles
    /// only, because a dialog button with an icon reaches VoiceOver as one button nested in another.
    @ViewBuilder
    private func rowActions(_ row: MessageRowModel, includesPrimary: Bool, showsIcons: Bool = true) -> some View {
        let removals = removalActions(row)
        let primary = removals[0]
        let secondary = removals.dropFirst().first
        Group {
            rowAction(row.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge", showsIcon: showsIcons) {
                act(row.isUnread ? .markRead : .markUnread, row.id)
            }
            rowAction(row.isFlagged ? "Unflag" : "Flag", systemImage: row.isFlagged ? "flag.slash" : "flag", showsIcon: showsIcons) {
                act(row.isFlagged ? .unflag : .flag, row.id)
            }
            rowAction("Move to…", systemImage: "folder", showsIcon: showsIcons) {
                moveRow = row
            }
            rowAction("Reply", systemImage: "arrowshape.turn.up.left", showsIcon: showsIcons) {
                Task { await session.composeFromList(.reply(messageID: row.id), messageID: row.id, destination: kind.destination) }
            }
            rowAction("Forward", systemImage: "arrowshape.turn.up.right", showsIcon: showsIcons) {
                Task { await session.composeFromList(.forward(messageID: row.id), messageID: row.id, destination: kind.destination) }
            }
            if let secondary {
                rowAction(kind.removalTitle(for: secondary), systemImage: MailRemovalPolicy.systemImage(for: secondary), showsIcon: showsIcons) {
                    act(secondary, row.id)
                }
            }
            if includesPrimary {
                rowAction(kind.removalTitle(for: primary), systemImage: MailRemovalPolicy.systemImage(for: primary), role: .destructive, showsIcon: showsIcons) {
                    act(primary, row.id)
                }
            }
        }
        .disabled(!allowsMutations)
    }

    @ViewBuilder
    private func rowAction(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        showsIcon: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if showsIcon {
            Button(title, systemImage: systemImage, role: role, action: action)
        } else {
            Button(title, role: role, action: action)
        }
    }
}

/// The long-press preview: the message as its row reads, with more of the preview.
private struct MobileMessagePreview: View {
    let row: MessageRowModel

    var body: some View {
        let text = MobileRowText(row: row)
        VStack(alignment: .leading, spacing: 6) {
            Text(text.sender).font(.headline)
            Text(text.subject).font(.subheadline.weight(.semibold))
            Text(text.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(8)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

extension MessageRowModel {
    /// A stand-in row for the redacted first-load placeholder.
    static func mobilePlaceholder(_ index: Int) -> MessageRowModel {
        MessageRowModel(
            id: "placeholder-\(index)", sender: "sender@example.com", senderDisplayName: "Placeholder Sender",
            subject: "Loading the subject line", preview: "Loading the first lines of this message preview",
            category: .personal, categoryLabel: "", isUnread: false, isPinned: false, dateLabel: "00:00", actions: []
        )
    }
}
private struct SavedDraftsLoadKey: Equatable {
    let accountID: AccountID?
    let composerOpen: Bool
    let refreshRevision: Int
}

/// A draft saved in the composer: who it's to, its subject, and how it starts.
struct MobileSavedDraftRow: View {
    let draft: Draft

    var body: some View {
        let summary = SavedDraftSummary(draft)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Draft").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text(summary.recipients).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Text(summary.subject).font(.subheadline).lineLimit(1)
            if !summary.preview.isEmpty {
                Text(summary.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the draft")
    }
}
#endif
