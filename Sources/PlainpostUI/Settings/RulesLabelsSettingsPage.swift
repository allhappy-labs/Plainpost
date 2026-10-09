import SwiftUI

enum RulesLabelsTab: String, CaseIterable, Identifiable {
    case rules = "Rules", labels = "Labels"
    var id: Self { self }
}

/// The Rules & Labels settings page. Mac shows a segmented Rules/Labels switch above the
/// shared `AccountScopedManagementPanel`; iOS lists both as sections of one page.
struct RulesLabelsSettingsPage: View {
    @ObservedObject var rules: MailRulesViewModel
    @ObservedObject var labels: MailLabelsViewModel
    @State private var tab: RulesLabelsTab = .rules

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(
                    title: PlainpostSettingsSection.rulesLabels.title,
                    detail: "",
                    systemImage: PlainpostSettingsSection.rulesLabels.systemImage,
                    tint: PlainpostSettingsSection.rulesLabels.settingsTint
                )
                Picker("", selection: $tab) {
                    ForEach(RulesLabelsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                switch tab {
                case .rules: MailRulesSettingsPanel(viewModel: rules)
                case .labels: MailLabelsSettingsPanel(viewModel: labels)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #else
        List {
            Section("Rules") { MailRulesSettingsPanel(viewModel: rules) }
            Section("Labels") { MailLabelsSettingsPanel(viewModel: labels) }
        }
        .listStyle(.insetGrouped)
        #endif
    }
}
