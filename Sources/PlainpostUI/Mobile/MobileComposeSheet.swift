#if os(iOS)
import PlainpostCore
import SwiftUI
import UniformTypeIdentifiers

/// The iPhone Compose sheet for new mail, Reply, Reply All, Forward and AI replies. ✕ offers
/// Save Draft or Delete Draft; Send is top right and keeps the undo-send flow. A bar above
/// the keyboard holds formatting, Draft with AI and attachments.
struct MobileComposeSheet: View {
    @ObservedObject var composer: ComposerViewModel
    @ObservedObject var suggestions: RecipientSuggestionProvider
    /// A Sync Node runtime's account, shown when the user has more than one account. A Direct
    /// composer offers its own From choice instead (`composer.fromAccounts`).
    let fromAddress: String?
    /// Fills only the body with an AI reply to the composer's own reply message. ✦ is
    /// disabled when this is nil or the draft isn't a reply.
    let draftWithAI: (() async -> ComposerAIBodyResult)?
    /// Why this account can't send (it is read-only), shown above the fields; nil when it can.
    /// Send stays disabled while it is set.
    let readOnlyReason: String?
    /// The host's status lines (a held switch, a released failed send, a notification waiting
    /// for this draft). The sheet covers the screens that show them, so it shows them too.
    let banner: AnyView?
    let close: () -> Void
    @StateObject private var formatting = MarkdownComposerController()
    @State private var showsCcBcc = false
    @FocusState private var focus: MobileComposeField?
    @FocusState private var isBodyFocused: Bool
    @State private var isConfirmingClose = false
    @State private var isImporting = false
    @State private var importFailure: String?
    @State private var isDraftingAI = false
    @State private var isConfirmingAIReplace = false
    @State private var aiFailure: String?
    @State private var aiUndo: AIUndo?

    /// The address this draft goes out from, when there's more than one account to tell apart.
    private var shownFromAddress: String? {
        if composer.fromAccounts.count > 1 {
            return composer.fromAccounts.first { $0.id == composer.fromAccountID }?.email.rawValue
        }
        return composer.fixedFromAddress ?? fromAddress
    }

    /// The body ✦ replaced, offered back until the AI body is edited.
    private struct AIUndo {
        let previous: String
        let applied: String
    }

    private var title: String {
        let subject = composer.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? "New Message" : subject
    }

    var body: some View {
        NavigationStack {
            // The body fills what the fields leave, so a tap anywhere below them writes.
            ComposerScrollingContent(minimumEditorHeight: 200) {
                fields
            } editor: {
                MarkdownComposerTextView(
                    markdown: $composer.bodyMarkdown,
                    controller: formatting,
                    placeholder: "Write your message",
                    onCancel: {},
                    isFocused: $isBodyFocused
                )
                .padding(.horizontal, 12)
                .disabled(composer.isWorking || isDraftingAI)
                // A confirmationDialog nested inside this sheet renders as a compact popover
                // that drops the .cancel-role button entirely, regardless of
                // presentationCompactAdaptation (confirmed empirically: F-Task23b). .alert
                // never adapts to that popover form, so Cancel always stays visible.
                .alert(
                    "Replace your message with an AI draft?",
                    isPresented: $isConfirmingAIReplace
                ) {
                    Button("Replace with AI Draft", action: runAIDraft)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Recipients, subject and attachments stay. You can undo this.")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: requestClose) { Label("Close", systemImage: "xmark") }
                        .accessibilityIdentifier("compose.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(.glassProminent)
                        .disabled(!composer.canSend)
                        .accessibilityIdentifier("compose.send")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Menu {
                        Button("Bold", systemImage: "bold") { formatting.apply(.bold) }
                        Button("Italic", systemImage: "italic") { formatting.apply(.italic) }
                        Button("Bulleted List", systemImage: "list.bullet") { formatting.apply(.bulletList) }
                        Button("Numbered List", systemImage: "list.number") { formatting.apply(.numberedList) }
                        Button("Quote", systemImage: "text.quote") { formatting.apply(.quote) }
                        Button("Link", systemImage: "link") { formatting.apply(.link) }
                    } label: {
                        Label("Format", systemImage: "textformat")
                    }
                    Button(action: requestAIDraft) {
                        if isDraftingAI {
                            ProgressView()
                        } else {
                            Label("Draft with AI", systemImage: "sparkles")
                        }
                    }
                    .accessibilityLabel(isDraftingAI ? "Drafting with AI" : "Draft with AI")
                    .disabled(draftWithAI == nil || composer.replyContext == nil || isDraftingAI || composer.isWorking)
                    Button { isImporting = true } label: { Label("Attach", systemImage: "paperclip") }
                        .accessibilityIdentifier("compose.attach")
                        .disabled(composer.attachmentImport != nil)
                    Spacer()
                }
            }
            // Same reason as the AI-replace dialog above: .alert instead of confirmationDialog
            // keeps Cancel visible instead of collapsing into a Cancel-less popover.
            .alert("Keep this draft?", isPresented: $isConfirmingClose) {
                Button("Save Draft", action: saveAndClose)
                if composer.canDeleteSavedDraft || !composer.hasSavedDraft {
                    Button("Delete Draft", role: .destructive, action: deleteAndClose)
                } else {
                    // This draft was saved where the iPhone can't delete it.
                    Button("Discard Changes", role: .destructive, action: close)
                }
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): attach(urls)
                case .failure: importFailure = "Plainpost couldn't open the file picker."
                }
            }
            .alert("Attachment", isPresented: Binding(get: { importFailure != nil }, set: { if !$0 { importFailure = nil } })) {
                Button("OK") { importFailure = nil }
            } message: {
                Text(importFailure ?? "")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(composer.hasUnsavedChanges)
        .onChange(of: composer.isSendScheduled) { _, scheduled in
            if scheduled { close() }
        }
        .onChange(of: readOnlyReason, initial: true) { _, reason in
            composer.sendBlockedReason = reason
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let readOnlyReason {
                Label(readOnlyReason, systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("compose.read-only")
                Divider()
            }
            MobileRecipientField(title: "To", text: $composer.to, suggestions: suggestions, focus: $focus, field: .to, onReturn: { advance(from: .to) })
            Divider()
            if showsCcBcc || !composer.cc.isEmpty || !composer.bcc.isEmpty {
                MobileRecipientField(title: "Cc", text: $composer.cc, suggestions: suggestions, focus: $focus, field: .cc, onReturn: { advance(from: .cc) })
                Divider()
                MobileRecipientField(title: "Bcc", text: $composer.bcc, suggestions: suggestions, focus: $focus, field: .bcc, onReturn: { advance(from: .bcc) })
                Divider()
                if composer.fromAccounts.count > 1 {
                    Picker("From:", selection: Binding(
                        get: { composer.fromAccountID },
                        set: { if let id = $0 { composer.selectFromAccount(id) } }
                    )) {
                        ForEach(composer.fromAccounts, id: \.id) { account in
                            Text(account.email.rawValue).tag(Optional(account.id))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("compose.from-picker")
                    Divider()
                } else if let shownFromAddress {
                    LabeledContent("From:", value: shownFromAddress)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                    Divider()
                }
            } else {
                Button { showsCcBcc = true } label: {
                    Text(shownFromAddress.map { "Cc/Bcc, From: \($0)" } ?? "Cc/Bcc")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            TextField("Subject", text: $composer.subject)
                .focused($focus, equals: .subject)
                .submitLabel(.next)
                .onSubmit { advance(from: .subject) }
                .accessibilityLabel("Subject")
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            Divider()
            // A reopened saved draft already holds its quote, so it has nothing to toggle.
            if let reply = composer.replyContext, !reply.quotedBody.isEmpty {
                // The quoted message goes below the reply when it's sent.
                Toggle("Quote \(reply.senderName)'s message", isOn: $composer.includesQuotedHistory)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                Divider()
            }
            attachmentList
            if let progress = composer.attachmentImport {
                // An iCloud file that isn't on the iPhone yet downloads here.
                ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                    Text(progress.total == 1
                        ? "Attaching \(progress.filename)…"
                        : "Attaching \(progress.filename) (\(progress.completed + 1) of \(progress.total))…")
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .accessibilityIdentifier("compose.attaching")
            }
            aiStatus
            if composer.isLoadingForwardAttachments {
                ProgressView("Loading the forwarded files…").padding(16)
            }
            // Only something to report (saving, a failure, a forward's missing files), not the
            // standing "Unsaved changes".
            if composer.statusMessage != nil {
                Text(composer.displayStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .disabled(composer.isWorking)
    }

    /// ✦ Draft with AI's progress, failure, or Undo for the body it replaced.
    @ViewBuilder
    private var aiStatus: some View {
        if isDraftingAI {
            HStack(spacing: 8) {
                ProgressView()
                Text("Drafting a reply with AI…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
        } else if let aiFailure {
            Label(aiFailure, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        } else if let aiUndo, composer.bodyMarkdown == aiUndo.applied {
            HStack {
                Label("AI draft added. Review it before sending.", systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    composer.undoAIDraftBody(aiUndo.previous)
                    self.aiUndo = nil
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("compose.ai-undo")
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var attachmentList: some View {
        if !composer.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(composer.attachments, id: \.id) { attachment in
                    HStack {
                        Label(attachment.filename, systemImage: "paperclip").lineLimit(1)
                        Spacer()
                        Button {
                            composer.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                }
            }
            .padding(.horizontal, 16)
            Divider()
        }
    }

    /// Return moves To → Cc → Bcc (when shown) → Subject → the body.
    private func advance(from field: MobileComposeField) {
        let next = field.next(showsCcBcc: showsCcBcc || !composer.cc.isEmpty || !composer.bcc.isEmpty)
        if next == .body {
            focus = nil
            isBodyFocused = true
        } else {
            focus = next
        }
    }

    private func requestClose() {
        guard !composer.isWorking else { return }
        guard composer.hasUnsavedChanges || composer.hasSavedDraft, !composer.isSendScheduled else {
            close()
            return
        }
        isConfirmingClose = true
    }

    private func saveAndClose() {
        guard composer.hasUnsavedChanges else {
            close()
            return
        }
        Task {
            // A failed save keeps the sheet open with the composer's reason on screen.
            try? await composer.saveDraft()
            if !composer.hasUnsavedChanges { close() }
        }
    }

    private func deleteAndClose() {
        Task {
            do {
                try await composer.discardDraft()
                close()
            } catch {
                // The sheet stays open and shows why the draft couldn't be deleted.
            }
        }
    }

    /// Asks before an AI draft replaces text the user wrote.
    private func requestAIDraft() {
        if composer.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runAIDraft()
        } else {
            isConfirmingAIReplace = true
        }
    }

    private func runAIDraft() {
        guard let draftWithAI, !isDraftingAI else { return }
        aiFailure = nil
        aiUndo = nil
        isDraftingAI = true
        Task {
            let result = await draftWithAI()
            isDraftingAI = false
            switch result {
            case let .filled(previousBody): aiUndo = AIUndo(previous: previousBody, applied: composer.bodyMarkdown)
            case let .failed(message): aiFailure = message
            }
        }
    }

    private func send() {
        Task { _ = try? await composer.send() }
    }

    /// Attaches each picked file that fits, read off the main thread with progress below the
    /// fields; the rest are named with the reason.
    private func attach(_ urls: [URL]) {
        Task {
            let failures = await composer.importAttachments(from: urls) { url, existing in
                try MobileAttachmentImport.attachment(from: url, addingTo: existing)
            }
            if !failures.isEmpty { importFailure = failures.joined(separator: "\n") }
        }
    }
}
#endif
