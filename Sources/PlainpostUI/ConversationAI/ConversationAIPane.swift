import PlainpostAI
import PlainpostCore
import SwiftUI

/// The ✦ pane for one conversation, the same on every platform: the summary, Translate, Draft
/// reply and Ask about this conversation. The iPhone shows it in a sheet, the iPad in a popover
/// and the Mac in the reader's inspector. Nothing is sent from it.
struct ConversationAIPane: View {
    @ObservedObject private var model: ConversationAIPaneModel
    @ObservedObject private var assistant: ThreadAIAssistantViewModel
    @ObservedObject private var translation: ThreadTranslationViewModel
    @ObservedObject private var askMail: AskMailViewModel
    @State private var question = ""
    private let translationLanguage: TranslationLanguageOption
    private let readOnlyReason: String?
    private let dismissAfterTranslate: (() -> Void)?
    private let openCompose: (ComposeRequest) -> Void
    private let close: (() -> Void)?
    private let didEnterAsk: () -> Void

    /// - Parameters:
    ///   - readOnlyReason: why replies can't be sent, while the account is read-only.
    ///   - dismissAfterTranslate: closes the sheet (iPhone) or popover (iPad) so the translated
    ///     bodies show; the Mac inspector passes nil and stays open.
    ///   - openCompose: opens Compose with the previewed draft.
    ///   - close: the inspector's close button; nil hides it.
    ///   - didEnterAsk: the iPhone grows its sheet to full height when the Ask route opens.
    init(
        model: ConversationAIPaneModel,
        translationLanguage: TranslationLanguageOption,
        readOnlyReason: String?,
        dismissAfterTranslate: (() -> Void)?,
        openCompose: @escaping (ComposeRequest) -> Void,
        close: (() -> Void)? = nil,
        didEnterAsk: @escaping () -> Void = {}
    ) {
        _model = ObservedObject(wrappedValue: model)
        _assistant = ObservedObject(wrappedValue: model.assistant)
        _translation = ObservedObject(wrappedValue: model.translation)
        _askMail = ObservedObject(wrappedValue: model.askMail)
        self.translationLanguage = translationLanguage
        self.readOnlyReason = readOnlyReason
        self.dismissAfterTranslate = dismissAfterTranslate
        self.openCompose = openCompose
        self.close = close
        self.didEnterAsk = didEnterAsk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.context == nil {
                        Text("Open a conversation to use AI on it.")
                            .font(.callout)
                            .foregroundStyle(MailDesign.secondaryText)
                    } else {
                        routeContent
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(MailDesign.background)
        .onAppear { model.paneDidAppear() }
        .onDisappear { model.paneDidDisappear() }
        .onChange(of: model.route) { _, route in
            if route == .ask { didEnterAsk() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if model.route != .overview {
                Button { model.showOverview() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("conversation.ai.back")
            }
            Text("✦ \(title)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(model.localityLabel)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
                .accessibilityIdentifier("conversation.ai.locality")
            if let close {
                Button(action: close) {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("conversation.ai.close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var title: String {
        switch model.route {
        case .overview: "This conversation"
        case .draft: "Draft reply"
        case .ask: "Ask"
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch model.route {
        case .overview: overview
        case .draft: draftRoute
        case .ask: askRoute
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            summarySection
            detectedActionsRow
            actionButtons
            askSection(prompt: "Ask about this conversation…")
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.purple)
                Group {
                    if model.offersSummarize {
                        Text("Not summarized yet.")
                            .foregroundStyle(MailDesign.secondaryText)
                    } else if !model.summaryIsCurrent || assistant.isWorking {
                        ProgressView("Summarizing…")
                    } else if let summary = assistant.summaryText {
                        Text(AISummaryMarkdown.attributedString(from: summary))
                    } else {
                        Text(assistant.statusMessage ?? assistant.summaryAvailability.reason ?? "Summary unavailable.")
                            .foregroundStyle(MailDesign.secondaryText)
                    }
                }
                .font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversation.ai.summary")
            if model.offersSummarize {
                Button("Summarize") { model.summarize() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("conversation.ai.summarize")
            } else if summaryOffersCheckAgain {
                checkAgainButton
            }
        }
    }

    /// AI was unavailable for the summary, or the summary failed to load.
    private var summaryOffersCheckAgain: Bool {
        assistant.summaryAvailability.canCheckAgain || model.summaryFailed
    }

    private var checkAgainButton: some View {
        Button("Check again") { model.checkAgain() }
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("conversation.ai.check-again")
    }

    /// Hidden while detecting and when nothing was found.
    @ViewBuilder
    private var detectedActionsRow: some View {
        if !model.isDetectingActions, !model.detectedActions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                AskMailFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(model.detectedActions) { action in
                        detectedActionChip(action)
                    }
                }
                ForEach(model.detectedActions) { action in
                    if case .failed(let message) = model.status(for: action) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(MailDesign.secondaryText)
                    }
                }
            }
        }
    }

    /// The same wording as Ask Mail's cards once an action is done.
    @ViewBuilder
    private func detectedActionChip(_ action: ConversationDetectedAction) -> some View {
        switch model.status(for: action) {
        case .eventAdded:
            Label("Added to Calendar", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .symbolRenderingMode(.multicolor)
        case .reminderAdded:
            Label("Reminder added", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .symbolRenderingMode(.multicolor)
        case .failed, nil:
            Button(action.title) {
                Task { await model.perform(action) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isPerforming(action))
            .accessibilityIdentifier("conversation.ai.action.\(action.kind.rawValue)")
        }
    }

    private var actionButtons: some View {
        let draftAvailability = model.draftAvailability(readOnlyReason: readOnlyReason)
        let translationReason = translation.statusMessage
            ?? (translation.displayMode == .original ? translation.actionAvailability.reason : nil)
        return VStack(alignment: .leading, spacing: 6) {
            AskMailFlowLayout(spacing: 8, lineSpacing: 8) {
                Button {
                    model.toggleTranslation(configuration: translationConfiguration)
                    dismissAfterTranslate?()
                } label: {
                    Label(
                        model.translateButtonTitle(targetLanguageName: translationLanguage.localizedName),
                        systemImage: "translate"
                    )
                }
                .disabled(
                    translation.isTranslating
                        || (translation.displayMode == .original && !translation.actionAvailability.isAvailable)
                )
                .accessibilityIdentifier("conversation.ai.translate")

                Button { model.showDraft() } label: {
                    Label("Draft reply", systemImage: "sparkles")
                }
                .disabled(!draftAvailability.isAvailable)
                .accessibilityIdentifier("conversation.ai.draft")
            }
            .buttonStyle(.bordered)
            if let translationReason {
                Text(translationReason)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            if let reason = draftAvailability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .accessibilityIdentifier("conversation.ai.draft.reason")
            }
            if translation.actionAvailability.canCheckAgain || assistant.replyAvailability.canCheckAgain,
               !summaryOffersCheckAgain {
                checkAgainButton
            }
        }
    }

    private var translationConfiguration: ThreadTranslationConfiguration {
        ThreadTranslationConfiguration(
            targetLanguageID: translationLanguage.id,
            targetLanguageName: translationLanguage.localizedName
        )
    }

    // MARK: Ask

    private func askSection(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(prompt, text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitQuestion() }
                .disabled(askMail.isWorking || !askMail.actionAvailability.isAvailable)
                .accessibilityIdentifier("conversation.ai.ask-field")
            if let reason = askMail.actionAvailability.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
        }
    }

    private func submitQuestion() {
        guard model.ask(question) != nil else { return }
        question = ""
    }

    /// Ask Mail's own turn and block views, hosted as they are; answers cite their messages.
    private var askRoute: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("This conversation only")
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
            ForEach(askMail.turns) { turn in
                AskMailTurnView(
                    turn: turn,
                    viewModel: askMail,
                    onCitation: { number in
                        if let citation = turn.answer.citations.first(where: { $0.number == number }) {
                            askMail.host.openMessage(citation.source)
                        }
                    },
                    onChangeSearch: { question = turn.question }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.ai.turn")
            }
            if let pending = askMail.pendingQuestion {
                VStack(alignment: .leading, spacing: 12) {
                    AskMailQuestionBubble(question: pending)
                    if askMail.isWorking {
                        ProgressView(askMail.statusMessage ?? "Searching mail…")
                    }
                }
            }
            if let status = askMail.statusMessage, !askMail.isWorking {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            askSection(prompt: "Ask a follow-up…")
        }
    }

    // MARK: Draft reply

    private var draftRoute: some View {
        VStack(alignment: .leading, spacing: 12) {
            AskMailFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(ConversationDraftTone.allCases) { tone in
                    Button(tone.title) { model.chooseTone(tone) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.draftTone == tone ? .purple : nil)
                        .disabled(model.draftState == .drafting)
                        .accessibilityIdentifier("conversation.ai.tone.\(tone.rawValue)")
                        .accessibilityAddTraits(model.draftTone == tone ? .isSelected : [])
                }
            }
            if model.draftTone == .custom {
                TextField("How should it reply?", text: $model.draftInstructions, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { model.submitCustomInstructions() }
                    .accessibilityIdentifier("conversation.ai.draft.instructions")
                Button("Draft") { model.submitCustomInstructions() }
                    .buttonStyle(.bordered)
                    .disabled(
                        model.draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.draftState == .drafting
                    )
                    .accessibilityIdentifier("conversation.ai.draft.custom-submit")
            }
            draftPreview
        }
    }

    @ViewBuilder
    private var draftPreview: some View {
        switch model.draftState {
        case .idle:
            Text("Pick a tone to draft a reply.")
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
        case .drafting:
            ProgressView("Drafting…")
                .accessibilityIdentifier("conversation.ai.draft.progress")
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
                .accessibilityIdentifier("conversation.ai.draft.failure")
        case .ready:
            if let draft = model.draftPreview {
                // Markdown, as Compose shows the same body.
                Text(AISummaryMarkdown.attributedString(from: draft.bodyMarkdown ?? draft.bodyPlain))
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("conversation.ai.draft.preview")
                HStack(spacing: 8) {
                    Button { model.regenerateDraft() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("conversation.ai.draft.regenerate")
                    Button("Edit in Compose") {
                        guard let request = model.editInComposeRequest(readOnlyReason: readOnlyReason) else { return }
                        openCompose(request)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(readOnlyReason != nil)
                    .accessibilityIdentifier("conversation.ai.draft.edit")
                }
            }
        }
    }
}
