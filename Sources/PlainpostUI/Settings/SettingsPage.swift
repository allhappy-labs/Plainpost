import SwiftUI

/// One settings page. Mac: the System Settings header above a grouped `Form`. iOS: a plain
/// inset-grouped `Form` whose only title is the navigation title.
struct SettingsPage<Content: View>: View {
    let section: PlainpostSettingsSection
    @ViewBuilder var content: Content

    init(_ section: PlainpostSettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        // A grouped Form, like the account page, so sections render as cards and toggles as
        // switches; the header is a row-less first section's footer, so it draws no card.
        Form {
            Section {
            } footer: {
                SettingsPageHeader(title: section.title, detail: "", systemImage: section.systemImage, tint: section.settingsTint)
                    .frame(maxWidth: .infinity)
                    // Footers default to secondary text; the page title stays primary.
                    .foregroundStyle(.primary)
                    // The footer slot reads as plain text; announce the page title as a heading.
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(MailDesign.background)
        #else
        Form { content }
            .formStyle(.grouped)
        #endif
    }
}
