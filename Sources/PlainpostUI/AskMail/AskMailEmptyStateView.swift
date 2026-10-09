import PlainpostCore
import SwiftUI

/// Empty Ask Mail: mailbox-computed starters plus three example questions.
struct AskMailEmptyStateView: View {
    let starters: [AskMailStarter]
    let ask: (String) -> Void

    static let exampleQuestions = [
        "Who hasn't replied to me this week?",
        "Find receipts from September",
        "What did we agree about the flat deposit?"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What do you need from your mail?")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                ForEach(starters) { starter in
                    starterCard(starter)
                }
                Text("Or ask")
                    .font(.caption)
                    .foregroundStyle(MailDesign.tertiaryText)
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.exampleQuestions, id: \.self) { question in
                        Button { ask(question) } label: {
                            Text(question)
                                .font(.subheadline)
                                .foregroundStyle(MailDesign.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, AskMailEmptyStateLayout.introductionTopPadding)
            .padding(.bottom, 16)
        }
    }

    private func starterCard(_ starter: AskMailStarter) -> some View {
        Button { ask(starter.question) } label: {
            HStack(spacing: 12) {
                Text(starter.count)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(MailDesign.primaryText)
                    .frame(minWidth: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(starter.title).font(.subheadline.weight(.semibold)).foregroundStyle(MailDesign.primaryText)
                    Text(starter.detail).font(.caption).foregroundStyle(MailDesign.secondaryText)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MailDesign.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
