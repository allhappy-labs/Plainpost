import SwiftUI

struct MessageLabelCommandCenterPanel: View {
    @ObservedObject var viewModel: MessageLabelCommandCenterViewModel
    @ObservedObject var labelActions: MessageLabelActions
    let reduceMotion: Bool
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    init(
        viewModel: MessageLabelCommandCenterViewModel,
        labelActions: MessageLabelActions,
        reduceMotion: Bool,
        onClose: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.labelActions = labelActions
        self.reduceMotion = reduceMotion
        self.onClose = onClose
    }

    private var context: MessageLabelCommandCenterContext? {
        viewModel.context
    }

    private var content: MessageLabelMenuContent {
        guard let context else { return .empty }
        return labelActions.menuContent(for: context.messageID)
    }

    private var presentation: MessageLabelCommandPresentation {
        switch content {
        case .items(let items):
            viewModel.presentation(items: items)
        case .loading, .loadFailed, .empty:
            viewModel.presentation(items: [])
        }
    }

    private var searchDisabled: Bool {
        if case .loading = content {
            true
        } else {
            false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            results
                #if os(iOS)
                .frame(maxHeight: 240)
                #else
                .frame(height: 394)
                #endif
            footer
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
        .shadow(color: Color.black.opacity(0.28), radius: 30, x: 0, y: 16)
        .foregroundStyle(MailDesign.primaryText)
        #if os(macOS)
        .onMoveCommand(perform: moveSelection)
        #endif
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        #if os(macOS)
        .onExitCommand(perform: close)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: labelActions.revision
        )
        .onAppear {
            searchFocused = true
            viewModel.reconcileSelection(in: presentation)
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.reconcileSelection(in: presentation)
        }
        .onChange(of: labelActions.revision) { _, _ in
            viewModel.reconcileSelection(in: presentation)
        }
        .task(id: appearanceKey) {
            guard let context else { return }
            await labelActions.runAppearanceTask(messageID: context.messageID)
        }
    }

    private var appearanceKey: MessageLabelRowRefreshKey? {
        context.map {
            MessageLabelRowRefreshKey(
                messageID: $0.messageID,
                revision: labelActions.revision
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(MailDesign.labelCommandTint)
                .frame(width: 34, height: 34)
                .background(
                    MailDesign.labelCommandTint.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(MailDesign.labelCommandTint.opacity(0.24))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Labels")
                    .font(.system(size: 16, weight: .semibold))
                Text(contextLine)
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(
                MailDesign.control.opacity(0.78),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(MailDesign.stroke)
            )
            .help("Close Labels (Esc)")
            .accessibilityLabel(Text("Close Labels"))
        }
        .padding(.horizontal, 2)
    }

    private var contextLine: String {
        guard let context else { return "" }
        return "\(context.sender) · \(context.subject)"
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MailDesign.secondaryText)

            TextField("Search labels", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .focused($searchFocused)
                .disabled(searchDisabled)
                .onSubmit(submitSelected)

            Spacer(minLength: 12)

            Text(resultLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MailDesign.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(MailDesign.control.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(MailDesign.stroke))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(
            MailDesign.controlHover.opacity(0.76),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(MailDesign.accentBlue.opacity(0.26))
        )
    }

    private var resultLabel: String {
        let count = presentation.assigned.count + presentation.available.count
        return count == 1 ? "1 label" : "\(count) labels"
    }

    @ViewBuilder
    private var results: some View {
        switch content {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading labels…")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed:
            VStack(spacing: 12) {
                EmptyState(
                    title: "Unable to load labels",
                    detail: "Try loading the labels for this email again."
                )
                Button("Retry", systemImage: "arrow.clockwise") {
                    retry()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            EmptyState(
                title: "No labels available",
                detail: "There are no labels available for this email account."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .items:
            if presentation.assigned.isEmpty,
               presentation.available.isEmpty {
                EmptyState(
                    title: "No matching labels",
                    detail: "Try a different label search."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !presentation.assigned.isEmpty {
                            section(
                                title: "Assigned",
                                commands: presentation.assigned
                            )
                        }
                        if !presentation.available.isEmpty {
                            section(
                                title: "Available",
                                commands: presentation.available
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func section(
        title: String,
        commands: [MessageLabelCommand]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(MailDesign.labelCommandTint)
                    .frame(width: 5, height: 5)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                Text("\(commands.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MailDesign.tertiaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(MailDesign.control.opacity(0.52), in: Capsule())
            }
            .foregroundStyle(MailDesign.tertiaryText)
            .padding(.horizontal, 8)

            ForEach(commands) { command in
                MessageLabelCommandRow(
                    command: command,
                    highlighted: command.labelID == viewModel.selectedLabelID,
                    pending: context.map {
                        labelActions.isPending(messageID: $0.messageID)
                    } ?? false
                ) {
                    Task { await execute(command) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            CommandCenterKeycap("↑↓")
            Text("navigate")
            CommandCenterKeycap("Return")
            Text("toggle label")
            CommandCenterKeycap("Esc")
            Text("close")
            Spacer()
            Text(effectiveLabelCountText)
                .font(.caption.weight(.medium))
                .foregroundStyle(MailDesign.labelCommandTint)
        }
        .font(.caption)
        .foregroundStyle(MailDesign.secondaryText)
        .padding(.horizontal, 2)
    }

    private var effectiveLabelCountText: String {
        let count = presentation.effectiveLabelCount
        return count == 1 ? "1 label assigned" : "\(count) labels assigned"
    }

    #if os(macOS)
    private func moveSelection(_ direction: MoveCommandDirection) {
        let mapped: MailboxRowMoveDirection?
        switch direction {
        case .up:
            mapped = .up
        case .down:
            mapped = .down
        default:
            mapped = nil
        }
        guard let mapped else { return }
        viewModel.moveSelection(mapped, in: presentation)
    }
    #endif

    private func submitSelected() {
        guard let command = presentation.actionableCommands.first(
            where: { $0.labelID == viewModel.selectedLabelID }
        ) else {
            return
        }
        Task { await execute(command) }
    }

    private func retry() {
        guard let context else { return }
        Task { await labelActions.retry(messageID: context.messageID) }
    }

    func execute(_ command: MessageLabelCommand) async {
        guard command.isActionable, let context else { return }
        let selected: Bool
        switch command.kind {
        case .add:
            selected = true
        case .remove:
            selected = false
        case .ruleOwned:
            return
        }
        await labelActions.setLabel(
            command.labelID,
            on: context.messageID,
            selected: selected
        )
        viewModel.reconcileSelection(in: presentation)
    }

    private func close() {
        onClose()
    }
}

private struct MessageLabelCommandRow: View {
    let command: MessageLabelCommand
    let highlighted: Bool
    let pending: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if command.isActionable {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
                .disabled(pending)
                .accessibilityValue(
                    command.accessibilitySelectionValue(
                        highlighted: highlighted
                    ) ?? ""
                )
            } else {
                content
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .help(command.ownershipHelp ?? "")
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : MailDesign.labelCommandTint)
                .frame(width: 32, height: 32)
                .background(
                    highlighted
                        ? MailDesign.accentBlue
                        : MailDesign.labelCommandTint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(MailDesign.labelCommandTint.opacity(0.22))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(command.title)
                    .font(.system(size: 14, weight: highlighted ? .semibold : .medium))
                if let ownershipHelp = command.ownershipHelp {
                    Text(ownershipHelp)
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            if pending, command.isActionable {
                ProgressView().controlSize(.small)
            } else if highlighted, command.isActionable {
                CommandCenterKeycap("Return", highlighted: true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(
            highlighted
                ? MailDesign.controlHover.opacity(0.76)
                : MailDesign.control.opacity(0.16),
            in: RoundedRectangle(cornerRadius: MailDesign.Radius.row)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MailDesign.Radius.row)
                .stroke(
                    highlighted
                        ? MailDesign.accentBlue.opacity(0.28)
                        : MailDesign.stroke.opacity(0.50)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
    }

    private var systemImage: String {
        switch command.kind {
        case .add:
            "tag.badge.plus"
        case .remove:
            "tag.slash"
        case .ruleOwned:
            "checkmark.tag"
        }
    }
}

private extension MailDesign {
    static let labelCommandTint = Color(hex: 0xFFD166)
}
