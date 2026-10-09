#if os(iOS)
import PlainpostCore
import SwiftUI

/// The iPhone root: a compact large title, the mailboxes, then one collapsible section per
/// account listing its folders, then Activity while work is running. Every Direct account
/// shares the mailboxes; a Sync Node account switcher, when the host gives one, sits above
/// them until Sync Node accounts join the shared mailboxes.
/// Settings sits after Agent Approvals. There is no Edit button.
struct MobileMailboxesScreen: View {
    let session: MailSession
    @ObservedObject var environment: MobileMailEnvironment
    @ObservedObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @ObservedObject private var approvalQueue: ApprovalQueueViewModel
    @ObservedObject private var directory: MailboxDirectoryModel
    @ObservedObject private var activity: MailActivityCoordinator
    @ObservedObject private var aiProviderSettings: AIProviderSettingsViewModel
    let open: (MobileMailbox) -> Void
    let compose: () -> Void
    let openSearch: () -> Void
    let askMail: () -> Void
    @State private var collapsedAccounts: Set<AccountID> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        session: MailSession,
        environment: MobileMailEnvironment,
        open: @escaping (MobileMailbox) -> Void,
        compose: @escaping () -> Void,
        openSearch: @escaping () -> Void,
        askMail: @escaping () -> Void
    ) {
        self.session = session
        self.environment = environment
        _inboxSnapshot = ObservedObject(wrappedValue: session.inboxSnapshot)
        _approvalQueue = ObservedObject(wrappedValue: session.approvalQueue)
        _directory = ObservedObject(wrappedValue: session.directory)
        _activity = ObservedObject(wrappedValue: session.activity)
        _aiProviderSettings = ObservedObject(wrappedValue: session.aiProviderSettings)
        self.open = open
        self.compose = compose
        self.openSearch = openSearch
        self.askMail = askMail
    }

    /// Unread messages across every account's inbox, from the directory; until it has
    /// loaded, the loaded inbox's.
    private var inboxUnread: Int {
        directory.sections.isEmpty ? inboxSnapshot.model.classicRows.filter(\.isUnread).count : directory.inboxUnreadCount
    }

    var body: some View {
        List {
            Section {
                if aiProviderSettings.smartInboxEnabled {
                    mailboxRow(.smartInbox, systemImage: "sparkles", count: inboxUnread, id: "smartInbox")
                }
                mailboxRow(.allInboxes, systemImage: "tray.2", count: inboxUnread, id: "allInboxes")
                mailboxRow(.unread, systemImage: "envelope.badge", count: inboxUnread, id: "unread")
                NavigationLink(value: MobileRoute.approvals) {
                    MobileMailboxLabel(title: "Agent Approvals", systemImage: "checkmark.seal", count: approvalQueue.pendingItemCount, showsChevron: false)
                }
                .accessibilityIdentifier("mailboxes.row.approvals")
                NavigationLink(value: MobileRoute.settings) {
                    MobileMailboxLabel(title: "Settings", systemImage: "gearshape", count: 0, showsChevron: false)
                }
                .accessibilityIdentifier("mailboxes.row.settings")
            }
            ForEach(directory.sections) { section in
                Section {
                    // An account that can't sync says so in its header; this row opens what fixes it.
                    if let settingsTitle = section.status.settingsTitle {
                        NavigationLink(value: MobileRoute.settingsDestination(.account(section.id))) {
                            MobileMailboxLabel(title: settingsTitle, systemImage: "person.crop.circle.badge.exclamationmark",
                                               count: 0, showsChevron: false)
                        }
                        .accessibilityIdentifier("mailboxes.account-settings.\(section.id.rawValue)")
                    }
                    if !collapsedAccounts.contains(section.id) {
                        ForEach(section.folders) { folder in
                            Button {
                                open(.folder(MailFolderRef(accountID: folder.accountID, path: folder.path, name: folder.name, role: folder.role)))
                            } label: {
                                MobileMailboxLabel(title: folder.name, systemImage: MailboxFolder.systemImage(for: folder.role), count: folder.unread)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("mailboxes.folder.\(folder.id)")
                        }
                    }
                } header: {
                    Button {
                        if collapsedAccounts.contains(section.id) { collapsedAccounts.remove(section.id) }
                        else { collapsedAccounts.insert(section.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: section)).font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
                                if let status = section.status.message {
                                    Label(status, systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                        .accessibilityIdentifier("mailboxes.account-status.\(section.id.rawValue)")
                                }
                            }
                            Spacer()
                            Image(systemName: collapsedAccounts.contains(section.id) ? "chevron.forward" : "chevron.down")
                                .foregroundStyle(.tint)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    // Plain, so the title keeps the primary color and only the chevron is tinted.
                    .buttonStyle(.plain)
                    // VoiceOver keeps the directory's title (display name, else address): the
                    // accessibility audit rejects a bare address as a label. Voice Control also
                    // accepts the address shown on screen.
                    .accessibilityLabel(section.title)
                    .accessibilityInputLabels([section.title, title(for: section)])
                    .accessibilityValue(
                        ([collapsedAccounts.contains(section.id) ? "Collapsed" : "Expanded"] + [section.status.message].compactMap { $0 })
                            .joined(separator: ", ")
                    )
                    .accessibilityIdentifier("mailboxes.account.\(section.id.rawValue)")
                }
            }
            // Last and unpinned: it scrolls with the list and shows only while work runs.
            if !activity.activities.isEmpty {
                Section("Activity") {
                    ForEach(activity.activities) { item in
                        HStack(spacing: 12) {
                            if item.kind == .syncFailure {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            } else if let fraction = item.fraction {
                                ProgressView(value: fraction).frame(width: 36)
                            } else {
                                ProgressView()
                            }
                            // One line, as in the spec; at accessibility sizes it wraps in full.
                            Text(item.line)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            Spacer(minLength: 8)
                            if item.retry {
                                Button("Retry") { Task { await session.retry(item, environment: environment) } }
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier(item.retryAccessibilityIdentifier(in: activity.activities))
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("mailboxes.activity.\(item.id)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // The first group sits 10 pt under the title, as the mockup's spacer div measures
        // (mail-style-v5.html), not a header's height below.
        .contentMargins(.top, 10, for: .scrollContent)
        .onAppear { directory.setVisible(true) }
        .onDisappear { directory.setVisible(false) }
        .navigationTitle("Mailboxes")
        // The large title sits in the bar's own row, so there is no empty row above it.
        .toolbarTitleDisplayMode(.inlineLarge)
        .safeAreaInset(edge: .top, spacing: 0) { environment.banner }
        .toolbar {
            MobileMailBottomBar.searchAskMailCompose(
                openSearch: openSearch,
                askMail: askMail,
                compose: compose,
                allowsMutations: session.allowsMailboxMutations()
            )
        }
    }

    /// Each account section is titled with its address, as in the mockup; until the account
    /// list has the account, with the directory's title (display name, else address).
    private func title(for section: MailboxAccountSection) -> String {
        session.accountSetup.accounts.first { $0.id == section.id }?.email.rawValue ?? section.title
    }

    private func mailboxRow(_ kind: MobileMailbox, systemImage: String, count: Int, id: String) -> some View {
        Button { open(kind) } label: {
            MobileMailboxLabel(title: kind.title, systemImage: systemImage, count: count)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("mailboxes.row.\(id)")
    }
}

/// A Mailboxes row: tinted icon, title, unread count and a chevron. The whole list row is the
/// target; the list keeps it at least 44 pt tall, so the label adds no height of its own.
struct MobileMailboxLabel: View {
    let title: String
    let systemImage: String
    let count: Int
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.tint).frame(width: 24)
            Text(title)
            Spacer(minLength: 8)
            if count > 0 {
                Text(count, format: .number).foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
