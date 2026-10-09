import Darwin
import XCTest
@testable import PlainpostCLI
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostTestSupport
@testable import PlainpostService
@testable import PlainpostUI

final class PlainpostCLIHarnessTests: XCTestCase {
    func testProductionVaultBoundary() throws {
        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.currentDirectoryURL = repositoryRootURL
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRootURL
                .appendingPathComponent(
                    "Scripts/plainpost/assert-service-vault-boundary.sh"
                )
                .path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let completeOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, completeOutput)
    }

    func testKeychainIsolationSourceContracts() throws {
        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for script in [
            "Scripts/plainpost-keychain-use-detector-contract.sh",
            "Scripts/plainpost-preflight-contract.sh",
        ] {
            let process = Process()
            process.currentDirectoryURL = repositoryRootURL
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                repositoryRootURL.appendingPathComponent(script).path,
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output

            try process.run()
            let completeOutput = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "\(script):\n\(completeOutput)"
            )
        }
    }

    func testKeychainIsolationRunnerRechecksBaselineAfterFailureAndSignal() throws {
        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlainpostKeychainIsolationRunner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let keychainURL = fixtureURL.appendingPathComponent(
            "fixture.keychain-db"
        )
        try Data("unchanged fixture".utf8).write(to: keychainURL)
        let callLogURL = fixtureURL.appendingPathComponent("calls.log")
        let bodyMarkerURL = fixtureURL.appendingPathComponent("body-ran")
        let securityStubURL = fixtureURL.appendingPathComponent("security")
        let countStubURL = fixtureURL.appendingPathComponent("count")
        let bodyStubURL = fixtureURL.appendingPathComponent("body")
        try writeExecutable(
            #"""
            #!/bin/zsh
            print -r -- "$1" >>"$CALL_LOG"
            case "$1" in
              default-keychain) print -r -- "\"$FIXTURE_KEYCHAIN\"" ;;
              list-keychains) print -r -- "\"$FIXTURE_KEYCHAIN\"" ;;
              *) exit 65 ;;
            esac
            """#,
            to: securityStubURL
        )
        try writeExecutable(
            #"""
            #!/bin/zsh
            print -r -- "count:$2" >>"$CALL_LOG"
            print -r -- "0"
            """#,
            to: countStubURL
        )
        try writeExecutable(
            #"""
            #!/bin/zsh
            : >"$BODY_MARKER"
            exit 23
            """#,
            to: bodyStubURL
        )

        let snapshotURL = fixtureURL.appendingPathComponent(
            "retained-baseline",
            isDirectory: true
        )
        let process = Process()
        process.currentDirectoryURL = repositoryRootURL
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRootURL.appendingPathComponent(
                "Scripts/plainpost/assert-keychain-isolation.sh"
            ).path,
            "run",
            snapshotURL.path,
            "--",
            bodyStubURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PLAINPOST_SECURITY_COMMAND"] = securityStubURL.path
        environment["PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND"] =
            countStubURL.path
        environment["FIXTURE_KEYCHAIN"] = keychainURL.path
        environment["CALL_LOG"] = callLogURL.path
        environment["BODY_MARKER"] = bodyMarkerURL.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let completeOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 23, completeOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyMarkerURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: snapshotURL.path),
            "The baseline must remain available for manual rechecking."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent(".incomplete").path
            )
        )
        let calls = try String(contentsOf: callLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            calls.filter { $0 == "default-keychain" }.count,
            2,
            completeOutput
        )
        XCTAssertEqual(
            calls.filter { $0 == "list-keychains" }.count,
            2,
            completeOutput
        )
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("count:") }.count,
            6,
            completeOutput
        )

        let signalCallLogURL = fixtureURL.appendingPathComponent(
            "signal-calls.log"
        )
        let signalBodyMarkerURL = fixtureURL.appendingPathComponent(
            "signal-body-ran"
        )
        let signalBodyPIDURL = fixtureURL.appendingPathComponent(
            "signal-body.pid"
        )
        let signalPostCheckMarkerURL = fixtureURL.appendingPathComponent(
            "signal-body-continued-after-parent-exit"
        )
        let signalBodyStubURL = fixtureURL.appendingPathComponent("signal-body")
        try writeExecutable(
            #"""
            #!/bin/zsh
            trap "" HUP INT TERM
            print -r -- "$$" >"$BODY_PID"
            : >"$BODY_MARKER"
            sleep 1
            : >"$POST_CHECK_MARKER"
            """#,
            to: signalBodyStubURL
        )
        let signalSnapshotURL = fixtureURL.appendingPathComponent(
            "retained-signal-baseline",
            isDirectory: true
        )
        let signalProcess = Process()
        signalProcess.currentDirectoryURL = repositoryRootURL
        signalProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        signalProcess.arguments = [
            repositoryRootURL.appendingPathComponent(
                "Scripts/plainpost/assert-keychain-isolation.sh"
            ).path,
            "run",
            signalSnapshotURL.path,
            "--",
            signalBodyStubURL.path,
        ]
        environment["CALL_LOG"] = signalCallLogURL.path
        environment["BODY_MARKER"] = signalBodyMarkerURL.path
        environment["BODY_PID"] = signalBodyPIDURL.path
        environment["POST_CHECK_MARKER"] = signalPostCheckMarkerURL.path
        signalProcess.environment = environment
        let signalOutput = Pipe()
        signalProcess.standardOutput = signalOutput
        signalProcess.standardError = signalOutput

        try signalProcess.run()
        let bodyStartDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(
            atPath: signalBodyMarkerURL.path
        ), Date() < bodyStartDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: signalBodyMarkerURL.path),
            "The guarded child did not start before the signal deadline."
        )
        signalProcess.terminate()
        let completeSignalOutput = String(
            decoding: signalOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        signalProcess.waitUntilExit()

        XCTAssertEqual(
            signalProcess.terminationStatus,
            143,
            completeSignalOutput
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: signalBodyMarkerURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: signalPostCheckMarkerURL.path
            ),
            "The guarded child continued after the wrapper's final check."
        )
        let childPID = try XCTUnwrap(
            Int32(
                String(
                    contentsOf: signalBodyPIDURL,
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertNotEqual(
            kill(childPID, 0),
            0,
            "The guarded child remained alive after interrupted verification."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: signalSnapshotURL.path),
            "The interrupted baseline must remain available for rechecking."
        )
        let signalCalls = try String(
            contentsOf: signalCallLogURL,
            encoding: .utf8
        )
        .split(separator: "\n")
        .map(String.init)
        XCTAssertEqual(
            signalCalls.filter { $0 == "default-keychain" }.count,
            2,
            completeSignalOutput
        )
        XCTAssertEqual(
            signalCalls.filter { $0 == "list-keychains" }.count,
            2,
            completeSignalOutput
        )
        XCTAssertEqual(
            signalCalls.filter { $0.hasPrefix("count:") }.count,
            6,
            completeSignalOutput
        )

        let immediateCallLogURL = fixtureURL.appendingPathComponent(
            "immediate-signal-calls.log"
        )
        let immediateHookMarkerURL = fixtureURL.appendingPathComponent(
            "immediate-signal-hook-ran"
        )
        let immediateBodyMarkerURL = fixtureURL.appendingPathComponent(
            "immediate-signal-body-ran"
        )
        let immediateHookURL = fixtureURL.appendingPathComponent(
            "immediate-signal-hook"
        )
        let immediateBodyURL = fixtureURL.appendingPathComponent(
            "immediate-signal-body"
        )
        try writeExecutable(
            #"""
            #!/bin/zsh
            trap "" HUP INT TERM
            : >"$IMMEDIATE_HOOK_MARKER"
            sleep 0.4
            """#,
            to: immediateHookURL
        )
        try writeExecutable(
            #"""
            #!/bin/zsh
            : >"$IMMEDIATE_BODY_MARKER"
            """#,
            to: immediateBodyURL
        )
        let immediateSnapshotURL = fixtureURL.appendingPathComponent(
            "retained-immediate-signal-baseline",
            isDirectory: true
        )
        let immediateProcess = Process()
        immediateProcess.currentDirectoryURL = repositoryRootURL
        immediateProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        immediateProcess.arguments = [
            repositoryRootURL.appendingPathComponent(
                "Scripts/plainpost/assert-keychain-isolation.sh"
            ).path,
            "run",
            immediateSnapshotURL.path,
            "--",
            immediateBodyURL.path,
        ]
        environment["CALL_LOG"] = immediateCallLogURL.path
        environment["IMMEDIATE_HOOK_MARKER"] = immediateHookMarkerURL.path
        environment["IMMEDIATE_BODY_MARKER"] = immediateBodyMarkerURL.path
        environment["PLAINPOST_KEYCHAIN_GUARD_BEFORE_RESERVE_COMMAND"] =
            immediateHookURL.path
        immediateProcess.environment = environment
        let immediateOutput = Pipe()
        immediateProcess.standardOutput = immediateOutput
        immediateProcess.standardError = immediateOutput

        try immediateProcess.run()
        let immediateSignalDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(
            atPath: immediateHookMarkerURL.path
        ), Date() < immediateSignalDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: immediateHookMarkerURL.path
            ),
            "The pre-launch hook did not start before the signal deadline."
        )
        immediateProcess.terminate()
        let completeImmediateOutput = String(
            decoding:
                immediateOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        immediateProcess.waitUntilExit()

        XCTAssertEqual(
            immediateProcess.terminationStatus,
            143,
            completeImmediateOutput
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: immediateBodyMarkerURL.path
            ),
            "An immediately interrupted wrapper must never launch the body."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: immediateSnapshotURL.path
            ),
            "The immediate-signal baseline must remain available."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    immediateSnapshotURL.appendingPathComponent(".incomplete")
                        .path
            )
        )
        let immediateCalls = try String(
            contentsOf: immediateCallLogURL,
            encoding: .utf8
        )
        .split(separator: "\n")
        .map(String.init)
        XCTAssertEqual(
            immediateCalls.filter { $0 == "default-keychain" }.count,
            2,
            completeImmediateOutput
        )
        XCTAssertEqual(
            immediateCalls.filter { $0 == "list-keychains" }.count,
            2,
            completeImmediateOutput
        )
        XCTAssertEqual(
            immediateCalls.filter { $0.hasPrefix("count:") }.count,
            6,
            completeImmediateOutput
        )
    }

    func testCalendarOAuthSignedPackagingNeedsNoAssociatedDomain() throws {
        // Calendar consent uses a loopback redirect, so signed macOS packaging
        // neither carries nor requires an Associated Domains entitlement.
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let capture = fixture.rootURL.appendingPathComponent("captured-app-entitlements.plist")
        let signer = try fixture.createExecutable(relativePath: "calendar-codesign.sh", contents: """
        #!/bin/bash
        previous=""
        for argument in "$@"; do
            if [[ "$previous" == "--entitlements" && "$argument" == *PlainpostApp.entitlements ]]; then
                /bin/cp "$argument" "\(capture.path)"
            fi
            previous="$argument"
        done
        """)
        var environment = signed.environment
        environment["PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND"] = signer.path
        let result = try fixture.runScript(named: "package-app-bundle.sh", environment: environment)
        XCTAssertEqual(result.status, 0, result.output)
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: capture), format: nil) as? [String: Any])
        XCTAssertNil(entitlements["com.apple.developer.associated-domains"])
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: signed.appProfileURL), format: nil) as? [String: Any])
        XCTAssertNil((profile["Entitlements"] as? [String: Any])?["com.apple.developer.associated-domains"], "the fixture profile must not need Associated Domains")
    }

    func testCalendarOAuthPackagingRejectsReintroducedAssociatedDomainEntitlement() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let entitlementsURL = fixture.rootURL.appendingPathComponent("Support/PlainpostApp/PlainpostApp.entitlements")
        var entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementsURL), format: nil) as? [String: Any])
        entitlements["com.apple.developer.associated-domains"] = ["webcredentials:mail.plainpost.app"]
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entitlementsURL)
        let result = try fixture.runScript(named: "package-app-bundle.sh", environment: signed.environment)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("App entitlements do not match the committed packaging contract."), result.output)
    }

    func testAssociatedDomainContractCoversOnlyIOSGmailApplinks() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        for path in ["Scripts/verify-associated-domain.sh", "Deploy/sync-node/apple-app-site-association.json", "Apps/PlainpostiOS/Config/Plainpost.entitlements", "Apps/PlainpostiOS/Config/Base.xcconfig", "Apps/PlainpostiOS/Plainpost.xcodeproj/project.pbxproj"] {
            try fixture.copyRepositoryFile(named: path)
        }
        let aasaURL = fixture.rootURL.appendingPathComponent("Deploy/sync-node/apple-app-site-association.json")
        var aasa = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: aasaURL)) as? [String: Any])
        XCTAssertEqual(Set(aasa.keys), ["applinks"])
        let details = (aasa["applinks"] as? [String: Any])?["details"] as? [[String: Any]]
        XCTAssertEqual(details?.first?["appIDs"] as? [String], ["9XN7WN8JN2.com.marynavdovenko.Plainpost.iOS"])
        let valid = try fixture.runScript(named: "verify-associated-domain.sh")
        XCTAssertEqual(valid.status, 0, valid.output)
        aasa["webcredentials"] = ["apps": ["9XN7WN8JN2.com.marynavdovenko.Plainpost"]]
        try JSONSerialization.data(withJSONObject: aasa).write(to: aasaURL)
        let invalid = try fixture.runScript(named: "verify-associated-domain.sh")
        XCTAssertNotEqual(invalid.status, 0, invalid.output)
    }

    func testPackagingPinnedParentCannotBeRedirectedAfterValidation() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "package-app-bundle.sh")
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")
        try fixture.copyRepositoryFile(
            named: "Support/PlainpostApp/PlainpostApp.entitlements"
        )
        try fixture.copyRepositoryFile(named: "Support/PlainpostBackgroundAgent/Info.plist")
        try fixture.createServiceSupportFiles()
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostBackgroundAgent")
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostBrowserBridge")
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostService")
        try fixture.createExecutable(relativePath: ".build/debug/plainpost")
        try fixture.createNativeAppFixture()
        let acceptedParent = fixture.rootURL.appendingPathComponent(".build/MacSyncAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: acceptedParent, withIntermediateDirectories: true)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-package-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let externalBundle = external.appendingPathComponent("Plainpost.app", isDirectory: true)
        try FileManager.default.createDirectory(at: externalBundle, withIntermediateDirectories: true)
        let sentinel = externalBundle.appendingPathComponent("untouched")
        try "untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        let externalBridge = externalBundle.appendingPathComponent("Contents/MacOS/PlainpostBrowserBridge")
        try FileManager.default.createDirectory(at: externalBridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "external bridge".write(to: externalBridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: externalBridge.path)
        let stopped = fixture.rootURL.appendingPathComponent("stopped.txt")
        try fixture.createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents: "#!/bin/sh\nprintf '%s' \"$1\" > \"\(stopped.path)\"\n"
        )
        let hook = try fixture.createExecutable(
            relativePath: "swap-parent.sh",
            contents: "#!/bin/sh\nmv \"\(acceptedParent.path)\" \"\(fixture.rootURL.appendingPathComponent(".build/retired").path)\"\nln -s \"\(external.path)\" \"\(acceptedParent.path)\"\n"
        )
        let codesignLog = fixture.rootURL.appendingPathComponent("codesign.txt")
        let fakeXcodebuild = try fixture.createExecutable(relativePath: "fake-xcodebuild.sh", contents: "#!/bin/sh\nexit 0\n")
        let fakeCodesign = try fixture.createExecutable(
            relativePath: "fake-codesign.sh",
            contents: "#!/bin/sh\nprintf '%s|%s\\n' \"$(/bin/pwd -P)\" \"$*\" >> \"\(codesignLog.path)\"\n"
        )
        let profileDecoder = try fixture.createProfileDecoder()
        let appProvisioningProfile = try fixture.createDecodedAppProfile()
        let provisioningProfile = try fixture.createDecodedServiceProfile()
        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: [
                "PLAINPOST_APP_BUNDLE_OUTPUT":
                    acceptedParent.appendingPathComponent(
                        "PlainpostAcceptanceFixture.app"
                    ).path,
                "PLAINPOST_PACKAGE_TEST_HOOK": hook.path,
                "PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND": fakeXcodebuild.path,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND": fakeCodesign.path,
                "PLAINPOST_CODESIGN_IDENTITY": PackagingScriptFixture.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
                "PLAINPOST_APP_PROVISIONING_PROFILE":
                    appProvisioningProfile.path,
                "PLAINPOST_SERVICE_PROVISIONING_PROFILE": provisioningProfile.path,
                "PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND":
                    profileDecoder.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: externalBridge.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o700)
        )
        XCTAssertFalse((try String(contentsOf: stopped, encoding: .utf8)).hasPrefix(external.path))
        let codesignInvocations = try String(contentsOf: codesignLog, encoding: .utf8)
        XCTAssertTrue(codesignInvocations.contains("\(fixture.rootURL.path)/.build/retired|"), codesignInvocations)
        XCTAssertTrue(
            codesignInvocations.contains(
                "PlainpostAcceptanceFixture.app/Contents/MacOS/PlainpostBrowserBridge"
            ),
            codesignInvocations
        )
        XCTAssertFalse(codesignInvocations.contains(external.path), codesignInvocations)
    }

    func testPackagingRejectsOutputOutsideBuildDirectory() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "package-app-bundle.sh")

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: ["PLAINPOST_APP_BUNDLE_OUTPUT": "/tmp/Plainpost.app"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.output, "PLAINPOST_APP_BUNDLE_OUTPUT must be an .app below .build.\n")
    }

    func testPackagingRejectsTestOverridesOutsideStructuralFixtureMode() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment,
            includeStructuralTestMode: false
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "PLAINPOST_PACKAGE_TEST_* overrides require structural fixture mode"
            ),
            result.output
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signed.codesignLogURL.path),
            "Production packaging must reject fake signing before invoking it."
        )
    }

    func testPackagingFixtureModeRejectsProductionBundlePath() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        var environment = signed.environment
        environment["PLAINPOST_APP_BUNDLE_OUTPUT"] = fixture.rootURL
            .appendingPathComponent(".build/Plainpost.app")
            .path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "Structural fixture mode cannot target Plainpost.app"
            ),
            result.output
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signed.codesignLogURL.path)
        )
    }

    func testPackagingFixtureContractRejectsTraversalRootAcrossAllEntrypoints() throws {
        let expectedRejection =
            "Structural fixture root must be a canonical physical path."

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let nested = fixture.rootURL.appendingPathComponent("nested")
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            var environment = signed.environment
            environment["PLAINPOST_PACKAGE_TEST_ROOT"] =
                nested.appendingPathComponent("..").path

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: signed.codesignLogURL.path
                ),
                "Traversal-root rejection must precede fake signing."
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "select-codesign-identity.sh"
            )
            let nested = fixture.rootURL.appendingPathComponent("nested")
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )

            let result = try fixture.runScript(
                named: "select-codesign-identity.sh",
                environment: [
                    "PLAINPOST_PACKAGE_TEST_ROOT":
                        nested.appendingPathComponent("..").path,
                    "PLAINPOST_CODESIGN_IDENTITY":
                        PackagingScriptFixture.signingIdentitySHA1,
                    "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                        "\(PackagingScriptFixture.signingIdentitySHA1)|"
                        + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                        + "9XN7WN8JN2|"
                        + "Apple Development: Plainpost Packaging Fixture|"
                        + PackagingScriptFixture.signingIdentityLabel,
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let nested = fixture.rootURL.appendingPathComponent("nested")
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/StopTraversalFixture.app"
            )
            _ = try fixture.createExecutable(
                relativePath:
                    ".build/StopTraversalFixture.app/Contents/Library/"
                    + "Helpers/PlainpostService.app/Contents/MacOS/"
                    + "PlainpostService"
            )
            let launchctl = try fixture.createLaunchctlFixture(
                bundleURL: bundleURL,
                label: "com.marynavdovenko.Plainpost.BackgroundAgent",
                initiallyLoaded: false
            )
            let traversalRoot = nested.appendingPathComponent("..").path
            let traversalBundle =
                "\(traversalRoot)/.build/StopTraversalFixture.app"

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [traversalBundle],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_ROOT": traversalRoot,
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        launchctl.commandURL.path,
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: launchctl.logURL.path),
                "Traversal-root rejection must precede fake launchctl."
            )
        }
    }

    func testPackagingFixtureContractRejectsSymlinkRootAcrossAllEntrypoints() throws {
        let expectedRejection =
            "Structural fixture root must be a canonical physical path."

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let aliasParentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "plainpost-packaging-alias-\(UUID().uuidString)"
                )
            try FileManager.default.createSymbolicLink(
                at: aliasParentURL,
                withDestinationURL: fixture.rootURL.deletingLastPathComponent()
            )
            defer { try? FileManager.default.removeItem(at: aliasParentURL) }
            let aliasURL = aliasParentURL.appendingPathComponent(
                fixture.rootURL.lastPathComponent
            )
            var environment = signed.environment
            environment["PLAINPOST_PACKAGE_TEST_ROOT"] = aliasURL.path

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: signed.codesignLogURL.path
                )
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "select-codesign-identity.sh"
            )
            let aliasParentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "plainpost-packaging-alias-\(UUID().uuidString)"
                )
            try FileManager.default.createSymbolicLink(
                at: aliasParentURL,
                withDestinationURL: fixture.rootURL.deletingLastPathComponent()
            )
            defer { try? FileManager.default.removeItem(at: aliasParentURL) }
            let aliasURL = aliasParentURL.appendingPathComponent(
                fixture.rootURL.lastPathComponent
            )

            let result = try fixture.runScript(
                named: "select-codesign-identity.sh",
                environment: [
                    "PLAINPOST_PACKAGE_TEST_ROOT": aliasURL.path,
                    "PLAINPOST_CODESIGN_IDENTITY":
                        PackagingScriptFixture.signingIdentitySHA1,
                    "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                        "\(PackagingScriptFixture.signingIdentitySHA1)|"
                        + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                        + "9XN7WN8JN2|"
                        + "Apple Development: Plainpost Packaging Fixture|"
                        + PackagingScriptFixture.signingIdentityLabel,
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let canonicalBundle = fixture.rootURL.appendingPathComponent(
                ".build/StopSymlinkRootFixture.app"
            )
            _ = try fixture.createExecutable(
                relativePath:
                    ".build/StopSymlinkRootFixture.app/Contents/Library/"
                    + "Helpers/PlainpostService.app/Contents/MacOS/"
                    + "PlainpostService"
            )
            let launchctl = try fixture.createLaunchctlFixture(
                bundleURL: canonicalBundle,
                label: "com.marynavdovenko.Plainpost.BackgroundAgent",
                initiallyLoaded: false
            )
            let aliasParentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "plainpost-packaging-alias-\(UUID().uuidString)"
                )
            try FileManager.default.createSymbolicLink(
                at: aliasParentURL,
                withDestinationURL: fixture.rootURL.deletingLastPathComponent()
            )
            defer { try? FileManager.default.removeItem(at: aliasParentURL) }
            let aliasURL = aliasParentURL.appendingPathComponent(
                fixture.rootURL.lastPathComponent
            )
            let aliasBundle = aliasURL.appendingPathComponent(
                ".build/StopSymlinkRootFixture.app"
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [aliasBundle.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_ROOT": aliasURL.path,
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        launchctl.commandURL.path,
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(expectedRejection),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: launchctl.logURL.path)
            )
        }
    }

    func testPackagingFixtureToolsStayInsideCanonicalFixtureRoot() throws {
        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            var environment = signed.environment
            environment["PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND"] =
                "/usr/bin/true"

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Fixture Xcodebuild command must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: signed.codesignLogURL.path
                )
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/StopSystemToolFixture.app"
            )
            _ = try fixture.createExecutable(
                relativePath:
                    ".build/StopSystemToolFixture.app/Contents/Library/"
                    + "Helpers/PlainpostService.app/Contents/MacOS/"
                    + "PlainpostService"
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [bundleURL.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        "/usr/bin/true"
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Fixture launchctl command must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/StopSymlinkParentFixture.app"
            )
            _ = try fixture.createExecutable(
                relativePath:
                    ".build/StopSymlinkParentFixture.app/Contents/Library/"
                    + "Helpers/PlainpostService.app/Contents/MacOS/"
                    + "PlainpostService"
            )
            let realTool = try fixture.createExecutable(
                relativePath: "tools-real/fake-launchctl.sh",
                contents: "#!/bin/sh\nexit 113\n"
            )
            let toolsAlias = fixture.rootURL.appendingPathComponent("tools")
            try FileManager.default.createSymbolicLink(
                at: toolsAlias,
                withDestinationURL: realTool.deletingLastPathComponent()
            )
            let aliasedTool = toolsAlias.appendingPathComponent(
                realTool.lastPathComponent
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [bundleURL.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        aliasedTool.path
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Fixture launchctl command must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
        }
    }

    func testRuntimeStopFixtureRejectsEscapedBundlesAndRealLaunchctl() throws {
        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let traversalBundle = fixture.rootURL.appendingPathComponent(
                ".build/../StopTraversalFixture.app"
            )
            let launchctl = try fixture.createLaunchctlFixture(
                bundleURL: traversalBundle,
                label: "com.marynavdovenko.Plainpost.BackgroundAgent",
                initiallyLoaded: false
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [traversalBundle.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        launchctl.commandURL.path
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Runtime-stop fixture bundle must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: launchctl.logURL.path),
                "Traversal rejection must precede fake launchctl invocation."
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let externalRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "plainpost-stop-external-\(UUID().uuidString)"
                )
            try FileManager.default.createDirectory(
                at: externalRoot,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: externalRoot) }
            let aliasParent = fixture.rootURL.appendingPathComponent(
                ".build/stop-alias"
            )
            try FileManager.default.createDirectory(
                at: aliasParent.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: aliasParent,
                withDestinationURL: externalRoot
            )
            let aliasedBundle = aliasParent.appendingPathComponent(
                "StopSymlinkFixture.app"
            )
            let launchctl = try fixture.createLaunchctlFixture(
                bundleURL: aliasedBundle,
                label: "com.marynavdovenko.Plainpost.BackgroundAgent",
                initiallyLoaded: false
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [aliasedBundle.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        launchctl.commandURL.path
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Runtime-stop fixture bundle must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: launchctl.logURL.path),
                "Symlink-parent rejection must precede fake launchctl."
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/StopRealLaunchctlFixture.app"
            )
            try FileManager.default.createDirectory(
                at: bundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [bundleURL.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        "/bin/launchctl"
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Fixture launchctl command must be a canonical "
                    + "path inside the fixture root."
                ),
                result.output
            )
        }

        do {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/StopDirectoryToolFixture.app"
            )
            let toolDirectory = fixture.rootURL.appendingPathComponent(
                "fake-launchctl-directory"
            )
            try FileManager.default.createDirectory(
                at: toolDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [bundleURL.path],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        toolDirectory.path
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "Fixture launchctl command must be a canonical "
                    + "regular executable inside the fixture root."
                ),
                result.output
            )
        }
    }

    func testPackagingStopsOnlySelectedAcceptanceBundle() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let stoppedBundlePath = fixture.rootURL.appendingPathComponent("stopped-bundle.txt")
        try fixture.createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents: "#!/bin/sh\nprintf '%s' \"$1\" > \"\(stoppedBundlePath.path)\"\nexit 97\n"
        )

        let acceptanceBundle = fixture.rootURL.appendingPathComponent(
            ".build/MacSyncAcceptance/PlainpostAcceptanceFixture.app"
        )
        var environment = signed.environment
        environment["PLAINPOST_APP_BUNDLE_OUTPUT"] = acceptanceBundle.path
        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertEqual(result.status, 97, result.output)
        let expectedBundlePath = acceptanceBundle.path.hasPrefix("/var/")
            ? "/private\(acceptanceBundle.path)"
            : acceptanceBundle.path
        XCTAssertEqual(
            try String(contentsOf: stoppedBundlePath, encoding: .utf8),
            expectedBundlePath
        )
        XCTAssertNotEqual(acceptanceBundle.path, fixture.rootURL.appendingPathComponent(".build/Plainpost.app").path)
    }

    func testPackagingRejectsNoncanonicalOrSymlinkedOutputWithoutStoppingAnything() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "package-app-bundle.sh")
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostBackgroundAgent")
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostBrowserBridge")
        let stopSentinel = fixture.rootURL.appendingPathComponent("stop-invoked.txt")
        try fixture.createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents: "#!/bin/sh\nprintf '%s' \"$1\" > \"\(stopSentinel.path)\"\nexit 97\n"
        )
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-package-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let externalBundle = externalRoot.appendingPathComponent("Plainpost.app")
        try FileManager.default.createDirectory(at: externalBundle, withIntermediateDirectories: true)
        let externalSentinel = externalBundle.appendingPathComponent("must-remain")
        try "untouched".write(to: externalSentinel, atomically: true, encoding: .utf8)
        let linkedParent = fixture.rootURL.appendingPathComponent(".build/link-to-outside")
        try FileManager.default.createSymbolicLink(atPath: linkedParent.path, withDestinationPath: externalRoot.path)
        let linkedBundle = fixture.rootURL.appendingPathComponent(".build/existing-link.app")
        try FileManager.default.createSymbolicLink(atPath: linkedBundle.path, withDestinationPath: externalBundle.path)

        let invalidOutputs = [
            fixture.rootURL.appendingPathComponent(".build/../outside.app").path,
            fixture.rootURL.appendingPathComponent(
                ".build/MacSyncAcceptance/../MacSyncAcceptance/"
                    + "PlainpostFixture.app"
            ).path,
            linkedParent.appendingPathComponent("PlainpostFixture.app").path,
            linkedBundle.path,
            ".build/MacSyncAcceptance/PlainpostFixture.app",
        ]
        for output in invalidOutputs {
            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: ["PLAINPOST_APP_BUNDLE_OUTPUT": output]
            )
            XCTAssertNotEqual(result.status, 0, output)
            XCTAssertEqual(result.output, "PLAINPOST_APP_BUNDLE_OUTPUT must be an .app below .build.\n", output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stopSentinel.path), output)
            XCTAssertEqual(try String(contentsOf: externalSentinel, encoding: .utf8), "untouched", output)
        }
    }

    func testPackagingSelectsExplicitAppleDevelopmentIdentityByCertificateFingerprint() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        guard fixture.repositoryScriptExists(named: "select-codesign-identity.sh") else {
            XCTFail("Missing Scripts/select-codesign-identity.sh")
            return
        }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY":
                    PackagingScriptFixture.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output,
            "\(PackagingScriptFixture.signingIdentitySHA1)\n"
        )
    }

    func testIdentityFixtureRecordsRequireStructuralFixtureMode() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY":
                    PackagingScriptFixture.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ],
            includeStructuralTestMode: false
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS requires structural fixture mode"
            ),
            result.output
        )
    }

    func testPackagingRejectsDisplayNameOnlyCodesignIdentity() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY":
                    PackagingScriptFixture.signingIdentityLabel,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "PLAINPOST_CODESIGN_IDENTITY must be an exact SHA-1 certificate fingerprint"
            ),
            result.output
        )
    }

    func testPackagingRejectsCodesignIdentityWithWrongCertificateTeam() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY":
                    PackagingScriptFixture.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "FG6BADTEAM|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "organizational unit 9XN7WN8JN2"
            ),
            result.output
        )
    }

    func testPackagingRejectsAmbiguousCodesignIdentity() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY":
                    PackagingScriptFixture.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + "\(PackagingScriptFixture.signingIdentityLabel)\n"
                    + "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("ambiguous"), result.output)
    }

    func testPackagingDebugWithoutExplicitIdentityStaysAdHoc() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "select-codesign-identity.sh")

        let result = try fixture.runScript(
            named: "select-codesign-identity.sh",
            arguments: ["debug"],
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY": "",
                "PLAINPOST_AVAILABLE_CODESIGN_IDENTITIES":
                    "0 valid identities found",
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(PackagingScriptFixture.signingIdentitySHA1)|"
                    + "\(PackagingScriptFixture.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + PackagingScriptFixture.signingIdentityLabel,
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "-\n")
    }

    func testPackagingKeepsAppCLIAndServiceExecutablesDistinct() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let bundle = fixture.bundleURL
        let expectedSentinels = [
            "Contents/MacOS/Plainpost": "native-app sentinel",
            "Contents/MacOS/PlainpostCLI": "cli sentinel",
            "Contents/MacOS/PlainpostBrowserBridge": "browser-bridge sentinel",
            "Contents/Library/Helpers/PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent":
                "background-agent sentinel",
            "Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService":
                "service sentinel",
        ]
        for (relativePath, sentinel) in expectedSentinels {
            XCTAssertEqual(
                try? String(
                    contentsOf: bundle.appendingPathComponent(relativePath),
                    encoding: .utf8
                ),
                sentinel,
                relativePath
            )
        }
        let packagedFiles = try XCTUnwrap(
            FileManager.default.enumerator(
                at: bundle,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.allObjects as? [URL]
        )
        for sentinel in expectedSentinels.values {
            let copies = packagedFiles.filter {
                (try? String(contentsOf: $0, encoding: .utf8)) == sentinel
            }
            XCTAssertEqual(
                copies.count,
                1,
                "\(sentinel) must be copied into exactly one packaged role: \(copies)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent(
                    "Contents/MacOS/PlainpostService"
                ).path
            )
        )
    }

    func testPackagingPlacesServiceInProvisionedNestedApp() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let appInfoData = try Data(
            contentsOf: fixture.bundleURL.appendingPathComponent("Contents/Info.plist")
        )
        let appInfo = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: appInfoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let documentTypes = try XCTUnwrap(
            appInfo["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        XCTAssertEqual(documentTypes.count, 1)
        let documentType = try XCTUnwrap(documentTypes.first)
        XCTAssertEqual(
            documentType["LSItemContentTypes"] as? [String],
            ["com.marynavdovenko.plainpost.server-setup"]
        )
        let exportedTypes = try XCTUnwrap(
            appInfo["UTExportedTypeDeclarations"] as? [[String: Any]]
        )
        XCTAssertEqual(exportedTypes.count, 1)
        let exportedType = try XCTUnwrap(exportedTypes.first)
        XCTAssertEqual(
            exportedType["UTTypeIdentifier"] as? String,
            "com.marynavdovenko.plainpost.server-setup"
        )
        let tagSpecification = try XCTUnwrap(
            exportedType["UTTypeTagSpecification"] as? [String: Any]
        )
        XCTAssertEqual(
            tagSpecification["public.filename-extension"] as? [String],
            ["plainpostserver"]
        )
        let serviceBundle = fixture.bundleURL.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app"
        )
        guard let infoData = try? Data(
            contentsOf: serviceBundle.appendingPathComponent("Contents/Info.plist")
        ) else {
            XCTFail("The packaged service helper must contain Contents/Info.plist.")
            return
        }
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.marynavdovenko.Plainpost.Service")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "PlainpostService")
        XCTAssertEqual(info["LSBackgroundOnly"] as? Bool, true)
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "26.0")
        let launchAgentData = try Data(
            contentsOf: fixture.bundleURL.appendingPathComponent(
                "Contents/Library/LaunchAgents/com.marynavdovenko.Plainpost.BackgroundAgent.plist"
            )
        )
        let launchAgent = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: launchAgentData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            launchAgent["BundleProgram"] as? String,
            "Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        XCTAssertEqual(
            launchAgent["ProgramArguments"] as? [String],
            ["PlainpostService", "--xpc-service"]
        )
        XCTAssertEqual(
            launchAgent["MachServices"] as? [String: Bool],
            ["com.marynavdovenko.Plainpost.Service": true]
        )
        XCTAssertEqual(
            try? Data(
                contentsOf: serviceBundle.appendingPathComponent(
                    "Contents/embedded.provisionprofile"
                )
            ),
            try Data(contentsOf: signed.profileURL)
        )
    }

    func testPackagingEmbedsTheExactValidatedMainAppProfileSnapshot() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.bundleURL.appendingPathComponent(
                    "Contents/embedded.provisionprofile"
                )
            ),
            try Data(contentsOf: signed.appProfileURL)
        )
    }

    func testPackagingEmbedsTheExactValidatedServiceProfileSnapshot() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let decodedProfileURL = fixture.rootURL.appendingPathComponent(
            "decoded-service-profile.plist"
        )
        try Data(contentsOf: signed.profileURL).write(to: decodedProfileURL)
        let validatedBytes = Data("raw CMS fixture envelope".utf8)
        try validatedBytes.write(to: signed.profileURL)
        let mutatingDecoder = try fixture.createExecutable(
            relativePath: "mutating-profile-decoder.sh",
            contents:
                "#!/bin/sh\n"
                + "case \"$1\" in\n"
                + "  */PlainpostApp.provisionprofile) /bin/cat \"\(signed.appProfileURL.path)\" ;;\n"
                + "  *) /bin/cat \"\(decodedProfileURL.path)\"; "
                + "/usr/bin/printf 'replaced after decode' > \"\(signed.profileURL.path)\" ;;\n"
                + "esac\n"
        )
        var environment = signed.environment
        environment["PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND"] =
            mutatingDecoder.path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let embeddedProfile = fixture.bundleURL.appendingPathComponent(
            "Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/embedded.provisionprofile"
        )
        XCTAssertEqual(
            try Data(contentsOf: embeddedProfile),
            validatedBytes,
            "Packaging must embed the exact immutable profile snapshot it validated."
        )
        XCTAssertNotEqual(try Data(contentsOf: signed.profileURL), validatedBytes)
    }

    func testPackagingRejectsMissingOrMalformedServiceInfoBeforeRuntimeStop() throws {
        for variant in ["missing", "malformed"] {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            let bundleSentinel = try fixture.createFile(
                relativePath: ".build/PlainpostFixture.app/preserve.txt",
                contents: "preserve"
            )
            let infoURL = fixture.rootURL.appendingPathComponent(
                "Support/PlainpostService/Info.plist"
            )
            if variant == "missing" {
                try FileManager.default.removeItem(at: infoURL)
            } else {
                try Data("not a plist".utf8).write(to: infoURL)
            }

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(variant): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Service Info.plist does not match the committed packaging contract"
                ),
                "\(variant): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(variant): runtime stop must not run"
            )
            XCTAssertEqual(
                try? String(contentsOf: bundleSentinel, encoding: .utf8),
                "preserve",
                "\(variant): existing output must remain untouched"
            )
        }
    }

    func testPackagingRejectsWrongServiceInfoContractBeforeRuntimeStop() throws {
        let mutations: [(String, Any)] = [
            ("CFBundleIdentifier", "com.olhapi.Wrong.Service"),
            ("CFBundleExecutable", "WrongService"),
            ("LSBackgroundOnly", false),
            ("LSMinimumSystemVersion", "25.0"),
            ("UnexpectedKey", "unexpected"),
        ]

        for (key, value) in mutations {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            var info = try fixture.propertyList(
                relativePath: "Support/PlainpostService/Info.plist"
            )
            info[key] = value
            try fixture.createPropertyList(
                relativePath: "Support/PlainpostService/Info.plist",
                object: info
            )

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(key): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Service Info.plist does not match the committed packaging contract"
                ),
                "\(key): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(key): runtime stop must not run"
            )
        }
    }

    func testPackagingRejectsWrongOrExtraServiceEntitlementsBeforeRuntimeStop() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            (
                "application identifier",
                {
                    $0["com.apple.application-identifier"] =
                        "9XN7WN8JN2.com.olhapi.Wrong.Service"
                }
            ),
            (
                "team identifier",
                {
                    $0["com.apple.developer.team-identifier"] = "FG6BADTEAM"
                }
            ),
            (
                "extra keychain group",
                {
                    $0["keychain-access-groups"] = [
                        "9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared",
                        "9XN7WN8JN2.com.olhapi.Wrong.Service",
                    ]
                }
            ),
            (
                "extra entitlement",
                {
                    $0["com.apple.security.network.client"] = true
                }
            ),
        ]

        for (name, mutate) in mutations {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            var entitlements = try fixture.propertyList(
                relativePath:
                    "Support/PlainpostService/PlainpostService.entitlements"
            )
            mutate(&entitlements)
            try fixture.createPropertyList(
                relativePath:
                    "Support/PlainpostService/PlainpostService.entitlements",
                object: entitlements
            )

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Service entitlements do not match the committed packaging contract"
                ),
                "\(name): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(name): runtime stop must not run"
            )
        }
    }

    func testPackagingRejectsWrongServiceMetadataTypesBeforeRuntimeStop() throws {
        let infoMutations: [
            (String, (inout [String: Any]) -> Void)
        ] = [
            (
                "string background-only flag",
                { $0["LSBackgroundOnly"] = "true" }
            ),
            (
                "integer bundle version",
                { $0["CFBundleVersion"] = NSNumber(value: 1) }
            ),
            (
                "numeric minimum system version",
                { $0["LSMinimumSystemVersion"] = NSNumber(value: 26.0) }
            ),
        ]

        for (name, mutate) in infoMutations {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            let bundleSentinel = try fixture.createFile(
                relativePath: ".build/PlainpostFixture.app/preserve.txt",
                contents: "preserve"
            )
            var info = try fixture.propertyList(
                relativePath: "Support/PlainpostService/Info.plist"
            )
            mutate(&info)
            try fixture.createPropertyList(
                relativePath: "Support/PlainpostService/Info.plist",
                object: info
            )

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Service Info.plist does not match the committed "
                    + "packaging contract"
                ),
                "\(name): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(name): runtime stop must not run"
            )
            XCTAssertEqual(
                try? String(contentsOf: bundleSentinel, encoding: .utf8),
                "preserve",
                "\(name): existing output must remain untouched"
            )
        }

        let applicationIdentifier =
            "9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"
        let teamIdentifier = "9XN7WN8JN2"
        let entitlementMutations: [
            (String, (inout [String: Any]) -> Void)
        ] = [
            (
                "dictionary application identifier",
                {
                    $0["com.apple.application-identifier"] = [
                        applicationIdentifier: "decoy"
                    ]
                }
            ),
            (
                "dictionary team identifier",
                {
                    $0["com.apple.developer.team-identifier"] = [
                        teamIdentifier: "decoy"
                    ]
                }
            ),
            (
                "non-string keychain group",
                {
                    $0["keychain-access-groups"] = [
                        [applicationIdentifier: "decoy"]
                    ]
                }
            ),
        ]

        for (name, mutate) in entitlementMutations {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            let bundleSentinel = try fixture.createFile(
                relativePath: ".build/PlainpostFixture.app/preserve.txt",
                contents: "preserve"
            )
            var entitlements = try fixture.propertyList(
                relativePath:
                    "Support/PlainpostService/PlainpostService.entitlements"
            )
            mutate(&entitlements)
            try fixture.createPropertyList(
                relativePath:
                    "Support/PlainpostService/PlainpostService.entitlements",
                object: entitlements
            )

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Service entitlements do not match the committed "
                    + "packaging contract"
                ),
                "\(name): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(name): runtime stop must not run"
            )
            XCTAssertEqual(
                try? String(contentsOf: bundleSentinel, encoding: .utf8),
                "preserve",
                "\(name): existing output must remain untouched"
            )
        }
    }

    func testPackagingUsesValidatedServiceMetadataSnapshotsAfterSourceSwap() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let infoPath = "Support/PlainpostService/Info.plist"
        let entitlementsPath =
            "Support/PlainpostService/PlainpostService.entitlements"
        let originalInfo = try Data(
            contentsOf: fixture.rootURL.appendingPathComponent(infoPath)
        )
        let originalEntitlements = try Data(
            contentsOf: fixture.rootURL.appendingPathComponent(entitlementsPath)
        )
        var wrongInfo = try fixture.propertyList(relativePath: infoPath)
        wrongInfo["CFBundleIdentifier"] = "com.olhapi.Swapped.Service"
        let wrongInfoURL = try fixture.createPropertyList(
            relativePath: "swapped/Info.plist",
            object: wrongInfo
        )
        var wrongEntitlements = try fixture.propertyList(
            relativePath: entitlementsPath
        )
        wrongEntitlements["com.apple.developer.team-identifier"] = "FG6SWAPPED"
        let wrongEntitlementsURL = try fixture.createPropertyList(
            relativePath: "swapped/PlainpostService.entitlements",
            object: wrongEntitlements
        )
        let mutatingXcodebuild = try fixture.createExecutable(
            relativePath: "mutating-xcodebuild.sh",
            contents:
                "#!/bin/sh\n"
                + "/usr/bin/ditto \"\(wrongInfoURL.path)\" "
                + "\"\(fixture.rootURL.appendingPathComponent(infoPath).path)\"\n"
                + "/usr/bin/ditto \"\(wrongEntitlementsURL.path)\" "
                + "\"\(fixture.rootURL.appendingPathComponent(entitlementsPath).path)\"\n"
        )
        let capturedEntitlements = fixture.rootURL.appendingPathComponent(
            "signed-service-entitlements.plist"
        )
        let capturingCodesign = try fixture.createExecutable(
            relativePath: "capturing-codesign.sh",
            contents:
                "#!/bin/bash\n"
                + "while [[ $# -gt 0 ]]; do\n"
                + "  if [[ \"$1\" == \"--entitlements\" ]]; then\n"
                + "    if [[ \"$2\" == */PlainpostService.entitlements ]]; then\n"
                + "      /usr/bin/ditto \"$2\" \"\(capturedEntitlements.path)\"\n"
                + "    fi\n"
                + "    break\n"
                + "  fi\n"
                + "  shift\n"
                + "done\n"
        )
        var environment = signed.environment
        environment["PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND"] =
            mutatingXcodebuild.path
        environment["PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND"] =
            capturingCodesign.path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.bundleURL.appendingPathComponent(
                    "Contents/Library/Helpers/PlainpostService.app/"
                        + "Contents/Info.plist"
                )
            ),
            originalInfo
        )
        XCTAssertEqual(
            try Data(contentsOf: capturedEntitlements),
            originalEntitlements,
            "Service signing must consume the validated entitlement snapshot."
        )
        XCTAssertNotEqual(
            try Data(
                contentsOf: fixture.rootURL.appendingPathComponent(infoPath)
            ),
            originalInfo,
            "The source-swap fixture must execute."
        )
    }

    func testPackagingRejectsMutatedRawProfileSnapshotBeforeRuntimeStop() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let decodedProfileURL = fixture.rootURL.appendingPathComponent(
            "decoded-profile-for-snapshot-mutation.plist"
        )
        try Data(contentsOf: signed.profileURL).write(to: decodedProfileURL)
        try Data("raw CMS fixture envelope".utf8).write(to: signed.profileURL)
        let mutatingDecoder = try fixture.createExecutable(
            relativePath: "snapshot-mutating-profile-decoder.sh",
            contents:
                "#!/bin/sh\n"
                + "case \"$1\" in\n"
                + "  */PlainpostApp.provisionprofile) /bin/cat \"\(signed.appProfileURL.path)\" ;;\n"
                + "  *) /bin/cat \"\(decodedProfileURL.path)\"; "
                + "/usr/bin/printf 'mutated validated snapshot' > \"$1\" ;;\n"
                + "esac\n"
        )
        let stopSentinel = try packagingStopSentinel(in: fixture)
        let bundleSentinel = try fixture.createFile(
            relativePath: ".build/PlainpostFixture.app/preserve.txt",
            contents: "preserve"
        )
        var environment = signed.environment
        environment["PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND"] =
            mutatingDecoder.path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains(
                "service provisioning profile snapshot changed during validation"
            ),
            result.output
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stopSentinel.path),
            "Runtime stop must not run after a profile snapshot integrity failure."
        )
        XCTAssertEqual(
            try? String(contentsOf: bundleSentinel, encoding: .utf8),
            "preserve"
        )
    }

    func testPackagingRequiresServiceProfileForSignedPackage() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        var environment = signed.environment
        environment.removeValue(forKey: "PLAINPOST_SERVICE_PROVISIONING_PROFILE")

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "Signed service packaging requires PLAINPOST_SERVICE_PROVISIONING_PROFILE."
            ),
            result.output
        )
    }

    func testPackagingRejectsWrongTeamServiceProfile() throws {
        var profile = ServiceProfileFixture()
        profile.teamIdentifier = "FG6BADTEAM"
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("team identifier 9XN7WN8JN2"),
            result.output
        )
    }

    func testPackagingRejectsWildcardServiceProfile() throws {
        var profile = ServiceProfileFixture()
        profile.applicationIdentifier = "9XN7WN8JN2.*"
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("wildcard application identifier"),
            result.output
        )
    }

    func testPackagingRejectsMismatchedServiceApplicationIdentifier() throws {
        var profile = ServiceProfileFixture()
        profile.applicationIdentifier = "9XN7WN8JN2.com.olhapi.OtherApp.Service"
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"
            ),
            result.output
        )
    }

    func testPackagingRejectsProfileWithoutRequiredKeychainGroup() throws {
        let invalidGroups = [
            "9XN7WN8JN2.com.olhapi.OtherApp.Service",
            "9XN7WN8JN2.com.olhapi.*",
            "FG6BADTEAM.*",
        ]

        for invalidGroup in invalidGroups {
            var profile = ServiceProfileFixture()
            profile.keychainAccessGroups = [invalidGroup]
            let result = try runPackagingFixture(profile: profile)

            XCTAssertNotEqual(result.status, 0, invalidGroup)
            XCTAssertTrue(
                result.output.contains(
                    "keychain group 9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
                ),
                "\(invalidGroup): \(result.output)"
            )
        }
    }

    func testPackagingAcceptsTeamScopedKeychainProfileForAccountSharedGroup() throws {
        var profile = ServiceProfileFixture()
        profile.keychainAccessGroups = ["9XN7WN8JN2.*"]

        let result = try runPackagingFixture(profile: profile)

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testPackagingRejectsServiceProfileWithMismatchedDeveloperCertificate() throws {
        var profile = ServiceProfileFixture()
        profile.developerCertificates = [Data("different certificate".utf8)]
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "does not contain the selected Apple Development certificate"
            ),
            result.output
        )
    }

    func testPackagingAcceptsMatchingDeveloperCertificateAfterEarlierMismatch() throws {
        var profile = ServiceProfileFixture()
        profile.developerCertificates = [
            Data("different certificate".utf8),
            Data("abc".utf8),
        ]
        let result = try runPackagingFixture(profile: profile)

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testPackagingRejectsMultipleMismatchedDeveloperCertificates() throws {
        var profile = ServiceProfileFixture()
        profile.developerCertificates = [
            Data("different certificate one".utf8),
            Data("different certificate two".utf8),
        ]
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "does not contain the selected Apple Development certificate"
            ),
            result.output
        )
    }

    func testPackagingRejectsExpiredServiceProfile() throws {
        var profile = ServiceProfileFixture()
        profile.expirationDate = Date(timeIntervalSince1970: 946_684_800)
        let result = try runPackagingFixture(profile: profile)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("service provisioning profile has expired"),
            result.output
        )
    }

    func testPackagingSignsServiceWithDataProtectionKeychainEntitlements() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let invocations = (try? String(
            contentsOf: signed.codesignLogURL,
            encoding: .utf8
        )) ?? ""
        let serviceSigning = invocations.split(separator: "\n").first {
            $0.contains("--identifier com.marynavdovenko.Plainpost.Service")
                && $0.hasSuffix("PlainpostService.app")
        }
        XCTAssertNotNil(serviceSigning, invocations)
        XCTAssertTrue(
            serviceSigning?.contains("--entitlements ") == true
                && serviceSigning?.contains(
                    "plainpost-package-preflight."
                ) == true
                && serviceSigning?.contains(
                    "/PlainpostService.entitlements"
                ) == true,
            serviceSigning.map(String.init) ?? invocations
        )
        XCTAssertFalse(
            serviceSigning?.contains(
                "Support/PlainpostService/PlainpostService.entitlements"
            ) == true,
            serviceSigning.map(String.init) ?? invocations
        )
        let entitlementsData = try Data(
            contentsOf: fixture.rootURL.appendingPathComponent(
                "Support/PlainpostService/PlainpostService.entitlements"
            )
        )
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: entitlementsData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(entitlements.keys), [
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
        ])
        XCTAssertEqual(
            entitlements["com.apple.application-identifier"] as? String,
            "9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"
        )
        XCTAssertEqual(
            entitlements["com.apple.developer.team-identifier"] as? String,
            "9XN7WN8JN2"
        )
        XCTAssertEqual(
            entitlements["keychain-access-groups"] as? [String],
            ["9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"]
        )
    }

    func testPackagingSignsMainAppWithSharedAccountEntitlements() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let invocations = (try? String(
            contentsOf: signed.codesignLogURL,
            encoding: .utf8
        )) ?? ""
        let appSigning = invocations.split(separator: "\n").first {
            $0.contains("--identifier com.marynavdovenko.Plainpost ")
                && $0.hasSuffix("PlainpostFixture.app")
        }
        XCTAssertNotNil(appSigning, invocations)
        XCTAssertTrue(
            appSigning?.contains("--entitlements ") == true
                && appSigning?.contains("plainpost-package-preflight.") == true
                && appSigning?.contains("/PlainpostApp.entitlements") == true,
            appSigning.map(String.init) ?? invocations
        )
        XCTAssertFalse(
            appSigning?.contains(
                "Support/PlainpostApp/PlainpostApp.entitlements"
            ) == true,
            appSigning.map(String.init) ?? invocations
        )
        let entitlements = try fixture.propertyList(
            relativePath: "Support/PlainpostApp/PlainpostApp.entitlements"
        )
        XCTAssertEqual(
            entitlements["com.apple.security.personal-information.addressbook"] as? Bool,
            true,
            "The Hardened Runtime app must be entitled before macOS will prompt for Contacts access."
        )
    }

    func testReleasePackagingUsesDevelopmentSignatureWithoutSecureTimestamp() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/package-app-bundle.sh"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("timestamp_argument=\"--timestamp=none\""))
        XCTAssertFalse(
            script.contains("timestamp_argument=\"--timestamp\""),
            "Apple Development packages must not request a secure timestamp."
        )
    }

    func testPackagingRejectsWrongOrExtraAppEntitlementsBeforeRuntimeStop() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            (
                "application identifier",
                {
                    $0["com.apple.application-identifier"] =
                        "9XN7WN8JN2.com.olhapi.Wrong"
                }
            ),
            (
                "team identifier",
                {
                    $0["com.apple.developer.team-identifier"] = "FG6BADTEAM"
                }
            ),
            (
                "Apple sign-in mode",
                {
                    $0["com.apple.developer.applesignin"] = ["Invalid"]
                }
            ),
            (
                "keychain group",
                {
                    $0["keychain-access-groups"] = [
                        "9XN7WN8JN2.com.olhapi.Wrong"
                    ]
                }
            ),
            (
                "extra entitlement",
                {
                    $0["com.apple.security.network.client"] = true
                }
            ),
        ]

        for (name, mutate) in mutations {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            let signed = try fixture.prepareSignedPackaging()
            let stopSentinel = try packagingStopSentinel(in: fixture)
            var entitlements = try fixture.propertyList(
                relativePath: "Support/PlainpostApp/PlainpostApp.entitlements"
            )
            mutate(&entitlements)
            try fixture.createPropertyList(
                relativePath: "Support/PlainpostApp/PlainpostApp.entitlements",
                object: entitlements
            )

            let result = try fixture.runScript(
                named: "package-app-bundle.sh",
                environment: signed.environment
            )

            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "App entitlements do not match the committed packaging contract"
                ),
                "\(name): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stopSentinel.path),
                "\(name): runtime stop must not run"
            )
        }
    }

    func testPackagingSignsEveryClientWithItsExactIdentifier() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let invocations = (try? String(
            contentsOf: signed.codesignLogURL,
            encoding: .utf8
        )) ?? ""
        let signingContracts = [
            ("--identifier com.marynavdovenko.Plainpost.CLI", "Contents/MacOS/PlainpostCLI"),
            ("--identifier com.marynavdovenko.Plainpost.BrowserHost", "Contents/MacOS/PlainpostBrowserBridge"),
            (
                "--identifier com.marynavdovenko.Plainpost.BackgroundAgent",
                "PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent"
            ),
            (
                "--identifier com.marynavdovenko.Plainpost.Service",
                "PlainpostService.app/Contents/MacOS/PlainpostService"
            ),
            (
                "--identifier com.marynavdovenko.Plainpost",
                "PlainpostFixture.app"
            ),
        ]
        for (identifier, pathSuffix) in signingContracts {
            XCTAssertTrue(
                invocations.split(separator: "\n").contains {
                    $0.contains(identifier) && $0.hasSuffix(pathSuffix)
                },
                "\(identifier) -> \(pathSuffix)\n\(invocations)"
            )
        }
        let outerSigningIndex = try XCTUnwrap(
            invocations.split(separator: "\n").lastIndex {
                $0.contains("--identifier com.marynavdovenko.Plainpost ")
                    && $0.hasSuffix("PlainpostFixture.app")
            }
        )
        let nestedVerificationIndices = invocations.split(separator: "\n")
            .indices.filter {
                let line = invocations.split(separator: "\n")[$0]
                return line.contains("--verify --strict")
                    && !line.contains("--deep")
            }
        let nestedVerificationSuffixes = [
            "Contents/MacOS/PlainpostCLI",
            "Contents/MacOS/PlainpostBrowserBridge",
            "PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent",
            "PlainpostService.app/Contents/MacOS/PlainpostService",
            "PlainpostBackgroundAgent.app",
            "PlainpostService.app",
        ]
        for pathSuffix in nestedVerificationSuffixes {
            XCTAssertTrue(
                invocations.split(separator: "\n").contains {
                    $0.contains("--verify --strict")
                        && $0.hasSuffix(pathSuffix)
                },
                "missing nested verification for \(pathSuffix)\n\(invocations)"
            )
        }
        XCTAssertFalse(nestedVerificationIndices.isEmpty, invocations)
        XCTAssertTrue(
            nestedVerificationIndices.allSatisfy { $0 < outerSigningIndex },
            invocations
        )
    }

    private func runPackagingFixture(
        profile: ServiceProfileFixture
    ) throws -> (status: Int32, output: String) {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging(profile: profile)
        return try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: signed.environment
        )
    }

    private func packagingStopSentinel(
        in fixture: PackagingScriptFixture
    ) throws -> URL {
        let sentinel = fixture.rootURL.appendingPathComponent(
            "runtime-stop-invoked.txt"
        )
        try fixture.createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents:
                "#!/bin/sh\n"
                + "/usr/bin/printf 'invoked' > \"\(sentinel.path)\"\n"
        )
        return sentinel
    }

    func testPackagingStopsBundleProcessStartedByNativeBuildBeforeReplacement() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        try FileManager.default.removeItem(
            at: fixture.rootURL.appendingPathComponent(
                "Scripts/stop-packaged-runtime.sh"
            )
        )
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let serviceReadyURL = fixture.rootURL.appendingPathComponent(
            "build-started-service.ready"
        )
        let serviceTerminatedURL = fixture.rootURL.appendingPathComponent(
            "build-started-service.terminated"
        )
        let serviceURL = try fixture.createTermReportingExecutable(
            relativePath:
                ".build/PlainpostFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService",
            readyURL: serviceReadyURL,
            terminatedURL: serviceTerminatedURL
        )
        let pinnedServicePath = serviceURL.path.hasPrefix("/var/")
            ? "/private\(serviceURL.path)"
            : serviceURL.path
        let processPIDURL = fixture.rootURL.appendingPathComponent(
            "build-started-service.pid"
        )
        let fakeXcodebuild = try fixture.createExecutable(
            relativePath: "process-starting-xcodebuild.sh",
            contents:
                "#!/bin/bash\n"
                + "/usr/bin/nohup \"\(pinnedServicePath)\" "
                + "</dev/null >/dev/null 2>&1 &\n"
                + "/usr/bin/printf '%s' \"$!\" > \"\(processPIDURL.path)\"\n"
                + "for attempt in {1..200}; do\n"
                + "  [[ -f \"\(serviceReadyURL.path)\" ]] && exit 0\n"
                + "  /bin/sleep 0.01\n"
                + "done\n"
                + "exit 74\n"
        )
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: fixture.bundleURL,
            label: "com.marynavdovenko.Plainpost.BackgroundAgent",
            initiallyLoaded: false
        )
        defer {
            if let pidText = try? String(
                contentsOf: processPIDURL,
                encoding: .utf8
            ), let pid = Int32(pidText) {
                _ = kill(pid, SIGKILL)
            }
        }
        var environment = signed.environment
        environment["PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND"] =
            fakeXcodebuild.path
        environment["PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND"] =
            launchctl.commandURL.path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try? String(
                contentsOf: serviceTerminatedURL,
                encoding: .utf8
            ),
            "terminated",
            "The final runtime-stop proof must TERM a service that starts "
                + "during the native build."
        )
    }

    func testPackagingForwardsCustomLaunchAgentLabelAndPreservesOutputWhenStopFails() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        let signed = try fixture.prepareSignedPackaging()
        let argumentsURL = fixture.rootURL.appendingPathComponent(
            "runtime-stop-arguments.txt"
        )
        let buildCompletedURL = fixture.rootURL.appendingPathComponent(
            "native-build-completed.txt"
        )
        let fakeXcodebuild = try fixture.createExecutable(
            relativePath: "marker-xcodebuild.sh",
            contents:
                "#!/bin/sh\n"
                + "/usr/bin/printf 'complete' > "
                + "\"\(buildCompletedURL.path)\"\n"
        )
        try fixture.createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents:
                "#!/bin/sh\n"
                + "[ -f \"\(buildCompletedURL.path)\" ] || exit 78\n"
                + "/usr/bin/printf '%s\\n' \"$@\" > \"\(argumentsURL.path)\"\n"
                + "exit 79\n"
        )
        let bundleSentinel = try fixture.createFile(
            relativePath: ".build/PlainpostFixture.app/preserve.txt",
            contents: "preserve"
        )
        var environment = signed.environment
        environment["PLAINPOST_LAUNCH_AGENT_LABEL"] =
            "com.marynavdovenko.Plainpost.CustomService"
        environment["PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND"] =
            fakeXcodebuild.path

        let result = try fixture.runScript(
            named: "package-app-bundle.sh",
            environment: environment
        )

        XCTAssertEqual(result.status, 79, result.output)
        let expectedBundlePath = fixture.bundleURL.path.hasPrefix("/var/")
            ? "/private\(fixture.bundleURL.path)"
            : fixture.bundleURL.path
        XCTAssertEqual(
            try? String(contentsOf: argumentsURL, encoding: .utf8),
            expectedBundlePath + "\ncom.marynavdovenko.Plainpost.CustomService\n"
        )
        XCTAssertEqual(
            try? String(contentsOf: buildCompletedURL, encoding: .utf8),
            "complete",
            "The native build must finish before the final runtime-stop gate."
        )
        XCTAssertEqual(
            try? String(contentsOf: bundleSentinel, encoding: .utf8),
            "preserve",
            "A failed unload/stop proof must abort before deleting output."
        )
    }

    func testPackagingRuntimeStopBootsOutExactCustomLaunchAgentBeforeTermination() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let customLabel = "com.marynavdovenko.Plainpost.CustomService"
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: customLabel,
            initiallyLoaded: true
        )
        let process = Process()
        process.executableURL = serviceURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path, customLabel],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: launchctl.stateURL, encoding: .utf8),
            "unloaded"
        )
        XCTAssertFalse(process.isRunning)
        let launchctlLog = (try? String(
            contentsOf: launchctl.logURL,
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            launchctlLog.contains(
                "bootout gui/\(getuid())/\(customLabel)"
            ),
            launchctlLog
        )
    }

    func testPackagingRuntimeStopAcceptsCurrentLaunchctlEndpointDescription() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let label = "com.marynavdovenko.Plainpost.Service"
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: label,
            initiallyLoaded: true,
            usesEndpointDescription: true
        )
        let process = Process()
        process.executableURL = serviceURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path, label],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: launchctl.stateURL, encoding: .utf8),
            "unloaded"
        )
        XCTAssertFalse(process.isRunning)
    }

    func testPackagingRuntimeStopRejectsLoadedLabelForDifferentMachService() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let label = "com.marynavdovenko.Plainpost.BackgroundAgent"
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: label,
            initiallyLoaded: true,
            jobMatchesRuntime: false,
            usesEndpointDescription: true
        )
        let process = Process()
        process.executableURL = serviceURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path, label],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "Loaded LaunchAgent does not match the Plainpost service runtime"
            ),
            result.output
        )
        XCTAssertTrue(
            process.isRunning,
            "An unrelated loaded label must be rejected before process termination."
        )
    }

    func testPackagingRuntimeStopRejectsDecoyLaunchAgentFieldsBeforeBootout() throws {
        let cases = [
            "program prefix",
            "Mach-service prefix",
            "disabled Mach service",
            "unmanaged endpoint",
            "unrelated-field decoys",
            "wrong job header",
            "duplicate program field",
        ]

        for name in cases {
            let fixture = try PackagingScriptFixture()
            defer { fixture.remove() }
            try fixture.copyRepositoryScript(
                named: "stop-packaged-runtime.sh"
            )
            let bundleURL = fixture.rootURL.appendingPathComponent(
                ".build/PlainpostStopFixture.app"
            )
            _ = try fixture.createExecutable(
                relativePath:
                    ".build/PlainpostStopFixture.app/Contents/Library/"
                    + "Helpers/PlainpostService.app/Contents/MacOS/"
                    + "PlainpostService"
            )
            let expectedProgram = bundleURL.appendingPathComponent(
                "Contents/Library/Helpers/PlainpostService.app/"
                    + "Contents/MacOS/PlainpostService"
            ).path
            let label = "com.marynavdovenko.Plainpost.BackgroundAgent"
            let expectedMachService = "com.marynavdovenko.Plainpost.Service"
            var programOverride: String?
            var machServiceOverride: String?
            var machServiceEnabled = true
            var targetOverride: String?
            var additionalJobDescription = ""
            var usesEndpointDescription = false

            switch name {
            case "program prefix":
                programOverride = expectedProgram + ".stale"
            case "Mach-service prefix":
                machServiceOverride = expectedMachService + ".stale"
            case "disabled Mach service":
                machServiceEnabled = false
            case "unmanaged endpoint":
                machServiceEnabled = false
                usesEndpointDescription = true
            case "unrelated-field decoys":
                programOverride = bundleURL.appendingPathComponent(
                    "Contents/MacOS/UnrelatedService"
                ).path
                machServiceOverride = "com.olhapi.Unrelated.Service"
                additionalJobDescription =
                    "    environment = {\n"
                    + "        expected-program = \(expectedProgram)\n"
                    + "        expected-mach = \(expectedMachService)\n"
                    + "    }\n"
            case "wrong job header":
                targetOverride = "gui/999/\(label)"
            case "duplicate program field":
                additionalJobDescription =
                    "    program = \(expectedProgram).stale\n"
            default:
                XCTFail("Unhandled launchctl fixture case: \(name)")
            }

            let launchctl = try fixture.createLaunchctlFixture(
                bundleURL: bundleURL,
                label: label,
                initiallyLoaded: true,
                programOverride: programOverride,
                machServiceOverride: machServiceOverride,
                machServiceEnabled: machServiceEnabled,
                targetOverride: targetOverride,
                additionalJobDescription: additionalJobDescription,
                usesEndpointDescription: usesEndpointDescription
            )

            let result = try fixture.runScript(
                named: "stop-packaged-runtime.sh",
                arguments: [bundleURL.path, label],
                environment: [
                    "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                        launchctl.commandURL.path
                ]
            )

            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Loaded LaunchAgent does not match the Plainpost "
                    + "service runtime"
                ),
                "\(name): \(result.output)"
            )
            XCTAssertEqual(
                try String(contentsOf: launchctl.stateURL, encoding: .utf8),
                "loaded",
                "\(name): a decoy job must not be booted out"
            )
            let log = (try? String(
                contentsOf: launchctl.logURL,
                encoding: .utf8
            )) ?? ""
            XCTAssertFalse(
                log.contains("bootout "),
                "\(name): \(log)"
            )
        }
    }

    func testPackagingRuntimeStopAbortsBeforeTerminationWhenBootoutFails() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let label = "com.marynavdovenko.Plainpost.BackgroundAgent"
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: label,
            initiallyLoaded: true,
            bootoutSucceeds: false
        )
        let process = Process()
        process.executableURL = serviceURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path, label],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("Could not boot out Plainpost LaunchAgent"),
            result.output
        )
        XCTAssertTrue(
            process.isRunning,
            "Process termination must not begin until launchd unload is proven."
        )
    }

    func testPackagingRuntimeStopMatchesMetacharacterExecutablePathExactly() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/Plainpost[Stop]+?.app"
        )
        let helperURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/Plainpost[Stop]+?.app/Contents/Library/Helpers/"
                + "PlainpostBackgroundAgent.app/Contents/MacOS/"
                + "PlainpostBackgroundAgent"
        )
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: "com.marynavdovenko.Plainpost.BackgroundAgent",
            initiallyLoaded: false
        )
        let process = Process()
        process.executableURL = helperURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(
            process.isRunning,
            "Executable paths must be matched literally, not as pgrep regexes."
        )
    }

    func testPackagingRuntimeStopRejectsPersistentRespawnAfterKill() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createIgnoringTermExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: "com.marynavdovenko.Plainpost.BackgroundAgent",
            initiallyLoaded: true
        )
        let supervisorStopURL = fixture.rootURL.appendingPathComponent(
            "stop-respawn-supervisor"
        )
        let childPIDURL = fixture.rootURL.appendingPathComponent(
            "respawned-service.pid"
        )
        let supervisorURL = try fixture.createExecutable(
            relativePath: "respawn-supervisor.sh",
            contents:
                "#!/bin/bash\n"
                + "while [[ ! -f \"\(supervisorStopURL.path)\" ]]; do\n"
                + "  \"\(serviceURL.path)\" &\n"
                + "  child=$!\n"
                + "  /usr/bin/printf '%s' \"$child\" > \"\(childPIDURL.path)\"\n"
                + "  wait \"$child\" 2>/dev/null\n"
                + "done\n"
        )
        let supervisor = Process()
        supervisor.executableURL = supervisorURL
        try supervisor.run()
        let startDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: childPIDURL.path),
              Date() < startDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDURL.path))
        defer {
            try? Data("stop".utf8).write(to: supervisorStopURL)
            if let pidText = try? String(
                contentsOf: childPIDURL,
                encoding: .utf8
            ), let pid = Int32(pidText) {
                _ = kill(pid, SIGKILL)
            }
            if supervisor.isRunning {
                supervisor.terminate()
                supervisor.waitUntilExit()
            }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains(
                "Unable to prove packaged runtime termination"
            ),
            result.output
        )
        XCTAssertEqual(
            try String(contentsOf: launchctl.stateURL, encoding: .utf8),
            "unloaded"
        )
    }

    func testPackagingRuntimeStopTerminatesStaleBundledHelper() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        guard fixture.repositoryScriptExists(named: "stop-packaged-runtime.sh") else {
            XCTFail("Missing Scripts/stop-packaged-runtime.sh")
            return
        }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let helperURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostBackgroundAgent.app/Contents/MacOS/"
                + "PlainpostBackgroundAgent"
        )
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: "com.marynavdovenko.Plainpost.BackgroundAgent",
            initiallyLoaded: false
        )
        let process = Process()
        process.executableURL = helperURL
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(process.isRunning, "The stale packaged helper must stop before its bundle is replaced.")
    }

    func testPackagingRuntimeStopTerminatesStaleBundledService() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        guard fixture.repositoryScriptExists(named: "stop-packaged-runtime.sh") else {
            XCTFail("Missing Scripts/stop-packaged-runtime.sh")
            return
        }
        try fixture.copyRepositoryScript(named: "stop-packaged-runtime.sh")
        let bundleURL = fixture.rootURL.appendingPathComponent(
            ".build/PlainpostStopFixture.app"
        )
        let serviceURL = try fixture.createSleepingExecutable(
            relativePath:
                ".build/PlainpostStopFixture.app/Contents/Library/Helpers/"
                + "PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        let launchctl = try fixture.createLaunchctlFixture(
            bundleURL: bundleURL,
            label: "com.marynavdovenko.Plainpost.BackgroundAgent",
            initiallyLoaded: false
        )
        let process = Process()
        process.executableURL = serviceURL
        try process.run()
        XCTAssertTrue(
            process.isRunning,
            "The service fixture must be live before the runtime-stop script runs."
        )
        defer {
            if process.isRunning { process.terminate() }
        }

        let result = try fixture.runScript(
            named: "stop-packaged-runtime.sh",
            arguments: [bundleURL.path],
            environment: [
                "PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND":
                    launchctl.commandURL.path
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(
            process.isRunning,
            "The stale packaged service must stop before its bundle is replaced."
        )
    }

    func testPackagingRequiresBrowserBridge() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        try fixture.copyRepositoryScript(named: "package-app-bundle.sh")
        try fixture.createExecutable(relativePath: ".build/debug/PlainpostBackgroundAgent")

        let result = try fixture.runScript(named: "package-app-bundle.sh")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(
            result.output,
            "Missing built browser bridge: \(fixture.rootURL.path)/.build/debug/PlainpostBrowserBridge\n"
        )
    }

    func testBrowserHostRepairCommandDelegatesInstallationToSwiftBridge() throws {
        let fixture = try PackagingScriptFixture()
        defer { fixture.remove() }
        guard fixture.repositoryScriptExists(named: "install-browser-extension-host.sh") else {
            XCTFail("Missing Scripts/install-browser-extension-host.sh")
            return
        }
        try fixture.copyRepositoryScript(named: "install-browser-extension-host.sh")
        let invocationURL = fixture.rootURL.appendingPathComponent("bridge-invocation.txt")
        let bridgeURL = try fixture.createExecutable(
            relativePath: ".build/debug/PlainpostBrowserBridge",
            contents: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(invocationURL.path)\"\n"
        )

        let result = try fixture.runScript(named: "install-browser-extension-host.sh")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: invocationURL, encoding: .utf8),
            "--install-hosts\n--executable\n\(bridgeURL.path)\n"
        )
    }

    func testPlainpostCLILaunchAgentInstallWritesSecretSafePlistWithoutLoading() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-launch-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appendingPathComponent("com.marynavdovenko.Plainpost.BackgroundAgent.plist")
        let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        let logDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let servicePath = tempDir.appendingPathComponent(
            "PlainpostService.app/Contents/MacOS/PlainpostService"
        ).path

        let output = try PlainpostCLIProcess.run([
            "service", "launch-agent",
            "install",
            "--service-executable", servicePath,
            "--plist-path", plistURL.path,
            "--data-dir", dataDir.path,
            "--log-dir", logDir.path,
            "--no-load",
            "--json"
        ])

        XCTAssertTrue(output.contains(#""installed":true"#), output)
        XCTAssertTrue(output.contains(#""launchctl_loaded":false"#), output)
        XCTAssertTrue(output.contains(#""label":"com.marynavdovenko.Plainpost.BackgroundAgent""#), output)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))

        let data = try Data(contentsOf: plistURL)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(object["Label"] as? String, "com.marynavdovenko.Plainpost.BackgroundAgent")
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [servicePath, "--xpc-service"]
        )
        XCTAssertEqual(
            object["MachServices"] as? [String: Bool],
            ["com.marynavdovenko.Plainpost.Service": true]
        )
        XCTAssertEqual(object["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((object["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(object["StandardOutPath"] as? String, logDir.appendingPathComponent("service.out.log").path)
        XCTAssertEqual(object["StandardErrorPath"] as? String, logDir.appendingPathComponent("service.err.log").path)

        let environment = try XCTUnwrap(object["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["PLAINPOST_DATA_DIR"], dataDir.path)

        let status = try PlainpostCLIProcess.run([
            "service", "launch-agent",
            "status",
            "--plist-path", plistURL.path,
            "--json"
        ])
        XCTAssertTrue(status.contains(#""installed":true"#), status)
        XCTAssertTrue(status.contains(#""label":"com.marynavdovenko.Plainpost.BackgroundAgent""#), status)
    }

    func testPlainpostCLILaunchAgentInstallDefaultsToNestedServiceExecutable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plainpost-packaged-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        let appBundle = tempDir.appendingPathComponent("Plainpost.app")
        let packagedCLI = appBundle.appendingPathComponent(
            "Contents/MacOS/PlainpostCLI"
        )
        try FileManager.default.createDirectory(
            at: packagedCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let productsDirectory = try XCTUnwrap(
            Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?
                .bundleURL.deletingLastPathComponent()
        )
        try FileManager.default.copyItem(
            at: productsDirectory.appendingPathComponent("plainpost"),
            to: packagedCLI
        )
        let appInfo: [String: Any] = [
            "CFBundleExecutable": "PlainpostCLI",
            "CFBundleIdentifier": "com.marynavdovenko.Plainpost.CLI",
            "CFBundlePackageType": "APPL",
        ]
        let appInfoData = try PropertyListSerialization.data(
            fromPropertyList: appInfo,
            format: .xml,
            options: 0
        )
        try appInfoData.write(
            to: appBundle.appendingPathComponent("Contents/Info.plist"),
            options: .atomic
        )
        let plistURL = tempDir.appendingPathComponent("launch-agent.plist")
        let expectedServicePath = appBundle.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app/"
                + "Contents/MacOS/PlainpostService"
        ).path

        let output = try PlainpostCLIProcess.run(
            [
                "service", "launch-agent", "install",
                "--plist-path", plistURL.path,
                "--data-dir", tempDir.appendingPathComponent("data").path,
                "--log-dir", tempDir.appendingPathComponent("logs").path,
                "--no-load",
                "--json",
            ],
            executableURL: packagedCLI
        )

        XCTAssertTrue(output.contains(#""installed":true"#), output)
        let data = try Data(contentsOf: plistURL)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [expectedServicePath, "--xpc-service"]
        )
        XCTAssertEqual(
            object["MachServices"] as? [String: Bool],
            ["com.marynavdovenko.Plainpost.Service": true]
        )
    }

    func testPlainpostCLILaunchAgentInstallDefaultsToSiblingServiceForSourceBuild() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plainpost-source-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let productsDirectory = try XCTUnwrap(
            Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?
                .bundleURL.deletingLastPathComponent()
        )
        let plistURL = tempDir.appendingPathComponent("launch-agent.plist")

        let output = try PlainpostCLIProcess.run([
            "service", "launch-agent", "install",
            "--plist-path", plistURL.path,
            "--data-dir", tempDir.appendingPathComponent("data").path,
            "--log-dir", tempDir.appendingPathComponent("logs").path,
            "--no-load",
            "--json",
        ])

        XCTAssertTrue(output.contains(#""installed":true"#), output)
        let data = try Data(contentsOf: plistURL)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            [
                productsDirectory.appendingPathComponent("PlainpostService").path,
                "--xpc-service",
            ]
        )
    }

    func testAccountTestUsesLocalIMAPAndSMTPHarnesses() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }
        let output = try credentials.runCLI([
            "account", "test",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--password", "secret",
            "--json"
        ])

        XCTAssertTrue(output.contains(#""imap":true"#))
        XCTAssertTrue(output.contains(#""smtp":true"#))
        XCTAssertFalse(output.contains("secret"))
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: "smtp-secret"
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-draft-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-draft-body-\(UUID().uuidString).txt")
        try "Draft body for server sync.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }

        _ = try credentials.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "imap-secret",
            "--smtp-password", "smtp-secret",
            "--db-path", dbURL.path,
            "--json",
        ])
        let createOutput = try credentials.runCLI([
            "draft", "create",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "Server draft sync",
            "--body-file", bodyURL.path,
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(createOutput.contains(#""draft_id":"drf_cli_1""#), createOutput)

        let syncOutput = try credentials.runCLI([
            "draft", "sync", "drf_cli_1",
            "--to-server",
            "--db-path", dbURL.path,
            "--json"
        ])

        XCTAssertTrue(syncOutput.contains(#""draft_id":"drf_cli_1""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""mailbox":"Drafts""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""server_draft_uid":1001"#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""server_draft_mailbox_id":"Drafts""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""synced_to_server":true"#), syncOutput)
        XCTAssertFalse(syncOutput.contains("imap-secret"))

        let appended = imap.appendedMessages
        guard let remoteDraft = appended.first else {
            XCTFail("Expected remote Drafts append after sync. Output: \(syncOutput)")
            return
        }
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(remoteDraft.uid, 1001)
        XCTAssertEqual(remoteDraft.mailbox, "Drafts")
        XCTAssertEqual(remoteDraft.flags, ["\\Draft"])
        XCTAssertTrue(remoteDraft.data.contains("Subject: Server draft sync"))
        XCTAssertTrue(remoteDraft.data.contains("Draft body for server sync."))
        XCTAssertFalse(remoteDraft.data.contains("Bcc:"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let draft = try reloaded.draft(id: DraftID("drf_cli_1"))
        XCTAssertEqual(draft.serverDraftUID, 1001)
        XCTAssertEqual(draft.serverDraftMailboxID, "Drafts")
    }

    func testPlainpostCLIDraftSyncCanUsePlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-draft-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-draft-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-draft-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-draft-body-\(UUID().uuidString).txt")
        try "Draft body through service sync.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let keychainService = "PlainpostServiceDraftSyncTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-draft-imap-secret",
            "--smtp-password", "service-draft-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("service-draft-imap-secret"))
        XCTAssertFalse(accountOutput.contains("service-draft-smtp-secret"))

        let createOutput = try keychain.runCLI([
            "draft", "create",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "Service draft sync",
            "--body-file", bodyURL.path,
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(createOutput.contains(#""draft_id":"drf_cli_1""#), createOutput)

        let output = try keychain.runCLI([
            "draft", "sync", "drf_cli_1",
            "--to-server",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"draft_sync""#), output)
        XCTAssertTrue(output.contains(#""draft_id":"drf_cli_1""#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Drafts""#), output)
        XCTAssertTrue(output.contains(#""server_draft_uid":1001"#), output)
        XCTAssertTrue(output.contains(#""server_draft_mailbox_id":"Drafts""#), output)
        XCTAssertTrue(output.contains(#""synced_to_server":true"#), output)
        XCTAssertFalse(output.contains("service-draft-imap-secret"))
        XCTAssertFalse(output.contains("service-draft-smtp-secret"))

        let appended = imap.appendedMessages
        guard let remoteDraft = appended.first else {
            XCTFail("Expected service-owned Drafts append. Output: \(output)")
            return
        }
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(remoteDraft.mailbox, "Drafts")
        XCTAssertEqual(remoteDraft.flags, ["\\Draft"])
        XCTAssertTrue(remoteDraft.data.contains("Subject: Service draft sync"))
        XCTAssertTrue(remoteDraft.data.contains("Draft body through service sync."))
        XCTAssertFalse(remoteDraft.data.contains("Bcc:"))
        XCTAssertEqual(
            imap.loginAttempts.last,
            LocalIMAPLoginAttempt(username: "me@example.com", password: "service-draft-imap-secret")
        )

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let draft = try reloaded.draft(id: DraftID("drf_cli_1"))
        XCTAssertEqual(draft.serverDraftUID, 1001)
        XCTAssertEqual(draft.serverDraftMailboxID, "Drafts")

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-draft-imap-secret"))
        XCTAssertFalse(dbText.contains("service-draft-smtp-secret"))
    }

    func testAccountAddPersistsSQLiteAndKeychainViaLocalHarnesses() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-account-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let keychainService = "PlainpostCLIAccountTests.\(UUID().uuidString)"
        let credentialCapability = CLITestCredentialCapability(service: keychainService)
        defer { credentialCapability.clear() }

        let output = try credentialCapability.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "imap-secret",
            "--smtp-password", "smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""account_id":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""imap_verified":true"#))
        XCTAssertTrue(output.contains(#""smtp_verified":true"#))
        XCTAssertFalse(output.contains("imap-secret"))
        XCTAssertFalse(output.contains("smtp-secret"))

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("imap-secret"))
        XCTAssertFalse(dbText.contains("smtp-secret"))

    }

    func testAccountAddUsesDefaultDataDirectoryWhenDbPathIsAbsent() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-account-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let keychainService = "PlainpostCLIAccountDefaultDataDirTests.\(UUID().uuidString)"
        let credentialCapability = CLITestCredentialCapability(service: keychainService)
        defer { credentialCapability.clear() }

        let output = try credentialCapability.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "imap-secret",
            "--smtp-password", "smtp-secret",
            "--keychain-service", keychainService,
            "--json"
        ], environment: ["PLAINPOST_DATA_DIR": dataDir.path])

        XCTAssertTrue(output.contains(#""account_id":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""imap_verified":true"#))
        XCTAssertTrue(output.contains(#""smtp_verified":true"#))
        XCTAssertFalse(output.contains("imap-secret"))
        XCTAssertFalse(output.contains("smtp-secret"))

        let dbURL = dataDir.appendingPathComponent("Plainpost.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            XCTFail("Expected account add to create \(dbURL.path)")
            return
        }

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.id.rawValue), ["acc_me_example_com"])
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("imap-secret"))
        XCTAssertFalse(dbText.contains("smtp-secret"))
    }

    func testPlainpostCLIServiceBridgeUsesApplicationSupportStoreWhenDbPathIsAbsent() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-default-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-default-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let appSupportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-app-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupportDir) }
        let environment = ["PLAINPOST_APPLICATION_SUPPORT_DIR": appSupportDir.path]

        let keychainService = "PlainpostServiceDefaultStoreTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-default-imap-secret",
            "--smtp-password", "service-default-smtp-secret",
            "--keychain-service", keychainService,
            "--json"
        ], environment: environment)

        XCTAssertTrue(accountOutput.contains(#""service":"PlainpostService""#), accountOutput)
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#))
        XCTAssertFalse(accountOutput.contains("service-default-imap-secret"))
        XCTAssertFalse(accountOutput.contains("service-default-smtp-secret"))
        let acceptedBeforeSync = await smtp.acceptedMessages()

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--keychain-service", keychainService,
            "--json"
        ], environment: environment)

        XCTAssertTrue(syncOutput.contains(#""service":"PlainpostService""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""action":"sync_inbox""#))
        XCTAssertTrue(
            syncOutput.contains(#""message_ids":[]"#),
            syncOutput
        )
        XCTAssertFalse(syncOutput.contains("service-default-imap-secret"))
        XCTAssertFalse(syncOutput.contains("service-default-smtp-secret"))

        let acceptedAfterSync = await smtp.acceptedMessages()
        XCTAssertEqual(acceptedAfterSync.count, acceptedBeforeSync.count)

        let dbURL = appSupportDir.appendingPathComponent("Plainpost.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            XCTFail("Expected service bridge to create \(dbURL.path)")
            return
        }

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.id.rawValue), ["acc_me_example_com"])
        XCTAssertTrue(reloaded.messages.contains { $0.id == MessageID("msg_acc_me_example_com_inbox_1_1") })

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-default-imap-secret"))
        XCTAssertFalse(dbText.contains("service-default-smtp-secret"))
    }

    func testPlainpostCLIAccountAddCanUsePlainpostService() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "bridge-add-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "bridge-add-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-bridge-add-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceBridgeAddTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let output = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "bridge-add-imap-secret",
            "--smtp-password", "bridge-add-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        guard output.contains(#""service":"PlainpostService""#) else {
            XCTFail(output)
            return
        }
        XCTAssertTrue(output.contains(#""action":"account_add""#))
        XCTAssertTrue(output.contains(#""account_id":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""imap_verified":true"#))
        XCTAssertTrue(output.contains(#""smtp_verified":true"#))
        XCTAssertFalse(output.contains("bridge-add-imap-secret"))
        XCTAssertFalse(output.contains("bridge-add-smtp-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.id.rawValue), ["acc_me_example_com"])
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(syncOutput.contains(#""action":"sync_inbox""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""synced_message_count":1"#))
        XCTAssertTrue(
            syncOutput.contains(#""message_ids":[]"#),
            syncOutput
        )
        XCTAssertFalse(syncOutput.contains("bridge-add-imap-secret"))
        XCTAssertFalse(syncOutput.contains("bridge-add-smtp-secret"))
        XCTAssertEqual(imap.loginAttempts.last, LocalIMAPLoginAttempt(username: "me@example.com", password: "bridge-add-imap-secret"))

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("bridge-add-imap-secret"))
        XCTAssertFalse(dbText.contains("bridge-add-smtp-secret"))
    }

    func testAccountSyncUsesLocalIMAPHarnessAndReturnsCachedMetadata() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "sync-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: "sync-secret"
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plainpost-account-sync-\(UUID().uuidString).sqlite"
            )
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }

        _ = try credentials.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--password", "sync-secret",
            "--db-path", databaseURL.path,
            "--json",
        ])
        try seedUnrelatedCachedSyncMessage(
            databaseURL: databaseURL
        )
        let output = try credentials.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--db-path", databaseURL.path,
            "--json"
        ])

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(output.utf8)
            ) as? [String: Any]
        )
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let jobID = try XCTUnwrap(data["job_id"] as? String)
        XCTAssertFalse(jobID.isEmpty)
        XCTAssertEqual(
            envelope as NSDictionary,
            [
                "ok": true,
                "data": [
                    "service": "PlainpostService",
                    "action": "sync_inbox",
                    "account": "acc_me_example_com",
                    "synced_message_count": 1,
                    "newly_discovered_message_count": 0,
                    "message_ids": [],
                    "mailboxes": [
                        ["path": "INBOX"]
                    ],
                    "messages": [
                        [
                            "message_id":
                                "msg_acc_me_example_com_inbox_1_1",
                            "subject": "Availability",
                            "preview": "Can you meet next Tuesday?",
                            "path": "INBOX",
                        ]
                    ],
                    "job_id": jobID,
                ] as [String: Any],
            ] as NSDictionary,
            output
        )
        XCTAssertFalse(output.contains("sync-secret"))

        let reloaded = try SQLiteMailStore(path: databaseURL.path)
        try reloaded.migrate()
        XCTAssertEqual(
            reloaded.messages.first?.preview,
            "Can you meet next Tuesday?"
        )
    }

    func testPlainpostServiceSyncInboxUsesLocalIMAPAndPersistsSQLite() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-sync-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: "service-sync-secret"
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }
        _ = try credentials.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--password", "service-sync-secret",
            "--db-path", dbURL.path,
            "--json",
        ])
        let output = try credentials.runCLI([
            "account", "sync", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--json",
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"sync_inbox""#))
        XCTAssertTrue(output.contains(#""account":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""synced_message_count":1"#))
        XCTAssertTrue(output.contains(#""path":"INBOX""#))
        XCTAssertTrue(output.contains(#""message_ids":[]"#), output)
        XCTAssertFalse(output.contains("service-sync-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])
        XCTAssertEqual(
            reloaded.messages.map(\.id.rawValue),
            ["msg_acc_me_example_com_inbox_1_1"]
        )
        XCTAssertEqual(reloaded.messages.first?.preview, "Can you meet next Tuesday?")

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-sync-secret"))
    }

    func testPlainpostServiceSyncInboxReturnsValidJSONForControlCharacters() async throws {
        let message = MessageSummary(
            id: MessageID("msg_control_1"),
            threadID: ThreadID("thr_control_1"),
            from: EmailAddress("alice@example.com"),
            subject: "Availability\tWindow",
            preview: "Can you meet next Tuesday?",
            smartCategory: .personal
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-sync-control-secret",
            message: message
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: "service-sync-control-secret"
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-sync-control-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }
        _ = try credentials.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--password", "service-sync-control-secret",
            "--db-path", dbURL.path,
            "--json",
        ])
        let output = try credentials.runCLI([
            "account", "sync", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--json",
        ])
        _ = try JSONSerialization.jsonObject(with: Data(output.utf8))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.messages.first?.subject, "Availability\tWindow")
        XCTAssertFalse(output.contains("service-sync-control-secret"))
    }

    func testPlainpostServiceSyncInboxUsesSQLiteAccountAndKeychainPassword() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "keychain-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "keychain-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-keychain-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceSyncTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "keychain-imap-secret",
            "--smtp-password", "keychain-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""service":"PlainpostService""#), accountOutput)
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#))
        XCTAssertTrue(accountOutput.contains(#""account_id":"acc_me_example_com""#))
        XCTAssertTrue(accountOutput.contains(#""imap_verified":true"#))
        XCTAssertTrue(accountOutput.contains(#""smtp_verified":true"#))
        XCTAssertFalse(accountOutput.contains("keychain-imap-secret"))
        XCTAssertFalse(accountOutput.contains("keychain-smtp-secret"))

        let output = try keychain.runService([
            "sync", "inbox",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#))
        XCTAssertTrue(output.contains(#""action":"sync_inbox""#))
        XCTAssertTrue(output.contains(#""account":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""synced_message_count":1"#))
        XCTAssertTrue(output.contains(#""message_ids":[]"#), output)
        XCTAssertFalse(output.contains("keychain-imap-secret"))
        XCTAssertFalse(output.contains("keychain-smtp-secret"))
        XCTAssertEqual(imap.loginAttempts.last, LocalIMAPLoginAttempt(username: "me@example.com", password: "keychain-imap-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.id.rawValue), ["acc_me_example_com"])
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])
        XCTAssertEqual(reloaded.messages.map(\.id.rawValue), ["msg_acc_me_example_com_inbox_1_1"])

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("keychain-imap-secret"))
        XCTAssertFalse(dbText.contains("keychain-smtp-secret"))
    }

    func testPlainpostServiceStoredCredentialsUsePersistedLoginUsername() async throws {
        let imap = LocalIMAPServer(
            username: "login-id",
            password: "stored-login-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "login-id", password: "stored-login-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-login-username-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let keychainService = "PlainpostServiceLoginUsernameTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "login-id",
            "--imap-password", "stored-login-imap-secret",
            "--smtp-password", "stored-login-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""service":"PlainpostService""#), accountOutput)
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#))
        XCTAssertFalse(accountOutput.contains("stored-login-imap-secret"))
        XCTAssertFalse(accountOutput.contains("stored-login-smtp-secret"))

        let syncOutput = try keychain.runService([
            "sync", "inbox",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""action":"sync_inbox""#), syncOutput)
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)
        XCTAssertFalse(syncOutput.contains("stored-login-imap-secret"))
        XCTAssertFalse(syncOutput.contains("stored-login-smtp-secret"))

        let store = try SQLiteMailStore(path: dbURL.path)
        try store.migrate()
        let draft = Draft(
            id: DraftID("drf_login_username"),
            accountID: AccountID("acc_me_example_com"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Tuesday works for me.",
            createdBy: "codex",
            aiGenerated: false,
            sourceThreadID: nil
        )
        _ = try store.createDraft(draft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Send with stored login username")
        let acceptedBeforeApproval = await smtp.acceptedMessages()

        let approvalResult = try keychain.perform(
            .approveSend(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: "local-user"
                )
            ),
            databaseURL: dbURL
        )
        XCTAssertEqual(approvalResult.kind, .approveSend)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeApproval.count + 1)
        let acceptedMessage = try XCTUnwrap(accepted.last)
        XCTAssertEqual(acceptedMessage.mailFrom, EmailAddress("me@example.com"))
        XCTAssertEqual(acceptedMessage.recipients, [EmailAddress("alice@example.com")])

        let appended = try XCTUnwrap(imap.appendedMessages.last)
        XCTAssertEqual(appended.mailbox, "Sent")
        XCTAssertEqual(appended.flags, ["\\Seen"])
        XCTAssertTrue(appended.data.contains("Subject: Re: Availability"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(try reloaded.sendRequest(id: request.id).status, .sent)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("stored-login-imap-secret"))
        XCTAssertFalse(dbText.contains("stored-login-smtp-secret"))
    }

    func testPlainpostCLIAccountSyncCanUsePlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "bridge-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "bridge-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-bridge-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceBridgeSyncTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "bridge-imap-secret",
            "--smtp-password", "bridge-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("bridge-imap-secret"))
        XCTAssertFalse(accountOutput.contains("bridge-smtp-secret"))

        let output = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"sync_inbox""#))
        XCTAssertTrue(output.contains(#""account":"acc_me_example_com""#))
        XCTAssertTrue(output.contains(#""synced_message_count":1"#))
        XCTAssertTrue(output.contains(#""message_ids":[]"#), output)
        XCTAssertFalse(output.contains("bridge-imap-secret"))
        XCTAssertFalse(output.contains("bridge-smtp-secret"))
        XCTAssertEqual(imap.loginAttempts.last, LocalIMAPLoginAttempt(username: "me@example.com", password: "bridge-imap-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.accounts.map(\.id.rawValue), ["acc_me_example_com"])
        XCTAssertEqual(reloaded.mailboxes.map(\.path), ["INBOX"])
        XCTAssertEqual(reloaded.messages.map(\.id.rawValue), ["msg_acc_me_example_com_inbox_1_1"])

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("bridge-imap-secret"))
        XCTAssertFalse(dbText.contains("bridge-smtp-secret"))
    }

    func testPlainpostServiceProcessReturnsAfterAOneShotServiceTimeout() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-one-shot-hang-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        try "#!/bin/sh\nexec sleep 60\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let start = Date()
        let output = try PlainpostServiceProcess.run(
            ["--health", "--json"],
            executableURL: scriptURL,
            timeout: 0.1
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(output.contains("timedOut=true"), output)
    }

    func testCredentialCapabilitySpawnClosesNonTargetDescriptorsAndGrandchildCannotInherit() throws {
        let script = """
        #!/bin/bash
        for descriptor in {3..256}; do
            if [ "$descriptor" != "198" ] && [ -e "/dev/fd/$descriptor" ]; then
                echo "unexpected-fd=$descriptor"
                exit 41
            fi
        done
        [ -e /dev/fd/198 ] || exit 42
        read -r -n 1 <&198
        exec 198<&-
        /bin/bash -c '[ ! -e /dev/fd/198 ]' || exit 43
        echo capability-probe-ok
        """

        let capability = CLITestCredentialCapability()
        try capability.seedAccountCredentials(email: "probe@example.com", imapPassword: "imap", smtpPassword: "smtp")
        let output = try capability.withPayload { payload in
            try PlainpostCLIProcess.runWithCredentialCapability(
                ["-c", script],
                stdin: nil,
                environment: [:],
                payload: payload,
                executable: URL(fileURLWithPath: "/bin/bash")
            )
        }

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "capability-probe-ok", output)
    }

    func testCredentialCapabilitySpawnPreservesInheritedStdinWithoutInputOverride() throws {
        let capability = CLITestCredentialCapability()
        let output = try capability.withPayload { payload in
            try PlainpostCLIProcess.runWithCredentialCapability(
                ["-c", "[ -e /dev/fd/0 ] && echo stdin-inherited || echo stdin-closed"],
                stdin: nil,
                environment: [:],
                payload: payload,
                executable: URL(fileURLWithPath: "/bin/bash")
            )
        }

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "stdin-inherited", output)
    }

    func testCredentialCapabilityParentEndpointsAreCloseOnExec() throws {
        let pipe = Pipe()
        let descriptors = [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor]
        try PlainpostCLIProcess.markCloseOnExec(descriptors)

        for descriptor in descriptors {
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        }
    }

    func testCredentialCapabilitySpawnReportsSignalTerminationReason() throws {
        let capability = CLITestCredentialCapability()
        try capability.seedAccountCredentials(email: "signal@example.com", imapPassword: "imap", smtpPassword: "smtp")
        let output = try capability.withPayload { payload in
            try PlainpostCLIProcess.runWithCredentialCapability(
                ["-c", "kill -TERM $$"],
                stdin: nil,
                environment: [:],
                payload: payload,
                executable: URL(fileURLWithPath: "/bin/bash")
            )
        }

        XCTAssertTrue(output.contains("status=143"), output)
        XCTAssertTrue(output.contains("reason=15"), output)
    }

    func testCLIIgnoresRetiredCredentialForwardingAndHighDescriptor() throws {
        let sentinel: Int32 = 1024
        let original = dup(sentinel)
        let source = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(source, 0)
        XCTAssertEqual(dup2(source, sentinel), sentinel)
        _ = close(source)
        defer {
            _ = close(sentinel)
            if original >= 0 {
                _ = dup2(original, sentinel)
                _ = close(original)
            }
        }

        let wrapper = try PlainpostServiceProcess.capabilityDescriptorProbeWrapper(sentinel: sentinel)
        defer { try? FileManager.default.removeItem(at: wrapper) }
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-capability-forwarding-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let capability = CLITestCredentialCapability()
        let output = try capability.withPayload { payload in
            try PlainpostCLIProcess.runWithCredentialCapability(
                ["send", "status", "missing", "--use-service", "--db-path", databaseURL.path, "--json"],
                stdin: nil,
                environment: ["PLAINPOST_SERVICE_EXECUTABLE": wrapper.path],
                payload: payload,
                additionalInheritedDescriptors: [sentinel]
            )
        }

        XCTAssertFalse(output.contains("sentinel-leaked"), output)
        XCTAssertTrue(output.contains(#""error""#), output)

        let persistentCapability = CLITestCredentialCapability()
        let persistentRequest = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"missing"}}}"#
        let persistentOutput = try persistentCapability.withPayload { payload in
            try PlainpostCLIProcess.runWithCredentialCapability(
                ["mcp", "serve", "--use-service", "--db-path", databaseURL.path],
                stdin: persistentRequest + "\n",
                environment: ["PLAINPOST_SERVICE_EXECUTABLE": wrapper.path],
                payload: payload,
                additionalInheritedDescriptors: [sentinel]
            )
        }
        XCTAssertFalse(persistentOutput.contains("sentinel-leaked"), persistentOutput)
        XCTAssertTrue(persistentOutput.contains(#""id":1"#), persistentOutput)
    }

    func testPlainpostCLISmartInboxBatchCanUsePlainpostServiceStoredCredentials() async throws {
        let newsletter = MessageSummary(
            id: MessageID("msg_uid_1"),
            threadID: ThreadID("thr_newsletter_1"),
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-smart-imap-secret",
            message: newsletter,
            extraMailboxes: [.init(path: "Archive")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-smart-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-smart-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceSmartInboxTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-smart-imap-secret",
            "--smtp-password", "service-smart-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("service-smart-imap-secret"))
        XCTAssertFalse(accountOutput.contains("service-smart-smtp-secret"))

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)

        let syncedStore = try SQLiteMailStore(path: dbURL.path)
        try syncedStore.migrate()
        _ = try syncedStore.recategorize(
            MessageID("msg_acc_me_example_com_inbox_1_1"),
            as: .newsletter,
            actor: PlainpostFixtures.codexActor
        )
        _ = try syncedStore.markSeen(
            MessageID("msg_acc_me_example_com_inbox_1_1"),
            seen: false,
            actor: PlainpostFixtures.codexActor
        )

        let output = try keychain.runCLI([
            "smart-inbox", "batch",
            "newsletters",
            "--action", "archive-read",
            "--use-service",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"smart_inbox_batch""#), output)
        XCTAssertTrue(output.contains(#""category":"newsletter""#), output)
        XCTAssertTrue(output.contains(#""affected_count":1"#), output)
        XCTAssertTrue(output.contains(#""message_ids":["msg_acc_me_example_com_inbox_1_1"]"#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Archive""#), output)
        XCTAssertFalse(output.contains("service-smart-imap-secret"))
        XCTAssertFalse(output.contains("service-smart-smtp-secret"))
        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.messages.first(where: { $0.id == MessageID("msg_acc_me_example_com_inbox_1_1") })?.isSeen, true)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-smart-imap-secret"))
        XCTAssertFalse(dbText.contains("service-smart-smtp-secret"))
    }

    func testPlainpostCLIMailSeenActionsCanUsePlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-mail-action-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-mail-action-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-mail-action-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceMailActionTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-mail-action-imap-secret",
            "--smtp-password", "service-mail-action-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("service-mail-action-imap-secret"))
        XCTAssertFalse(accountOutput.contains("service-mail-action-smtp-secret"))

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)

        let markReadOutput = try keychain.runCLI([
            "mail", "mark-read", "msg_acc_me_example_com_inbox_1_1",
            "--use-service",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(markReadOutput.contains(#""service":"PlainpostService""#), markReadOutput)
        XCTAssertTrue(markReadOutput.contains(#""action":"mark_read""#), markReadOutput)
        XCTAssertTrue(markReadOutput.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), markReadOutput)
        XCTAssertTrue(markReadOutput.contains(#""seen":true"#), markReadOutput)
        XCTAssertFalse(markReadOutput.contains("service-mail-action-imap-secret"))
        XCTAssertFalse(markReadOutput.contains("service-mail-action-smtp-secret"))
        XCTAssertEqual(
            try reloadedSeen(
                dbURL: dbURL,
                messageID: "msg_acc_me_example_com_inbox_1_1"
            ),
            true
        )

        let markUnreadOutput = try keychain.runCLI([
            "mail", "mark-unread", "msg_acc_me_example_com_inbox_1_1",
            "--use-service",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(markUnreadOutput.contains(#""service":"PlainpostService""#), markUnreadOutput)
        XCTAssertTrue(markUnreadOutput.contains(#""action":"mark_unread""#), markUnreadOutput)
        XCTAssertTrue(markUnreadOutput.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), markUnreadOutput)
        XCTAssertTrue(markUnreadOutput.contains(#""seen":false"#), markUnreadOutput)
        XCTAssertFalse(markUnreadOutput.contains("service-mail-action-imap-secret"))
        XCTAssertFalse(markUnreadOutput.contains("service-mail-action-smtp-secret"))
        XCTAssertEqual(
            try reloadedSeen(
                dbURL: dbURL,
                messageID: "msg_acc_me_example_com_inbox_1_1"
            ),
            false
        )

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-mail-action-imap-secret"))
        XCTAssertFalse(dbText.contains("service-mail-action-smtp-secret"))
    }

    func testMCPMarkSeenUsesPlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-mark-seen-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-mark-seen-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-mark-seen-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPMarkSeenTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "mcp-mark-seen-imap-secret",
            "--smtp-password", "mcp-mark-seen-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("mcp-mark-seen-imap-secret"))
        XCTAssertFalse(accountOutput.contains("mcp-mark-seen-smtp-secret"))

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)

        let retainedServiceRequests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.mark_seen","arguments":{"message_id":"msg_acc_me_example_com_inbox_1_1","seen":true,"account":"acc_me_example_com"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.mark_seen","arguments":{"message_id":"msg_acc_me_example_com_inbox_1_1","seen":false,"account":"acc_me_example_com"}}}"#,
        ].joined(separator: "\n")
        let retainedServiceOutput = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path, "--keychain-service", keychainService],
            stdin: retainedServiceRequests + "\n"
        )

        XCTAssertTrue(retainedServiceOutput.contains(#""id":1"#), retainedServiceOutput)
        XCTAssertTrue(retainedServiceOutput.contains(#""id":2"#), retainedServiceOutput)
        XCTAssertTrue(retainedServiceOutput.contains(#""action":"mark_read""#), retainedServiceOutput)
        XCTAssertTrue(retainedServiceOutput.contains(#""action":"mark_unread""#), retainedServiceOutput)
        XCTAssertFalse(retainedServiceOutput.contains("mcp-mark-seen-imap-secret"))
        XCTAssertFalse(retainedServiceOutput.contains("mcp-mark-seen-smtp-secret"))
        XCTAssertEqual(
            try reloadedSeen(
                dbURL: dbURL,
                messageID: "msg_acc_me_example_com_inbox_1_1"
            ),
            false
        )

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("mcp-mark-seen-imap-secret"))
        XCTAssertFalse(dbText.contains("mcp-mark-seen-smtp-secret"))
    }

    func testPlainpostCLIMailArchiveCanUsePlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-archive-imap-secret",
            message: PlainpostFixtures.aliceMessage,
            extraMailboxes: [.init(path: "Archive")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-archive-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-archive-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceArchiveTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        try addAndSyncServiceAccount(
            credentials: keychain,
            imap: imap,
            smtp: smtp,
            dbURL: dbURL,
            keychainService: keychainService,
            imapPassword: "service-archive-imap-secret",
            smtpPassword: "service-archive-smtp-secret"
        )

        let output = try keychain.runCLI([
            "mail", "archive", "msg_acc_me_example_com_inbox_1_1",
            "--use-service",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"archive""#), output)
        XCTAssertTrue(output.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Archive""#), output)
        XCTAssertTrue(output.contains(#""archived":true"#), output)
        XCTAssertFalse(output.contains("service-archive-imap-secret"))
        XCTAssertFalse(output.contains("service-archive-smtp-secret"))
        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let archived = try reloadedMessage(
            dbURL: dbURL,
            messageID: "msg_acc_me_example_com_inbox_1_1"
        )
        XCTAssertEqual(archived?.mailboxPath, "Archive")
        XCTAssertEqual(archived?.isDeleted, false)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-archive-imap-secret"))
        XCTAssertFalse(dbText.contains("service-archive-smtp-secret"))
    }

    func testPlainpostCLIMailDeleteCanUsePlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-delete-imap-secret",
            message: PlainpostFixtures.aliceMessage,
            extraMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-delete-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceDeleteTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        try addAndSyncServiceAccount(
            credentials: keychain,
            imap: imap,
            smtp: smtp,
            dbURL: dbURL,
            keychainService: keychainService,
            imapPassword: "service-delete-imap-secret",
            smtpPassword: "service-delete-smtp-secret"
        )

        let output = try keychain.runCLI([
            "mail", "delete", "msg_acc_me_example_com_inbox_1_1",
            "--use-service",
            "--account", "acc_me_example_com",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"delete""#), output)
        XCTAssertTrue(output.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), output)
        XCTAssertTrue(output.contains(#""outcome":"moved_to_trash""#), output)
        XCTAssertTrue(output.contains(#""deleted":false"#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Trash""#), output)
        XCTAssertFalse(output.contains("service-delete-imap-secret"))
        XCTAssertFalse(output.contains("service-delete-smtp-secret"))
        // Delete moves to Trash: copy, then expunge that UID from the Inbox.
        XCTAssertEqual(imap.copyAttempts, [LocalIMAPCopyAttempt(uid: 1, mailbox: "Trash")])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let deleted = try reloadedMessage(
            dbURL: dbURL,
            messageID: "msg_acc_me_example_com_inbox_1_1"
        )
        XCTAssertEqual(deleted?.isDeleted, false)
        XCTAssertEqual(deleted?.mailboxPath, "Trash")

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-delete-imap-secret"))
        XCTAssertFalse(dbText.contains("service-delete-smtp-secret"))
    }

    func testMCPArchiveUsesPlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-archive-imap-secret",
            message: PlainpostFixtures.aliceMessage,
            extraMailboxes: [.init(path: "Archive")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-archive-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-archive-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPArchiveTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        try addAndSyncServiceAccount(
            credentials: keychain,
            imap: imap,
            smtp: smtp,
            dbURL: dbURL,
            keychainService: keychainService,
            imapPassword: "mcp-archive-imap-secret",
            smtpPassword: "mcp-archive-smtp-secret"
        )

        let archiveRequest = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.archive","arguments":{"message_id":"msg_acc_me_example_com_inbox_1_1","account":"acc_me_example_com","archive_mailbox":"Archive"}}}"#
        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path, "--keychain-service", keychainService],
            stdin: archiveRequest + "\n"
        )

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"archive""#), output)
        XCTAssertTrue(output.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Archive""#), output)
        XCTAssertTrue(output.contains(#""archived":true"#), output)
        XCTAssertFalse(output.contains("mcp-archive-imap-secret"))
        XCTAssertFalse(output.contains("mcp-archive-smtp-secret"))
        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let archived = try reloadedMessage(
            dbURL: dbURL,
            messageID: "msg_acc_me_example_com_inbox_1_1"
        )
        XCTAssertEqual(archived?.mailboxPath, "Archive")
        XCTAssertEqual(archived?.isDeleted, false)
    }

    func testMCPDeleteUsesPlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-delete-imap-secret",
            message: PlainpostFixtures.aliceMessage,
            extraMailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-delete-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPDeleteTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        try addAndSyncServiceAccount(
            credentials: keychain,
            imap: imap,
            smtp: smtp,
            dbURL: dbURL,
            keychainService: keychainService,
            imapPassword: "mcp-delete-imap-secret",
            smtpPassword: "mcp-delete-smtp-secret"
        )

        let deleteRequest = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"msg_acc_me_example_com_inbox_1_1","account":"acc_me_example_com"}}}"#
        // The same call again, as an agent retrying would send it.
        let retryRequest = deleteRequest.replacingOccurrences(of: #""id":1"#, with: #""id":2"#)
        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path, "--keychain-service", keychainService],
            stdin: deleteRequest + "\n" + retryRequest + "\n"
        )

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"delete""#), output)
        XCTAssertTrue(output.contains(#""message_id":"msg_acc_me_example_com_inbox_1_1""#), output)
        // In Trash, not erased: the reply says what happened, and the retry erases nothing.
        XCTAssertTrue(output.contains("moved_to_trash"), output)
        XCTAssertTrue(output.contains("already_in_trash"), output)
        XCTAssertTrue(output.contains("Moved to Trash."), output)
        XCTAssertTrue(output.contains("Trash"), output)
        XCTAssertFalse(output.contains("mcp-delete-imap-secret"))
        XCTAssertFalse(output.contains("mcp-delete-smtp-secret"))
        XCTAssertEqual(imap.copyAttempts, [LocalIMAPCopyAttempt(uid: 1, mailbox: "Trash")])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let deleted = try reloadedMessage(
            dbURL: dbURL,
            messageID: "msg_acc_me_example_com_inbox_1_1"
        )
        XCTAssertEqual(deleted?.isDeleted, false)
        XCTAssertEqual(deleted?.mailboxPath, "Trash")
    }

    private func remoteHeader(imap: LocalIMAPServer, password: String) async throws -> String {
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await client.login(username: "me@example.com", password: password)
        _ = try await client.selectMailbox("INBOX")
        return try await client.fetchHeader(uid: 1)
    }

    private func reloadedSeen(dbURL: URL, messageID: String) throws -> Bool? {
        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        return resolvedReloadedMessage(messageID, messages: reloaded.messages)?.isSeen
    }

    private func reloadedMessage(dbURL: URL, messageID: String) throws -> MessageSummary? {
        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        return resolvedReloadedMessage(messageID, messages: reloaded.messages)
    }

    private func resolvedReloadedMessage(_ messageID: String, messages: [MessageSummary]) -> MessageSummary? {
        if let exact = messages.first(where: { $0.id == MessageID(messageID) }) { return exact }
        let prefix = "msg_uid_"
        guard messageID.hasPrefix(prefix), let uid = Int(messageID.dropFirst(prefix.count)) else { return nil }
        let matches = messages.filter { Int($0.id.rawValue.split(separator: "_").last ?? "") == uid }
        return matches.count == 1 ? matches[0] : nil
    }

    private func addAndSyncServiceAccount(
        credentials: CLITestCredentialCapability,
        imap: LocalIMAPServer,
        smtp: LocalSMTPServer,
        dbURL: URL,
        keychainService: String,
        imapPassword: String,
        smtpPassword: String
    ) throws {
        let accountOutput = try credentials.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", imapPassword,
            "--smtp-password", smtpPassword,
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains(imapPassword))
        XCTAssertFalse(accountOutput.contains(smtpPassword))

        let syncOutput = try credentials.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)
    }

    func testPlainpostServiceCreatesPendingSendRequestWithoutSMTP() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-request-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-request-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-send-request-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-send-request-\(UUID().uuidString).txt")
        try "Tuesday works for me from the service queue.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let keychainService = "PlainpostServiceSendRequestTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-request-imap-secret",
            "--smtp-password", "service-request-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("service-request-imap-secret"))
        XCTAssertFalse(accountOutput.contains("service-request-smtp-secret"))
        let acceptedBeforeRequest = await smtp.acceptedMessages()

        let output = try keychain.runService([
            "send", "request",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "Service follow up",
            "--body-file", bodyURL.path,
            "--agent", "codex",
            "--reason", "Prepare this reply",
            "--db-path", dbURL.path,
            "--json"
        ])

        let outputData = try cliData(output)
        let requestID = try XCTUnwrap(
            outputData["request_id"] as? String
        )
        XCTAssertTrue(output.contains(#""status":"pending""#))
        XCTAssertFalse(output.contains("service-request-imap-secret"))
        XCTAssertFalse(output.contains("service-request-smtp-secret"))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeRequest.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let request = try reloaded.sendRequest(
            id: SendRequestID(requestID)
        )
        let draft = try reloaded.draft(id: request.draftID)
        XCTAssertEqual(draft.accountID, AccountID("acc_me_example_com"))
        XCTAssertEqual(draft.from, EmailAddress("me@example.com"))
        XCTAssertEqual(draft.to, [EmailAddress("alice@example.com")])
        XCTAssertEqual(draft.subject, "Service follow up")
        XCTAssertEqual(draft.bodyPlain, "Tuesday works for me from the service queue.")
        XCTAssertEqual(request.draftID, draft.id)
        XCTAssertEqual(request.requestedBy, "codex")
        XCTAssertEqual(request.status, .pending)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-request-imap-secret"))
        XCTAssertFalse(dbText.contains("service-request-smtp-secret"))
    }

    func testPlainpostServiceReadsAndCancelsSendRequestWithoutSMTP() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-status-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-status-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-status-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-status-\(UUID().uuidString).txt")
        try "Tuesday works for me from service status.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let keychainService = "PlainpostServiceStatusTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-status-imap-secret",
            "--smtp-password", "service-status-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)

        let requestOutput = try keychain.runService([
            "send", "request",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "Service status follow up",
            "--body-file", bodyURL.path,
            "--agent", "codex",
            "--reason", "Prepare then inspect",
            "--db-path", dbURL.path,
            "--json"
        ])
        let requestID = try XCTUnwrap(
            try cliData(requestOutput)["request_id"] as? String
        )
        let acceptedBeforeStatus = await smtp.acceptedMessages()

        let statusOutput = try keychain.runService([
            "send", "status",
            "--request", requestID,
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(statusOutput.contains(#""request_id":"\#(requestID)""#))
        XCTAssertTrue(statusOutput.contains(#""status":"pending""#))
        XCTAssertFalse(statusOutput.contains("service-status-imap-secret"))
        XCTAssertFalse(statusOutput.contains("service-status-smtp-secret"))

        let cancelOutput = try keychain.runService([
            "send", "cancel",
            "--request", requestID,
            "--actor", "codex",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(cancelOutput.contains(#""request_id":"\#(requestID)""#))
        XCTAssertTrue(cancelOutput.contains(#""status":"cancelled""#))
        XCTAssertFalse(cancelOutput.contains("service-status-imap-secret"))
        XCTAssertFalse(cancelOutput.contains("service-status-smtp-secret"))

        let statusAfterCancelOutput = try keychain.runService([
            "send", "status",
            "--request", requestID,
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(statusAfterCancelOutput.contains(#""status":"cancelled""#))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeStatus.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let request = try reloaded.sendRequest(id: SendRequestID(requestID))
        XCTAssertEqual(request.status, .cancelled)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-status-imap-secret"))
        XCTAssertFalse(dbText.contains("service-status-smtp-secret"))
    }

    func testPlainpostCLISendRequestCanUsePlainpostServiceWithoutSMTP() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "cli-service-request-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "cli-service-request-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-service-send-request-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-service-send-request-\(UUID().uuidString).txt")
        try "Tuesday works for me through plainpost service bridge.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let keychainService = "PlainpostCLIServiceSendRequestTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "cli-service-request-imap-secret",
            "--smtp-password", "cli-service-request-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("cli-service-request-imap-secret"))
        XCTAssertFalse(accountOutput.contains("cli-service-request-smtp-secret"))
        let acceptedBeforeRequest = await smtp.acceptedMessages()

        let output = try keychain.runCLI([
            "send", "request",
            "--use-service",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "CLI service follow up",
            "--body-file", bodyURL.path,
            "--agent", "codex",
            "--reason", "Prepare through service",
            "--db-path", dbURL.path,
            "--json"
        ])

        let requestID = try XCTUnwrap(
            try cliData(output)["request_id"] as? String
        )
        XCTAssertTrue(output.contains(#""status":"pending""#))
        XCTAssertFalse(output.contains("cli-service-request-imap-secret"))
        XCTAssertFalse(output.contains("cli-service-request-smtp-secret"))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeRequest.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let request = try reloaded.sendRequest(
            id: SendRequestID(requestID)
        )
        let draft = try reloaded.draft(id: request.draftID)
        XCTAssertEqual(draft.accountID, AccountID("acc_me_example_com"))
        XCTAssertEqual(draft.from, EmailAddress("me@example.com"))
        XCTAssertEqual(draft.to, [EmailAddress("alice@example.com")])
        XCTAssertEqual(draft.subject, "CLI service follow up")
        XCTAssertEqual(draft.bodyPlain, "Tuesday works for me through plainpost service bridge.")
        XCTAssertEqual(request.draftID, draft.id)
        XCTAssertEqual(request.requestedBy, "codex")
        XCTAssertEqual(request.status, .pending)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("cli-service-request-imap-secret"))
        XCTAssertFalse(dbText.contains("cli-service-request-smtp-secret"))
    }

    func testPlainpostCLISendStatusAndCancelCanUsePlainpostService() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "cli-service-status-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "cli-service-status-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-service-status-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-service-status-\(UUID().uuidString).txt")
        try "Tuesday works for me through plainpost service status.".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let keychainService = "PlainpostCLIServiceStatusTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "cli-service-status-imap-secret",
            "--smtp-password", "cli-service-status-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)

        let requestOutput = try keychain.runCLI([
            "send", "request",
            "--use-service",
            "--account", "acc_me_example_com",
            "--from", "me@example.com",
            "--to", "alice@example.com",
            "--subject", "CLI service status follow up",
            "--body-file", bodyURL.path,
            "--agent", "codex",
            "--reason", "Prepare then inspect through CLI",
            "--db-path", dbURL.path,
            "--json"
        ])
        let requestID = try XCTUnwrap(
            try cliData(requestOutput)["request_id"] as? String
        )
        let acceptedBeforeStatus = await smtp.acceptedMessages()

        let statusOutput = try keychain.runCLI([
            "send", "status",
            requestID,
            "--use-service",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(statusOutput.contains(#""request_id":"\#(requestID)""#))
        XCTAssertTrue(statusOutput.contains(#""status":"pending""#))

        let cancelOutput = try keychain.runCLI([
            "send", "cancel",
            requestID,
            "--use-service",
            "--agent", "codex",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(cancelOutput.contains(#""request_id":"\#(requestID)""#))
        XCTAssertTrue(cancelOutput.contains(#""status":"cancelled""#))
        XCTAssertFalse(statusOutput.contains("cli-service-status-imap-secret"))
        XCTAssertFalse(statusOutput.contains("cli-service-status-smtp-secret"))
        XCTAssertFalse(cancelOutput.contains("cli-service-status-imap-secret"))
        XCTAssertFalse(cancelOutput.contains("cli-service-status-smtp-secret"))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeStatus.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(
            try reloaded.sendRequest(id: SendRequestID(requestID)).status,
            .cancelled
        )
    }

    func testMCPRequestSendCanUsePlainpostServiceWithoutSMTP() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-service-request-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-service-request-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-service-send-request-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPServiceSendRequestTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "mcp-service-request-imap-secret",
            "--smtp-password", "mcp-service-request-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("mcp-service-request-imap-secret"))
        XCTAssertFalse(accountOutput.contains("mcp-service-request-smtp-secret"))
        let acceptedBeforeRequest = await smtp.acceptedMessages()

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.request_send","arguments":{"account":"acc_me_example_com","from":"me@example.com","to":"alice@example.com","subject":"MCP service follow up","body":"Tuesday works for me through MCP service bridge.","agent":"codex","reason":"Prepare through MCP service"}}}"#
        ].joined(separator: "\n")

        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path],
            stdin: requests + "\n"
        )

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""draft_id":"drf_mcp_1""#))
        XCTAssertTrue(output.contains(#""request_id":"srq_drf_mcp_1""#))
        XCTAssertTrue(output.contains(#""status":"pending""#))
        XCTAssertFalse(output.contains("mcp-service-request-imap-secret"))
        XCTAssertFalse(output.contains("mcp-service-request-smtp-secret"))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeRequest.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let draft = try reloaded.draft(id: DraftID("drf_mcp_1"))
        XCTAssertEqual(draft.accountID, AccountID("acc_me_example_com"))
        XCTAssertEqual(draft.from, EmailAddress("me@example.com"))
        XCTAssertEqual(draft.to, [EmailAddress("alice@example.com")])
        XCTAssertEqual(draft.subject, "MCP service follow up")
        XCTAssertEqual(draft.bodyPlain, "Tuesday works for me through MCP service bridge.")
        let request = try reloaded.sendRequest(
            id: SendRequestID("srq_drf_mcp_1")
        )
        XCTAssertEqual(request.draftID, draft.id)
        XCTAssertEqual(request.requestedBy, "plainpost")
        XCTAssertEqual(request.status, .pending)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("mcp-service-request-imap-secret"))
        XCTAssertFalse(dbText.contains("mcp-service-request-smtp-secret"))
    }

    func testMCPSyncDraftUsesPlainpostServiceStoredCredentials() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-draft-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-draft-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-draft-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPDraftSyncTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "mcp-draft-imap-secret",
            "--smtp-password", "mcp-draft-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("mcp-draft-imap-secret"))
        XCTAssertFalse(accountOutput.contains("mcp-draft-smtp-secret"))

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.create_draft","arguments":{"account":"acc_me_example_com","from":"me@example.com","to":"alice@example.com","subject":"MCP synced draft","body":"Draft body through MCP sync."}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.sync_draft","arguments":{"draft_id":"drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path, "--keychain-service", keychainService],
            stdin: requests + "\n"
        )

        XCTAssertTrue(output.contains(#""id":1"#), output)
        XCTAssertTrue(output.contains(#""draft_id":"drf_mcp_1""#), output)
        XCTAssertTrue(output.contains(#""id":2"#), output)
        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"draft_sync""#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Drafts""#), output)
        XCTAssertTrue(output.contains(#""server_draft_uid":1001"#), output)
        XCTAssertTrue(output.contains(#""server_draft_mailbox_id":"Drafts""#), output)
        XCTAssertTrue(output.contains(#""synced_to_server":true"#), output)
        XCTAssertFalse(output.contains("mcp-draft-imap-secret"))
        XCTAssertFalse(output.contains("mcp-draft-smtp-secret"))

        let appended = imap.appendedMessages
        guard let remoteDraft = appended.first else {
            XCTFail("Expected MCP service Drafts append. Output: \(output)")
            return
        }
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(remoteDraft.uid, 1001)
        XCTAssertEqual(remoteDraft.mailbox, "Drafts")
        XCTAssertEqual(remoteDraft.flags, ["\\Draft"])
        XCTAssertTrue(remoteDraft.data.contains("Subject: MCP synced draft"))
        XCTAssertTrue(remoteDraft.data.contains("Draft body through MCP sync."))
        XCTAssertFalse(remoteDraft.data.contains("Bcc:"))
        XCTAssertEqual(
            imap.loginAttempts.last,
            LocalIMAPLoginAttempt(username: "me@example.com", password: "mcp-draft-imap-secret")
        )

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let draft = try reloaded.draft(id: DraftID("drf_mcp_1"))
        XCTAssertEqual(draft.accountID, AccountID("acc_me_example_com"))
        XCTAssertEqual(draft.from, EmailAddress("me@example.com"))
        XCTAssertEqual(draft.serverDraftUID, 1001)
        XCTAssertEqual(draft.serverDraftMailboxID, "Drafts")

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("mcp-draft-imap-secret"))
        XCTAssertFalse(dbText.contains("mcp-draft-smtp-secret"))
    }

    func testMCPSmartInboxBatchUsesPlainpostServiceStoredCredentials() async throws {
        let newsletter = MessageSummary(
            id: MessageID("msg_uid_1"),
            threadID: ThreadID("thr_newsletter_1"),
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-smart-imap-secret",
            message: newsletter,
            extraMailboxes: [.init(path: "Archive")]
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-smart-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-smart-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPSmartInboxTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "mcp-smart-imap-secret",
            "--smtp-password", "mcp-smart-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("mcp-smart-imap-secret"))
        XCTAssertFalse(accountOutput.contains("mcp-smart-smtp-secret"))

        let syncOutput = try keychain.runCLI([
            "account", "sync",
            "acc_me_example_com",
            "--use-service",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(syncOutput.contains(#""message_ids":[]"#), syncOutput)

        let syncedStore = try SQLiteMailStore(path: dbURL.path)
        try syncedStore.migrate()
        _ = try syncedStore.recategorize(
            MessageID("msg_acc_me_example_com_inbox_1_1"),
            as: .newsletter,
            actor: PlainpostFixtures.codexActor
        )
        _ = try syncedStore.markSeen(
            MessageID("msg_acc_me_example_com_inbox_1_1"),
            seen: false,
            actor: PlainpostFixtures.codexActor
        )

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.smart_inbox_batch","arguments":{"category":"newsletters","action":"archive-read","account":"acc_me_example_com"}}}"#
        ].joined(separator: "\n")

        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path, "--keychain-service", keychainService],
            stdin: requests + "\n"
        )

        XCTAssertTrue(output.contains(#""service":"PlainpostService""#), output)
        XCTAssertTrue(output.contains(#""action":"smart_inbox_batch""#), output)
        XCTAssertTrue(output.contains(#""affected_count":1"#), output)
        XCTAssertTrue(output.contains(#""message_ids":["msg_acc_me_example_com_inbox_1_1"]"#), output)
        XCTAssertTrue(output.contains(#""mailbox":"Archive""#), output)
        XCTAssertFalse(output.contains("mcp-smart-imap-secret"))
        XCTAssertFalse(output.contains("mcp-smart-smtp-secret"))
        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(reloaded.messages.first(where: { $0.id == MessageID("msg_acc_me_example_com_inbox_1_1") })?.isSeen, true)

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("mcp-smart-imap-secret"))
        XCTAssertFalse(dbText.contains("mcp-smart-smtp-secret"))
    }

    func testMCPServiceSendStatusAndCancelUsePlainpostService() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mcp-service-status-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "mcp-service-status-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-service-status-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostMCPServiceStatusTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runCLI([
            "account", "add",
            "--use-service",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "mcp-service-status-imap-secret",
            "--smtp-password", "mcp-service-status-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ])
        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        let acceptedBeforeStatus = await smtp.acceptedMessages()

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.request_send","arguments":{"account":"acc_me_example_com","from":"me@example.com","to":"alice@example.com","subject":"MCP service status follow up","body":"Tuesday works for me through MCP service status.","agent":"codex","reason":"Prepare through MCP service status"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.cancel_send_request","arguments":{"request_id":"srq_drf_mcp_1","agent":"codex"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let output = try keychain.runCLI(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path],
            stdin: requests + "\n"
        )

        XCTAssertTrue(output.contains(#""id":1"#), output)
        XCTAssertTrue(output.contains(#""request_id":"srq_drf_mcp_1""#))
        XCTAssertTrue(output.contains(#""id":2"#))
        XCTAssertTrue(output.contains(#""status":"pending""#))
        XCTAssertTrue(output.contains(#""id":3"#))
        XCTAssertTrue(output.contains(#""status":"cancelled""#))
        XCTAssertTrue(output.contains(#""id":4"#))
        XCTAssertFalse(output.contains("mcp-service-status-imap-secret"))
        XCTAssertFalse(output.contains("mcp-service-status-smtp-secret"))

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeStatus.count)

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(
            try reloaded.sendRequest(id: SendRequestID("srq_drf_mcp_1"))
                .status,
            .cancelled
        )
    }

    func testMCPSearchIgnoresRetiredGenericServiceExecutableOverride() throws {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }
        let dbURL = fixture.directory.appendingPathComponent("Plainpost.sqlite")

        let wrapper = try PlainpostServiceProcess.wrapperLoggingInvocations()
        defer {
            try? FileManager.default.removeItem(at: wrapper.scriptURL)
            try? FileManager.default.removeItem(at: wrapper.logURL)
        }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.search","arguments":{"query":"from:alice@example.com","mode":"messages","limit":2}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.search","arguments":{"query":"from:bob@example.com","mode":"messages","limit":2}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", dbURL.path],
            stdin: requests + "\n",
            environment: [
                "PLAINPOST_SERVICE_EXECUTABLE": wrapper.scriptURL.path
            ]
        )

        let responses = try output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
            }
        XCTAssertEqual(responses.count, 2, output)
        for (id, expectedMessageID) in [(1, "msg_cli_primary"), (2, "msg_cli_secondary")] {
            let envelope = try XCTUnwrap(responses.first { $0["id"] as? Int == id })
            XCTAssertNil(envelope["error"], "response \(id): \(envelope)")
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            let responseData = try JSONSerialization.data(withJSONObject: structuredContent)
            let response = try MailSearchJSON.decoder().decode(MailSearchResponse.self, from: responseData)
            guard case .message(let hit) = try XCTUnwrap(response.hits.first) else {
                return XCTFail("response \(id) did not contain a message hit: \(response)")
            }
            XCTAssertEqual(hit.messageID.rawValue, expectedMessageID)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wrapper.logURL.path)
        )
    }

    func testMCPServeRespondsBeforeStdinCloses() throws {
        let process = try PlainpostCLIProcess.start(["mcp", "serve"])
        defer { process.close() }

        try process.writeLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let response = try XCTUnwrap(process.readLine(timeout: 2), "Expected initialize response while stdin remains open")

        XCTAssertTrue(response.contains(#""id":1"#), response)
        XCTAssertTrue(response.contains(#""protocolVersion":"2024-11-05""#), response)
    }

    func testMCPIgnoresMissingRetiredGenericServiceExecutable() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-service-startup-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let missingService = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-plainpost-service-\(UUID().uuidString)")
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.request_send","arguments":{"account":"acc_personal","from":"me@example.com","to":"alice@example.com","subject":"MCP service startup failure","body":"This should fail through MCP.","agent":"codex","reason":"Regression coverage"}}}"#

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path],
            stdin: request + "\n",
            environment: [
                "PLAINPOST_SERVICE_EXECUTABLE": missingService.path
            ]
        )

        XCTAssertTrue(output.contains(#""id":1"#), output)
        XCTAssertFalse(output.contains(#""error""#), output)
        XCTAssertTrue(output.contains(#""request_id""#), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path), output)
    }

    func testMCPIgnoresHungRetiredGenericServiceExecutable() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-service-hang-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let wrapper = try PlainpostServiceProcess.hangingStdioWrapper()
        defer {
            try? FileManager.default.removeItem(at: wrapper.scriptURL)
            try? FileManager.default.removeItem(at: wrapper.logURL)
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.request_send","arguments":{"account":"acc_personal","from":"me@example.com","to":"alice@example.com","subject":"MCP service hang","body":"This should time out through MCP.","agent":"codex","reason":"Regression coverage"}}}"#
        let start = Date()
        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--use-service", "--db-path", dbURL.path],
            stdin: request + "\n",
            environment: [
                "PLAINPOST_SERVICE_EXECUTABLE": wrapper.scriptURL.path,
                "PLAINPOST_SERVICE_BRIDGE_TIMEOUT_SECONDS": "1"
            ]
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertTrue(output.contains(#""id":1"#), output)
        XCTAssertFalse(output.contains(#""error""#), output)
        XCTAssertTrue(output.contains(#""request_id""#), output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wrapper.logURL.path)
        )
    }

    func testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "service-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "service-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-approval-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let credentials = CLITestCredentialCapability()
        defer { credentials.clear() }
        _ = try credentials.runCLI([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "service-imap-secret",
            "--smtp-password", "service-smtp-secret",
            "--db-path", dbURL.path,
            "--json",
        ])
        let writer = try SQLiteMailStore(path: dbURL.path)
        try writer.migrate()
        let draft = try writer.createDraft(
            Draft(
                id: DraftID("drf_typed_service_approval"),
                accountID: AccountID("acc_me_example_com"),
                from: EmailAddress("me@example.com"),
                to: [EmailAddress("alice@example.com")],
                cc: [],
                bcc: [],
                subject: "Re: Availability",
                bodyPlain: "Tuesday works for me.",
                createdBy: "codex",
                aiGenerated: false,
                sourceThreadID: nil
            ),
            actor: PlainpostFixtures.codexActor
        )
        let request = try writer.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "User asked me to reply"
        )

        let acceptedBeforeApproval = await smtp.acceptedMessages()
        let approvalResult = try credentials.perform(
            .approveSend(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: "local-user"
                )
            ),
            databaseURL: dbURL
        )
        XCTAssertEqual(approvalResult.kind, .approveSend)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeApproval.count + 1)
        let acceptedMessage = try XCTUnwrap(accepted.last)
        XCTAssertTrue(acceptedMessage.data.contains("Subject: Re: Availability"))
        XCTAssertTrue(acceptedMessage.data.contains("Tuesday works for me."))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let persisted = try reloaded.sendRequest(id: request.id)
        XCTAssertEqual(persisted.status, .sent)
        XCTAssertEqual(persisted.approvedBy, "local-user")
        XCTAssertEqual(persisted.approvedDraftHash, draft.contentHash)
        XCTAssertTrue(reloaded.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("service-smtp-secret"))
    }

    func testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "stored-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "stored-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-stored-approval-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceApprovalTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "stored-imap-secret",
            "--smtp-password", "stored-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ], timeout: 30)

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("stored-imap-secret"))
        XCTAssertFalse(accountOutput.contains("stored-smtp-secret"))
        let acceptedBeforeApproval = await smtp.acceptedMessages()

        let writer = try SQLiteMailStore(path: dbURL.path)
        try writer.migrate()
        let draft = Draft(
            id: DraftID("drf_service_keychain_approval"),
            accountID: AccountID("acc_me_example_com"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Tuesday works for me.",
            createdBy: "codex",
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_alice_1")
        )
        let persistedDraft = try writer.createDraft(draft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(
            draftID: persistedDraft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "User asked me to reply"
        )

        let approvalResult = try keychain.perform(
            .approveSend(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: "local-user"
                )
            ),
            databaseURL: dbURL
        )
        XCTAssertEqual(approvalResult.kind, .approveSend)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeApproval.count + 1)
        let acceptedMessage = try XCTUnwrap(accepted.last)
        XCTAssertEqual(acceptedMessage.mailFrom, EmailAddress("me@example.com"))
        XCTAssertEqual(acceptedMessage.recipients, [EmailAddress("alice@example.com")])
        XCTAssertTrue(acceptedMessage.data.contains("Subject: Re: Availability"))
        XCTAssertTrue(acceptedMessage.data.contains("Tuesday works for me."))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        let persisted = try reloaded.sendRequest(id: request.id)
        XCTAssertEqual(persisted.status, .sent)
        XCTAssertEqual(persisted.approvedBy, "local-user")
        XCTAssertEqual(persisted.approvedDraftHash, persistedDraft.contentHash)
        XCTAssertTrue(reloaded.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("stored-imap-secret"))
        XCTAssertFalse(dbText.contains("stored-smtp-secret"))
    }

    func testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "stored-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "stored-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-remote-sent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceRemoteSentTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "stored-imap-secret",
            "--smtp-password", "stored-smtp-secret",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ], timeout: 30)

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("stored-imap-secret"))
        XCTAssertFalse(accountOutput.contains("stored-smtp-secret"))
        let acceptedBeforeApproval = await smtp.acceptedMessages()

        let writer = try SQLiteMailStore(path: dbURL.path)
        try writer.migrate()
        let draft = Draft(
            id: DraftID("drf_service_remote_sent"),
            accountID: AccountID("acc_me_example_com"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Tuesday works for me.",
            createdBy: "codex",
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_alice_1")
        )
        let persistedDraft = try writer.createDraft(draft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(
            draftID: persistedDraft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "User asked me to reply"
        )

        let approvalResult = try keychain.perform(
            .approveSend(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: "local-user"
                )
            ),
            databaseURL: dbURL
        )
        XCTAssertEqual(approvalResult.kind, .approveSend)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, acceptedBeforeApproval.count + 1)

        let appended = try XCTUnwrap(imap.appendedMessages.last)
        XCTAssertEqual(appended.mailbox, "Sent")
        XCTAssertEqual(appended.flags, ["\\Seen"])
        XCTAssertTrue(appended.data.contains("Subject: Re: Availability"))
        XCTAssertTrue(appended.data.contains("Tuesday works for me."))
        XCTAssertFalse(appended.data.contains("stored-imap-secret"))
        XCTAssertFalse(appended.data.contains("stored-smtp-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(try reloaded.sendRequest(id: request.id).status, .sent)
        XCTAssertTrue(reloaded.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("stored-imap-secret"))
        XCTAssertFalse(dbText.contains("stored-smtp-secret"))
    }

    func testPlainpostServiceApprovalUsesConfiguredSentMailbox() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "custom-sent-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: "custom-sent-smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-custom-sent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keychainService = "PlainpostServiceCustomSentTests.\(UUID().uuidString)"
        let keychain = CLITestCredentialCapability(service: keychainService)
        defer {
            try? keychain.deletePassword(account: "acc_me_example_com:imap")
            try? keychain.deletePassword(account: "acc_me_example_com:smtp")
        }

        let accountOutput = try keychain.runService([
            "account", "add",
            "--display-name", "Personal",
            "--email", "me@example.com",
            "--imap-host", "127.0.0.1",
            "--imap-port", "\(imap.port)",
            "--smtp-host", "127.0.0.1",
            "--smtp-port", "\(smtp.port)",
            "--username", "me@example.com",
            "--imap-password", "custom-sent-imap-secret",
            "--smtp-password", "custom-sent-smtp-secret",
            "--sent-mailbox", "Sent Items",
            "--db-path", dbURL.path,
            "--keychain-service", keychainService,
            "--json"
        ], timeout: 30)

        XCTAssertTrue(accountOutput.contains(#""action":"account_add""#), accountOutput)
        XCTAssertFalse(accountOutput.contains("custom-sent-imap-secret"))
        XCTAssertFalse(accountOutput.contains("custom-sent-smtp-secret"))

        let writer = try SQLiteMailStore(path: dbURL.path)
        try writer.migrate()
        XCTAssertEqual(writer.accounts.first?.sentMailbox, "Sent Items")
        let draft = Draft(
            id: DraftID("drf_service_custom_sent"),
            accountID: AccountID("acc_me_example_com"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Availability",
            bodyPlain: "Tuesday works for me.",
            createdBy: "codex",
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_alice_1")
        )
        let persistedDraft = try writer.createDraft(draft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(
            draftID: persistedDraft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "User asked me to reply"
        )

        let approvalResult = try keychain.perform(
            .approveSend(
                PlainpostApprovalDecisionInput(
                    requestID: request.id,
                    actorID: "local-user"
                )
            ),
            databaseURL: dbURL
        )
        XCTAssertEqual(approvalResult.kind, .approveSend)

        let appended = try XCTUnwrap(imap.appendedMessages.last)
        XCTAssertEqual(appended.mailbox, "Sent Items")
        XCTAssertEqual(appended.flags, ["\\Seen"])
        XCTAssertTrue(appended.data.contains("Subject: Re: Availability"))
        XCTAssertFalse(appended.data.contains("custom-sent-imap-secret"))
        XCTAssertFalse(appended.data.contains("custom-sent-smtp-secret"))

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(try reloaded.sendRequest(id: request.id).status, .sent)
        XCTAssertTrue(reloaded.mailboxes.contains { $0.path == "Sent Items" && $0.specialUse == "\\Sent" })
        XCTAssertTrue(reloaded.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })

        let dbText = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(dbText.contains("custom-sent-imap-secret"))
        XCTAssertFalse(dbText.contains("custom-sent-smtp-secret"))
    }

    func testPlainpostServiceRejectsRetiredGenericStdioWithoutMutatingQueue()
        async throws
    {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-stdio-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let writer = try SQLiteMailStore(path: dbURL.path)
        try writer.migrate()
        let draft = try writer.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try writer.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Inspect persistent service status"
        )

        let input = [
            #"{"id":"status-before","argv":["send","status","--request","\#(request.id.rawValue)","--db-path","\#(dbURL.path)","--json"]}"#,
            #"{"id":"cancel","argv":["send","cancel","--request","\#(request.id.rawValue)","--actor","codex","--db-path","\#(dbURL.path)","--json"]}"#,
            #"{"id":"status-after","argv":["send","status","--request","\#(request.id.rawValue)","--db-path","\#(dbURL.path)","--json"]}"#
        ].joined(separator: "\n") + "\n"

        let output = try PlainpostServiceProcess.runStdio(
            ["serve", "--stdio", "--json"],
            input: input
        )
        XCTAssertTrue(
            output.contains(
                "PlainpostService supports only --xpc-service and --version."
            ),
            output
        )

        let reloaded = try SQLiteMailStore(path: dbURL.path)
        try reloaded.migrate()
        XCTAssertEqual(try reloaded.sendRequest(id: request.id).status, .pending)
    }

    func testPlainpostServiceRejectsRetiredGenericStdioForInvalidInput()
        throws
    {
        let input = [
            #"{"id":"bad","argv":"not-array"}"#,
            #"{"id":"health","argv":["--health","--json"]}"#
        ].joined(separator: "\n") + "\n"

        let output = try PlainpostServiceProcess.runStdio(
            ["serve", "--stdio", "--json"],
            input: input
        )
        XCTAssertTrue(
            output.contains(
                "PlainpostService supports only --xpc-service and --version."
            ),
            output
        )
        XCTAssertFalse(output.contains(#""id":"health""#), output)
    }

    func testPlainpostServiceVersionRemainsAvailableWithoutGenericStdio()
        throws
    {
        let output = try PlainpostServiceProcess.run(["--version"])
        XCTAssertEqual(
            output.trimmingCharacters(in: .whitespacesAndNewlines),
            "PlainpostService 0.1.0"
        )
    }

    func testMCPStdioListsAndCallsSafeTools() throws {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.search","arguments":{"query":"project","limit":5}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.add_label","arguments":{"message_id":"msg_alice_1","label":"Needs Reply"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.recategorize","arguments":{"message_id":"msg_alice_1","category":"support"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"email.remove_label","arguments":{"message_id":"msg_alice_1","label":"Needs Reply"}}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"email.create_draft","arguments":{"to":"alice@example.com","subject":"MCP draft","body":"Draft body"}}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"email.update_draft","arguments":{"draft_id":"drf_mcp_1","subject":"Updated MCP draft","body":"Updated body"}}}"#,
            #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"email.delete_draft","arguments":{"draft_id":"drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"email.send_now","arguments":{}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            [
                "mcp", "serve",
                "--db-path",
                fixture.directory.appendingPathComponent(
                    "Plainpost.sqlite"
                ).path,
            ],
            stdin: requests + "\n"
        )

        XCTAssertTrue(output.contains(#""name":"email.search""#))
        XCTAssertTrue(
            output.contains(#""bestMatchingMessageID":"msg_cli_primary""#),
            output
        )
        XCTAssertTrue(output.contains(#""labels":["Needs Reply"]"#))
        XCTAssertTrue(output.contains(#""category":"support""#))
        XCTAssertTrue(output.contains(#""draft_id":"drf_mcp_1""#))
        XCTAssertTrue(output.contains(#""subject":"Updated MCP draft""#), output)
        XCTAssertTrue(output.contains(#""status":"deleted""#), output)
        XCTAssertTrue(output.contains(#""id":14"#))
        XCTAssertTrue(output.contains(#""error""#))
        XCTAssertFalse(output.contains(#""email.send_now""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPSearchMatchesTheCanonicalPlainpostServiceResponse()
        async throws
    {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }
        let request = MailSearchRequest(
            query: "project",
            scope: MailSearchSelectionScope(
                accountIDs: [fixture.primaryAccount.id, fixture.secondaryAccount.id],
                mailboxIDs: [fixture.primaryMailbox.id, fixture.secondaryMailbox.id]
            ),
            mode: .messages,
            limit: 2
        )
        let directStore = try SQLiteMailStore(
            path: fixture.directory
                .appendingPathComponent("Plainpost.sqlite").path
        )
        try directStore.migrate()
        let direct = try await SQLiteMailSearchService(
            store: directStore
        ).search(request)
        let mcpArguments: [String: Any] = [
            "query": request.query,
            "account_ids": request.scope.accountIDs.map(\.rawValue),
            "mailbox_ids": request.scope.mailboxIDs.map(\.rawValue),
            "mode": request.mode.rawValue,
            "limit": request.limit,
        ]
        let mcpCall = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": [
                "name": "email.search",
                "arguments": mcpArguments,
            ],
        ], options: [.sortedKeys])
        let mcpOutput = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", fixture.directory.appendingPathComponent("Plainpost.sqlite").path],
            stdin: String(decoding: mcpCall, as: UTF8.self) + "\n"
        )
        let mcpEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mcpOutput.utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(mcpEnvelope["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let canonicalData = try JSONSerialization.data(withJSONObject: structuredContent)
        let mcpResponse = try MailSearchJSON.decoder().decode(
            MailSearchResponse.self,
            from: canonicalData
        )

        XCTAssertEqual(mcpResponse, direct)
        XCTAssertFalse(mcpOutput.contains("msg_alice_1"), mcpOutput)
    }

    func testMCPSearchMapsTypedErrorsWithoutLeakingQueryText() throws {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }
        let privateQuery = #""private\q""#
        let mcpCall = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 43,
            "method": "tools/call",
            "params": [
                "name": "email.search",
                "arguments": ["query": privateQuery],
            ],
        ], options: [.sortedKeys])
        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", fixture.directory.appendingPathComponent("Plainpost.sqlite").path],
            stdin: String(decoding: mcpCall, as: UTF8.self) + "\n"
        )

        XCTAssertTrue(output.contains(#""code":-32602"#), output)
        XCTAssertTrue(output.contains("Mail search query is invalid."), output)
        XCTAssertFalse(output.contains(privateQuery), output)
    }

    func testMCPSearchAllowsOmittedQueryOnlyWithStructuralScope() throws {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }

        func call(arguments: [String: Any], id: Int) throws -> String {
            let request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": [
                    "name": "email.search",
                    "arguments": arguments,
                ],
            ], options: [.sortedKeys])
            return try PlainpostCLIProcess.run(
                ["mcp", "serve", "--db-path", fixture.directory.appendingPathComponent("Plainpost.sqlite").path],
                stdin: String(decoding: request, as: UTF8.self) + "\n"
            )
        }

        let scopedOutput = try call(
            arguments: ["account_ids": [fixture.primaryAccount.id.rawValue]],
            id: 46
        )
        XCTAssertTrue(scopedOutput.contains(#""canonicalQuery":"*""#), scopedOutput)
        XCTAssertFalse(scopedOutput.contains(#""code":-32602"#), scopedOutput)

        let unscopedOutput = try call(arguments: [:], id: 47)
        XCTAssertTrue(unscopedOutput.contains(#""code":-32602"#), unscopedOutput)
        XCTAssertTrue(unscopedOutput.contains("Invalid email.search arguments."), unscopedOutput)
    }

    func testMCPSearchRejectsBooleanLimitAsInvalidArguments() throws {
        let fixture = try CLIMailSearchFixture()
        defer { fixture.removeArtifacts() }
        let mcpCall = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 44,
            "method": "tools/call",
            "params": [
                "name": "email.search",
                "arguments": ["query": "project", "limit": true],
            ],
        ], options: [.sortedKeys])
        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", fixture.directory.appendingPathComponent("Plainpost.sqlite").path],
            stdin: String(decoding: mcpCall, as: UTF8.self) + "\n"
        )

        XCTAssertTrue(output.contains(#""code":-32602"#), output)
        XCTAssertTrue(output.contains("Invalid email.search arguments."), output)
    }

    func testMCPSearchRuntimeRejectsCanonicalScopeBoundsBeforeServiceDispatch() throws {
        let missingDatabase = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-mcp-search-\(UUID().uuidString).sqlite")
        let accountIDs = (0 ... MailSearchScopeContract.maximumAccountCount).map {
            "account-\($0)"
        }
        let mcpCall = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 45,
            "method": "tools/call",
            "params": [
                "name": "email.search",
                "arguments": ["query": "project", "account_ids": accountIDs],
            ],
        ], options: [.sortedKeys])

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", missingDatabase.path],
            stdin: String(decoding: mcpCall, as: UTF8.self) + "\n"
        )

        XCTAssertTrue(output.contains(#""code":-32602"#), output)
        XCTAssertTrue(output.contains("Invalid email.search arguments."), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDatabase.path))
    }

    func testMCPDoesNotExposeOrExecuteFormerAIToolsOrResources() throws {
        let list = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        )
        XCTAssertFalse(list.contains("email.ai."))

        let toolCall = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.ai.summarize_thread","arguments":{"thread_id":"thr_alice_1"}}}"# + "\n"
        )
        XCTAssertTrue(toolCall.contains(#""code":-32601"#))
        XCTAssertTrue(toolCall.contains("Unknown MCP tool."))

        let resources = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"# + "\n"
        )
        XCTAssertFalse(resources.contains("email://ai-summary/"))

        let resourceRead = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"email://ai-summary/thr_alice_1"}}"# + "\n"
        )
        XCTAssertTrue(resourceRead.contains(#""code":-32002"#))
    }

    func testMCPToolsListSerializesSafetyAnnotationsForSpecificTools() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        let output = try PlainpostCLIProcess.run(["mcp", "serve"], stdin: request + "\n")
        let line = try XCTUnwrap(output.split(whereSeparator: \.isNewline).first)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        func tool(named name: String) throws -> [String: Any] {
            try XCTUnwrap(tools.first { $0["name"] as? String == name })
        }

        func annotations(for name: String) throws -> [String: Any] {
            let descriptor = try tool(named: name)
            return try XCTUnwrap(descriptor["annotations"] as? [String: Any])
        }

        let search = try tool(named: "email.search")
        let searchAnnotations = try XCTUnwrap(search["annotations"] as? [String: Any])
        let searchSchema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
        let searchProperties = try XCTUnwrap(searchSchema["properties"] as? [String: Any])
        XCTAssertEqual(searchAnnotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(searchAnnotations["destructiveHint"] as? Bool, false)
        XCTAssertNil(searchSchema["required"])
        XCTAssertEqual((searchSchema["anyOf"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(
            (searchProperties["mode"] as? [String: Any])?["enum"] as? [String],
            ["conversations", "messages"]
        )
        XCTAssertEqual(
            (searchProperties["mode"] as? [String: Any])?["default"] as? String,
            "conversations"
        )
        XCTAssertEqual((searchProperties["account_ids"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((searchProperties["mailbox_ids"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((searchProperties["limit"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((searchProperties["limit"] as? [String: Any])?["maximum"] as? Int, 100)
        XCTAssertEqual((searchProperties["cursor"] as? [String: Any])?["type"] as? String, "string")
        let searchDescription = try XCTUnwrap(search["description"] as? String)
        for field in MailSearchFieldRegistry.all {
            XCTAssertTrue(searchDescription.contains("\(field.name):"), field.name)
            for example in field.examples {
                XCTAssertTrue(searchDescription.contains(example), example)
            }
        }
        XCTAssertTrue(searchDescription.contains("people, subject, date, state, or mailbox"))
        XCTAssertTrue(searchDescription.contains("next_cursor"))

        let markSeen = try annotations(for: "email.mark_seen")
        XCTAssertEqual(markSeen["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(markSeen["destructiveHint"] as? Bool, true)

        let delete = try annotations(for: "email.delete")
        XCTAssertEqual(delete["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(delete["destructiveHint"] as? Bool, true)
    }

    func testMCPSendStatusAndCancelUseStoredRequestState() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.request_send","arguments":{"draft_id":"drf_reply_1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_reply_1"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.cancel_send_request","arguments":{"request_id":"srq_drf_reply_1"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_missing"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.cancel_send_request","arguments":{"request_id":"srq_missing"}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(["mcp", "serve"], stdin: requests + "\n")

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""request_id":"srq_drf_reply_1""#))
        XCTAssertTrue(output.contains(#""id":2"#))
        XCTAssertTrue(output.contains(#""status":"pending""#))
        XCTAssertTrue(output.contains(#""id":3"#))
        XCTAssertTrue(output.contains(#""status":"cancelled""#))
        XCTAssertTrue(output.contains(#""id":4"#))
        XCTAssertTrue(output.contains(#""id":5"#))
        XCTAssertTrue(output.contains("Send request not found."))
        XCTAssertFalse(output.contains(#""request_id":"srq_missing""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPStdioSendQueuePersistsAcrossSQLiteSessions() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let firstSession = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.create_draft","arguments":{"to":"alice@example.com","subject":"Durable MCP draft","body":"Persist this draft"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.request_send","arguments":{"draft_id":"drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let firstOutput = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", dbURL.path],
            stdin: firstSession + "\n"
        )

        XCTAssertTrue(firstOutput.contains(#""id":1"#))
        XCTAssertTrue(firstOutput.contains(#""draft_id":"drf_mcp_1""#))
        XCTAssertTrue(firstOutput.contains(#""id":2"#))
        XCTAssertTrue(firstOutput.contains(#""request_id":"srq_drf_mcp_1""#))
        XCTAssertTrue(firstOutput.contains(#""id":3"#))
        XCTAssertTrue(firstOutput.contains(#""status":"pending""#))

        let secondSession = [
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.cancel_send_request","arguments":{"request_id":"srq_drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let secondOutput = try PlainpostCLIProcess.run(
            ["mcp", "serve", "--db-path", dbURL.path],
            stdin: secondSession + "\n"
        )

        XCTAssertTrue(secondOutput.contains(#""id":4"#))
        XCTAssertTrue(secondOutput.contains(#""status":"pending""#))
        XCTAssertTrue(secondOutput.contains(#""id":5"#))
        XCTAssertTrue(secondOutput.contains(#""status":"cancelled""#))
        XCTAssertTrue(secondOutput.contains(#""id":6"#))
        XCTAssertTrue(secondOutput.contains(#""status":"cancelled""#))
        XCTAssertFalse(firstOutput.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(firstOutput.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(secondOutput.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(secondOutput.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPStdioSendQueueUsesDefaultDataDirectoryAcrossSessions() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mcp-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let environment = ["PLAINPOST_DATA_DIR": dataDir.path]

        let firstSession = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.create_draft","arguments":{"to":"alice@example.com","subject":"Default MCP draft","body":"Persist through default store"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.request_send","arguments":{"draft_id":"drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let firstOutput = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: firstSession + "\n",
            environment: environment
        )

        XCTAssertTrue(firstOutput.contains(#""draft_id":"drf_mcp_1""#))
        XCTAssertTrue(firstOutput.contains(#""request_id":"srq_drf_mcp_1""#))
        XCTAssertTrue(firstOutput.contains(#""status":"pending""#))

        let secondSession = [
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.cancel_send_request","arguments":{"request_id":"srq_drf_mcp_1"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"email.send_status","arguments":{"request_id":"srq_drf_mcp_1"}}}"#
        ].joined(separator: "\n")

        let secondOutput = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: secondSession + "\n",
            environment: environment
        )

        XCTAssertTrue(secondOutput.contains(#""id":4"#))
        XCTAssertTrue(secondOutput.contains(#""status":"pending""#))
        XCTAssertTrue(secondOutput.contains(#""id":5"#))
        XCTAssertTrue(secondOutput.contains(#""status":"cancelled""#))
        XCTAssertTrue(secondOutput.contains(#""id":6"#))
        XCTAssertTrue(secondOutput.contains(#""status":"cancelled""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("Plainpost.sqlite").path))
        XCTAssertFalse(firstOutput.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(firstOutput.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(secondOutput.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(secondOutput.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPStdioListsAndReadsSafeResources() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"email://message/msg_alice_1"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"email://thread/thr_alice_1"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"email://draft/drf_reply_1"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"email://send-request/srq_drf_reply_1"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"email://smart-inbox"}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(["mcp", "serve"], stdin: requests + "\n")

        XCTAssertTrue(output.contains(#""uri":"email://message/msg_alice_1""#))
        XCTAssertTrue(output.contains(#""uri":"email://thread/thr_alice_1""#))
        XCTAssertTrue(output.contains(#""uri":"email://draft/drf_reply_1""#))
        XCTAssertTrue(output.contains(#""uri":"email://send-request/srq_drf_reply_1""#))
        XCTAssertTrue(output.contains(#""uri":"email://smart-inbox""#))
        XCTAssertTrue(output.contains(#""subject":"Availability""#))
        XCTAssertTrue(output.contains(#""body":"Can you meet next Tuesday?""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPBodyReadsHonorRestrictedAgentPermission() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.read","arguments":{"message_id":"msg_alice_1","include":"body"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"email://message/msg_alice_1"}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: requests + "\n",
            environment: ["PLAINPOST_AGENT_READ_BODY": "false"]
        )

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""id":2"#))
        XCTAssertTrue(output.contains(#""error""#))
        XCTAssertTrue(output.contains("Actor is not allowed to read message bodies."))
        XCTAssertFalse(output.contains("Can you meet next Tuesday?"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPAttachmentReadsHonorRestrictedAgentPermission() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.read","arguments":{"message_id":"msg_alice_1","include":"attachments"}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: requests + "\n",
            environment: ["PLAINPOST_AGENT_READ_ATTACHMENTS": "false"]
        )

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""error""#))
        XCTAssertTrue(output.contains("Actor is not allowed to read attachments."))
        XCTAssertFalse(output.contains(#""attachments""#))
        XCTAssertFalse(output.contains("Can you meet next Tuesday?"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPMutationToolsHonorRestrictedAgentPermissions() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.create_draft","arguments":{"to":"alice@example.com","subject":"Blocked draft","body":"Draft body"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.request_send","arguments":{"draft_id":"drf_reply_1"}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: requests + "\n",
            environment: [
                "PLAINPOST_AGENT_CREATE_DRAFTS": "false",
                "PLAINPOST_AGENT_REQUEST_SEND": "false"
            ]
        )

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""id":2"#))
        XCTAssertTrue(output.contains(#""error""#))
        XCTAssertTrue(output.contains("Actor is not allowed to create drafts."))
        XCTAssertTrue(output.contains("Actor is not allowed to request sends."))
        XCTAssertFalse(output.contains(#""draft_id":"drf_mcp_1""#))
        XCTAssertFalse(output.contains(#""request_id":"srq_drf_reply_1""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMCPMessageMutationToolsHonorRestrictedAgentPermissions() throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.add_label","arguments":{"message_id":"msg_alice_1","label":"Needs Reply"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.recategorize","arguments":{"message_id":"msg_alice_1","category":"support"}}}"#
        ].joined(separator: "\n")

        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            stdin: requests + "\n",
            environment: [
                "PLAINPOST_AGENT_ADD_LABELS": "false",
                "PLAINPOST_AGENT_RECATEGORIZE": "false",
                "PLAINPOST_AGENT_MARK_SEEN": "false"
            ]
        )

        XCTAssertTrue(output.contains(#""id":1"#))
        XCTAssertTrue(output.contains(#""id":2"#))
        XCTAssertTrue(output.contains(#""error""#))
        XCTAssertTrue(output.contains("Actor is not allowed to modify labels."))
        XCTAssertTrue(output.contains("Actor is not allowed to recategorize messages."))
        XCTAssertFalse(output.contains(#""labels":["Needs Reply"]"#))
        XCTAssertFalse(output.contains(#""category":"support""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    private func cliData(_ output: String) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(output.utf8)
            ) as? [String: Any]
        )
        return try XCTUnwrap(envelope["data"] as? [String: Any])
    }

    private func parseServiceStdioOutput(_ output: String) throws -> [[String: Any]] {
        try output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try XCTUnwrap(object as? [String: Any])
            }
    }

    private func serviceResponse(in envelope: [String: Any]) -> [String: Any]? {
        envelope["response"] as? [String: Any]
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }
}

private struct ServiceProfileFixture {
    var teamIdentifier = "9XN7WN8JN2"
    var applicationIdentifier = "9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"
    var keychainAccessGroups = ["9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"]
    var expirationDate = Date(timeIntervalSince1970: 4_102_444_800)
    var developerCertificates = [Data("abc".utf8)]
}

private struct SignedPackagingFixture {
    let environment: [String: String]
    let codesignLogURL: URL
    let appProfileURL: URL
    let profileURL: URL
}

private struct RuntimeStopLaunchctlFixture {
    let commandURL: URL
    let stateURL: URL
    let logURL: URL
}

private final class PackagingScriptFixture {
    static let signingIdentitySHA1 = "1111111111111111111111111111111111111111"
    static let signingCertificateSHA256 =
        "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
    static let signingIdentityLabel =
        "Apple Development: Plainpost Packaging Fixture (9XN7WN8JN2)"
    static let packageTestMarker = "Plainpost package fixture v1\n"

    let rootURL: URL
    private let repositoryRootURL: URL
    var bundleURL: URL {
        rootURL.appendingPathComponent(
            ".build/PlainpostFixture.app",
            isDirectory: true
        )
    }

    init() throws {
        repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-packaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Self.packageTestMarker.write(
            to: rootURL.appendingPathComponent(".plainpost-package-test-fixture"),
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func repositoryScriptExists(named name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: repositoryRootURL.appendingPathComponent("Scripts/\(name)").path
        )
    }

    func copyRepositoryScript(named name: String) throws {
        try copyRepositoryFile(named: "Scripts/\(name)")
        let fixtureContract =
            "Scripts/lib/plainpost-package-fixture-contract.sh"
        let fixtureContractDestination = rootURL.appendingPathComponent(
            fixtureContract
        )
        if !FileManager.default.fileExists(
            atPath: fixtureContractDestination.path
        ) {
            try copyRepositoryFile(named: fixtureContract)
        }
    }

    func copyRepositoryFile(named name: String) throws {
        let destination = rootURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repositoryRootURL.appendingPathComponent(name), to: destination)
    }

    @discardableResult
    func createFile(relativePath: String, data: Data) throws -> URL {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    func createFile(relativePath: String, contents: String) throws -> URL {
        try createFile(relativePath: relativePath, data: Data(contents.utf8))
    }

    func createServiceSupportFiles() throws {
        try copyRepositoryFile(named: "Support/PlainpostService/Info.plist")
        try copyRepositoryFile(
            named: "Support/PlainpostService/PlainpostService.entitlements"
        )
    }

    @discardableResult
    func createDecodedServiceProfile(
        _ profile: ServiceProfileFixture = ServiceProfileFixture()
    ) throws -> URL {
        try createPropertyList(
            relativePath: "PlainpostService.provisionprofile",
            object: [
                "Name": "Plainpost service fixture",
                "TeamIdentifier": [profile.teamIdentifier],
                "ExpirationDate": profile.expirationDate,
                "DeveloperCertificates": profile.developerCertificates,
                "Entitlements": [
                    "com.apple.application-identifier":
                        profile.applicationIdentifier,
                    "keychain-access-groups": profile.keychainAccessGroups,
                ],
            ]
        )
    }

    @discardableResult
    func createDecodedAppProfile() throws -> URL {
        try createPropertyList(
            relativePath: "PlainpostApp.provisionprofile",
            object: [
                "Name": "Plainpost app fixture",
                "TeamIdentifier": ["9XN7WN8JN2"],
                "ExpirationDate": Date(timeIntervalSince1970: 4_102_444_800),
                "DeveloperCertificates": [Data("abc".utf8)],
                "Entitlements": [
                    "com.apple.application-identifier":
                        "9XN7WN8JN2.com.marynavdovenko.Plainpost",
                    "com.apple.developer.applesignin": ["Default"],
                    "keychain-access-groups": [
                        "9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
                    ],
                ],
            ]
        )
    }

    @discardableResult
    func createProfileDecoder() throws -> URL {
        try createExecutable(
            relativePath: "fake-profile-decoder-\(UUID().uuidString).sh",
            contents: "#!/bin/sh\n/bin/cat \"$1\"\n"
        )
    }

    func prepareSignedPackaging(
        profile: ServiceProfileFixture = ServiceProfileFixture()
    ) throws -> SignedPackagingFixture {
        try copyRepositoryScript(named: "package-app-bundle.sh")
        try copyRepositoryScript(named: "select-codesign-identity.sh")
        try copyRepositoryFile(
            named: "Support/PlainpostApp/PlainpostApp.entitlements"
        )
        try copyRepositoryFile(named: "Support/PlainpostBackgroundAgent/Info.plist")
        try createServiceSupportFiles()
        try createExecutable(
            relativePath: ".build/debug/PlainpostBackgroundAgent",
            contents: "background-agent sentinel"
        )
        try createExecutable(
            relativePath: ".build/debug/PlainpostBrowserBridge",
            contents: "browser-bridge sentinel"
        )
        try createExecutable(
            relativePath: ".build/debug/PlainpostService",
            contents: "service sentinel"
        )
        try createExecutable(
            relativePath: ".build/debug/plainpost",
            contents: "cli sentinel"
        )
        try createNativeAppFixture()
        try createExecutable(
            relativePath: "Scripts/stop-packaged-runtime.sh",
            contents: "#!/bin/sh\nexit 0\n"
        )
        let fakeXcodebuild = try createExecutable(
            relativePath: "fake-xcodebuild.sh",
            contents: "#!/bin/sh\nexit 0\n"
        )
        let codesignLogURL = rootURL.appendingPathComponent("codesign.txt")
        let fakeCodesign = try createExecutable(
            relativePath: "fake-codesign.sh",
            contents: "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(codesignLogURL.path)\"\n"
        )
        let profileDecoder = try createProfileDecoder()
        let appProfileURL = try createDecodedAppProfile()
        let profileURL = try createDecodedServiceProfile(profile)
        return SignedPackagingFixture(
            environment: [
                "PLAINPOST_CODESIGN_IDENTITY": Self.signingIdentitySHA1,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS":
                    "\(Self.signingIdentitySHA1)|"
                    + "\(Self.signingCertificateSHA256)|"
                    + "9XN7WN8JN2|Apple Development: Plainpost Packaging Fixture|"
                    + Self.signingIdentityLabel,
                "PLAINPOST_APP_PROVISIONING_PROFILE": appProfileURL.path,
                "PLAINPOST_SERVICE_PROVISIONING_PROFILE": profileURL.path,
                "PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND":
                    profileDecoder.path,
                "PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND": fakeXcodebuild.path,
                "PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND": fakeCodesign.path,
            ],
            codesignLogURL: codesignLogURL,
            appProfileURL: appProfileURL,
            profileURL: profileURL
        )
    }

    @discardableResult
    func createPropertyList(
        relativePath: String,
        object: Any
    ) throws -> URL {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        return try createFile(relativePath: relativePath, data: data)
    }

    func createNativeAppFixture() throws {
        try copyRepositoryFile(named: "Support/PlainpostApp/Info.plist")
        let info = try Data(
            contentsOf: rootURL.appendingPathComponent(
                "Support/PlainpostApp/Info.plist"
            )
        )
        try createFile(
            relativePath:
                ".build/xcode-derived/Build/Products/Debug/"
                + "Plainpost.app/Contents/Info.plist",
            data: info
        )
        try createExecutable(
            relativePath:
                ".build/xcode-derived/Build/Products/Debug/"
                + "Plainpost.app/Contents/MacOS/Plainpost",
            contents: "native-app sentinel"
        )
    }

    func propertyList(relativePath: String) throws -> [String: Any] {
        let data = try Data(
            contentsOf: rootURL.appendingPathComponent(relativePath)
        )
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }

    @discardableResult
    func createExecutable(
        relativePath: String,
        contents: String = ""
    ) throws -> URL {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
        return url
    }

    @discardableResult
    func copyExecutable(at sourceURL: URL, relativePath: String) throws -> URL {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
        return url
    }

    @discardableResult
    func createSleepingExecutable(relativePath: String) throws -> URL {
        try createCExecutable(
            relativePath: relativePath,
            source: """
            #include <unistd.h>
            int main(void) { sleep(60); return 0; }
            """
        )
    }

    @discardableResult
    func createTermReportingExecutable(
        relativePath: String,
        readyURL: URL,
        terminatedURL: URL
    ) throws -> URL {
        try createCExecutable(
            relativePath: relativePath,
            source: """
            #include <fcntl.h>
            #include <signal.h>
            #include <unistd.h>

            static void report_termination(int signal_number) {
                (void) signal_number;
                int descriptor = open(
                    "\(terminatedURL.path)",
                    O_WRONLY | O_CREAT | O_TRUNC,
                    0600
                );
                if (descriptor >= 0) {
                    (void) write(descriptor, "terminated", 10);
                    (void) close(descriptor);
                }
                _exit(0);
            }

            int main(void) {
                signal(SIGTERM, report_termination);
                int descriptor = open(
                    "\(readyURL.path)",
                    O_WRONLY | O_CREAT | O_TRUNC,
                    0600
                );
                if (descriptor < 0) {
                    return 2;
                }
                (void) write(descriptor, "ready", 5);
                (void) close(descriptor);
                for (;;) {
                    pause();
                }
            }
            """
        )
    }

    @discardableResult
    func createIgnoringTermExecutable(relativePath: String) throws -> URL {
        try createCExecutable(
            relativePath: relativePath,
            source: """
            #include <signal.h>
            #include <unistd.h>
            int main(void) {
                signal(SIGTERM, SIG_IGN);
                for (;;) { pause(); }
            }
            """
        )
    }

    func createLaunchctlFixture(
        bundleURL: URL,
        label: String,
        initiallyLoaded: Bool,
        bootoutSucceeds: Bool = true,
        jobMatchesRuntime: Bool = true,
        programOverride: String? = nil,
        machServiceOverride: String? = nil,
        machServiceEnabled: Bool = true,
        targetOverride: String? = nil,
        additionalJobDescription: String = "",
        usesEndpointDescription: Bool = false
    ) throws -> RuntimeStopLaunchctlFixture {
        let stateURL = try createFile(
            relativePath: "launchctl-state-\(UUID().uuidString)",
            contents: initiallyLoaded ? "loaded" : "unloaded"
        )
        let logURL = rootURL.appendingPathComponent(
            "launchctl-log-\(UUID().uuidString)"
        )
        let expectedServicePath = bundleURL.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app/"
                + "Contents/MacOS/PlainpostService"
        ).path
        let defaultServicePath = jobMatchesRuntime
            ? expectedServicePath
            : bundleURL.appendingPathComponent(
                "Contents/MacOS/UnrelatedService"
            ).path
        let describedServicePath = programOverride ?? defaultServicePath
        let defaultMachService = jobMatchesRuntime
            ? "com.marynavdovenko.Plainpost.Service"
            : "com.olhapi.Unrelated.Service"
        let describedMachService =
            machServiceOverride ?? defaultMachService
        let serviceDescription: String
        if usesEndpointDescription {
            serviceDescription =
                "    endpoints = {\n"
                + "        \"\(describedMachService)\" = {\n"
                + "            port = 0x123\n"
                + "            active = 1\n"
                + "            managed = "
                + "\(machServiceEnabled ? "1" : "0")\n"
                + "        }\n"
                + "    }\n"
        } else {
            serviceDescription =
                "    mach services = {\n"
                + "        \"\(describedMachService)\" => "
                + "\(machServiceEnabled ? "true" : "false")\n"
                + "    }\n"
        }
        let descriptionURL = try createFile(
            relativePath: "launchctl-description-\(UUID().uuidString)",
            contents:
                "    program = \(describedServicePath)\n"
                + "    arguments = {\n"
                + "        \(describedServicePath)\n"
                + "    }\n"
                + serviceDescription
                + additionalJobDescription
                + "}\n"
        )
        let headerCommand: String
        if let targetOverride {
            headerCommand =
                "    /usr/bin/printf '%s\\n' "
                + "\"\(targetOverride) = {\"\n"
        } else {
            headerCommand =
                "    /usr/bin/printf '%s = {\\n' \"$2\"\n"
        }
        let bootoutStatus = bootoutSucceeds ? 0 : 71
        let commandURL = try createExecutable(
            relativePath: "fake-launchctl-\(UUID().uuidString).sh",
            contents:
                "#!/bin/bash\n"
                + "/usr/bin/printf '%s\\n' \"$*\" >> \"\(logURL.path)\"\n"
                + "state=\"$(/bin/cat \"\(stateURL.path)\")\"\n"
                + "case \"$1\" in\n"
                + "  print)\n"
                + "    [[ \"$state\" == \"loaded\" ]] || exit 113\n"
                + headerCommand
                + "    /bin/cat \"\(descriptionURL.path)\"\n"
                + "    ;;\n"
                + "  bootout)\n"
                + "    [[ \"$2\" == gui/*/\(label) ]] || exit 72\n"
                + "    [[ \(bootoutStatus) -eq 0 ]] || exit \(bootoutStatus)\n"
                + "    /usr/bin/printf 'unloaded' > \"\(stateURL.path)\"\n"
                + "    ;;\n"
                + "  *) exit 73 ;;\n"
                + "esac\n"
        )
        return RuntimeStopLaunchctlFixture(
            commandURL: commandURL,
            stateURL: stateURL,
            logURL: logURL
        )
    }

    private func createCExecutable(
        relativePath: String,
        source: String
    ) throws -> URL {
        let executableURL = rootURL.appendingPathComponent(relativePath)
        let sourceURL = try createFile(
            relativePath: "process-fixture-\(UUID().uuidString).c",
            contents: source
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [sourceURL.path, "-o", executableURL.path]
        let output = Pipe()
        compiler.standardOutput = output
        compiler.standardError = output
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let detail = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "PlainpostPackagingFixture",
                code: Int(compiler.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        return executableURL
    }

    func runScript(
        named name: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        includeStructuralTestMode: Bool = true
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [rootURL.appendingPathComponent("Scripts/\(name)").path] + arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.removeValue(forKey: "PLAINPOST_PACKAGE_TEST_MODE")
        processEnvironment.removeValue(forKey: "PLAINPOST_PACKAGE_TEST_ROOT")
        processEnvironment.removeValue(
            forKey: "PLAINPOST_RUNTIME_STOP_TEST_MODE"
        )
        processEnvironment.removeValue(
            forKey: "PLAINPOST_RUNTIME_STOP_TEST_ROOT"
        )
        if includeStructuralTestMode,
           name == "package-app-bundle.sh"
            || name == "select-codesign-identity.sh"
            || name == "stop-packaged-runtime.sh" {
            processEnvironment["PLAINPOST_RUNTIME_STOP_TEST_MODE"] = "1"
            processEnvironment["PLAINPOST_RUNTIME_STOP_TEST_ROOT"] =
                rootURL.path
        }
        if includeStructuralTestMode,
           name == "package-app-bundle.sh"
            || name == "select-codesign-identity.sh" {
            processEnvironment["PLAINPOST_PACKAGE_TEST_MODE"] = "1"
            processEnvironment["PLAINPOST_PACKAGE_TEST_ROOT"] = rootURL.path
            if name == "package-app-bundle.sh" {
                processEnvironment["PLAINPOST_APP_BUNDLE_OUTPUT"] = bundleURL.path
            }
        }
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private struct CLIMailSearchSuccess: Decodable {
    let ok: Bool
    let data: MailSearchResponse
}

private func seedUnrelatedCachedSyncMessage(
    databaseURL: URL
) throws {
    let store = try SQLiteMailStore(path: databaseURL.path)
    try store.migrate()
    let account = Account(
        id: AccountID("acc_unrelated_example_com"),
        displayName: "Unrelated",
        email: EmailAddress("unrelated@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )
    let thread = MailThread(
        id: ThreadID("thr_unrelated_sync"),
        accountID: account.id,
        subjectNormalized: "unrelated sync",
        participantEmails: [
            EmailAddress("sender@example.com"),
            account.email,
        ]
    )
    let message = MessageSummary(
        id: MessageID("msg_unrelated_sync"),
        threadID: thread.id,
        from: EmailAddress("sender@example.com"),
        subject: "Unrelated sync message",
        preview: "Must not appear in another account's sync envelope.",
        smartCategory: .personal
    )
    try store.cacheAccounts([account])
    try store.cacheMailboxes([
        Mailbox(
            id: MailboxID("mbx_unrelated_sync"),
            accountID: account.id,
            name: "INBOX",
            path: "INBOX",
            specialUse: "\\Inbox"
        )
    ])
    try store.cacheThread(thread)
    _ = try store.commitIncomingMessage(
        message,
        metadata: IncomingMessageSearchMetadata(
            to: [account.email],
            cc: [],
            bcc: [],
            attachments: [],
            messageIdentifiers: []
        ),
        accountID: account.id,
        mailboxPath: "INBOX",
        uidValidity: 1,
        uid: 1,
        notificationEligible: false
    )
}

private final class CLIMailSearchFixture {
    let directory: URL
    let primaryAccount = Account(
        id: AccountID("acc_cli_primary"),
        displayName: "Primary",
        email: EmailAddress("primary@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )
    let secondaryAccount = Account(
        id: AccountID("acc_cli_secondary"),
        displayName: "Secondary",
        email: EmailAddress("secondary@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )
    let primaryMailbox = Mailbox(
        id: MailboxID("mbx_cli_primary"),
        accountID: AccountID("acc_cli_primary"),
        name: "Inbox",
        path: "INBOX",
        specialUse: "\\Inbox"
    )
    let secondaryMailbox = Mailbox(
        id: MailboxID("mbx_cli_secondary"),
        accountID: AccountID("acc_cli_secondary"),
        name: "Inbox",
        path: "INBOX",
        specialUse: "\\Inbox"
    )

    var environment: [String: String] {
        ["PLAINPOST_DATA_DIR": directory.path]
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("Plainpost.sqlite").path)
        try store.migrate()
        try store.cacheAccounts([primaryAccount, secondaryAccount])
        try store.cacheMailboxes([primaryMailbox, secondaryMailbox])

        let primaryThread = MailThread(
            id: ThreadID("thr_cli_primary"),
            accountID: primaryAccount.id,
            subjectNormalized: "project alpha",
            participantEmails: [EmailAddress("alice@example.com"), primaryAccount.email]
        )
        let secondaryThread = MailThread(
            id: ThreadID("thr_cli_secondary"),
            accountID: secondaryAccount.id,
            subjectNormalized: "project beta",
            participantEmails: [EmailAddress("bob@example.com"), secondaryAccount.email]
        )
        try store.cacheThreads([primaryThread, secondaryThread])
        try insert(
            MessageSummary(
                id: MessageID("msg_cli_primary"),
                threadID: primaryThread.id,
                from: EmailAddress("alice@example.com"),
                fromDisplayName: "Alice",
                subject: "Project Alpha",
                preview: "Primary project result",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            account: primaryAccount,
            store: store,
            uid: 1
        )
        try insert(
            MessageSummary(
                id: MessageID("msg_cli_secondary"),
                threadID: secondaryThread.id,
                from: EmailAddress("bob@example.com"),
                fromDisplayName: "Bob",
                subject: "Project Beta",
                preview: "Secondary project result",
                smartCategory: .notification,
                sentAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            account: secondaryAccount,
            store: store,
            uid: 1
        )
    }

    func removeArtifacts() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(
        _ message: MessageSummary,
        account: Account,
        store: SQLiteMailStore,
        uid: Int
    ) throws {
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [account.email],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: uid,
            notificationEligible: false
        )
    }
}

private actor CLIHarnessVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x5A, count: 32)

    func createIfMissing() async throws {}

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        key
    }

    func countMatchingItems() async throws -> Int {
        1
    }
}

private actor CLIHarnessTypedServiceClient:
    PlainpostServiceClientProtocol
{
    private let assembly: SQLiteCredentialVaultAssembly
    private let operations: PlainpostServiceOperations

    static func make(databaseURL: URL) async throws
        -> CLIHarnessTypedServiceClient
    {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let assembly = SQLiteCredentialVaultAssembly(
            store: store,
            provider: CLIHarnessVaultKeyProvider()
        )
        try await assembly.unlockForeground(
            prompt: "Plainpost integration harness"
        )
        let operations = PlainpostServiceOperations(
            applicationSupportURL: databaseURL.deletingLastPathComponent(),
            store: store,
            assembly: assembly
        )
        await operations.reopenRuntimeConstruction()
        return CLIHarnessTypedServiceClient(
            assembly: assembly,
            operations: operations
        )
    }

    private init(
        assembly: SQLiteCredentialVaultAssembly,
        operations: PlainpostServiceOperations
    ) {
        self.assembly = assembly
        self.operations = operations
    }

    func status() async throws -> PlainpostVaultStatus {
        PlainpostVaultStatus(
            availability: await assembly.session.state == .unlocked
                ? .unlocked
                : .locked,
            matchingKeyItemCount: 1
        )
    }

    func unlock(reason: String) async throws {
        try await assembly.unlockForeground(prompt: reason)
        await operations.reopenRuntimeConstruction()
    }

    func lock() async throws {
        await operations.beginVaultLockdown()
        await assembly.session.lock()
        await operations.confirmVaultLocked()
    }

    func processBackgroundJobs() async throws
        -> PlainpostBackgroundJobResult
    {
        try await operations.processBackgroundJobs()
    }

    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        try await operations.performSmartInboxBatch(request)
    }

    func sendBrowserApprovedReply(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult {
        try await operations.sendBrowserApprovedReply(jobID: jobID)
    }

    func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult {
        try await operations.syncDraftToServer(
            draftID: draftID,
            mailbox: mailbox
        )
    }

    func perform(
        _ operation: PlainpostForegroundOperation
    ) async throws -> PlainpostForegroundOperationResult {
        try await operations.perform(operation)
    }
}

private final class CLIHarnessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func write(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    var combined: String {
        lock.withLock {
            values.joined(separator: "\n")
        }
    }
}

private final class CLIHarnessLineInput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]

    init(_ input: String?) {
        lines = input?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }

    func next() -> String? {
        lock.withLock {
            lines.isEmpty ? nil : lines.removeFirst()
        }
    }
}

private final class CLIHarnessBlockingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<Value, Error>? {
        lock.withLock { result }
    }
}

private func cliHarnessAwait<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = CLIHarnessBlockingResult<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load()!.get()
}

final class CLITestCredentialCapability: @unchecked Sendable {
    private let recordLock = NSLock()
    private var records: [CredentialRecordKey: Data] = [:]
    private let runtimeLock = NSLock()
    private var runtimes: [String: CLIHarnessTypedServiceClient] = [:]
    private let fallbackDatabaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "plainpost-typed-cli-\(UUID().uuidString)",
            isDirectory: true
        )
        .appendingPathComponent("Plainpost.sqlite")

    init() {}

    /// The legacy service string remains in call sites while the migration is
    /// in flight, but it is deliberately not used for capability discovery.
    convenience init(service _: String) {
        self.init()
    }

    func savePassword(_ password: String, account: String) throws {
        try save(Data(password.utf8), account: account)
    }

    func deletePassword(account: String) throws {
        recordLock.lock()
        defer { recordLock.unlock() }
        if let key = semanticKey(forLegacyAccount: account), var value = records.removeValue(forKey: key) {
            value.resetBytes(in: value.indices)
        }
    }

    func credentialAvailability(account: String) -> KeychainCredentialAvailability {
        recordLock.lock()
        defer { recordLock.unlock() }
        guard let key = semanticKey(forLegacyAccount: account), records[key] != nil else { return .missing }
        return .interactionRequired
    }

    func clear() {
        recordLock.lock()
        while let key = records.keys.first, var value = records.removeValue(forKey: key) {
            value.resetBytes(in: value.indices)
        }
        recordLock.unlock()
        try? FileManager.default.removeItem(
            at: fallbackDatabaseURL.deletingLastPathComponent()
        )
    }

    func seedAccountCredentials(email: String, imapPassword: String, smtpPassword: String) throws {
        let accountID = "acc_" + email.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        try save(Data(imapPassword.utf8), account: "\(accountID):imap")
        try save(Data(smtpPassword.utf8), account: "\(accountID):smtp")
    }

    private func save(_ value: Data, account: String) throws {
        guard let key = semanticKey(forLegacyAccount: account) else {
            throw CredentialVaultError.ciphertextInvalid
        }
        recordLock.lock()
        records[key] = value
        recordLock.unlock()
    }

    private func recordAccountAdd(arguments: [String]) throws {
        guard let imapPassword = Self.option("--imap-password", in: arguments),
              let smtpPassword = Self.option("--smtp-password", in: arguments),
              let email = Self.option("--email", in: arguments) else { return }
        let accountID = "acc_" + email.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        try save(Data(imapPassword.utf8), account: "\(accountID):imap")
        try save(Data(smtpPassword.utf8), account: "\(accountID):smtp")
    }

    private func encodedPayload() throws -> Data {
        recordLock.lock()
        let snapshot = records
        recordLock.unlock()
        return try CredentialCapabilityCodec.encode(records: snapshot)
    }

    fileprivate func withPayload<T>(_ operation: (Data) throws -> T) throws -> T {
        var payload = try encodedPayload()
        defer { payload.resetBytes(in: payload.indices) }
        return try operation(payload)
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    fileprivate static func sanitizedArguments(_ arguments: [String]) -> [String] {
        var sanitized: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--imap-password" || argument == "--smtp-password" {
                index += 2
            } else {
                sanitized.append(argument)
                index += 1
            }
        }
        return sanitized
    }

    fileprivate func runCLI(
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String] = [:]
    ) throws -> String {
        try recordAccountAdd(arguments: arguments)
        let client = try typedServiceClient(
            arguments: arguments,
            environment: environment
        )
        let output = CLIHarnessOutput()
        let input = CLIHarnessLineInput(stdin)
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.write,
            stderr: output.write,
            mcpReadLine: input.next
        )
        _ = try cliHarnessAwait {
            try await cli.run(arguments)
        }
        return output.combined
    }

    fileprivate func runService(
        _ arguments: [String],
        executableURL: URL? = nil,
        timeout: TimeInterval = 10
    ) throws -> String {
        try recordAccountAdd(arguments: arguments)
        if executableURL != nil {
            return try PlainpostServiceProcess.run(
                Self.sanitizedArguments(arguments),
                executableURL: executableURL,
                timeout: timeout,
                credentialCapability: self
            )
        }
        return try runCLI(
            Self.cliArguments(forLegacyServiceArguments: arguments)
        )
    }

    fileprivate func perform(
        _ operation: PlainpostForegroundOperation,
        databaseURL: URL
    ) throws -> PlainpostForegroundOperationResult {
        let client = try typedServiceClient(
            arguments: ["--db-path", databaseURL.path],
            environment: [:]
        )
        return try cliHarnessAwait {
            try await client.perform(operation)
        }
    }

    private func typedServiceClient(
        arguments: [String],
        environment: [String: String]
    ) throws -> CLIHarnessTypedServiceClient {
        let databaseURL = Self.databaseURL(
            arguments: arguments,
            environment: environment,
            fallback: fallbackDatabaseURL
        )
        runtimeLock.lock()
        if let existing = runtimes[databaseURL.path] {
            runtimeLock.unlock()
            return existing
        }
        runtimeLock.unlock()

        let created = try cliHarnessAwait {
            try await CLIHarnessTypedServiceClient.make(
                databaseURL: databaseURL
            )
        }
        runtimeLock.lock()
        let resolved = runtimes[databaseURL.path] ?? created
        runtimes[databaseURL.path] = resolved
        runtimeLock.unlock()
        return resolved
    }

    private static func databaseURL(
        arguments: [String],
        environment: [String: String],
        fallback: URL
    ) -> URL {
        if let path = option("--db-path", in: arguments) {
            return URL(fileURLWithPath: path)
        }
        if let path = environment["PLAINPOST_APPLICATION_SUPPORT_DIR"],
           !path.isEmpty
        {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("Plainpost.sqlite")
        }
        if let path = environment["PLAINPOST_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("Plainpost.sqlite")
        }
        return fallback
    }

    private static func cliArguments(
        forLegacyServiceArguments arguments: [String]
    ) -> [String] {
        if arguments.starts(with: ["sync", "inbox"]),
           let account = option("--account", in: arguments)
        {
            return ["account", "sync", account]
                + arguments.dropFirst(2).filter {
                    $0 != "--account" && $0 != account
                }
        }
        if arguments.starts(with: ["send", "status"]),
           let requestID = option("--request", in: arguments)
        {
            return ["send", "status", requestID]
                + removingOption(
                    "--request",
                    from: Array(arguments.dropFirst(2))
                )
        }
        if arguments.starts(with: ["send", "cancel"]),
           let requestID = option("--request", in: arguments)
        {
            return ["send", "cancel", requestID]
                + removingOption(
                    "--request",
                    from: Array(arguments.dropFirst(2))
                )
        }
        return arguments
    }

    private static func removingOption(
        _ name: String,
        from arguments: [String]
    ) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == name,
               arguments.indices.contains(index + 1)
            {
                index += 2
            } else {
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    private func semanticKey(forLegacyAccount account: String) -> CredentialRecordKey? {
        let suffix: String
        if account.hasSuffix(":imap") { suffix = ":imap-password" }
        else if account.hasSuffix(":smtp") { suffix = ":smtp-password" }
        else { return nil }
        return CredentialRecordKey(rawValue: "account:\(account.dropLast(5))\(suffix)")
    }
}

private enum PlainpostCLIProcess {
    static func run(
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String] = [:],
        credentialCapability: CLITestCredentialCapability? = nil,
        executableURL: URL? = nil
    ) throws -> String {
        if let credentialCapability {
            return try credentialCapability.withPayload { payload in
                try runWithCredentialCapability(
                    arguments,
                    stdin: stdin,
                    environment: environment,
                    payload: payload,
                    executable: executableURL
                )
            }
        }
        let executable =
            executableURL ?? productsDirectory.appendingPathComponent("plainpost")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdout = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        if stdin != nil {
            process.standardInput = stdinPipe
        }
        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try stdinPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if timedOut || output.isEmpty || process.terminationStatus != 0 {
            return output
                + "\n<plainpost status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) timedOut=\(timedOut)>"
        }
        return output
    }

    fileprivate static func runWithCredentialCapability(
        _ arguments: [String],
        stdin: String?,
        environment: [String: String],
        payload: Data,
        executable explicitExecutable: URL? = nil,
        additionalInheritedDescriptors: Set<Int32> = []
    ) throws -> String {
        let executable = explicitExecutable ?? productsDirectory.appendingPathComponent("plainpost")
        let stdout = Pipe()
        let stdinPipe = Pipe()
        let capability = Pipe()
        try markCloseOnExec([
            stdout.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stdinPipe.fileHandleForReading.fileDescriptor,
            stdinPipe.fileHandleForWriting.fileDescriptor,
            capability.fileHandleForReading.fileDescriptor,
            capability.fileHandleForWriting.fileDescriptor,
        ])
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EINVAL) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw POSIXError(.EINVAL)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let capabilityFD = InheritedCredentialCapability.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&actions, capability.fileHandleForReading.fileDescriptor, capabilityFD) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, capability.fileHandleForWriting.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, stdout.fileHandleForReading.fileDescriptor) == 0 else {
            throw POSIXError(.EINVAL)
        }
        if stdin != nil {
            guard posix_spawn_file_actions_adddup2(&actions, stdinPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
                  posix_spawn_file_actions_addclose(&actions, stdinPipe.fileHandleForWriting.fileDescriptor) == 0 else {
                throw POSIXError(.EINVAL)
            }
        } else if fcntl(STDIN_FILENO, F_GETFD) != -1 {
            guard posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0 else {
                throw POSIXError(.EINVAL)
            }
        }
        for descriptor in additionalInheritedDescriptors {
            guard fcntl(descriptor, F_GETFD) != -1,
                  posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0 else {
                throw POSIXError(.EINVAL)
            }
        }
        let childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawnStatus = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executable.path,
                    &actions,
                    &attributes,
                    argvBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        guard spawnStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EINVAL) }

        try? capability.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        if stdin != nil { try? stdinPipe.fileHandleForReading.close() }
        try capability.fileHandleForWriting.write(contentsOf: payload)
        try capability.fileHandleForWriting.close()
        if let stdin {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try stdinPipe.fileHandleForWriting.close()
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(30)
        while waitpid(pid, &status, WNOHANG) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = waitpid(pid, &status, WNOHANG) == 0
        if timedOut {
            _ = kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let normalExit = status & 0x7f == 0
        let exitStatus = normalExit ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let terminationReason = normalExit ? 0 : status & 0x7f
        if timedOut || output.isEmpty || exitStatus != 0 {
            return output + "\n<plainpost status=\(exitStatus) reason=\(terminationReason) timedOut=\(timedOut)>"
        }
        return output
    }

    fileprivate static func markCloseOnExec(_ descriptors: [Int32]) throws {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw POSIXError(.EINVAL)
            }
        }
    }

    static func start(
        _ arguments: [String],
        environment: [String: String] = [:],
        credentialCapability: CLITestCredentialCapability? = nil
    ) throws -> InteractivePlainpostCLIProcess {
        guard credentialCapability == nil else {
            throw PlainpostError.validationFailed("Interactive test credential capability is not supported.")
        }
        let executable = productsDirectory.appendingPathComponent("plainpost")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        return InteractivePlainpostCLIProcess(process: process, stdin: stdin, stdout: stdout)
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find products directory")
    }
}

private final class InteractivePlainpostCLIProcess {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe

    init(process: Process, stdin: Pipe, stdout: Pipe) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    deinit {
        close()
    }

    func writeLine(_ line: String) throws {
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func readLine(timeout: TimeInterval) throws -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = InteractivePlainpostCLIReadResult()
        let handle = stdout.fileHandleForReading

        Thread.detachNewThread {
            let readResult = Result<String?, Error> {
                var bytes: [UInt8] = []
                while true {
                    let data = handle.readData(ofLength: 1)
                    guard let byte = data.first else {
                        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
                    }
                    if byte == 0x0A {
                        return String(decoding: bytes, as: UTF8.self)
                    }
                    bytes.append(byte)
                }
            }
            resultBox.store(readResult)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        let completed = resultBox.load()
        return try completed?.get()
    }

    func close() {
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if process.isRunning {
            process.waitUntilExit()
        }
    }
}

private final class InteractivePlainpostCLIReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String?, Error>?

    func store(_ result: Result<String?, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<String?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

enum PlainpostServiceProcess {
    static func run(
        _ arguments: [String],
        executableURL: URL? = nil,
        timeout: TimeInterval = 10,
        credentialCapability: CLITestCredentialCapability? = nil
    ) throws -> String {
        let executable = executableURL ?? productsDirectory.appendingPathComponent("PlainpostService")
        if let credentialCapability {
            let capability = credentialCapability
            return try capability.withPayload { payload in
                try PlainpostCLIProcess.runWithCredentialCapability(
                    arguments,
                    stdin: nil,
                    environment: [:],
                    payload: payload,
                    executable: executable
                )
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }
        try process.run()

        let timedOut = termination.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if timedOut || output.isEmpty || process.terminationStatus != 0 {
            return output
                + "\n<PlainpostService status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) timedOut=\(timedOut)>"
        }
        return output
    }

    static func runStdio(_ arguments: [String], input: String) throws -> String {
        let executable = productsDirectory.appendingPathComponent("PlainpostService")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        if let data = input.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        stdin.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if timedOut || output.isEmpty || process.terminationStatus != 0 {
            return output
                + "\n<PlainpostService status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) timedOut=\(timedOut)>"
        }
        return output
    }

    static func wrapperLoggingInvocations() throws -> (scriptURL: URL, logURL: URL) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-wrapper-\(UUID().uuidString).sh")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-wrapper-\(UUID().uuidString).log")
        let realService = productsDirectory.appendingPathComponent("PlainpostService").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        exec "\(realService)" "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return (scriptURL, logURL)
    }

    static func capabilityDescriptorProbeWrapper(sentinel: Int32) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-capability-probe-\(UUID().uuidString).sh")
        let realService = productsDirectory.appendingPathComponent("PlainpostService").path
        let script = """
        #!/bin/sh
        if [ -e /dev/fd/\(sentinel) ]; then
            echo sentinel-leaked
            exit 93
        fi
        exec "\(realService)" "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    static func hangingStdioWrapper() throws -> (scriptURL: URL, logURL: URL) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-hanging-wrapper-\(UUID().uuidString).sh")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-hanging-wrapper-\(UUID().uuidString).log")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        if [ "$1" = "serve" ]; then
          exec sleep 60
        fi
        exit 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return (scriptURL, logURL)
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find products directory")
    }
}
