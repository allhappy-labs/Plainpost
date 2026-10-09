import Foundation
import XCTest
@testable import PlainpostCore

final class LaunchAgentPlistTests: XCTestCase {
    func testPackagedServiceRestoreRegistersCurrentBundledService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostServiceRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appBundleURL = root.appendingPathComponent("Plainpost.app", isDirectory: true)
        let serviceURL = appBundleURL.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        try FileManager.default.createDirectory(
            at: serviceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("signed-service".utf8).write(to: serviceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serviceURL.path)
        let plistURL = appBundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(PlainpostPackagedServiceRestorer.bundledPlistName)"
        )
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("packaged-launch-agent".utf8).write(to: plistURL)
        let legacyPlistURL = root.appendingPathComponent("legacy-launch-agent.plist")
        try Data("obsolete-absolute-path".utf8).write(to: legacyPlistURL)
        let registrations = ServiceRegistrationRecorder()
        let restorer = PlainpostPackagedServiceRestorer(
            appBundleURL: appBundleURL,
            legacyPlistURL: legacyPlistURL,
            registerService: { await registrations.register() }
        )

        let didRestore = try await restorer.restore()
        XCTAssertTrue(didRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlistURL.path))
        let registrationCount = await registrations.snapshot()
        XCTAssertEqual(registrationCount, 1)
    }

    func testLaunchAgentTargetsNestedServiceAndPublishesMachService() throws {
        let serviceExecutablePath =
            "/Applications/Plainpost.app/Contents/Library/Helpers/"
            + "PlainpostService.app/Contents/MacOS/PlainpostService"
        let configuration = PlainpostLaunchAgentConfiguration(
            serviceExecutablePath: serviceExecutablePath,
            standardOutPath: "/Users/me/Library/Logs/Plainpost/service.out.log",
            standardErrorPath: "/Users/me/Library/Logs/Plainpost/service.err.log"
        )

        let object = try XCTUnwrap(
            PlainpostLaunchAgentPlist.propertyList(for: configuration) as [String: Any]?
        )

        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [serviceExecutablePath, "--xpc-service"]
        )
        XCTAssertEqual(
            object["MachServices"] as? [String: Bool],
            ["com.marynavdovenko.Plainpost.Service": true]
        )
    }

    func testLaunchAgentPlistRunsPersistentServiceWithoutSecrets() throws {
        let configuration = PlainpostLaunchAgentConfiguration(
            serviceExecutablePath:
                "/Applications/Plainpost.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService",
            dataDirectoryPath: "/Users/me/Library/Application Support/Plainpost",
            standardOutPath: "/Users/me/Library/Logs/Plainpost/service.out.log",
            standardErrorPath: "/Users/me/Library/Logs/Plainpost/service.err.log"
        )

        let data = try PlainpostLaunchAgentPlist.data(for: configuration)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(object["Label"] as? String, "com.marynavdovenko.Plainpost.BackgroundAgent")
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [
                "/Applications/Plainpost.app/Contents/Library/Helpers/"
                    + "PlainpostService.app/Contents/MacOS/PlainpostService",
                "--xpc-service",
            ]
        )
        XCTAssertEqual(
            object["MachServices"] as? [String: Bool],
            ["com.marynavdovenko.Plainpost.Service": true]
        )
        XCTAssertEqual(object["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((object["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(object["StandardOutPath"] as? String, "/Users/me/Library/Logs/Plainpost/service.out.log")
        XCTAssertEqual(object["StandardErrorPath"] as? String, "/Users/me/Library/Logs/Plainpost/service.err.log")

        let environment = try XCTUnwrap(object["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["PLAINPOST_DATA_DIR"], "/Users/me/Library/Application Support/Plainpost")

        let plist = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(plist.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(plist.localizedCaseInsensitiveContains("secret"))
    }
}

private actor ServiceRegistrationRecorder {
    private var count = 0

    func register() { count += 1 }
    func snapshot() -> Int { count }
}
