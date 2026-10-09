import Darwin
import Foundation
import PlainpostBrowserIntegration
import PlainpostLocalAPI
import PlainpostServiceIPC

#if os(macOS)
import AppKit
#endif

private let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--install-hosts" {
    guard arguments.count == 3, arguments[1] == "--executable" else {
        exit(EX_USAGE)
    }
    do {
        let homeDirectory = ProcessInfo.processInfo.environment["HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        try BrowserNativeHostInstaller().install(
            executableURL: URL(fileURLWithPath: arguments[2]),
            homeDirectory: homeDirectory
        )
        exit(EXIT_SUCCESS)
    } catch {
        exit(EXIT_FAILURE)
    }
}

guard BrowserCallerValidator.isAllowed(arguments: arguments) else {
    exit(EX_NOPERM)
}

let homeDirectory = ProcessInfo.processInfo.environment["HOME"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let socketURL = homeDirectory.appendingPathComponent(
    "Library/Application Support/Plainpost/LocalAPI-v1.sock"
)
let client = LocalAPIUnixClient(socketURL: socketURL)
let serviceClient = PlainpostServiceClient(capability: .browserHost)

do {
    try BrowserBridgeRuntime.run(
        readFrame: {
            try NativeMessagingFrameCodec.readFrame(read: { count in
                try FileHandle.standardInput.read(upToCount: count) ?? Data()
            })
        },
        vaultIsUnlocked: {
            sharedVaultIsUnlocked(serviceClient)
        },
        lockedResponse: { request in
            BrowserBridgeResponse.unavailable(for: request)
        },
        forward: { request in
            guard BrowserBridgeResponse.isRequestAllowedForForwarding(request) else {
                return BrowserBridgeResponse.invalidRequest()
            }
            do {
                return try client.requestLaunchingApplicationIfNeeded(
                    request,
                    launchApplication: launchPlainpost
                )
            } catch {
                return BrowserBridgeResponse.unavailable(for: request)
            }
        },
        writeFrame: { response in
            try FileHandle.standardOutput.write(
                contentsOf: NativeMessagingFrameCodec.encode(response)
            )
        },
        onOutputFailure: {
            try? FileHandle.standardInput.close()
        }
    )
    exit(EXIT_SUCCESS)
} catch {
    exit(EX_DATAERR)
}

@Sendable private func sharedVaultIsUnlocked(
    _ client: PlainpostServiceClient
) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let result = LockedVaultStatus()
    Task {
        let unlocked = (try? await client.status().availability) == .unlocked
        result.set(unlocked)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else {
        return false
    }
    return result.value
}

private final class LockedVaultStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var unlocked = false

    var value: Bool {
        lock.withLock { unlocked }
    }

    func set(_ value: Bool) {
        lock.withLock {
            unlocked = value
        }
    }
}

@Sendable private func launchPlainpost() -> Bool {
    #if os(macOS)
    guard let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.marynavdovenko.Plainpost"
    ) else {
        return false
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(
        at: applicationURL,
        configuration: configuration
    ) { _, _ in }
    return true
    #else
    return false
    #endif
}
