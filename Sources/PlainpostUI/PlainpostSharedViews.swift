import SwiftUI
import PlainpostCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if os(iOS)
private let localDeviceName = "device"
private let localKeychainName = "Keychain on this device"
#else
private let localDeviceName = "Mac"
private let localKeychainName = "macOS Keychain"
#endif

struct CommandCenterPanel: View {
    @ObservedObject var viewModel: CommandCenterViewModel
    let onExecute: (CommandCenterCommand) -> Void

    init(
        viewModel: CommandCenterViewModel,
        onExecute: @escaping (CommandCenterCommand) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onExecute = onExecute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandCenterHeader(
                commandCount: viewModel.commands.count,
                onClose: viewModel.close
            )
            CommandCenterSearchField(
                query: $viewModel.query,
                resultCount: viewModel.filteredCommands.count,
                onSubmit: submitSelectedCommand
            )

            ScrollView {
                if viewModel.filteredCommands.isEmpty {
                    EmptyState(
                        title: "No commands found",
                        detail: "Try a different search term or clear the command query."
                    )
                    .frame(height: 320)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(CommandCenterCategory.allCases, id: \.self) { category in
                            let commands = viewModel.filteredCommands.filter { $0.category == category }
                            if !commands.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    CommandCenterCategoryHeader(category: category, count: commands.count)
                                    ForEach(commands) { command in
                                        CommandCenterRow(
                                            command: command,
                                            highlighted: command.id == viewModel.selectedCommandID
                                        ) {
                                            execute(command)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            #if os(iOS)
            .frame(maxHeight: 240)
            #else
            .frame(height: 394)
            #endif

            #if os(macOS)
            CommandCenterFooter()
            #endif
        }
        .padding(16)
        #if os(iOS)
        .frame(maxWidth: 560)
        #else
        .frame(width: 560)
        #endif
        .liquidGlassPanel(cornerRadius: MailDesign.Radius.window)
        #if os(iOS)
        .padding(.horizontal, 16)
        #endif
        .shadow(color: Color.black.opacity(0.20), radius: 28, x: 0, y: 14)
        .foregroundStyle(MailDesign.primaryText)
        #if os(macOS)
        .onMoveCommand { direction in
            switch direction {
            case .up: viewModel.moveSelection(.up)
            case .down: viewModel.moveSelection(.down)
            default: break
            }
        }
        #endif
        .onKeyPress(.escape) {
            viewModel.close()
            return .handled
        }
        #if os(macOS)
        .onExitCommand(perform: viewModel.close)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func submitSelectedCommand() {
        guard let command = try? viewModel.submitSelected() else {
            return
        }
        onExecute(command)
    }

    private func execute(_ command: CommandCenterCommand) {
        do {
            viewModel.select(commandID: command.id)
            try viewModel.execute(commandID: command.id)
            onExecute(command)
        } catch {
            // Only commands supplied by the view model are rendered.
        }
    }
}

struct CommandCenterHeader: View {
    let commandCount: Int
    let onClose: () -> Void

    init(commandCount: Int, onClose: @escaping () -> Void = {}) {
        self.commandCount = commandCount
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(MailDesign.accentBlue)
                .frame(width: 34, height: 34)
                .background(MailDesign.accentBlue.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(MailDesign.accentBlue.opacity(0.24)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Command Center")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(commandCount) local commands")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }

            Spacer()

            HStack(spacing: 4) {
                #if os(macOS)
                CommandCenterKeycap("⌘")
                CommandCenterKeycap("K")
                #endif

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(MailDesign.control.opacity(0.78), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(MailDesign.stroke))
                .help("Close Command Center (Esc)")
                .accessibilityLabel(Text("Close Command Center"))
            }
        }
        .padding(.horizontal, 2)
    }
}

struct CommandCenterSearchField: View {
    @Binding var query: String
    let resultCount: Int
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    init(
        query: Binding<String>,
        resultCount: Int,
        onSubmit: @escaping () -> Void = {}
    ) {
        self._query = query
        self.resultCount = resultCount
        self.onSubmit = onSubmit
    }

    private var resultLabel: String {
        resultCount == 1 ? "1 result" : "\(resultCount) results"
    }

    private var searchPrompt: String {
        #if os(iOS)
        "Search commands"
        #else
        "Search mail, folders, settings, or commands"
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MailDesign.secondaryText)

            TextField(searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .focused($isFocused)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("command-center.search")

            Spacer(minLength: 12)

            #if os(macOS)
            Text(resultLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MailDesign.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(MailDesign.control.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(MailDesign.stroke))
            #endif
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(MailDesign.controlHover.opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(MailDesign.accentBlue.opacity(0.26)))
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }
}

struct CommandCenterCategoryHeader: View {
    let category: CommandCenterCategory
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(category.commandTint)
                .frame(width: 5, height: 5)
            Text(category.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MailDesign.tertiaryText)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(MailDesign.control.opacity(0.52), in: Capsule())
        }
        .foregroundStyle(MailDesign.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

struct CommandCenterRow: View {
    let command: CommandCenterCommand
    let highlighted: Bool
    let action: () -> Void

    init(command: CommandCenterCommand, highlighted: Bool = false, action: @escaping () -> Void) {
        self.command = command
        self.highlighted = highlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : command.category.commandTint)
                    .frame(width: 32, height: 32)
                    .background(highlighted ? command.category.commandTint : command.category.commandTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(command.category.commandTint.opacity(highlighted ? 0.34 : 0.22)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title)
                        .font(.system(size: 14, weight: highlighted ? .semibold : .medium))
                    Text(command.category.displayName)
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                }

                Spacer()

                #if os(macOS)
                if let shortcut = command.keyboardShortcut {
                    CommandCenterKeycap(shortcut, highlighted: highlighted)
                } else if highlighted {
                    CommandCenterKeycap("Return", highlighted: true)
                }
                #endif
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(highlighted ? MailDesign.controlHover.opacity(0.76) : MailDesign.control.opacity(0.16), in: RoundedRectangle(cornerRadius: MailDesign.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.row).stroke(highlighted ? command.category.commandTint.opacity(0.28) : MailDesign.stroke.opacity(0.50)))
            .overlay(alignment: .leading) {
                if highlighted {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(command.category.commandTint)
                        .frame(width: 3, height: 32)
                        .offset(x: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        .accessibilityValue(highlighted ? "Selected" : "Not selected")
        .accessibilityIdentifier("command-center.\(command.id)")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

struct CommandCenterKeycap: View {
    let label: String
    let highlighted: Bool

    init(_ label: String, highlighted: Bool = false) {
        self.label = label
        self.highlighted = highlighted
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(highlighted ? MailDesign.primaryText : MailDesign.secondaryText)
            .padding(.horizontal, label.count > 1 ? 8 : 7)
            .frame(height: 24)
            .background(MailDesign.control.opacity(highlighted ? 0.92 : 0.68), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlighted ? MailDesign.strokeStrong : MailDesign.stroke))
    }
}

struct CommandCenterFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            CommandCenterKeycap("Return")
            Text("run selected")
            Circle().fill(MailDesign.strokeStrong).frame(width: 3, height: 3)
            CommandCenterKeycap("Esc")
            Text("close")
            Spacer()
            Text("Local actions only")
                .font(.caption.weight(.medium))
                .foregroundStyle(MailDesign.accentTeal)
        }
        .font(.caption)
        .foregroundStyle(MailDesign.secondaryText)
        .padding(.horizontal, 2)
    }
}

private extension CommandCenterCategory {
    var commandTint: Color {
        switch self {
        case .search:
            MailDesign.accentBlue
        case .navigation:
            MailDesign.accentBlue
        case .ai:
            MailDesign.accentTeal
        case .mailAction:
            Color.orange
        case .label:
            Color(hex: 0xFFD166)
        case .compose:
            MailDesign.accentTeal
        case .maintenance:
            Color(hex: 0xB197FC)
        }
    }
}

#if os(macOS)
struct MacNotificationEnablementCallout: View {
    @ObservedObject var model: NotificationPermissionModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MailDesign.accentBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enable new-mail notifications")
                    .font(.callout.weight(.semibold))
                Text("Plainpost can alert you when new mail arrives. Permission is requested only if you choose Enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button("Not Now") { model.dismissCallout() }
            Button("Enable") { Task { await model.enable() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }
}
#endif

struct OperationActivityRow: View {
    let operation: OperationActivityRowModel

    var showsIndeterminateProgress: Bool {
        operation.isActive && operation.state != .paused && operation.progressFraction == nil
    }

    @ViewBuilder
    var body: some View {
        if operation.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(elapsedAt: context.date)
            }
        } else {
            content(elapsedAt: operation.updatedAt)
        }
    }

    private func content(elapsedAt date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: operation.state == .paused ? "pause.circle.fill" : (operation.isActive ? "gearshape.2" : stateSymbol))
                    .foregroundStyle(operation.state == .paused ? Color.orange : (operation.isActive ? MailDesign.accentBlue : stateTint))

                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title)
                        .font(.callout.weight(.semibold))
                    Text(OperationActivityPresentation.metadata(operation, now: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(operation.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateTint)
            }

            if operation.isActive {
                if let fraction = operation.progressFraction {
                    ProgressView(value: fraction)
                    Text("\(operation.current) of \(operation.total ?? 0) · \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if showsIndeterminateProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let resultDetail = operation.resultDetail {
                Text(resultDetail)
                    .font(.caption)
                    .foregroundStyle(
                        operation.state == .failed || operation.isPartialFailure
                            ? Color.orange
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("DiagnosticsOperationRow-\(operation.id)")
    }

    private var stateSymbol: String {
        switch operation.state {
        case .completed: "checkmark.circle.fill"
        case .failed, .deliveryUncertain: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .queued, .running: "gearshape.2"
        case .paused: "pause.circle.fill"
        }
    }

    private var stateTint: Color {
        if operation.isPartialFailure { return .orange }
        return switch operation.state {
        case .completed: MailDesign.accentTeal
        case .failed, .deliveryUncertain: .orange
        case .cancelled: .secondary
        case .queued, .running: MailDesign.accentBlue
        case .paused: .orange
        }
    }

}

public enum PlainpostPrivacyPreference {
    public static let blockRemoteImagesKey = "Plainpost.privacy.blockRemoteImages"

    public static var blockRemoteImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: blockRemoteImagesKey) != nil else {
            return true
        }
        return defaults.bool(forKey: blockRemoteImagesKey)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool
    var showsSeparator = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(symbol: symbol, tint: isOn ? MailDesign.accentBlue : MailDesign.secondaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityHidden(true)

            Spacer()

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(detail))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                SystemSettingsInsetSeparator()
            }
        }
    }
}

struct SettingsRowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct EmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(MailDesign.tertiaryText)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(MailDesign.secondaryText)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(MailDesign.primaryText)
    }
}

struct WorkflowStateBanner: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(tint.opacity(0.24)))
        .foregroundStyle(MailDesign.primaryText)
    }
}

struct MailAvatar: View {
    let text: String
    let category: SmartCategory?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Text(text.uppercased())
                .font(.system(size: max(10, size * 0.32), weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var fill: LinearGradient {
        let colors: [Color]
        switch category {
        case .personal:
            colors = [Color(hex: 0x3A86FF), Color(hex: 0x335CFF)]
        case .notification:
            colors = [Color(hex: 0x20C997), Color(hex: 0x087F5B)]
        case .newsletter:
            colors = [Color(hex: 0xFF922B), Color(hex: 0xF03E3E)]
        case .receipt, .finance:
            colors = [Color(hex: 0x22B8CF), Color(hex: 0x1971C2)]
        case .security:
            colors = [Color(hex: 0xFA5252), Color(hex: 0xE67700)]
        case .travel:
            colors = [Color(hex: 0x15AABF), Color(hex: 0x4DABF7)]
        case .invitation:
            colors = [Color(hex: 0x5F3DC4), Color(hex: 0x845EF7)]
        case .invitationResponse:
            colors = [Color(hex: 0x2B8A3E), Color(hex: 0x40C057)]
        case .support, .social:
            colors = [Color(hex: 0x845EF7), Color(hex: 0xE64980)]
        case .system, .unknown, nil:
            colors = [Color(hex: 0x5C6470), Color(hex: 0x343A40)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A local-only identity treatment for message senders. It deliberately never
/// resolves Gravatar, favicons, or other remote identity sources.
struct MailSenderIdentity: Equatable, Sendable {
    enum Brand: Equatable, Sendable {
        case homegate
        case github
        case slack
        case linear
        case none

        init(domain: String, candidate: String) {
            let identity = "\(domain) \(candidate)".lowercased()
            let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain == "homegate.ch" || domain.hasSuffix(".homegate.ch") || identity.contains("homegate") {
                self = .homegate
            } else if domain == "github.com" || domain.hasSuffix(".github.com") || normalizedCandidate == "github" {
                self = .github
            } else if domain == "slack.com" || domain.hasSuffix(".slack.com") || normalizedCandidate == "slack" {
                self = .slack
            } else if domain == "linear.app" || domain.hasSuffix(".linear.app") || normalizedCandidate == "linear" {
                self = .linear
            } else {
                self = .none
            }
        }

        var label: String? {
            switch self {
            case .homegate: "Homegate"
            case .github: "GitHub"
            case .slack: "Slack"
            case .linear: "Linear"
            case .none: nil
            }
        }

        var symbol: String? {
            switch self {
            case .homegate: "house.fill"
            case .github: "chevron.left.forwardslash.chevron.right"
            case .slack: "bubble.left.and.bubble.right.fill"
            case .linear: "line.3.horizontal.decrease.circle.fill"
            case .none: nil
            }
        }
    }

    let address: String
    let displayName: String
    let initials: String
    let brand: Brand
    let paletteIndex: Int

    init(sender: String, displayName: String? = nil) {
        let parsedAddress = Self.address(from: sender)
        let domain = Self.domain(from: parsedAddress)
        let suppliedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBrand = Brand(domain: domain, candidate: suppliedName ?? parsedAddress)
        let localPart = parsedAddress.split(separator: "@", maxSplits: 1).first.map(String.init) ?? parsedAddress
        let isAutomated = ["noreply", "no-reply", "notifications", "notification", "mailer-daemon"].contains(localPart.lowercased())
        let fallback = resolvedBrand.label
            ?? (isAutomated ? Self.domainLabel(domain) : Self.humanized(localPart))

        self.address = parsedAddress
        self.displayName = (suppliedName?.isEmpty == false ? suppliedName! : fallback)
        self.initials = Self.initials(from: self.displayName)
        self.brand = resolvedBrand
        let seed = Self.stableHash(domain.isEmpty ? parsedAddress : domain)
        self.paletteIndex = Int(UInt(bitPattern: seed) % UInt(Self.palettes.count))
    }

    private static let palettes: [(Color, Color)] = [
        (Color(hex: 0x1D9BD1), Color(hex: 0x1769E0)),
        (Color(hex: 0x845EF7), Color(hex: 0x5F3DC4)),
        (Color(hex: 0xF76707), Color(hex: 0xE03131)),
        (Color(hex: 0x12B886), Color(hex: 0x087F5B)),
        (Color(hex: 0x228BE6), Color(hex: 0x364FC7)),
        (Color(hex: 0xE64980), Color(hex: 0xA61E4D))
    ]

    var colors: (Color, Color) {
        switch brand {
        case .homegate:
            (Color(hex: 0x16A3D6), Color(hex: 0x1769E0))
        case .github:
            (Color(hex: 0x4B5563), Color(hex: 0x1F2937))
        case .slack:
            (Color(hex: 0x7C3AED), Color(hex: 0x4C1D95))
        case .linear:
            (Color(hex: 0x64748B), Color(hex: 0x334155))
        case .none:
            Self.palettes[paletteIndex]
        }
    }

    private static func address(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.lastIndex(of: "<"),
           let end = trimmed[trimmed.index(after: start)...].firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func domain(from address: String) -> String {
        address.split(separator: "@", maxSplits: 1).dropFirst().first.map { String($0).lowercased() } ?? ""
    }

    private static func domainLabel(_ domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        let ignored = Set(["mail", "email", "notifications", "notification", "updates", "news"])
        let candidate = parts.first(where: { !ignored.contains($0.lowercased()) }) ?? parts.first ?? "Sender"
        return humanized(candidate)
    }

    private static func humanized(_ value: String) -> String {
        let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return "Sender" }
        return words.map { word in
            word.count <= 4 && word == word.uppercased() ? word : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func initials(from value: String) -> String {
        let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(value.prefix(2)).uppercased()
    }

    private static func stableHash(_ value: String) -> Int {
        value.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) } & Int.max
    }
}

struct MailSenderAvatar: View {
    @AppStorage(SiteIconPreference.fetchEnabledKey) private var fetchSiteIcons = true
    @Environment(\.mailContactDirectorySnapshot) private var contactDirectory
    @Environment(\.mailSiteIconDirectory) private var siteIconDirectory
    private let identity: MailSenderIdentity
    let size: CGFloat

    init(sender: String, displayName: String? = nil, size: CGFloat) {
        identity = MailSenderIdentity(sender: sender, displayName: displayName)
        self.size = size
    }

    init(identity: MailSenderIdentity, size: CGFloat) {
        self.identity = identity
        self.size = size
    }

    var body: some View {
        Group {
            if let contact = contactDirectory.contact(for: identity.address),
               contact.thumbnailImageData != nil {
                MailContactPhoto(contact: contact, size: size)
            } else if let siteIconDirectory {
                ObservedSiteIconAvatar(directory: siteIconDirectory, identity: identity, size: size)
            } else {
                SenderAvatarFallback(identity: identity, size: size)
            }
        }
        .task(id: fetchSiteIcons) {
            guard contactDirectory.contact(for: identity.address)?.thumbnailImageData == nil else { return }
            siteIconDirectory?.resolveIfNeeded(sender: identity.address)
        }
        .accessibilityLabel("\(identity.displayName), \(identity.address)")
    }
}

private struct ObservedSiteIconAvatar: View {
    @ObservedObject var directory: SiteIconDirectoryModel
    let identity: MailSenderIdentity
    let size: CGFloat

    var body: some View {
        if let data = directory.data(for: identity.address) {
            SiteIconAvatar(data: data, size: size)
        } else {
            SenderAvatarFallback(identity: identity, size: size)
        }
    }
}

private struct SenderAvatarFallback: View {
    let identity: MailSenderIdentity
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [identity.colors.0, identity.colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let symbol = identity.brand.symbol {
                Image(systemName: symbol)
                    .font(.system(size: max(11, size * 0.36), weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(identity.initials)
                    .font(.system(size: max(10, size * 0.32), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SiteIconAvatar: View {
    let data: Data
    let size: CGFloat

    var body: some View {
        Group {
#if canImport(AppKit)
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            }
#elseif canImport(UIKit)
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            }
#endif
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct MailField: View {
    let placeholder: String
    @Binding var text: String
    let width: CGFloat?

    init(_ placeholder: String, text: Binding<String>, width: CGFloat? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    }
}

struct MailDivider: View {
    var body: some View {
        Rectangle()
            .fill(MailDesign.stroke)
            .frame(width: 1)
    }
}

public struct MailAccessibilityPreviewOverrides: Equatable, Sendable {
    public let increasedContrast: Bool?
    public let reduceTransparency: Bool?
    public let reduceMotion: Bool?
    public let hoveredMailboxRowID: String?
    public let hoveredReadStateMessageID: String?

    public init(
        increasedContrast: Bool? = nil,
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil,
        hoveredMailboxRowID: String? = nil,
        hoveredReadStateMessageID: String? = nil
    ) {
        self.increasedContrast = increasedContrast
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
        self.hoveredMailboxRowID = hoveredMailboxRowID
        self.hoveredReadStateMessageID = hoveredReadStateMessageID
    }
}

private struct MailAccessibilityPreviewOverridesKey: EnvironmentKey {
    static let defaultValue = MailAccessibilityPreviewOverrides()
}

extension EnvironmentValues {
    var mailAccessibilityPreviewOverrides: MailAccessibilityPreviewOverrides {
        get { self[MailAccessibilityPreviewOverridesKey.self] }
        set { self[MailAccessibilityPreviewOverridesKey.self] = newValue }
    }
}

public extension View {
    func mailAccessibilityPreview(
        increasedContrast: Bool? = nil,
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil,
        hoveredMailboxRowID: String? = nil,
        hoveredReadStateMessageID: String? = nil
    ) -> some View {
        environment(
            \.mailAccessibilityPreviewOverrides,
            MailAccessibilityPreviewOverrides(
                increasedContrast: increasedContrast,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                hoveredMailboxRowID: hoveredMailboxRowID,
                hoveredReadStateMessageID: hoveredReadStateMessageID
            )
        )
    }
}

enum MailDesign {
    enum Radius {
        static let control: CGFloat = 10
        static let row: CGFloat = 12
        static let panel: CGFloat = 16
        static let window: CGFloat = 22
    }

    static var background: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemBackground)
#endif
    }

    static var rail: Color { Color.clear }

    static var column: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }

    static var workArea: Color {
#if os(macOS)
        Color(nsColor: .textBackgroundColor)
#else
        Color(uiColor: .systemBackground)
#endif
    }

    static var panel: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }

    static var panelElevated: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .tertiarySystemBackground)
#endif
    }

    static var control: Color {
#if os(macOS)
        Color(nsColor: .controlColor)
#else
        Color(uiColor: .tertiarySystemFill)
#endif
    }

    static var controlHover: Color { Color.accentColor.opacity(0.16) }
    static var selection: Color { Color.accentColor.opacity(0.30) }
    static var selectionSoft: Color { Color.accentColor.opacity(0.14) }
    static var accentBlue: Color { Color.accentColor }

    static var accentTeal: Color {
#if os(macOS)
        Color(nsColor: .systemTeal)
#else
        Color(uiColor: .systemTeal)
#endif
    }

    static var unread: Color { Color.accentColor }
    static var primaryText: Color { Color.primary }
    static var secondaryText: Color { Color.secondary }
    static var tertiaryText: Color { Color.secondary.opacity(0.74) }

    static var stroke: Color {
#if os(macOS)
        Color(nsColor: .separatorColor).opacity(0.72)
#else
        Color(uiColor: .separator).opacity(0.72)
#endif
    }

    static var strokeStrong: Color {
#if os(macOS)
        Color(nsColor: .separatorColor)
#else
        Color(uiColor: .separator)
#endif
    }
}

extension View {
    @ViewBuilder
    func mailGlassButtonStyle() -> some View {
#if os(macOS)
        self.buttonStyle(.glass)
#else
        self.buttonStyle(.bordered)
#endif
    }

    @ViewBuilder
    func mailInspectorColumnWidth() -> some View {
#if os(macOS)
        self.inspectorColumnWidth(min: 300, ideal: 360, max: 460)
#else
        self
#endif
    }

    func mailPanel(cornerRadius: CGFloat = MailDesign.Radius.panel) -> some View {
        self
            .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(MailDesign.stroke))
    }

    func mailControlBackground(cornerRadius: CGFloat = MailDesign.Radius.control) -> some View {
        self
            .background(MailDesign.control, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(MailDesign.stroke))
    }

    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat = MailDesign.Radius.window) -> some View {
#if os(macOS)
        modifier(MailLiquidGlassPanelModifier(cornerRadius: cornerRadius))
#else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
    }

    func iconButton(help: String) -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(MailDesign.secondaryText)
            .frame(width: 32, height: 32)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    func railIcon(selected: Bool, badge: Int?, help: String) -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? .white : MailDesign.secondaryText)
            .frame(width: 40, height: 40)
            .background(selected ? MailDesign.controlHover : Color.clear, in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(MailDesign.accentBlue)
                        .frame(width: 3, height: 18)
                        .offset(x: -6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.orange, in: Circle())
                        .offset(x: 5, y: -4)
                }
            }
            .help(help)
            .accessibilityLabel(Text(help))
            .accessibilityValue(Text(selected ? "Selected" : "Not selected"))
    }

    func pillButton() -> some View {
        self
            .buttonStyle(.bordered)
            .font(.callout.weight(.medium))
            .controlSize(.regular)
    }

    func destructiveActionButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .font(.headline.weight(.semibold))
            .frame(width: 176, height: 46)
    }

    func approveActionButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .font(.headline.weight(.semibold))
            .frame(width: 176, height: 46)
    }

    func approvalSecondaryButton() -> some View {
        self
            .buttonStyle(.bordered)
            .font(.callout.weight(.semibold))
            .controlSize(.regular)
    }

    func approvalTintButton(tint: Color) -> some View {
        self
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(minWidth: 104, minHeight: 34)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(tint.opacity(0.28)))
    }
}

#if os(macOS)
private struct MailLiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
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
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    MailDesign.panelElevated,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(MailDesign.strokeStrong, lineWidth: increasedContrast ? 2 : 1)
                }
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    if increasedContrast {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(MailDesign.primaryText.opacity(0.46), lineWidth: 2)
                    }
                }
        }
    }
}
#endif

struct MailCategoryBadge: View {
    let label: String
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.mailAccessibilityPreviewOverrides) private var previewOverrides

    private var increasedContrast: Bool {
        previewOverrides.increasedContrast ?? (systemContrast == .increased)
    }

    private var tint: Color {
#if os(macOS)
        switch label.lowercased() {
        case "notifications":
            Color(nsColor: .systemPurple)
        case "newsletters":
            Color(nsColor: .systemTeal)
        case "support":
            Color(nsColor: .systemBlue)
        default:
            Color(nsColor: .systemOrange)
        }
#else
        switch label.lowercased() {
        case "notifications": .purple
        case "newsletters": .teal
        case "support": .blue
        default: .orange
        }
#endif
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MailDesign.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                tint.opacity(increasedContrast ? 0.30 : 0.18),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint.opacity(increasedContrast ? 0.90 : 0.48), lineWidth: increasedContrast ? 2 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Category: \(label)")
    }
}

extension String {
    var mailDisplayName: String {
        MailSenderIdentity(sender: self).displayName
    }

    var mailInitials: String {
        MailSenderIdentity(sender: self).initials
    }
}

extension SmartCategory {
    var rowSymbol: String {
        switch self {
        case .personal:
            "person.2"
        case .notification:
            "bell"
        case .newsletter:
            "newspaper"
        case .receipt:
            "receipt"
        case .security:
            "lock.shield"
        case .finance:
            "creditcard"
        case .travel:
            "airplane"
        case .support:
            "questionmark.bubble"
        case .social:
            "person.2"
        case .system:
            "gearshape"
        case .invitation:
            "calendar"
        case .invitationResponse:
            "calendar.badge.checkmark"
        case .unknown:
            "tray"
        }
    }
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

#Preview {
    PlainpostRootView()
}
