#if os(iOS)
import PlainpostCore
import SwiftUI

/// A conversation: newest message first and expanded, earlier ones folded behind "N earlier
/// messages", and a bottom bar with Archive or Delete, a Reply menu, ✦ (the conversation's AI
/// pane, in a sheet) and Compose.
struct MobileConversationScreen: View {
    let session: MailSession
    let messageID: String
    let orderedMessageIDs: () -> [String]
    /// The list row the conversation was opened from: its sender, date and subject show
    /// while the thread loads.
    let listRow: MessageRowModel?
    let compose: (ComposeRequest) -> Void
    /// The mailbox list under this conversation, if any; an archive folder offers no Archive.
    let openedFrom: MobileMailbox?
    /// Why replies can't be sent while the account is read-only; nil while it's writable.
    let readOnlyReason: String?
    @ObservedObject private var mailbox: MailboxController
    @ObservedObject private var inboxSnapshot: InboxViewModelSnapshotStore
    @ObservedObject private var translation: ThreadTranslationViewModel
    @ObservedObject private var translationSettings: TranslationLanguageSettingsViewModel
    @ObservedObject private var aiProviderSettings: AIProviderSettingsViewModel
    @ObservedObject private var conversationAI: ConversationAIPaneModel
    @State private var showsEarlier = false
    @State private var allowsRemoteContent = false
    /// Settings ▸ Privacy: with blocking off, remote images load without asking.
    @AppStorage(PlainpostPrivacyPreference.blockRemoteImagesKey) private var blockRemoteImages = true
    @State private var detailsMessage: ThreadMessageModel?
    @State private var showsAIPane = false
    @State private var showsMoveSheet = false
    /// The message's flag as it was when the screen last looked; the action flips it.
    @State private var isFlagged = false
    @State private var aiPaneDetent: PresentationDetent = .medium
    /// Edit in Compose waits for the ✦ sheet to close: a second sheet can't open over it.
    @State private var composeAfterAIPane: ComposeRequest?

    init(
        session: MailSession,
        messageID: String,
        orderedMessageIDs: @escaping () -> [String],
        listRow: MessageRowModel? = nil,
        compose: @escaping (ComposeRequest) -> Void,
        openedFrom: MobileMailbox? = nil,
        readOnlyReason: String? = nil
    ) {
        self.session = session
        self.messageID = messageID
        self.orderedMessageIDs = orderedMessageIDs
        self.listRow = listRow
        self.compose = compose
        self.openedFrom = openedFrom
        self.readOnlyReason = readOnlyReason
        _mailbox = ObservedObject(wrappedValue: session.mailbox)
        _inboxSnapshot = ObservedObject(wrappedValue: session.inboxSnapshot)
        _translation = ObservedObject(wrappedValue: session.threadTranslation)
        _translationSettings = ObservedObject(wrappedValue: session.translationSettings)
        _aiProviderSettings = ObservedObject(wrappedValue: session.aiProviderSettings)
        _conversationAI = ObservedObject(wrappedValue: session.conversationAI)
    }

    /// The loaded thread, once it is this conversation's (the snapshot refreshes after open).
    private var thread: ThreadDetailModel? {
        let thread = inboxSnapshot.model.thread(for: mailbox.selectedDestination)
        return thread.messages.contains { $0.id == messageID } ? thread : nil
    }

    /// This conversation as the ✦ pane sees it, once its thread has loaded.
    private var aiContext: ConversationAIContext? {
        thread.flatMap { ConversationAIContext.make(selectedMessageID: messageID, thread: $0) }
    }

    private var translationConfiguration: ThreadTranslationConfiguration {
        let option = translationSettings.selectedOption
        return ThreadTranslationConfiguration(targetLanguageID: option.id, targetLanguageName: option.localizedName)
    }

    /// What translation is prepared for, keyed like the macOS reader: messages, language and provider.
    private var translationPreparationID: ThreadTranslationPreparationID? {
        guard let thread else { return nil }
        let provider = PlainpostRootView.translationProviderIdentity(providerID: aiProviderSettings.selectedProviderID)
        return ThreadTranslationPreparationID(
            orderedMessageIDs: thread.messages.map(\.id),
            orderedSourceFingerprints: thread.messages.map(\.translationSourceFingerprint),
            targetLanguageID: translationConfiguration.targetLanguageID,
            providerID: provider.providerID,
            modelID: provider.modelID
        )
    }

    private var removal: InboxMailAction {
        let primary = session.removalAction(forMessageID: messageID)
        return actionList?.removalActions(primary: primary, offersPermanentDelete: session.offersPermanentDelete).first ?? primary
    }

    /// The list this conversation's Archive and Delete act in, if it shows the message.
    private var actionList: MobileMailbox? {
        MobileMailbox.actionList(under: openedFrom, messageID: messageID, listMessageIDs: orderedMessageIDs())
    }
    private var allowsMutations: Bool { session.allowsMailboxMutations() }

    private var replyMenu: MobileReplyMenu {
        MobileReplyMenu(allowsMutations: allowsMutations)
    }

    private func adjacent(_ direction: MailboxController.Direction) -> String? {
        mailbox.adjacentMessageID(direction, in: orderedMessageIDs())
    }

    /// Opens the neighbouring conversation in place: the stack keeps one conversation level.
    private func openAdjacent(_ direction: MailboxController.Direction) {
        guard let next = adjacent(direction),
              case let .reader(_, returnContext) = mailbox.mailboxNavigation.route else { return }
        session.openMailboxMessage(next, destination: mailbox.selectedDestination, from: returnContext)
    }

    var body: some View {
        Group {
            if let thread {
                content(thread)
            } else if let listRow {
                loading(listRow)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Two separate ToolbarItems, not a ControlGroup: a ControlGroup collapses its
            // children into one platform control cluster for the accessibility tree, dropping
            // their .accessibilityIdentifier (Task 14 review). This keeps the same trailing,
            // joined-pill look while keeping each button's identifier reachable.
            ToolbarItem(placement: .topBarTrailing) {
                Button { openAdjacent(.previous) } label: { Label("Previous", systemImage: "chevron.up") }
                    .disabled(adjacent(.previous) == nil)
                    .accessibilityIdentifier("conversation.toolbar.previous")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { openAdjacent(.next) } label: { Label("Next", systemImage: "chevron.down") }
                    .disabled(adjacent(.next) == nil)
                    .accessibilityIdentifier("conversation.toolbar.next")
            }
            bottomBar
        }
        .sheet(item: $detailsMessage) { MobileRecipientDetailsSheet(message: $0) }
        .sheet(isPresented: $showsMoveSheet) {
            MoveToFolderSheet(
                folders: session.moveDestinations(forMessageID: messageID, excluding: actionList?.shownMailboxPath ?? "INBOX"),
                choose: { folder in
                    session.actions.perform(.move(to: folder.path), messageID: messageID, shownIn: actionList?.shownMailboxPath)
                }
            )
        }
        .task(id: messageID) { isFlagged = session.isMessageFlagged(messageID) }
        .sheet(isPresented: $showsAIPane, onDismiss: composeAfterClosingAIPane) { aiPane }
        // The pane follows this conversation; its summary is prepared as soon as the thread loads.
        .onChange(of: aiContext, initial: true) { _, context in
            conversationAI.setConversation(context)
        }
        // Leaving the conversation cancels the pane's work: nobody will see it.
        .onDisappear { conversationAI.leave(messageID: messageID) }
        .task(id: translationPreparationID) {
            guard let thread else { return }
            await translation.prepare(messages: thread.messages, configuration: translationConfiguration)
        }
    }

    /// Remote images load once the user shows them here, or always when blocking is off.
    private var loadsRemoteContent: Bool { allowsRemoteContent || !blockRemoteImages }

    private var title: String {
        guard let count = thread?.messages.count ?? listRow?.threadMessageCount, count > 1 else { return "" }
        return "\(count) Messages"
    }

    private var aiPane: some View {
        ConversationAIPane(
            model: conversationAI,
            translationLanguage: translationSettings.selectedOption,
            readOnlyReason: readOnlyReason,
            // Translate swaps the bodies in place: close the sheet so they show.
            dismissAfterTranslate: { showsAIPane = false },
            openCompose: closeAIPaneThenCompose,
            didEnterAsk: { aiPaneDetent = .large }
        )
        .presentationDetents([.medium, .large], selection: $aiPaneDetent)
        .onAppear {
            // Ask's replies and drafts take Edit in Compose's path: the sheet closes first.
            session.attachConversationAskMailHost(
                beforeOpening: { showsAIPane = false },
                openCompose: closeAIPaneThenCompose
            )
        }
    }

    /// Opens Compose with `request` once the ✦ sheet has closed.
    private func closeAIPaneThenCompose(_ request: ComposeRequest) {
        composeAfterAIPane = request
        showsAIPane = false
    }

    private func composeAfterClosingAIPane() {
        aiPaneDetent = .medium
        guard let request = composeAfterAIPane else { return }
        composeAfterAIPane = nil
        compose(request)
    }

    private func content(_ thread: ThreadDetailModel) -> some View {
        let newestFirst = Array(thread.messages.reversed())
        let earlier = Array(newestFirst.dropFirst())
        let blocked = Set(thread.messages.flatMap(\.blockedRemoteImageURLs)).count
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let code = thread.verificationCode {
                    VerificationCodeBanner(code: code)
                        .id(code)
                }
                if translation.isTranslating || translation.displayMode == .translated {
                    ConversationTranslationPill(
                        sourceLanguageName: conversationAI.sourceLanguageName,
                        progressText: translation.progressText,
                        showOriginal: { translation.showOriginal() }
                    )
                }
                if blocked > 0, !loadsRemoteContent {
                    RemoteImagesBanner(blockedCount: blocked, showImages: { allowsRemoteContent = true })
                }
                if let newest = newestFirst.first {
                    // As in the mockup, the subject sits under the newest message's header.
                    message(newest, expanded: true, subject: thread.subject.isEmpty ? "(No subject)" : thread.subject)
                }
                if !earlier.isEmpty {
                    Button {
                        withAnimation { showsEarlier.toggle() }
                    } label: {
                        Label(
                            showsEarlier ? "Hide earlier messages" : "\(earlier.count) earlier \(earlier.count == 1 ? "message" : "messages")",
                            systemImage: showsEarlier ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("conversation.earlier")
                    if showsEarlier {
                        ForEach(earlier) { message($0, expanded: false) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// The row's header and subject, laid out as the loaded message's, over a spinner for the body.
    private func loading(_ row: MessageRowModel) -> some View {
        let header = ThreadMessageModel(
            id: messageID,
            sender: row.sender,
            senderDisplayName: row.senderDisplayName,
            dateLabel: row.readerDateLabel,
            body: .plainText("")
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MobileThreadMessage(
                    message: header,
                    subject: row.subject.isEmpty ? "(No subject)" : row.subject,
                    displayedBody: header.renderedBodySnapshot,
                    allowsRemoteContent: false,
                    expanded: true,
                    bodyIsLoading: true,
                    openAttachment: session.openAttachment,
                    showDetails: {}
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func message(_ message: ThreadMessageModel, expanded: Bool, subject: String? = nil) -> some View {
        MobileThreadMessage(
            message: message,
            subject: subject,
            displayedBody: translation.displayedBody(for: message),
            allowsRemoteContent: loadsRemoteContent,
            expanded: expanded,
            openAttachment: session.openAttachment,
            showDetails: { detailsMessage = message }
        )
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                session.actions.perform(removal, messageID: messageID, shownIn: actionList?.shownMailboxPath)
            } label: {
                Label(actionList?.removalTitle(for: removal) ?? MailRemovalPolicy.title(for: removal), systemImage: MailRemovalPolicy.systemImage(for: removal))
            }
            .disabled(!allowsMutations)
            .accessibilityIdentifier("conversation.toolbar.remove")
            Menu {
                Button(isFlagged ? "Unflag" : "Flag", systemImage: isFlagged ? "flag.slash" : "flag") {
                    session.actions.perform(isFlagged ? .unflag : .flag, messageID: messageID, shownIn: actionList?.shownMailboxPath)
                    isFlagged.toggle()
                }
                .accessibilityIdentifier("conversation.more.flag")
                Button("Move to…", systemImage: "folder") { showsMoveSheet = true }
                    .accessibilityIdentifier("conversation.more.move")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(!allowsMutations)
            .accessibilityIdentifier("conversation.toolbar.more")
            // Read-only mail disables the reply items, not the menu.
            let menu = replyMenu
            Menu {
                Group {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(messageID: messageID)) }
                        .accessibilityIdentifier("conversation.reply-menu.reply")
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll(messageID: messageID)) }
                        .accessibilityIdentifier("conversation.reply-menu.reply-all")
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(.forward(messageID: messageID)) }
                        .accessibilityIdentifier("conversation.reply-menu.forward")
                }
                .disabled(!menu.allowsReplies)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .accessibilityIdentifier("conversation.toolbar.reply")
        }
        ToolbarItem(placement: .bottomBar) {
            Button { showsAIPane = true } label: {
                Label("Conversation AI", systemImage: "sparkles")
            }
            .disabled(thread == nil)
            .accessibilityIdentifier("conversation.toolbar.ai")
        }
        MobileMailBottomBar.composeTail(compose: { compose(.new) }, allowsMutations: allowsMutations)
    }
}

/// One message in a conversation: a header (avatar, name, time, recipients), the thread's
/// subject under the newest message's header, and, when expanded, its body with quoted
/// history folded behind "…".
private struct MobileThreadMessage: View {
    let message: ThreadMessageModel
    let subject: String?
    let displayedBody: RenderedEmailBody
    let allowsRemoteContent: Bool
    /// The thread is still loading: a spinner stands where the body will be.
    let bodyIsLoading: Bool
    let openAttachment: (MailAttachment) async -> Void
    let showDetails: () -> Void
    @State private var isExpanded: Bool
    @State private var showsQuoted = false
    @State private var originalFold: MobileQuoteSplitter.Fold?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        message: ThreadMessageModel,
        subject: String?,
        displayedBody: RenderedEmailBody,
        allowsRemoteContent: Bool,
        expanded: Bool,
        bodyIsLoading: Bool = false,
        openAttachment: @escaping (MailAttachment) async -> Void,
        showDetails: @escaping () -> Void
    ) {
        self.message = message
        self.subject = subject
        self.displayedBody = displayedBody
        self.allowsRemoteContent = allowsRemoteContent
        self.bodyIsLoading = bodyIsLoading
        self.openAttachment = openAttachment
        self.showDetails = showDetails
        _isExpanded = State(initialValue: expanded)
    }

    /// Plain text shown as written folds its quoted history; HTML, translations and bodies
    /// without a quote keep `ThreadMessageBlock`'s own display.
    private var fold: MobileQuoteSplitter.Fold? {
        displayedBody == message.renderedBodySnapshot ? originalFold : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let subject {
                Text(subject)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("mailbox.reader.subject")
            }
            if bodyIsLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityLabel("Loading message")
            } else if isExpanded {
                let fold = fold
                ThreadMessageBlock(
                    message: message,
                    displayedBody: fold?.body ?? displayedBody,
                    allowsRemoteContent: allowsRemoteContent,
                    openAttachment: openAttachment,
                    plainTextFont: .subheadline
                )
                .task(id: message.id) {
                    let folded = await MobileQuoteSplitter.fold(message)
                    guard !Task.isCancelled else { return }
                    originalFold = folded
                }
                if let quoted = fold?.quoted {
                    if showsQuoted {
                        Text(quoted).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Button("…") { showsQuoted = true }
                            .font(.headline)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Show quoted text")
                    }
                }
            }
            Divider()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            MailSenderAvatar(sender: MailSenderDisplay.address(message.sender), displayName: message.senderDisplayName, size: 36)
                .accessibilityHidden(true)
            // Each line takes only its text's height, so the recipients follow the name
            // directly however many lines it wraps to. Each button's 44 pt target reaches
            // past its text, over the space around it, without adding to the layout.
            VStack(alignment: .leading, spacing: 2) {
                // Two sibling buttons, not one inside another: VoiceOver reads the sender line
                // (which folds the message) and the recipients (which open the details) apart.
                Button { toggleExpanded() } label: {
                    senderLine
                        .padding(.vertical, Self.senderTargetOverhang)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -Self.senderTargetOverhang)
                .accessibilityHint(isExpanded ? "Collapses this message" : "Expands this message")
                if let line = MobileRowText.recipientLine(to: message.to, cc: message.cc) {
                    Button(action: showDetails) {
                        Text("\(line) ›").font(.footnote).foregroundStyle(.secondary)
                            .padding(.vertical, Self.recipientsTargetOverhang)
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -Self.recipientsTargetOverhang)
                    .accessibilityHint("Shows everyone on this message")
                }
            }
            // The name's first line centres on the avatar.
            .padding(.top, 7)
        }
        // The avatar folds the message too, as the whole header did before.
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded() }
    }

    /// How far each header button's tap target reaches past its text: a one-line headline
    /// (22 pt) and footnote (18 pt) each make a 44 pt target.
    private static let senderTargetOverhang: CGFloat = 11
    private static let recipientsTargetOverhang: CGFloat = 13

    /// Name and time on one line; at accessibility sizes the time moves under the name.
    @ViewBuilder
    private var senderLine: some View {
        let name = Text(MailSenderDisplay.name(displayName: message.senderDisplayName, address: message.sender))
            .font(.headline)
        let time = Text(message.dateLabel).font(.footnote).foregroundStyle(.secondary)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) { name; time }
        } else {
            HStack(alignment: .firstTextBaseline) {
                name
                Spacer(minLength: 8)
                time
            }
        }
    }

    private func toggleExpanded() {
        withAnimation { isExpanded.toggle() }
    }
}

/// Everyone on a message, from "To: … & N more ›".
private struct MobileRecipientDetailsSheet: View {
    let message: ThreadMessageModel

    var body: some View {
        NavigationStack {
            List {
                Section("From") {
                    Text(MailSenderDisplay.name(displayName: message.senderDisplayName, address: message.sender))
                    Text(MailSenderDisplay.address(message.sender)).foregroundStyle(.secondary)
                }
                if !message.to.isEmpty {
                    Section("To") { ForEach(message.to, id: \.self) { Text($0) } }
                }
                if !message.cc.isEmpty {
                    Section("Cc") { ForEach(message.cc, id: \.self) { Text($0) } }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
