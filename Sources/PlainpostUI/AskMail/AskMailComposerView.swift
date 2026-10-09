import PlainpostCore
import SwiftUI

/// Ask Mail input: rounded field, scope menu, current-conversation chip, Send or Stop.
struct AskMailComposer: View {
    @ObservedObject var viewModel: AskMailViewModel
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Ask or tell your mail…", text: $viewModel.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AskMailTypography.answer)
                    .lineLimit(1...5)
                    .accessibilityLabel("Ask Mail")
                    .focused(inputFocused)
                    .onSubmit(send)
                    #if os(iOS)
                    // A vertical field inserts a newline on Return instead of
                    // submitting, so Return typed into a question sends it.
                    .submitLabel(.send)
                    .onChange(of: viewModel.input) { old, new in
                        guard let question = AskMailReturnKey.submittedQuestion(old: old, new: new) else { return }
                        viewModel.input = question
                        send()
                    }
                    #endif
                    .disabled(viewModel.isWorking)
                HStack(spacing: 6) {
                    scopeMenu
                    contextChip
                    Spacer(minLength: 0)
                    sendOrStopButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MailDesign.stroke))

            if let status = viewModel.statusMessage, !viewModel.isWorking,
               status != viewModel.actionAvailability.reason {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(MailDesign.secondaryText)
                    .padding(.horizontal, 6)
            }
        }
        .padding(12)
    }

    private var scopeMenu: some View {
        Menu {
            Button("All mail") { viewModel.scope = .allMail }
            Button("This conversation") { viewModel.scope = .activeConversation }
                .disabled(viewModel.activeContext == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray")
                Text(viewModel.scope == .allMail ? "All mail" : "This conversation")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(MailDesign.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Search scope")
    }

    @ViewBuilder
    private var contextChip: some View {
        if let context = viewModel.activeContext {
            HStack(spacing: 4) {
                Text("Current: \(context.subject) · \(context.messageIDs.count)")
                    .lineLimit(1)
                Button {
                    viewModel.clearActiveContext()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove current conversation context")
            }
            .font(.caption2)
            .foregroundStyle(MailDesign.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(AskMailFill.soft, in: Capsule())
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if viewModel.isWorking {
            Button { viewModel.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MailDesign.background)
                    .frame(width: 28, height: 28)
                    .background(MailDesign.primaryText, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
            .opacity(viewModel.canSend ? 1 : 0.45)
            .accessibilityLabel("Ask")
        }
    }

    private func send() {
        guard viewModel.canSend else { return }
        Task { await viewModel.askCurrentQuestion() }
    }
}

/// Return in the iOS composer: one newline typed into a non-empty question
/// means "send". The keyboard may deliver it together with an autocorrected
/// last word, so a trailing newline counts too. Pastes are left alone.
enum AskMailReturnKey {
    static func submittedQuestion(old: String, new: String) -> String? {
        guard new.filter({ $0 == "\n" }).count == old.filter({ $0 == "\n" }).count + 1 else { return nil }
        let question: String
        if new.hasSuffix("\n") {
            question = String(new.dropLast())
        } else {
            let before = Array(old), after = Array(new)
            guard after.count == before.count + 1 else { return nil }
            let index = zip(before, after).prefix { $0 == $1 }.count
            guard after[index] == "\n", Array(after[..<index] + after[(index + 1)...]) == before else { return nil }
            question = old
        }
        return question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : question
    }
}
