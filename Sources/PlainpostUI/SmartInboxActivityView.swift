import SwiftUI
import PlainpostOperations

#if os(macOS)
import AppKit
#endif

struct SmartInboxActivityActionError: Error {
    let didCommitResume: Bool

    init(didCommitResume: Bool) {
        self.didCommitResume = didCommitResume
    }
}

@MainActor
final class SmartInboxActivityCoordinator: ObservableObject {
    typealias JobProvider = () -> PlainpostDurableJob?
    typealias PauseAction = (String) throws -> Void
    typealias ResumeAction = (String) async throws -> Void

    @Published private(set) var presentation: SmartInboxActivityPresentation?
    @Published private(set) var isActionInFlight = false
    @Published private(set) var actionMessage: String?
    private(set) var job: PlainpostDurableJob?

    private let jobProvider: JobProvider
    private let pauseAction: PauseAction
    private let resumeAction: ResumeAction
    private let lowPowerAllowsWork: () -> Bool

    init(
        jobProvider: @escaping JobProvider,
        pause: @escaping PauseAction,
        resume: @escaping ResumeAction,
        lowPowerAllowsWork: @escaping () -> Bool = { false }
    ) {
        self.jobProvider = jobProvider
        self.pauseAction = pause
        self.resumeAction = resume
        self.lowPowerAllowsWork = lowPowerAllowsWork
        refresh()
    }

    init(previewPresentation: SmartInboxActivityPresentation?) {
        self.jobProvider = { nil }
        self.pauseAction = { _ in }
        self.resumeAction = { _ in }
        self.lowPowerAllowsWork = { false }
        self.presentation = previewPresentation
        self.job = nil
    }

    func refresh(locale: Locale = .current, clearActionMessage: Bool = true) {
        job = jobProvider()
        presentation = SmartInboxActivityPresentation(
            job: job,
            lowPowerAllowsWork: lowPowerAllowsWork(),
            locale: locale
        )
        if clearActionMessage {
            actionMessage = nil
        }
    }

    var isActive: Bool {
        guard let job else { return false }
        return job.state == .queued || job.state == .running || job.state == .paused
    }

    var isRerunActive: Bool {
        Self.isActiveRerun(job)
    }

    static func isActiveRerun(
        _ job: PlainpostDurableJob?
    ) -> Bool {
        guard let job,
              job.state == .queued || job.state == .running || job.state == .paused,
              let input = try? JSONDecoder().decode(
                  PlainpostAIOperationInput.self,
                  from: Data(job.payloadJSON.utf8)
              ),
              input.operation == .recategorizeInbox else {
            return false
        }
        return input.smartInboxRunMode == .rerunAll
    }

    func pause(_ jobID: String, locale: Locale = .current) {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        actionMessage = nil
        defer { isActionInFlight = false }

        do {
            try pauseAction(jobID)
            refresh(locale: locale)
        } catch {
            refresh(locale: locale, clearActionMessage: false)
            actionMessage = "Couldn't pause—try again."
        }
    }

    func resume(_ jobID: String, locale: Locale = .current) async {
        guard !isActionInFlight else { return }
        isActionInFlight = true
        actionMessage = nil
        defer { isActionInFlight = false }

        do {
            try await resumeAction(jobID)
            refresh(locale: locale)
        } catch {
            refresh(locale: locale, clearActionMessage: false)
            if let actionError = error as? SmartInboxActivityActionError,
               actionError.didCommitResume {
                actionMessage = "Waiting to resume"
            } else if error as? SmartInboxPowerGateError == .lowPowerMode {
                actionMessage = "Paused in Low Power Mode"
            } else {
                actionMessage = "Couldn't resume—try again."
            }
        }
    }
}

struct SmartInboxActivitySection: View {
    static let detailMinimumScaleFactor: CGFloat = 0.84

    let presentation: SmartInboxActivityPresentation
    let isActionInFlight: Bool
    let actionMessage: String?
    let pause: (String) -> Void
    let resume: (String) -> Void

    var isControlDisabled: Bool {
        isActionInFlight || presentation.control == .pausing
    }

    private var displayedTitle: String {
        actionMessage == "Waiting to resume"
            ? "Waiting to resume"
            : presentation.title
    }

    private var displayedError: String? {
        guard actionMessage != "Waiting to resume" else {
            return presentation.errorDetail
        }
        return actionMessage ?? presentation.errorDetail
    }

    var descriptiveAccessibilityLabel: String {
        let baseLabel: String
        if displayedTitle != presentation.title,
           presentation.accessibilityLabel.hasPrefix(presentation.title) {
            baseLabel = displayedTitle
                + presentation.accessibilityLabel.dropFirst(presentation.title.count)
        } else {
            baseLabel = presentation.accessibilityLabel
        }
        guard let displayedError,
              !baseLabel.contains(displayedError) else {
            return baseLabel
        }
        return "\(baseLabel), \(displayedError)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    progressIndicator
                        .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayedTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let detail = presentation.detail {
                            if let compactDetail = presentation.compactDetail {
                                ViewThatFits(in: .horizontal) {
                                    activityDetail(detail)
                                        .fixedSize(horizontal: true, vertical: false)
                                    activityDetail(compactDetail)
                                }
                            } else {
                                activityDetail(detail)
                            }
                        }
                        if let displayedError {
                            Text(displayedError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(descriptiveAccessibilityLabel)

                if presentation.control != nil {
                    controlButton
                        .frame(width: 28, height: 28)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func activityDetail(_ detail: String) -> some View {
        Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(Self.detailMinimumScaleFactor)
    }

    func performControl() {
        guard !isControlDisabled else { return }
        switch presentation.control {
        case .pause:
            pause(presentation.id)
        case .resume:
            resume(presentation.id)
        case .pausing, .none:
            return
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if presentation.errorDetail != nil {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        } else if let fraction = presentation.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var controlButton: some View {
#if os(macOS)
        switch presentation.control {
        case .pause:
            SmartInboxActivityNativeControl(
                symbolName: "pause.fill",
                accessibilityLabel: "Pause Smart Inbox",
                accessibilityValue: nil,
                isEnabled: !isControlDisabled,
                action: performControl
            )
        case .pausing:
            SmartInboxActivityNativeControl(
                symbolName: "pause.fill",
                accessibilityLabel: "Pause Smart Inbox",
                accessibilityValue: "Pausing",
                isEnabled: false,
                action: {}
            )
        case .resume:
            SmartInboxActivityNativeControl(
                symbolName: "play.fill",
                accessibilityLabel: "Resume Smart Inbox",
                accessibilityValue: nil,
                isEnabled: !isControlDisabled,
                action: performControl
            )
        case .none:
            EmptyView()
        }
#else
        switch presentation.control {
        case .pause:
            Button(action: performControl) {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Pause Smart Inbox")
            .accessibilityLabel("Pause Smart Inbox")
            .accessibilityIdentifier("smart-inbox-activity-control")
            .disabled(isControlDisabled)
        case .pausing:
            Button(action: {}) {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Pause Smart Inbox")
            .accessibilityLabel("Pause Smart Inbox")
            .accessibilityValue("Pausing")
            .accessibilityIdentifier("smart-inbox-activity-control")
            .disabled(true)
        case .resume:
            Button(action: performControl) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Resume Smart Inbox")
            .accessibilityLabel("Resume Smart Inbox")
            .accessibilityIdentifier("smart-inbox-activity-control")
            .disabled(isControlDisabled)
        case .none:
            EmptyView()
        }
#endif
    }
}

#if os(macOS)
private struct SmartInboxActivityNativeControl: NSViewRepresentable {
    let symbolName: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: NSButton, coordinator: Coordinator) {
        coordinator.action = action
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        button.toolTip = accessibilityLabel
        button.isEnabled = isEnabled
        button.setAccessibilityIdentifier("smart-inbox-activity-control")
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}
#endif
