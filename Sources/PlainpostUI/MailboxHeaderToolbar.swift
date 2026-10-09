import SwiftUI

struct MailboxToolbarActionPadding: ViewModifier {
    static let groupEdgeInset: CGFloat = 6
    let outerEdge: Edge.Set

    func body(content: Content) -> some View {
        content
            .padding(outerEdge, Self.groupEdgeInset)
    }
}

struct MailboxToolbarCircleButtonStyle: ButtonStyle {
    static let diameter: CGFloat = 32

    let isSelected: Bool

    init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    func makeBody(configuration: Configuration) -> some View {
        CircleButtonBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }

    private struct CircleButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        let configuration: Configuration
        let isSelected: Bool

        var body: some View {
            configuration.label
                .frame(width: MailboxToolbarCircleButtonStyle.diameter, height: MailboxToolbarCircleButtonStyle.diameter)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(Circle().fill(backgroundColor))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var backgroundColor: Color {
            guard isHovering || configuration.isPressed else {
                return .clear
            }
            if isSelected {
                return Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.16)
            }
            return Color.primary.opacity(configuration.isPressed ? 0.14 : 0.09)
        }
    }
}

extension View {
    func mailboxToolbarActionPadding(outerEdge: Edge.Set = []) -> some View {
        modifier(MailboxToolbarActionPadding(outerEdge: outerEdge))
    }
}

struct MailboxHeaderPresentation: Equatable {
    let title: String
    let conversationCountLabel: String
    /// The Sync Node status line ("Sync Node unavailable — connected
    /// directly", "Update your Sync Node", "Reconnect Sync Node"); nil while
    /// the Node is connected or there is none.
    var statusLine: String? = nil

    static func make(
        title: String,
        availableRows: [MessageRowModel],
        mode: InboxDisplayMode,
        destination: PlainpostDestination,
        statusLine: String? = nil
    ) -> Self {
        let count = mode.visibleRows(
            from: availableRows,
            destination: destination
        ).count
        return Self(
            title: title,
            conversationCountLabel:
                "\(count) \(count == 1 ? "conversation" : "conversations")",
            statusLine: statusLine
        )
    }
}

struct MailboxHeaderIdentity: View {
    let presentation: MailboxHeaderPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.conversationCountLabel)
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
            if let statusLine = presentation.statusLine {
                NodeMailModeStatusLineView(text: statusLine)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct MailboxHeaderModePicker: View {
    @Binding var selectedInboxMode: String

    var body: some View {
        #if os(iOS)
        // Without the room to show its buttons, a toolbar `ControlGroup`
        // collapses to its label, so iOS gives it one.
        ControlGroup {
            modeButtons
        } label: {
            Label("Inbox view", systemImage: selectedMode.segmentedSystemImage)
        }
        .labelStyle(.iconOnly)
        .fixedSize()
        .accessibilityLabel("Inbox view")
        .accessibilityIdentifier("mailbox.toolbar.layout")
        #else
        ControlGroup {
            modeButtons
        }
        .labelStyle(.iconOnly)
        .fixedSize()
        .accessibilityLabel("Inbox view")
        .accessibilityIdentifier("mailbox.toolbar.layout")
        #endif
    }

    #if os(iOS)
    private var selectedMode: InboxDisplayMode {
        InboxDisplayMode(rawValue: selectedInboxMode) ?? .focusedList
    }
    #endif

    @ViewBuilder
    private var modeButtons: some View {
        let modes = InboxDisplayMode.segmentedDisplayOrder

        ForEach(Array(modes.enumerated()), id: \.element.rawValue) { index, mode in
            Button(mode.segmentedTitle, systemImage: mode.segmentedSystemImage) {
                selectedInboxMode = mode.rawValue
            }
            .help(mode.segmentedTitle)
            .accessibilityLabel(mode.segmentedAccessibilityLabel)
            .accessibilityAddTraits(
                selectedInboxMode == mode.rawValue ? .isSelected : []
            )
            .mailboxToolbarActionPadding(
                outerEdge: outerEdge(for: index, count: modes.count)
            )
            .buttonStyle(
                MailboxToolbarCircleButtonStyle(
                    isSelected: selectedInboxMode == mode.rawValue
                )
            )
        }
    }

    private func outerEdge(for index: Int, count: Int) -> Edge.Set {
        if index == 0 {
            return .leading
        }
        if index == count - 1 {
            return .trailing
        }
        return []
    }
}

struct MailboxGlobalActionGroup: View {
    let controlSize: ControlSize
    let compose: () -> Void
    let toggleAskMail: () -> Void
    let openCommandCenter: () -> Void

    var body: some View {
        ControlGroup {
            Button("Compose", systemImage: "square.and.pencil") {
                compose()
            }
            .help("Compose a new message")
            .accessibilityIdentifier("mailbox.toolbar.compose")
            .mailboxToolbarActionPadding(outerEdge: .leading)
            .buttonStyle(MailboxToolbarCircleButtonStyle())

            Button("Ask Mail", systemImage: "sparkles") {
                toggleAskMail()
            }
            .help("Ask questions across your local mail")
            .accessibilityIdentifier("mailbox.toolbar.ask-mail")
            .mailboxToolbarActionPadding()
            .buttonStyle(MailboxToolbarCircleButtonStyle())

            Button("Command Center", systemImage: "command") {
                openCommandCenter()
            }
            .help("Command Center (⌘K)")
            .accessibilityIdentifier("mailbox.toolbar.command-center")
            .mailboxToolbarActionPadding(outerEdge: .trailing)
            .buttonStyle(MailboxToolbarCircleButtonStyle())
        }
        .labelStyle(.iconOnly)
        .controlSize(controlSize)
        .fixedSize()
    }
}
