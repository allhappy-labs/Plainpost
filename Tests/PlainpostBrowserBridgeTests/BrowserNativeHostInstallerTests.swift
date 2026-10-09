import Foundation
import XCTest
@testable import PlainpostBrowserIntegration

final class BrowserNativeHostInstallerTests: XCTestCase {
    func testInstalledHostIdentityUsesValidNativeMessagingGrammar() throws {
        let fixture = try InstallerFixture()

        try BrowserNativeHostInstaller().install(
            executableURL: fixture.executableURL,
            homeDirectory: fixture.homeURL
        )

        let directory = try fixture.manifestDirectory(
            BrowserNativeHostInstaller.chromiumDirectories[0]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["com.marynavdovenko.plainpost.browser.json"]
        )

        let manifestURL = directory.appendingPathComponent(
            "com.marynavdovenko.plainpost.browser.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let hostName = try XCTUnwrap(object["name"] as? String)
        XCTAssertEqual(hostName, "com.marynavdovenko.plainpost.browser")
        XCTAssertNotNil(
            hostName.range(
                of: #"^[a-z0-9_]+(?:\.[a-z0-9_]+)*$"#,
                options: .regularExpression
            )
        )
    }

    func testInstallerWritesEveryChromiumAndGeckoManifest() throws {
        let fixture = try InstallerFixture()

        try BrowserNativeHostInstaller().install(
            executableURL: fixture.executableURL,
            homeDirectory: fixture.homeURL
        )

        for directory in BrowserNativeHostInstaller.chromiumDirectories {
            let object = try fixture.manifest(in: directory)
            XCTAssertEqual(object["name"] as? String, "com.marynavdovenko.plainpost.browser")
            XCTAssertEqual(object["description"] as? String, "Plainpost browser integration")
            XCTAssertEqual(object["path"] as? String, fixture.executableURL.path)
            XCTAssertEqual(object["type"] as? String, "stdio")
            XCTAssertEqual(
                object["allowed_origins"] as? [String],
                ["chrome-extension://fjhlbghobimgnakkhigjmjejahjackfo/"]
            )
            XCTAssertNil(object["allowed_extensions"])
            XCTAssertEqual(object.keys.count, 5)
        }

        for directory in BrowserNativeHostInstaller.geckoDirectories {
            let object = try fixture.manifest(in: directory)
            XCTAssertEqual(object["name"] as? String, "com.marynavdovenko.plainpost.browser")
            XCTAssertEqual(object["description"] as? String, "Plainpost browser integration")
            XCTAssertEqual(object["path"] as? String, fixture.executableURL.path)
            XCTAssertEqual(object["type"] as? String, "stdio")
            XCTAssertEqual(
                object["allowed_extensions"] as? [String],
                ["quick-mail@plainpost.olhapi.com"]
            )
            XCTAssertNil(object["allowed_origins"])
            XCTAssertEqual(object.keys.count, 5)
        }
    }

    func testInstallerRefusesRelativeOrNonExecutableBridgePath() throws {
        let fixture = try InstallerFixture()
        let nonExecutable = fixture.rootURL.appendingPathComponent("not-executable")
        XCTAssertTrue(FileManager.default.createFile(atPath: nonExecutable.path, contents: Data()))

        XCTAssertThrowsError(
            try BrowserNativeHostInstaller().install(
                executableURL: URL(fileURLWithPath: "relative/bridge"),
                homeDirectory: fixture.homeURL
            )
        ) { error in
            XCTAssertEqual(error as? BrowserNativeHostInstallerError, .invalidExecutable)
        }
        XCTAssertThrowsError(
            try BrowserNativeHostInstaller().install(
                executableURL: nonExecutable,
                homeDirectory: fixture.homeURL
            )
        ) { error in
            XCTAssertEqual(error as? BrowserNativeHostInstallerError, .invalidExecutable)
        }
    }

    func testInstallerRefusesExecutableDirectoryAsBridgePath() throws {
        let fixture = try InstallerFixture()
        let directory = fixture.rootURL.appendingPathComponent("not-a-bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )

        XCTAssertThrowsError(
            try BrowserNativeHostInstaller().install(
                executableURL: directory,
                homeDirectory: fixture.homeURL
            )
        ) { error in
            XCTAssertEqual(error as? BrowserNativeHostInstallerError, .invalidExecutable)
        }
    }

    func testInstallerAtomicallyReplacesAndIdempotentlyRepairsManifest() throws {
        let fixture = try InstallerFixture()
        let directory = try fixture.manifestDirectory(
            BrowserNativeHostInstaller.chromiumDirectories[0]
        )
        let manifestURL = directory.appendingPathComponent(
            "com.marynavdovenko.plainpost.browser.json"
        )
        try Data("incomplete".utf8).write(to: manifestURL)

        try BrowserNativeHostInstaller().install(
            executableURL: fixture.executableURL,
            homeDirectory: fixture.homeURL
        )
        let firstData = try Data(contentsOf: manifestURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: firstData))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)

        try BrowserNativeHostInstaller().install(
            executableURL: fixture.executableURL,
            homeDirectory: fixture.homeURL
        )
        XCTAssertEqual(try Data(contentsOf: manifestURL), firstData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }
}

private final class InstallerFixture {
    let rootURL: URL
    let homeURL: URL
    let executableURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainpostBrowserInstallerTests-\(UUID().uuidString)")
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        executableURL = rootURL.appendingPathComponent("PlainpostBrowserBridge")
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: executableURL.path, contents: Data("bridge".utf8))
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func manifestDirectory(_ relativeDirectory: String) throws -> URL {
        let url = homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func manifest(in relativeDirectory: String) throws -> [String: Any] {
        let url = try manifestDirectory(relativeDirectory)
            .appendingPathComponent("com.marynavdovenko.plainpost.browser.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}
