#if os(iOS)
import SwiftUI

/// Smart Inbox's category chips. The selected chip shows its icon and name; the others show
/// only an icon. "All" clears the selection.
struct MobileCategoryChips: View {
    @Binding var selection: SmartInboxDisplayBundle?
    let available: [SmartInboxDisplayBundle]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(available) { chip($0) }
                Button { selection = nil } label: {
                    capsule(isSelected: selection == nil) {
                        Text("All").font(.subheadline.weight(selection == nil ? .semibold : .regular))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == nil ? .isSelected : [])
                .accessibilityIdentifier("mailbox.chip.all")
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ bundle: SmartInboxDisplayBundle) -> some View {
        let isSelected = selection == bundle
        return Button { selection = isSelected ? nil : bundle } label: {
            capsule(isSelected: isSelected) {
                if isSelected {
                    Label(bundle.title, systemImage: bundle.systemImage).font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: bundle.systemImage).font(.subheadline)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bundle.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("mailbox.chip.\(bundle.rawValue)")
    }

    /// A 34 pt capsule, as in the mockup, inside a 44 pt target: the button, not only the
    /// layout, is 44 pt tall.
    private func capsule(isSelected: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 34)
            .background(isSelected ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
#endif
