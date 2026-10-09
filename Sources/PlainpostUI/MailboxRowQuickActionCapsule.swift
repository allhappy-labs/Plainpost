import SwiftUI

struct MailboxRowQuickActionCapsule: View {
    let messageID: String
    let hasEffectiveLabels: Bool
    let actionsDisabled: Bool
    @ObservedObject var focusCoordinator: MailboxRowQuickActionFocusCoordinator
    let archive: () -> Void
    let openLabels: () -> Void
    let delete: () -> Void
    let onFocusChange: (Bool) -> Void
    @FocusState private var focusedAction: MailboxRowQuickAction?

    static let labelSystemImage = "tag"

    private var labelAccessibilityLabel: String {
        hasEffectiveLabels ? "Add or remove labels" : "Add a label"
    }

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                title: "Archive",
                systemImage: "archivebox",
                foreground: MailDesign.secondaryText,
                disabled: actionsDisabled,
                quickAction: .archive,
                action: archive
            )
            separator
            labelButton
            separator
            actionButton(
                title: "Delete",
                systemImage: "trash",
                foreground: .red,
                disabled: actionsDisabled,
                quickAction: .delete,
                action: delete
            )
        }
        .padding(MailboxListMetrics.quickActionCapsuleInset)
        .frame(width: MailboxListMetrics.trailingActionSlotWidth)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(MailDesign.stroke.opacity(0.72), lineWidth: 1)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .onChange(of: focusedAction) { _, action in
            onFocusChange(action != nil)
        }
        .onAppear {
            acceptRequestedLabelFocus()
        }
        .onChange(of: focusCoordinator.requestedLabelMessageID) { _, _ in
            acceptRequestedLabelFocus()
        }
    }

    private func acceptRequestedLabelFocus() {
        guard focusCoordinator.requestedLabelMessageID == messageID else {
            return
        }
        onFocusChange(true)
        focusedAction = .labels
        _ = focusCoordinator.consumeLabelFocusRequest(for: messageID)
    }

    private var separator: some View {
        Rectangle()
            .fill(MailDesign.stroke.opacity(0.72))
            .frame(
                width: MailboxListMetrics.quickActionSeparatorWidth,
                height: 16
            )
            .accessibilityHidden(true)
    }

    private var labelButton: some View {
        Button(action: openLabels) {
            Image(systemName: Self.labelSystemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    hasEffectiveLabels
                        ? MailDesign.accentBlue
                        : MailDesign.secondaryText
                )
                .frame(
                    width: MailboxListMetrics.quickActionButtonSize,
                    height: MailboxListMetrics.quickActionButtonSize
                )
                .contentShape(Rectangle())
        }
        .focused($focusedAction, equals: .labels)
        .accessibilityLabel(Text(labelAccessibilityLabel))
        .help(labelAccessibilityLabel)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        foreground: Color,
        disabled: Bool,
        quickAction: MailboxRowQuickAction,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(
                    width: MailboxListMetrics.quickActionButtonSize,
                    height: MailboxListMetrics.quickActionButtonSize
                )
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .focused($focusedAction, equals: quickAction)
        .accessibilityLabel(Text(title))
        .help(title)
    }
}

@MainActor
final class MailboxRowQuickActionFocusCoordinator: ObservableObject {
    @Published private(set) var requestedLabelMessageID: String?

    func requestLabelFocus(for messageID: String) {
        requestedLabelMessageID = messageID
    }

    func consumeLabelFocusRequest(for messageID: String) -> Bool {
        guard requestedLabelMessageID == messageID else { return false }
        requestedLabelMessageID = nil
        return true
    }
}
