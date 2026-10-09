import PlainpostAI
import PlainpostOperations
import SwiftUI

#if os(iOS)
import UIKit
#endif

enum SmartInboxPageText {
    static func cutoffFooter(_ mode: SmartInboxMode) -> String? {
        guard let since = mode.newMailSince else { return nil }
        return "Mail from before \(since.formatted(.dateTime.month(.abbreviated).day())) isn't sorted."
    }

    static func status(mode: SmartInboxMode, processed: Int?, total: Int?, lowPowerPaused: Bool) -> String? {
        // With sorting Off there is nothing for Low Power Mode to pause.
        if lowPowerPaused, mode.isEnabled { return "Paused in Low Power Mode" }
        guard let processed, let total, total > 0 else { return nil }
        return "Sorting \(processed.formatted()) of \(total.formatted())"
    }
}

/// The Smart Inbox & AI settings page: the sort-mail choice, the AI model (Apple Intelligence,
/// or OpenRouter with the user's key and model), and the translation language. Replaces the old provider table, which surfaced
/// raw provider internals this page keeps private.
struct SmartInboxSettingsPage: View {
    @ObservedObject var settings: AIProviderSettingsViewModel
    @ObservedObject var translation: TranslationLanguageSettingsViewModel
    @ObservedObject var maintenance: MailMaintenanceViewModel
    @State private var confirmsResort = false
    @State private var isLanguagePickerPresented = false
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        SettingsPage(.smartInbox) {
            if aiRequiresNewerIOS {
                Section {
                    Text("AI features require iOS 26 or later on this device.")
                }
            } else {
                smartInboxSection
                modelSection
                translationSection
            }
        }
        .confirmationDialog("Re-sort all mail?", isPresented: $confirmsResort) {
            Button("Re-sort All Mail") { Task { await maintenance.rerunSmartInbox() } }
        } message: {
            Text("Every message Smart Inbox covers is sorted again. Large mailboxes may take hours.")
        }
    }

    private var smartInboxSection: some View {
        Section {
            Picker("Sort mail", selection: Binding(
                get: { SmartInboxModeChoice(settings.smartInboxMode) },
                set: { settings.setSmartInboxMode($0) }
            )) {
                ForEach(SmartInboxModeChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings.smartInbox.mode")

            if let status = SmartInboxPageText.status(
                mode: settings.smartInboxMode,
                processed: maintenance.smartInboxProgress?.processed,
                total: maintenance.smartInboxProgress?.total,
                lowPowerPaused: maintenance.isSmartInboxPausedForLowPower
            ) {
                LabeledContent("Status", value: status)
            }

            if settings.smartInboxEnabled {
                Button("Re-sort All Mail…") { confirmsResort = true }
                    .disabled(!maintenance.canRerunSmartInbox)
                    .accessibilityIdentifier("diagnostics.rerun-smart-inbox")
            }

            if let error = settings.smartInboxPolicyError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.smartInbox.error")
            }
        } header: {
            Text("Smart Inbox")
        } footer: {
            if let footer = SmartInboxPageText.cutoffFooter(settings.smartInboxMode) {
                Text(footer)
            }
        }
    }

    @ViewBuilder private var modelSection: some View {
        Section {
            if settings.choosableRows.count > 1 {
                Picker("Provider", selection: Binding(
                    get: { settings.selectedProviderID },
                    set: { settings.selectProvider($0) }
                )) {
                    ForEach(settings.choosableRows) { Text($0.choiceTitle).tag($0.id) }
                }
                .accessibilityIdentifier("settings.ai.provider")
            }
            if settings.selectedProviderID == OpenRouterConfiguration.providerID {
                openRouterRows
            } else if let apple = settings.rows.first(where: \.isAppleSystemModel) {
                LabeledContent("Apple Intelligence", value: apple.statusLabel)
                if apple.statusLabel != "Ready" {
                    Text(apple.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    #endif
                }
            }
        } header: {
            Text("AI Model")
        } footer: {
            if settings.selectedProviderID == OpenRouterConfiguration.providerID {
                Text("Mail you use with AI, including Smart Inbox sorting, is sent to OpenRouter and the model’s provider. Enter any model name from openrouter.ai/models.")
            }
        }
    }

    @ViewBuilder private var openRouterRows: some View {
        SecureField("API key", text: $settings.openRouterAPIKey, prompt: Text("sk-or-…"))
            .textContentType(.password)
            .onSubmit { settings.saveOpenRouter() }
            .accessibilityIdentifier("settings.ai.openrouter.key")
        TextField("Model", text: $settings.openRouterModelID, prompt: Text("anthropic/claude-sonnet-4.5"))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .onSubmit { settings.saveOpenRouter() }
            .accessibilityIdentifier("settings.ai.openrouter.model")
        HStack {
            Button("Save") { settings.saveOpenRouter() }
                .accessibilityIdentifier("settings.ai.openrouter.save")
            Button("Check Connection") { Task { await settings.checkOpenRouter() } }
                .disabled(settings.isCheckingOpenRouter)
                .accessibilityIdentifier("settings.ai.openrouter.check")
            if settings.isCheckingOpenRouter {
                ProgressView().controlSize(.small)
            }
        }
        #if os(iOS)
        .buttonStyle(.borderless)
        #endif
        if let message = settings.openRouterMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.ai.openrouter.message")
        }
    }

    private var translationSection: some View {
        Section("Translation") {
            Button {
                translation.query = ""
                isLanguagePickerPresented = true
            } label: {
                LabeledContent("Translate messages to", value: translation.selectedOption.localizedName)
            }
            .popover(isPresented: $isLanguagePickerPresented) {
                TranslationLanguagePickerPopover(
                    viewModel: translation,
                    isPresented: $isLanguagePickerPresented
                )
            }
        }
    }

    private var aiRequiresNewerIOS: Bool {
        #if os(iOS)
        !PlainpostAIGenerationPolicy.current
        #else
        false
        #endif
    }
}
