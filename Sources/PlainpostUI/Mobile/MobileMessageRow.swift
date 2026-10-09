#if os(iOS)
import SwiftUI

/// One conversation in a mailbox list: unread dot, avatar, sender, date, subject, a two-line
/// preview and the thread count. At accessibility sizes nothing truncates: every line
/// wraps in full and the date moves under the sender.
struct MobileMessageRow: View {
    let row: MessageRowModel
    /// The row's cleaned lines, computed once per row: the list passes the copy it also reads
    /// the accessibility label from.
    let text: MobileRowText
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(row: MessageRowModel, text: MobileRowText? = nil) {
        self.row = row
        self.text = text ?? MobileRowText(row: row)
    }

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The row's leading list inset: with the dot and its gap, the avatar starts 12 pt in, as
    /// in the mockup. The list screens apply it, since a row inset set inside a button's
    /// label never reaches the list.
    static let leadingListInset: CGFloat = 2

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            Circle()
                .fill(row.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 14)
            HStack(alignment: .top, spacing: 10) {
                MailSenderAvatar(sender: MailSenderDisplay.address(row.sender), displayName: row.senderDisplayName, size: 36)
                textColumn
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Text(text.subject)
                .font(.subheadline.weight(row.isUnread ? .semibold : .regular))
                .lineLimit(isLarge ? nil : 1)
            if !text.preview.isEmpty {
                Text(text.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isLarge ? nil : 2)
            }
            if row.isWaitingForNode {
                WaitingForSyncNodeBadge(selected: false)
            }
        }
        // Separators start under the text. Otherwise the list aligns them to the first text it
        // finds, which is an initials avatar's letters in some rows and not in others.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    @ViewBuilder
    private var header: some View {
        if isLarge {
            VStack(alignment: .leading, spacing: 2) {
                senderLine
                Text(row.dateLabel).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                senderLine
                Spacer(minLength: 4)
                if row.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Flagged")
                }
                Text(row.dateLabel).font(.footnote).foregroundStyle(.secondary).fixedSize()
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var senderLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text.sender).font(.headline).lineLimit(isLarge ? nil : 1)
            if row.threadMessageCount > 1 {
                Text(row.threadMessageCount, format: .number)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
