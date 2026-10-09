import SwiftUI

extension PlainpostSettingsSection {
    var settingsTint: Color {
        switch self {
        case .accounts:
            .blue
        case .smartInbox:
            .purple
        case .rulesLabels:
            .blue
        case .notifications:
            .red
        case .privacy:
            .indigo
        case .plainpostAccount:
            .indigo
        case .syncNode:
            .cyan
        #if os(macOS)
        case .calendars:
            .blue
        #endif
        case .troubleshooting:
            .gray
        }
    }
}

struct SystemSettingsSidebarLabel: View {
    static let titleLeadingPadding: CGFloat = 4

    let section: PlainpostSettingsSection
    let isSelected: Bool

    var body: some View {
        Label {
            Text(section.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .padding(.leading, Self.titleLeadingPadding)
        } icon: {
            Image(systemName: section.systemImage)
                .symbolVariant(.fill)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    isSelected ? Color.white.opacity(0.2) : section.settingsTint,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
    }
}

struct SystemSettingsHero: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides

    private var reduceTransparency: Bool {
        previewOverrides.reduceTransparency ?? systemReduceTransparency
    }

    private var increasedContrast: Bool {
        previewOverrides.increasedContrast ?? (systemContrast == .increased)
    }

    @ViewBuilder
    private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape.fill(MailDesign.panelElevated)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    var body: some View {
        Group {
        #if os(iOS)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .symbolVariant(.fill)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background { tileBackground }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        #else
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolVariant(.fill)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background { tileBackground }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            increasedContrast ? MailDesign.primaryText.opacity(0.55) : MailDesign.strokeStrong,
                            lineWidth: increasedContrast ? 2 : (reduceTransparency ? 1 : 0.75)
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 28, weight: .bold))

            if !detail.isEmpty {
                Text(detail)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail.isEmpty ? title : "\(title). \(detail)"))
    }
}

struct SystemSettingsGroup<Content: View>: View {
    let title: String?
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides

    private var reduceTransparency: Bool {
        previewOverrides.reduceTransparency ?? systemReduceTransparency
    }

    private var increasedContrast: Bool {
        previewOverrides.increasedContrast ?? (systemContrast == .increased)
    }

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                reduceTransparency ? MailDesign.panelElevated : MailDesign.panel,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        increasedContrast ? MailDesign.primaryText.opacity(0.55) : (reduceTransparency ? MailDesign.strokeStrong : MailDesign.stroke),
                        lineWidth: increasedContrast ? 2 : 1
                    )
            }
        }
    }
}

struct SystemSettingsValueRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(symbol: systemImage, tint: tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.callout.weight(.medium))

            Spacer(minLength: 16)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}

struct SystemSettingsInsetSeparator: View {
    var body: some View {
        Divider()
            .padding(.leading, 54)
    }
}
