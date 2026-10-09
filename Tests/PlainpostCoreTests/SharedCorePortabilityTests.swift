import XCTest

final class SharedCorePortabilityTests: XCTestCase {
    func testPackageDeclaresIOSPlatform() throws {
        let package = try String(contentsOfFile: "\(Self.repositoryRoot)/Package.swift", encoding: .utf8)

        XCTAssertTrue(package.contains(".iOS("))
    }

    func testSharedModulesAvoidAppleUIAndLimitSecurityToMailTLS() throws {
        let sharedModulePaths = [
            "Sources/PlainpostCore",
            "Sources/PlainpostAI",
            "Sources/PlainpostDB"
        ]
        let forbiddenUIImports = [
            "import AppKit",
            "import UIKit",
            "import SwiftUI"
        ]

        for modulePath in sharedModulePaths {
            let root = "\(Self.repositoryRoot)/\(modulePath)"
            let files = try FileManager.default.subpathsOfDirectory(atPath: root)
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let path = "\(root)/\(file)"
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                for forbiddenImport in forbiddenUIImports {
                    XCTAssertFalse(contents.contains(forbiddenImport), "\(modulePath)/\(file) imports \(forbiddenImport)")
                }
                // Certificate trust evaluation is shared by the macOS and
                // iOS mail transports; keep Security out of every other
                // shared source file.
                if "\(modulePath)/\(file)" != "Sources/PlainpostCore/MailTLSSettings.swift" {
                    XCTAssertFalse(contents.contains("import Security"), "\(modulePath)/\(file) imports Security")
                }
            }
        }
    }

    private static var repositoryRoot: String {
        String(URL(fileURLWithPath: #filePath).pathComponents.dropLast(3).joined(separator: "/"))
    }
}
