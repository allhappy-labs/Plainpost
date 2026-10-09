import PlainpostCore
import SwiftUI

extension ThreadDetailModel {
    /// The sign-in code in the newest message; older messages' codes have
    /// usually expired.
    var verificationCode: String? {
        guard let newest = messages.last else { return nil }
        return VerificationCodeDetector.code(subject: subject, body: newest.safeBodyText)
    }
}

/// Shows the newest message's sign-in code above the conversation with a
/// one-tap Copy, so the code never has to be read out of the mail.
struct VerificationCodeBanner: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(MailDesign.accentTeal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Verification code")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                Text(Self.grouped(code))
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(MailDesign.primaryText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                MailClipboard.copy(code)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(copied ? MailDesign.accentTeal : .accentColor)
            #if os(macOS)
            .controlSize(.small)
            #endif
            .accessibilityIdentifier("conversation.verificationCode.copy")
            .accessibilityHint("Copies the code to the clipboard.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .mailControlBackground(cornerRadius: MailDesign.Radius.control)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verification code \(code)")
        .accessibilityIdentifier("conversation.verificationCode")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// "482913" reads as "482 913"; the copied value keeps no space.
    static func grouped(_ code: String) -> String {
        guard code.allSatisfy(\.isNumber), code.count == 6 || code.count == 8 else { return code }
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<half] + " " + code[half...]
    }
}
