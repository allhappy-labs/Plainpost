import SwiftUI

struct MailboxReadStateTogglePresentation: Equatable, Sendable {
    let showsUnreadDotAtRest: Bool
    let hoverSystemImage: String
    let accessibilityLabel: String
    let action: InboxMailAction

    static func resolve(isUnread: Bool) -> Self {
        if isUnread {
            Self(
                showsUnreadDotAtRest: true,
                hoverSystemImage: "eye",
                accessibilityLabel: "Mark as Read",
                action: .markRead
            )
        } else {
            Self(
                showsUnreadDotAtRest: false,
                hoverSystemImage: "eye.slash",
                accessibilityLabel: "Mark as Unread",
                action: .markUnread
            )
        }
    }
}

enum MailboxReadStateToggleLayout {
    static let hitTargetSize: CGFloat = 26
    static let actionPreviewSize: CGFloat = 20
    static let indicatorFootprint = MailboxListMetrics.unreadDotWidth
    static let horizontalOffset = -(hitTargetSize - indicatorFootprint) / 2
    static let narrowVerticalOffset = 13 - (hitTargetSize - indicatorFootprint) / 2
}

struct MailboxReadStateToggle: View {
    let presentation: MailboxReadStateTogglePresentation
    let unreadColor: Color
    let isRowHovered: Bool
    let forceDirectHover: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var showsActionPreview: Bool {
        forceDirectHover || isHovering || isFocused
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if showsActionPreview {
                    ZStack {
                        Circle()
                            .fill(unreadColor.opacity(0.10))
                        Circle()
                            .stroke(unreadColor.opacity(0.92), lineWidth: 1)
                        Image(systemName: presentation.hoverSystemImage)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(unreadColor)
                    }
                    .frame(
                        width: MailboxReadStateToggleLayout.actionPreviewSize,
                        height: MailboxReadStateToggleLayout.actionPreviewSize
                    )
                } else if presentation.showsUnreadDotAtRest {
                    Circle()
                        .fill(unreadColor)
                        .frame(
                            width: MailboxReadStateToggleLayout.indicatorFootprint,
                            height: MailboxReadStateToggleLayout.indicatorFootprint
                        )
                } else if isRowHovered {
                    Circle()
                        .stroke(MailDesign.tertiaryText.opacity(0.72), lineWidth: 1)
                        .frame(
                            width: MailboxReadStateToggleLayout.indicatorFootprint,
                            height: MailboxReadStateToggleLayout.indicatorFootprint
                        )
                }
            }
            .frame(
                width: MailboxReadStateToggleLayout.hitTargetSize,
                height: MailboxReadStateToggleLayout.hitTargetSize
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help(presentation.accessibilityLabel)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}
