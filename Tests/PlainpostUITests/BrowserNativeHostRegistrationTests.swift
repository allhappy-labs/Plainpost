import Foundation
import XCTest
@testable import PlainpostUI

final class BrowserNativeHostRegistrationTests: XCTestCase {
    @MainActor
    func testStartupReturnsWhileInstallerIsBlockedThenPublishesReady() async throws {
        let status = BrowserNativeHostRegistrationStatus()
        let gate = BlockingBrowserNativeHostInstaller()

        PlainpostBrowserNativeHostStartup.startIfPackaged(
            bundleURL: URL(fileURLWithPath: "/Applications/Plainpost.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            status: status,
            executor: .utility,
            isExecutableFile: { _ in true },
            install: { executableURL, homeDirectory in
                gate.install(executableURL: executableURL, homeDirectory: homeDirectory)
            }
        )

        XCTAssertEqual(status.state, .pending)
        try await waitUntil { gate.hasStarted }
        XCTAssertFalse(gate.hasBeenReleased)
        XCTAssertEqual(status.state, .pending)
        XCTAssertEqual(
            gate.installedExecutableURL,
            URL(fileURLWithPath: "/Applications/Plainpost.app/Contents/MacOS/PlainpostBrowserBridge")
        )
        XCTAssertEqual(
            gate.installedHomeDirectory,
            URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        gate.release()

        try await waitUntil { status.state == .ready }
        XCTAssertEqual(status.diagnostic.value, "Ready")
    }

    @MainActor
    func testUnpackagedStartupIsANoOp() {
        let status = BrowserNativeHostRegistrationStatus(state: .ready)
        let counter = BrowserInstallerInvocationCounter()

        PlainpostBrowserNativeHostStartup.startIfPackaged(
            bundleURL: URL(fileURLWithPath: "/tmp/Plainpost", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            status: status,
            executor: .utility,
            isExecutableFile: { _ in true },
            install: { _, _ in counter.increment() }
        )

        XCTAssertEqual(status.state, .notApplicable)
        XCTAssertEqual(counter.value, 0)
    }

    @MainActor
    func testStartupReturnsWhileExecutableCheckIsBlockedThenInstallsAndPublishesReady() async throws {
        let status = BrowserNativeHostRegistrationStatus()
        let checker = BrowserExecutableCheckGate(result: true)
        let installer = BrowserInstallerInvocationCounter()

        PlainpostBrowserNativeHostStartup.startIfPackaged(
            bundleURL: URL(fileURLWithPath: "/Applications/Plainpost.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            status: status,
            executor: .utility,
            isExecutableFile: { checker.check(path: $0) },
            install: { _, _ in installer.increment() }
        )

        XCTAssertEqual(status.state, .pending)
        XCTAssertFalse(checker.wasCalledOnMainThread)
        guard !checker.wasCalledOnMainThread else { return }

        try await waitUntil { checker.hasStarted }
        XCTAssertFalse(checker.hasBeenReleased)
        XCTAssertEqual(status.state, .pending)
        XCTAssertEqual(installer.value, 0)
        XCTAssertEqual(
            checker.checkedPath,
            "/Applications/Plainpost.app/Contents/MacOS/PlainpostBrowserBridge"
        )

        checker.release()

        try await waitUntil { status.state == .ready }
        XCTAssertEqual(installer.value, 1)
        XCTAssertEqual(status.diagnostic.value, "Ready")
    }

    @MainActor
    func testMissingExecutablePublishesNeedsRepairAsynchronouslyWithoutInstalling() async throws {
        let status = BrowserNativeHostRegistrationStatus()
        let checker = BrowserExecutableCheckGate(result: false, blocks: false)
        let installer = BrowserInstallerInvocationCounter()

        PlainpostBrowserNativeHostStartup.startIfPackaged(
            bundleURL: URL(fileURLWithPath: "/Applications/Plainpost.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            status: status,
            executor: .utility,
            isExecutableFile: { checker.check(path: $0) },
            install: { _, _ in installer.increment() }
        )

        XCTAssertEqual(status.state, .pending)
        XCTAssertFalse(checker.wasCalledOnMainThread)
        try await waitUntil { status.state == .needsRepair }
        XCTAssertEqual(installer.value, 0)
        XCTAssertEqual(status.diagnostic.value, "Needs repair")
    }

    @MainActor
    func testInstallerFailurePublishesSafeNeedsRepairDiagnostic() async throws {
        struct SensitiveInstallerFailure: Error {}
        let status = BrowserNativeHostRegistrationStatus()

        PlainpostBrowserNativeHostStartup.startIfPackaged(
            bundleURL: URL(fileURLWithPath: "/Applications/Plainpost.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/private-user", isDirectory: true),
            status: status,
            executor: .utility,
            isExecutableFile: { _ in true },
            install: { _, _ in throw SensitiveInstallerFailure() }
        )

        XCTAssertEqual(status.state, .pending)
        try await waitUntil { status.state == .needsRepair }
        XCTAssertEqual(status.diagnostic.value, "Needs repair")
        XCTAssertEqual(
            status.diagnostic.detail,
            "Plainpost could not register the local browser bridge. Reopen Plainpost or run the local repair command."
        )
        XCTAssertFalse(status.diagnostic.detail.contains("private-user"))
        XCTAssertFalse(status.diagnostic.detail.localizedCaseInsensitiveContains("error"))
    }

    @MainActor
    func testDiagnosticsModelExposesLiveBrowserRegistrationStatus() {
        let status = BrowserNativeHostRegistrationStatus(state: .pending)
        let viewModel = AuditLogViewModel(
            log: EmptyAuditLog(),
            browserRegistrationStatus: status
        )

        XCTAssertIdentical(viewModel.browserRegistrationStatus, status)
        XCTAssertEqual(viewModel.browserRegistrationDiagnostic.value, "Pending")

        status.transition(to: .needsRepair)

        XCTAssertEqual(viewModel.browserRegistrationDiagnostic.value, "Needs repair")
        XCTAssertTrue(viewModel.browserRegistrationDiagnostic.needsAttention)
    }

    @MainActor
    func testBrowserRegistrationDiagnosticCopyIsFixedForEveryState() {
        XCTAssertEqual(
            BrowserNativeHostRegistrationStatus(state: .notApplicable).diagnostic,
            BrowserNativeHostRegistrationDiagnostic(
                value: "Not applicable",
                detail: "Browser registration runs only from the packaged Plainpost app.",
                needsAttention: false
            )
        )
        XCTAssertEqual(
            BrowserNativeHostRegistrationStatus(state: .pending).diagnostic,
            BrowserNativeHostRegistrationDiagnostic(
                value: "Pending",
                detail: "Plainpost is registering the local browser bridge.",
                needsAttention: false
            )
        )
        XCTAssertEqual(
            BrowserNativeHostRegistrationStatus(state: .ready).diagnostic,
            BrowserNativeHostRegistrationDiagnostic(
                value: "Ready",
                detail: "The local browser bridge is registered for this user.",
                needsAttention: false
            )
        )
        XCTAssertEqual(
            BrowserNativeHostRegistrationStatus(state: .needsRepair).diagnostic,
            BrowserNativeHostRegistrationDiagnostic(
                value: "Needs repair",
                detail: "Plainpost could not register the local browser bridge. Reopen Plainpost or run the local repair command.",
                needsAttention: true
            )
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for browser registration state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct EmptyAuditLog: AuditLogHandling {
    func rows() throws -> [AuditLogRowModel] { [] }
}

private final class BlockingBrowserNativeHostInstaller: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var executableURL: URL?
    private var homeDirectory: URL?

    var hasStarted: Bool {
        condition.withLock { started }
    }

    var hasBeenReleased: Bool {
        condition.withLock { released }
    }

    var installedExecutableURL: URL? {
        condition.withLock { executableURL }
    }

    var installedHomeDirectory: URL? {
        condition.withLock { homeDirectory }
    }

    func install(executableURL: URL, homeDirectory: URL) {
        condition.lock()
        self.executableURL = executableURL
        self.homeDirectory = homeDirectory
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private final class BrowserInstallerInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class BrowserExecutableCheckGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let result: Bool
    private let blocks: Bool
    private var started = false
    private var released = false
    private var mainThreadCall = false
    private var path: String?

    init(result: Bool, blocks: Bool = true) {
        self.result = result
        self.blocks = blocks
    }

    var hasStarted: Bool {
        condition.withLock { started }
    }

    var hasBeenReleased: Bool {
        condition.withLock { released }
    }

    var wasCalledOnMainThread: Bool {
        condition.withLock { mainThreadCall }
    }

    var checkedPath: String? {
        condition.withLock { path }
    }

    func check(path: String) -> Bool {
        condition.lock()
        self.path = path
        if Thread.isMainThread {
            mainThreadCall = true
            condition.unlock()
            return result
        }
        started = true
        condition.broadcast()
        while blocks && !released {
            condition.wait()
        }
        condition.unlock()
        return result
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}
