import PlainpostCore
import SwiftUI

struct AskMailEmptyStateLayout {
    static let introductionTopPadding: CGFloat = 24
}

public struct AskMailInspectorWorkspace: View {
    @ObservedObject private var viewModel: AskMailViewModel
    private let activeContext: AskMailActiveContext?
    private let close: () -> Void
    @State private var showsPrivacy = false
    @FocusState private var inputFocused: Bool

    public init(
        viewModel: AskMailViewModel,
        activeContext: AskMailActiveContext? = nil,
        close: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.activeContext = activeContext
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            #if os(macOS)
            Divider()
            #endif
            content
            if viewModel.actionAvailability.reason == nil {
                AskMailComposer(viewModel: viewModel, inputFocused: $inputFocused)
            }
        }
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 420, maxHeight: .infinity)
        .background(MailDesign.background)
        .onAppear {
            viewModel.setActiveContext(activeContext)
            viewModel.refreshAvailability()
            viewModel.refreshStarters()
        }
        // Leaving Ask Mail cancels an unanswered question and its queued AI job.
        .onDisappear {
            if viewModel.isWorking { viewModel.stop() }
        }
        .onChange(of: activeContext) { _, context in
            viewModel.setActiveContext(context)
        }
    }

    // MARK: Header

    private var header: some View {
        Group {
            #if os(iOS)
            ViewThatFits(in: .horizontal) {
                fullHeader
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        headerTitle
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        newConversationButton
                        closeButton
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            #else
            fullHeader
                .padding(.horizontal, 14)
                .frame(height: 52)
            #endif
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 8) {
            headerTitle
            Spacer(minLength: 0)
            newConversationButton
            closeButton
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 4) {
            Text("Ask Mail").font(.headline)
            privacyButton
        }
    }

    private var privacyButton: some View {
        Button { showsPrivacy.toggle() } label: {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MailDesign.tertiaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Privacy")
        .popover(isPresented: $showsPrivacy) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AskMailPrivacyCopy.title(localOnly: viewModel.localOnly)).font(.headline)
                Text(AskMailPrivacyCopy.body(providerName: viewModel.providerName, localOnly: viewModel.localOnly))
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }

    private var newConversationButton: some View {
        headerButton("square.and.pencil", label: "New conversation") {
            viewModel.newConversation()
            viewModel.refreshStarters()
        }
    }

    private var closeButton: some View {
        headerButton("xmark", label: "Close Ask Mail", action: close)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                #if os(iOS)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MailDesign.primaryText)
                .frame(width: 34, height: 34)
                .background(MailDesign.control, in: Circle())
                #else
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MailDesign.secondaryText)
                .frame(width: 28, height: 28)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.turns.isEmpty, !viewModel.isWorking, viewModel.pendingQuestion == nil {
            if let reason = viewModel.actionAvailability.reason {
                unavailableState(reason: reason)
            } else {
                AskMailEmptyStateView(starters: viewModel.starters, ask: ask)
            }
        } else {
            VStack(spacing: 0) {
                if let reason = viewModel.actionAvailability.reason {
                    unavailableHistoryNotice(reason: reason)
                }
                transcript
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(viewModel.turns) { turn in
                        AskMailTurnView(
                            turn: turn,
                            viewModel: viewModel,
                            onCitation: { cite($0, in: turn, proxy: proxy) },
                            onChangeSearch: {
                                viewModel.input = turn.question
                                inputFocused = true
                            }
                        )
                        .id(turn.id)
                    }
                    if let pending = viewModel.pendingQuestion {
                        VStack(alignment: .leading, spacing: 12) {
                            AskMailQuestionBubble(question: pending)
                            if viewModel.isWorking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(viewModel.statusMessage ?? "Searching your mail…")
                                        .font(.subheadline)
                                        .foregroundStyle(MailDesign.secondaryText)
                                }
                            }
                        }
                        .id("working")
                    }
                }
                .padding(16)
            }
            // On a compact iPhone the keyboard leaves little room for an
            // answer; scrolling it puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: viewModel.turns.count) { _, _ in
                if let lastID = viewModel.turns.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(lastID, anchor: .top) }
                }
            }
            .onChange(of: viewModel.pendingQuestion) { _, pending in
                if pending != nil {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("working", anchor: .top) }
                }
            }
        }
    }

    /// A citation scrolls to its quote when the answer has one, otherwise opens the cited email.
    private func cite(_ number: Int, in turn: AskMailTurn, proxy: ScrollViewProxy) {
        let hasQuote = turn.answer.blocks.contains { block in
            if case .quotes(let quotes) = block { return quotes.quotes.contains { $0.number == number } }
            return false
        }
        if hasQuote {
            withAnimation { proxy.scrollTo(AskMailBlockView.quoteAnchor(turnID: turn.id, number: number), anchor: .center) }
        } else if let citation = turn.answer.citations.first(where: { $0.number == number }) {
            viewModel.host.openMessage(citation.source)
        }
    }

    // MARK: Unavailable

    private func unavailableState(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(MailDesign.secondaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Ask Mail is unavailable")
                    .font(.title3.weight(.semibold))
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.ask-mail.unavailable")
            }

            if viewModel.actionAvailability.canCheckAgain {
                Button("Check AI availability", systemImage: "arrow.clockwise") {
                    viewModel.checkAvailability()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                if let lastCheck = viewModel.lastAvailabilityCheck {
                    Text("Checked at \(lastCheck.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .accessibilityIdentifier("ai.last-availability-check")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, AskMailEmptyStateLayout.introductionTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func unavailableHistoryNotice(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Mail is unavailable")
                .font(.callout.weight(.semibold))
            Text(reason)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ai.ask-mail.unavailable")
            if viewModel.actionAvailability.canCheckAgain {
                Button("Check AI availability", systemImage: "arrow.clockwise") {
                    viewModel.checkAvailability()
                }
                .buttonStyle(.bordered)
                if let lastCheck = viewModel.lastAvailabilityCheck {
                    Text("Checked at \(lastCheck.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .accessibilityIdentifier("ai.last-availability-check")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(MailDesign.panel)
    }

    // MARK: Actions

    private func ask(_ question: String) {
        guard !viewModel.isWorking else { return }
        Task { await viewModel.ask(question) }
    }
}
