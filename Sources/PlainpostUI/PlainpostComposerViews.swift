import SwiftUI
import PlainpostCore

public struct ComposerWindow: View {
    @Environment(\.mailContactDirectoryModel) private var contactDirectory
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @ObservedObject var viewModel: ComposerViewModel
    @State private var isCloseConfirmationPresented = false
    let close: () -> Void
    let showsEmbeddedChrome: Bool
    let showsCommandBar: Bool

    public init(
        viewModel: ComposerViewModel,
        close: @escaping () -> Void,
        showsEmbeddedChrome: Bool = true,
        showsCommandBar: Bool = true
    ) {
        self.viewModel = viewModel
        self.close = close
        self.showsEmbeddedChrome = showsEmbeddedChrome
        self.showsCommandBar = showsCommandBar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsEmbeddedChrome {
                ComposerHeader(mode: viewModel.presentationMode, close: requestClose,
                               compact: isCompactHeight)
            }

            #if os(iOS)
            // With little height (an iPhone in landscape with the keyboard
            // up) the address fields and editor scroll between the pinned
            // header and command bar; with room, the editor fills it.
            ComposerScrollingContent(
                minimumEditorHeight: ComposerBodyEditor.minimumBlockHeight(
                    hasReplyContext: viewModel.replyContext != nil
                )
            ) {
                addressFields
            } editor: {
                bodyEditor
            }
            #else
            addressFields
            bodyEditor
            #endif

            if showsCommandBar {
                ComposerCommandBar(viewModel: viewModel, onSendScheduled: close)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MailDesign.background)
        .foregroundStyle(MailDesign.primaryText)
        #if os(macOS)
        .onExitCommand(perform: requestClose)
        #endif
        .task {
            await contactDirectory?.requestAccessAndRefresh()
        }
        #if os(iOS)
        .alert(
            "Keep this draft?",
            isPresented: $isCloseConfirmationPresented
        ) {
            Button("Keep Draft") {
                guard viewModel.hasUnsavedChanges else {
                    close()
                    return
                }
                Task {
                    do {
                        try await viewModel.saveDraft()
                        if !viewModel.hasUnsavedChanges { close() }
                    } catch {
                        // The composer keeps the message open and shows its save error.
                    }
                }
            }
            if viewModel.canDeleteSavedDraft || !viewModel.hasSavedDraft {
                Button("Delete Draft", role: .destructive) {
                    Task {
                        do {
                            try await viewModel.discardDraft()
                            close()
                        } catch {
                            // The composer stays open and shows its delete error.
                        }
                    }
                }
            } else {
                Button("Discard Changes", role: .destructive) { close() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.canDeleteSavedDraft || !viewModel.hasSavedDraft
                 ? "Keep it for later or delete it from this device."
                 : "Keep the saved draft or discard your latest changes.")
        }
        #endif
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerFromRow(viewModel: viewModel)
            ComposerAddressFields(
                to: $viewModel.to,
                cc: $viewModel.cc,
                bcc: $viewModel.bcc,
                subject: $viewModel.subject
            )
        }
        .disabled(viewModel.isWorking)
    }

    private var bodyEditor: some View {
        ComposerBodyEditor(
            bodyMarkdown: $viewModel.bodyMarkdown,
            placeholder: viewModel.presentationMode == .newMessage ? "Write your message..." : "Write your reply...",
            replyContext: viewModel.replyContext,
            includesQuotedHistory: $viewModel.includesQuotedHistory,
            close: requestClose
        )
        .disabled(viewModel.isWorking)
    }

    private func requestClose() {
        guard !viewModel.isWorking else { return }
        #if os(iOS)
        if (viewModel.hasUnsavedChanges || viewModel.hasSavedDraft) && !viewModel.isSendScheduled {
            isCloseConfirmationPresented = true
            return
        }
        #endif
        close()
    }

    private var isCompactHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}

#if os(iOS)
/// Scrolls the composer's address fields and editor. The editor is given the
/// viewport's remaining height, never less than it needs, so with room it
/// fills the composer and without it the whole block scrolls. One view tree in
/// both cases, so the editor keeps focus as the keyboard changes the height.
struct ComposerScrollingContent<Fields: View, Editor: View>: View {
    let minimumEditorHeight: CGFloat
    @ViewBuilder let fields: () -> Fields
    @ViewBuilder let editor: () -> Editor
    @State private var viewportHeight: CGFloat = 0
    @State private var fieldsHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                fields()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldsHeight = $0 }
                editor()
                    .frame(height: Self.editorHeight(
                        viewport: viewportHeight,
                        fields: fieldsHeight,
                        minimum: minimumEditorHeight
                    ))
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .frame(maxHeight: .infinity)
    }

    static func editorHeight(viewport: CGFloat, fields: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, viewport - fields)
    }
}
#endif

struct ComposerHeader: View {
    let mode: ComposerPresentationMode
    let close: () -> Void
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            if !compact {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MailDesign.tertiaryText.opacity(0.55))
                    .frame(width: 30, height: 4)
            }
            #endif

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                #if os(macOS)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(1)
                #endif
            }

            Spacer()

            #if os(macOS)
            Label("Local draft", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MailDesign.accentTeal)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(MailDesign.accentTeal.opacity(0.12), in: Capsule())
            #endif

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .iconButton(help: "Close composer")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, compact ? 6 : 14)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }
    }

    private var title: String {
        switch mode {
        case .newMessage:
            "New message"
        case .reply:
            "Reply draft"
        }
    }

    #if os(macOS)
    private var subtitle: String {
        switch mode {
        case .newMessage:
            "Compose and send from this device."
        case .reply(let recipient, let subject):
            "Reply to \(recipient.mailDisplayName) · \(subject)"
        }
    }
    #endif
}

struct ComposerAddressFields: View {
    @Binding var to: String
    @Binding var cc: String
    @Binding var bcc: String
    @Binding var subject: String
    @State private var showsCc: Bool
    @State private var showsBcc: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        to: Binding<String>,
        cc: Binding<String>,
        bcc: Binding<String>,
        subject: Binding<String>
    ) {
        self._to = to
        self._cc = cc
        self._bcc = bcc
        self._subject = subject
        self._showsCc = State(initialValue: Self.shouldRevealRecipientField(cc.wrappedValue))
        self._showsBcc = State(initialValue: Self.shouldRevealRecipientField(bcc.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ComposerFieldLabel("To")
                ComposerRecipientTextField(
                    label: "To",
                    placeholder: "Recipient name or email",
                    text: $to
                )

                Spacer(minLength: 8)

                if !showsCc {
                    recipientDisclosureButton("Cc") {
                        revealCc()
                    }
                }

                if !showsBcc {
                    recipientDisclosureButton("Bcc") {
                        revealBcc()
                    }
                }
            }
            .frame(height: 40)
            .zIndex(1)

            fieldSeparator

            if showsCc {
                recipientField("Cc", placeholder: "Carbon copy", text: $cc)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                fieldSeparator
            }

            if showsBcc {
                recipientField("Bcc", placeholder: "Blind carbon copy", text: $bcc)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                fieldSeparator
            }

            HStack(spacing: 12) {
                ComposerFieldLabel("Subject")
                TextField("Subject", text: $subject)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }
        .onChange(of: cc) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showsCc = true
            }
        }
        .onChange(of: bcc) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showsBcc = true
            }
        }
    }

    private func recipientField(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            ComposerFieldLabel(label)
            ComposerRecipientTextField(
                label: label,
                placeholder: placeholder,
                text: text
            )
        }
        .frame(height: 40)
    }

    static func shouldRevealRecipientField(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func recipientDisclosureButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 30, minHeight: 28)
            .contentShape(Rectangle())
            .help("Show \(title) field")
            .accessibilityLabel("Show \(title) recipient field")
    }

    private func revealCc() {
        if reduceMotion {
            showsCc = true
        } else {
            withAnimation(.snappy(duration: 0.20)) {
                showsCc = true
            }
        }
    }

    private func revealBcc() {
        if reduceMotion {
            showsBcc = true
        } else {
            withAnimation(.snappy(duration: 0.20)) {
                showsBcc = true
            }
        }
    }

    private var fieldSeparator: some View {
        Rectangle()
            .fill(MailDesign.stroke)
            .frame(height: 1)
    }
}

/// The account a draft goes out from, above To: a picker for a new message when there is
/// more than one account, the fixed address for a reply or forward, nothing with one account.
struct ComposerFromRow: View {
    @ObservedObject var viewModel: ComposerViewModel

    var body: some View {
        if viewModel.fromAccounts.count > 1 {
            row {
                Picker("From", selection: Binding(
                    get: { viewModel.fromAccountID },
                    set: { if let id = $0 { viewModel.selectFromAccount(id) } }
                )) {
                    ForEach(viewModel.fromAccounts, id: \.id) { account in
                        Text(account.email.rawValue).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("From")
                .accessibilityIdentifier("compose.from-picker")
            }
        } else if let address = viewModel.fixedFromAddress {
            row {
                Text(address)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("compose.from-address")
            }
        } else if viewModel.sendBlockedReason == ComposerViewModel.missingFromAccountReason {
            // A reply whose original's account is gone: say why Send is off.
            row {
                Text(ComposerViewModel.missingFromAccountReason)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("compose.from-unavailable")
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ComposerFieldLabel("From")
                content()
                Spacer(minLength: 8)
            }
            .frame(height: 40)
            Divider()
        }
    }
}

struct ComposerFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MailDesign.tertiaryText)
            .frame(width: 58, alignment: .leading)
    }
}

struct ComposerRecipientTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.mailContactDirectorySnapshot) private var contactDirectory
    @FocusState private var isFocused: Bool
    @State private var showsSuggestions = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isFocused)
            .accessibilityLabel("\(label) recipients")
            .onChange(of: text) { _, _ in
                updateSuggestionPresentation()
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    updateSuggestionPresentation()
                } else {
                    // Allow a suggestion button to receive its tap before a
                    // focus change dismisses the inline completion list.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if !isFocused { showsSuggestions = false }
                    }
                }
            }
            .onChange(of: contactDirectory) { _, _ in
                updateSuggestionPresentation()
            }
            .onSubmit {
                if let firstSuggestion = suggestions.first {
                    select(firstSuggestion)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsSuggestions {
                    ComposerRecipientSuggestions(
                        suggestions: Array(suggestions.prefix(4)),
                        select: select
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 38)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
                }
            }
            .zIndex(showsSuggestions ? 1 : 0)
    }

    private var suggestions: [MailContact] {
        contactDirectory.suggestions(
            matching: ComposerRecipientInput.activeFragment(in: text),
            excluding: ComposerRecipientInput.completedAddresses(in: text)
        )
    }

    private func updateSuggestionPresentation() {
        showsSuggestions = isFocused && !suggestions.isEmpty
    }

    private func select(_ contact: MailContact) {
        text = ComposerRecipientInput.replacingActiveFragment(
            in: text,
            with: contact.emailAddress
        )
        showsSuggestions = false
        isFocused = true
    }
}

struct ComposerRecipientSuggestions: View {
    let suggestions: [MailContact]
    let select: (MailContact) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { contact in
                    Button {
                        select(contact)
                    } label: {
                        HStack(spacing: 10) {
                            MailContactPhoto(contact: contact, size: 30)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(MailDesign.primaryText)
                                    .lineLimit(1)
                                Text(contact.emailAddress)
                                    .font(.caption)
                                    .foregroundStyle(MailDesign.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(contact.displayName), \(contact.emailAddress)")

                    if contact.id != suggestions.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .frame(maxHeight: 4 * 46)
        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MailDesign.stroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityIdentifier("composer.recipient-suggestions")
    }
}

struct ComposerBodyEditor: View {
    /// On iOS the editor shrinks to make room for the keyboard, so the
    /// address fields and Send bar stay on screen.
    static var minimumEditorHeight: CGFloat {
        #if os(iOS)
        72
        #else
        260
        #endif
    }

    #if os(iOS)
    /// The whole editor block at its smallest: formatting toolbar, text view,
    /// top padding and, for a reply, the quoted-history disclosure.
    static func minimumBlockHeight(hasReplyContext: Bool) -> CGFloat {
        minimumEditorHeight + 56 + (hasReplyContext ? 56 : 0)
    }
    #endif

    @Binding var bodyMarkdown: String
    let placeholder: String
    let replyContext: ComposerReplyContext?
    @Binding var includesQuotedHistory: Bool
    let close: () -> Void
    @StateObject private var editor = MarkdownComposerController()

    init(
        bodyMarkdown: Binding<String>,
        placeholder: String,
        replyContext: ComposerReplyContext? = nil,
        includesQuotedHistory: Binding<Bool> = .constant(true),
        close: @escaping () -> Void = {}
    ) {
        self._bodyMarkdown = bodyMarkdown
        self.placeholder = placeholder
        self.replyContext = replyContext
        self._includesQuotedHistory = includesQuotedHistory
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownFormattingToolbar(controller: editor)
            MarkdownComposerTextView(
                markdown: $bodyMarkdown,
                controller: editor,
                placeholder: placeholder,
                onCancel: close
            )
            .frame(minHeight: Self.minimumEditorHeight, maxHeight: .infinity)

            if let replyContext {
                ComposerQuotedHistoryDisclosure(
                    context: replyContext,
                    isIncluded: $includesQuotedHistory
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

private struct ComposerQuotedHistoryDisclosure: View {
    let context: ComposerReplyContext
    @Binding var isIncluded: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        isExpanded ? "Hide quoted message" : "Show quoted message",
                        systemImage: isExpanded ? "chevron.down" : "ellipsis"
                    )
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))

                Text(context.senderName)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(1)

                Spacer()

                Toggle("Include in reply", isOn: $isIncluded)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(.switch)
                    #endif
                    .font(.caption)
            }

            if isExpanded {
                ScrollView {
                    Text(context.quotedBody)
                        .font(.callout)
                        .foregroundStyle(MailDesign.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }
    }
}

public struct ComposerToolbarStatusCapsule: View {
    public let isWorking: Bool
    public let message: String
    public let tint: Color

    public init(isWorking: Bool, message: String, tint: Color = .primary) {
        self.isWorking = isWorking
        self.message = message
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else {
                Image(systemName: "checkmark.circle.fill")
            }
            Text(message)
                #if os(iOS)
                .fixedSize(horizontal: false, vertical: true)
                #else
                .lineLimit(1)
                #endif
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct UndoSendPendingPresentation: Equatable {
    let message: String
    let symbol: String
    let actionTitle: String?

    init(deadline: Date, date: Date) {
        guard date < deadline else {
            message = "Sending…"
            symbol = "clock.fill"
            actionTitle = nil
            return
        }

        let seconds = max(0, Int(deadline.timeIntervalSince(date).rounded(.up)))
        message = "Sending in \(seconds)s"
        symbol = "clock"
        actionTitle = "Undo"
    }
}

struct UndoSendSnackbar: View {
    let state: UndoSendSnackbarState
    let undo: () -> Void
    let openDraft: () -> Void

    init(
        state: UndoSendSnackbarState,
        undo: @escaping () -> Void,
        openDraft: @escaping () -> Void = {}
    ) {
        self.state = state
        self.undo = undo
        self.openDraft = openDraft
    }

    @ViewBuilder
    var body: some View {
        switch state {
        case let .pending(_, deadline):
            TimelineView(.periodic(from: Self.timelineStart(deadline: deadline), by: 1)) { context in
                let presentation = UndoSendPendingPresentation(deadline: deadline, date: context.date)
                content(
                    message: presentation.message,
                    symbol: presentation.symbol,
                    actionTitle: presentation.actionTitle,
                    action: undo
                )
            }
        case .sending:
            content(message: "Sending…", symbol: "paperplane.fill")
        case .uncertain:
            content(message: "Delivery uncertain. Check Sent mail before sending again.", symbol: "exclamationmark.triangle.fill")
                .accessibilityIdentifier("composer.send-status.uncertain")
        case .failed:
            content(
                message: "Couldn’t send. Draft saved.",
                symbol: "exclamationmark.triangle.fill",
                actionTitle: actionTitle,
                action: openDraft
            )
        case .sent:
            content(message: "Sent", symbol: "checkmark.circle.fill")
                .accessibilityIdentifier("composer.send-status.sent")
        case .queuedForSyncNode:
            content(message: Self.queuedMessage, symbol: "clock.arrow.circlepath")
        }
    }

    static func timelineStart(deadline: Date) -> Date {
        deadline.addingTimeInterval(-10)
    }

    var actionTitle: String? {
        switch state {
        case let .pending(_, deadline):
            UndoSendPendingPresentation(deadline: deadline, date: .now).actionTitle
        case .failed:
            "Open Draft"
        case .sending, .sent, .queuedForSyncNode, .uncertain:
            nil
        }
    }

    static let queuedMessage = "Queued for Sync Node"

    @ViewBuilder
    private func content(
        message: String,
        symbol: String,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 12) {
            Label(message, systemImage: symbol)
            if let actionTitle {
                Spacer(minLength: 12)
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout.weight(.medium))
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(MailDesign.stroke))
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }
}

struct ComposerCommandBar: View {
    @ObservedObject var viewModel: ComposerViewModel
    var onSendScheduled: () -> Void = {}
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        Group {
        #if os(iOS)
        HStack(spacing: 12) {
            if viewModel.statusMessage != nil {
                status
            }
            Spacer(minLength: 0)
            actions
        }
        #else
        HStack(spacing: 12) {
            status
            Spacer()
            actions
        }
        #endif
        }
        .padding(.horizontal, 18)
        .padding(.vertical, commandBarVerticalPadding)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(MailDesign.stroke).frame(height: 1) }
    }

    private var commandBarVerticalPadding: CGFloat {
        #if os(iOS)
        verticalSizeClass == .compact ? 6 : 14
        #else
        14
        #endif
    }

    private var status: some View {
        ComposerToolbarStatusCapsule(
            isWorking: viewModel.isWorking,
            message: viewModel.displayStatusMessage,
            tint: statusTint
        )
    }

    private var actions: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            Button("Save Draft") {
                Task {
                    do {
                        try await viewModel.saveDraft()
                    } catch {
                        // The view model exposes a safe, actionable status message.
                    }
                }
            }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!viewModel.canSaveDraft)
            #endif
            Button {
                Task {
                    do {
                        if try await viewModel.send() {
                            onSendScheduled()
                        }
                    } catch {
                        // The view model exposes a safe, actionable status message.
                    }
                }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .font(.callout.weight(.semibold))
            .opacity(viewModel.canSend ? 1 : 0.55)
            .disabled(!viewModel.canSend)
        }
    }

    private var statusTint: Color {
        if viewModel.statusMessage?.localizedCaseInsensitiveContains("could not") == true
            || viewModel.statusMessage?.localizedCaseInsensitiveContains("valid") == true {
            return Color(hex: 0xFF6B6B)
        }
        if viewModel.lastSentMessageID != nil || viewModel.lastDraftID != nil {
            return MailDesign.accentTeal
        }
        return MailDesign.secondaryText
    }
}
