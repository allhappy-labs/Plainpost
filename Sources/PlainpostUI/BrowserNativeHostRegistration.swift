import Dispatch
import Foundation
import PlainpostBrowserIntegration
import OSLog

public enum BrowserNativeHostRegistrationState: Equatable, Sendable {
    case notApplicable
    case pending
    case ready
    case needsRepair
}

public struct BrowserNativeHostRegistrationDiagnostic: Equatable, Sendable {
    public let value: String
    public let detail: String
    public let needsAttention: Bool

    public init(value: String, detail: String, needsAttention: Bool) {
        self.value = value
        self.detail = detail
        self.needsAttention = needsAttention
    }
}

@MainActor
public final class BrowserNativeHostRegistrationStatus: ObservableObject {
    @Published public private(set) var state: BrowserNativeHostRegistrationState

    public init(state: BrowserNativeHostRegistrationState = .notApplicable) {
        self.state = state
    }

    public var diagnostic: BrowserNativeHostRegistrationDiagnostic {
        switch state {
        case .notApplicable:
            BrowserNativeHostRegistrationDiagnostic(
                value: "Not applicable",
                detail: "Browser registration runs only from the packaged Plainpost app.",
                needsAttention: false
            )
        case .pending:
            BrowserNativeHostRegistrationDiagnostic(
                value: "Pending",
                detail: "Plainpost is registering the local browser bridge.",
                needsAttention: false
            )
        case .ready:
            BrowserNativeHostRegistrationDiagnostic(
                value: "Ready",
                detail: "The local browser bridge is registered for this user.",
                needsAttention: false
            )
        case .needsRepair:
            BrowserNativeHostRegistrationDiagnostic(
                value: "Needs repair",
                detail: "Plainpost could not register the local browser bridge. Reopen Plainpost or run the local repair command.",
                needsAttention: true
            )
        }
    }

    func transition(to state: BrowserNativeHostRegistrationState) {
        self.state = state
    }
}

struct BrowserNativeHostInstallationExecutor: Sendable {
    private let submitHandler: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(submit: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.submitHandler = submit
    }

    func submit(_ operation: @escaping @Sendable () -> Void) {
        submitHandler(operation)
    }

    static let utility = BrowserNativeHostInstallationExecutor { operation in
        DispatchQueue.global(qos: .utility).async(execute: operation)
    }
}

private struct BrowserNativeHostInstallationRequest: Sendable {
    let bundleURL: URL
    let homeDirectory: URL
    let bridgeURL: URL
}

private struct BrowserNativeHostInstallationDependencies: Sendable {
    let isExecutableFile: @Sendable (String) -> Bool
    let install: @Sendable (URL, URL) throws -> Void
}

private let plainpostBrowserIntegrationLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "browser-integration"
)

enum PlainpostBrowserNativeHostStartup {
    private static var defaultHomeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    @MainActor
    static func startIfPackaged(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = defaultHomeDirectory,
        status: BrowserNativeHostRegistrationStatus,
        executor: BrowserNativeHostInstallationExecutor = .utility,
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        install: @escaping @Sendable (URL, URL) throws -> Void = { executableURL, homeDirectory in
            try BrowserNativeHostInstaller().install(
                executableURL: executableURL,
                homeDirectory: homeDirectory
            )
        }
    ) {
        guard bundleURL.pathExtension == "app" else {
            status.transition(to: .notApplicable)
            return
        }
        let request = BrowserNativeHostInstallationRequest(
            bundleURL: bundleURL,
            homeDirectory: homeDirectory,
            bridgeURL: bundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent("PlainpostBrowserBridge")
        )
        let dependencies = BrowserNativeHostInstallationDependencies(
            isExecutableFile: isExecutableFile,
            install: install
        )

        status.transition(to: .pending)
        executor.submit { [request, dependencies] in
            let result: BrowserNativeHostRegistrationState
            if !dependencies.isExecutableFile(request.bridgeURL.path) {
                plainpostBrowserIntegrationLogger.error(
                    "Browser integration is unavailable because the bundled bridge is missing or not executable."
                )
                result = .needsRepair
            } else {
                do {
                    try dependencies.install(request.bridgeURL, request.homeDirectory)
                    result = .ready
                } catch {
                    plainpostBrowserIntegrationLogger.error(
                        "Browser integration manifests could not be installed for the current user."
                    )
                    result = .needsRepair
                }
            }
            Task { @MainActor [weak status] in
                status?.transition(to: result)
            }
        }
    }
}
