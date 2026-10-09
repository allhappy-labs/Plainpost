#if os(iOS)
import SwiftUI

/// "Archived · Undo", shown for the grace period after an archive or delete.
struct MobileUndoToast: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("mailbox.undo")
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
#endif
