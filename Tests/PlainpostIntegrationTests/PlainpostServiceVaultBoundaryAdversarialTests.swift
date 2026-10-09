import Foundation
import XCTest

final class PlainpostServiceVaultBoundaryAdversarialTests: XCTestCase {
    func testCanonicalFixturePasses() throws {
        try withBoundaryFixture { fixture in
            let result = try fixture.run()

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains("Plainpost service vault boundary: ok"),
                result.output
            )
        }
    }

    func testSubprocessesInTestSupportDoNotRelaxProductionChecks() throws {
        try withBoundaryFixture { fixture in
            try fixture.write(
                "import Foundation\nlet fixtureProcess = Process()\n",
                to: "Sources/PlainpostTestSupport/LocalProcessFixture.swift"
            )

            let result = try fixture.run()

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertFalse(
                result.output.contains("forbidden production subprocess"),
                result.output
            )

            try fixture.write(
                "import Foundation\nlet unexpectedProcess = Process()\n",
                to: "Sources/PlainpostUI/UnexpectedProcess.swift"
            )

            let productionResult = try fixture.run()

            XCTAssertNotEqual(productionResult.status, 0, productionResult.output)
            XCTAssertTrue(
                productionResult.output.contains(
                    "Sources/PlainpostUI/UnexpectedProcess.swift:2: forbidden production subprocess exposure Process"
                ),
                productionResult.output
            )
        }
    }

    func testRejectsProductionBodyOwnedByDecoyType() throws {
        try withBoundaryFixture { fixture in
            try fixture.write(
                """
                struct PlainpostServiceComposition {}

                struct DecoyComposition {
                    static func production() {
                        _ = MacVaultKeyProvider()
                        _ = SQLiteCredentialVaultAssembly()
                    }
                }
                """,
                to: "Sources/PlainpostService/PlainpostServiceComposition.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "expected exactly one PlainpostServiceComposition.production body"
                ),
                result.output
            )
        }
    }

    func testRejectsInitAndStoredMetatypeConstructorBypasses() throws {
        let bypasses = [
            """
            func bypass() {
                _ = MacVaultKeyProvider.init()
                _ = SQLiteCredentialVaultAssembly.init()
            }
            """,
            """
            func bypass() {
                let providerFactory = MacVaultKeyProvider.self
                let assemblyFactory = SQLiteCredentialVaultAssembly.self
                _ = providerFactory.init()
                _ = assemblyFactory.init()
            }
            """,
        ]

        try withBoundaryFixture { fixture in
            for (index, source) in bypasses.enumerated() {
                try fixture.write(
                    source,
                    to: "Sources/PlainpostUI/ConstructorBypass\(index).swift"
                )
                let result = try fixture.run()
                XCTAssertNotEqual(
                    result.status,
                    0,
                    "bypass \(index) unexpectedly passed:\n\(result.output)"
                )
                XCTAssertTrue(
                    result.output.contains(
                        "type reference is outside PlainpostServiceComposition.production"
                    ),
                    "bypass \(index) returned the wrong violation:\n\(result.output)"
                )
            }
        }
    }

    func testRejectsIndirectRestrictedConstructionInsideProductionBody() throws {
        try withBoundaryFixture { fixture in
            try fixture.write(
                """
                struct PlainpostServiceComposition {
                    static func production() {
                        typealias ProviderAlias = MacVaultKeyProvider
                        typealias AssemblyAlias = SQLiteCredentialVaultAssembly
                        let providerFactory = MacVaultKeyProvider.self
                        let assemblyFactory = SQLiteCredentialVaultAssembly.self
                        _ = ProviderAlias()
                        _ = AssemblyAlias()
                        _ = providerFactory.init()
                        _ = assemblyFactory.init()
                        _ = MacVaultKeyProvider()
                        _ = SQLiteCredentialVaultAssembly()
                    }
                }
                """,
                to: "Sources/PlainpostService/PlainpostServiceComposition.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "must be an exact direct constructor expression"
                ),
                result.output
            )
        }
    }

    func testRejectsDerivedMetatypeAndCallableExtractionInsideProductionBody() throws {
        let bypasses = [
            """
                    let providerType = type(of: provider)
                    let assemblyType = type(of: assembly)
                    _ = providerType.init()
                    _ = assemblyType.init(store: store, provider: provider)
            """,
            """
                    let providerConstructor = type(of: provider).init
                    let assemblyConstructor = type(of: assembly).init
                    _ = providerConstructor()
                    _ = assemblyConstructor(store: store, provider: provider)
            """,
            """
                    _ = Mirror(reflecting: provider)
                    _ = Mirror(reflecting: assembly)
            """,
            """
                    let opaqueProvider: Any = provider
                    let opaqueAssembly: Any = assembly
                    _ = unsafeBitCast(opaqueProvider, to: Any.Type.self)
                    _ = unsafeBitCast(opaqueAssembly, to: Any.Type.self)
            """,
        ]

        try withBoundaryFixture { fixture in
            for (index, bypass) in bypasses.enumerated() {
                let source = try fixture.compositionSource(
                    insertingAfterAssembly: bypass
                )
                try fixture.write(
                    source,
                    to: "Sources/PlainpostService/PlainpostServiceComposition.swift"
                )

                let result = try fixture.run()

                XCTAssertNotEqual(
                    result.status,
                    0,
                    "derived bypass \(index) unexpectedly passed:\n\(result.output)"
                )
                XCTAssertTrue(
                    result.output.contains(
                        "production composition token contract"
                    ),
                    "derived bypass \(index) returned the wrong violation:\n\(result.output)"
                )
            }
        }
    }

    func testRejectsBackgroundAgentPathSwapAndAdditionalProcess() throws {
        try withBoundaryFixture { fixture in
            let bypasses = [
                try fixture.workerSource(
                    appName: "PlainpostService.app",
                    executableName: "PlainpostService",
                    processCount: 1
                ),
                try fixture.workerSource(
                    appName: "PlainpostBackgroundAgent.app",
                    executableName: "PlainpostBackgroundAgent",
                    processCount: 2
                ),
                try fixture.workerSource(
                    appName: "PlainpostBackgroundAgent.app",
                    executableName: "PlainpostBackgroundAgent",
                    processCount: 1
                ).replacingOccurrences(
                    of: "let process = Process()",
                    with: """
                    let extraProcessFactory = Process.self
                            let extraProcess = extraProcessFactory.init()
                            let process = Process()
                    """
                ),
            ]

            for (index, source) in bypasses.enumerated() {
                try fixture.write(
                    source,
                    to: "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
                )
                let result = try fixture.run()
                XCTAssertNotEqual(
                    result.status,
                    0,
                    "process bypass \(index) unexpectedly passed:\n\(result.output)"
                )
                XCTAssertTrue(
                    result.output.contains(
                        "PackagedOperationWorkerSignal must contain exactly one "
                    ),
                    "process bypass \(index) returned the wrong violation:\n\(result.output)"
                )
            }
        }
    }

    func testRejectsAliasedProcessAndSplitServicePathDecoy() throws {
        try withBoundaryFixture { fixture in
            let source = try fixture.workerSource(
                appName: "PlainpostBackgroundAgent.app",
                executableName: "PlainpostBackgroundAgent",
                processCount: 1
            ).replacingOccurrences(
                of: "let process = Process()",
                with: """
                typealias ExtraProcess = Process
                    let serviceExecutableURL = URL(fileURLWithPath: "Plainpost" + "Service.app")
                        .appendingPathComponent("Contents/MacOS/" + "Plainpost" + "Service")
                    let extraProcess = ExtraProcess()
                    extraProcess.executableURL = serviceExecutableURL
                    try extraProcess.run()
                    let process = Process()
                """
            )
            try fixture.write(
                source,
                to: "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "PackagedOperationWorkerSignal must contain exactly one "
                ),
                result.output
            )
        }
    }

    func testRejectsCrossTargetProcessExposureAndNonliteralServiceLaunch() throws {
        let exposures = [
            (
                source: """
                import Foundation

                public typealias ExtraProcess = Process
                """,
                construction: "ExtraProcess()"
            ),
            (
                source: """
                import Foundation

                public func makeExtraProcess() -> Process {
                    Process()
                }
                """,
                construction: "makeExtraProcess()"
            ),
            (
                source: """
                import Foundation

                public let extraProcessType = Process.self
                """,
                construction: "extraProcessType.init()"
            ),
        ]
        let servicePathBytes = """
        47, 116, 109, 112, 47, 80, 108, 97, 105, 110, 112, 111, 115, 116,
        83, 101, 114, 118, 105, 99, 101, 46, 97, 112, 112, 47, 67, 111,
        110, 116, 101, 110, 116, 115, 47, 77, 97, 99, 79, 83, 47, 80,
        108, 97, 105, 110, 112, 111, 115, 116, 83, 101, 114, 118, 105,
        99, 101
        """

        try withBoundaryFixture { fixture in
            for (index, exposure) in exposures.enumerated() {
                try fixture.write(
                    exposure.source,
                    to: "Sources/PlainpostServiceIPC/ExtraProcess.swift"
                )
                let canonicalWorker = try fixture.workerSource(
                    appName: "PlainpostBackgroundAgent.app",
                    executableName: "PlainpostBackgroundAgent",
                    processCount: 1
                )
                let worker = canonicalWorker
                    .replacingOccurrences(
                        of: "import PlainpostOperationRuntime",
                        with: """
                        import PlainpostOperationRuntime
                        import PlainpostServiceIPC
                        """
                    )
                    .replacingOccurrences(
                        of: "let process = Process()",
                        with: """
                        let servicePath = String(
                                    decoding: [\(servicePathBytes)],
                                    as: UTF8.self
                                )
                                let serviceExecutableURL = URL(
                                    fileURLWithPath: servicePath
                                )
                                let extraProcess = \(exposure.construction)
                                extraProcess.executableURL = serviceExecutableURL
                                try extraProcess.run()
                                let process = Process()
                        """
                    )
                try fixture.write(
                    worker,
                    to: "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
                )

                let result = try fixture.run()

                XCTAssertNotEqual(
                    result.status,
                    0,
                    "cross-target bypass \(index) unexpectedly passed:\n\(result.output)"
                )
                XCTAssertTrue(
                    result.output.contains(
                        "forbidden production subprocess"
                    ),
                    "cross-target bypass \(index) returned the wrong violation:\n\(result.output)"
                )
            }
        }
    }

    func testRejectsDesignSnapshotDecoyThenExecutableReassignment() throws {
        try withBoundaryFixture { fixture in
            let source = try fixture.designSnapshotSource(
                replacingCaptureSetupWith: """
                        let capture = Process()
                        capture.executableURL = URL(
                            fileURLWithPath: "/usr/sbin/screencapture"
                        )
                        let serviceExecutableURL = URL(
                            fileURLWithPath:
                                "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                        )
                        capture.executableURL = serviceExecutableURL
                """
            )
            try fixture.write(
                source,
                to: "Sources/PlainpostDesignSnapshot/main.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "single canonical screencapture Process sequence"
                ),
                result.output
            )
        }
    }

    func testRejectsDesignSnapshotServiceAssignmentWithDisplacedLiteral() throws {
        try withBoundaryFixture { fixture in
            let source = try fixture.designSnapshotSource(
                replacingCaptureSetupWith: """
                        let displacedScreencapturePath = "/usr/sbin/screencapture"
                        let capture = Process()
                        capture.executableURL = URL(
                            fileURLWithPath:
                                "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                        )
                """
            )
            try fixture.write(
                source,
                to: "Sources/PlainpostDesignSnapshot/main.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "single canonical screencapture Process sequence"
                ),
                result.output
            )
        }
    }

    func testRejectsDesignSnapshotAliasExecutableMutation() throws {
        try withBoundaryFixture { fixture in
            let source = try fixture.designSnapshotSource(
                replacingCaptureSetupWith: """
                        let capture = Process()
                        capture.executableURL = URL(
                            fileURLWithPath: "/usr/sbin/screencapture"
                        )
                        let processAlias = capture
                        processAlias.executableURL = URL(
                            fileURLWithPath:
                                "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                        )
                """
            )
            try fixture.write(
                source,
                to: "Sources/PlainpostDesignSnapshot/main.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "single canonical screencapture Process sequence"
                ),
                result.output
            )
        }
    }

    func testRejectsDesignSnapshotURLNameResolutionShadows() throws {
        try withBoundaryFixture { fixture in
            let canonicalCaptureSetup = """
                    let capture = Process()
                    capture.executableURL = URL(
                        fileURLWithPath: "/usr/sbin/screencapture"
                    )
            """
            let bypasses = [
                (
                    name: "local callable value",
                    source: try fixture.designSnapshotSource(
                        replacingCaptureSetupWith: """
                                struct SnapshotURLFactory {
                                    func callAsFunction(
                                        fileURLWithPath: String
                                    ) -> Foundation.URL {
                                        Foundation.URL(
                                            fileURLWithPath:
                                                "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                                        )
                                    }
                                }
                                let URL = SnapshotURLFactory()
                        \(canonicalCaptureSetup)
                        """
                    )
                ),
                (
                    name: "local function",
                    source: try fixture.designSnapshotSource(
                        replacingCaptureSetupWith: """
                                func URL(
                                    fileURLWithPath: String
                                ) -> Foundation.URL {
                                    Foundation.URL(
                                        fileURLWithPath:
                                            "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                                    )
                                }
                        \(canonicalCaptureSetup)
                        """
                    )
                ),
                (
                    name: "enclosing static function",
                    source: try fixture.designSnapshotSource(
                        replacingCaptureSetupWith: canonicalCaptureSetup,
                        insertingBeforeRender: """
                            private static func URL(
                                fileURLWithPath: String
                            ) -> Foundation.URL {
                                Foundation.URL(
                                    fileURLWithPath:
                                        "/tmp/PlainpostService.app/Contents/MacOS/PlainpostService"
                                )
                            }
                        """
                    )
                ),
            ]

            for bypass in bypasses {
                try fixture.write(
                    bypass.source,
                    to: "Sources/PlainpostDesignSnapshot/main.swift"
                )

                let result = try fixture.run()

                XCTAssertNotEqual(
                    result.status,
                    0,
                    "\(bypass.name) unexpectedly passed:\n\(result.output)"
                )
                XCTAssertTrue(
                    result.output.contains(
                        "single canonical screencapture Process sequence"
                    ),
                    "\(bypass.name) returned the wrong violation:\n\(result.output)"
                )
            }
        }
    }

    func testProductionServiceRuntimeGraphUsesOneAssemblyAndLazyRuntimes() throws {
        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let operations = try String(
            contentsOf: repositoryRootURL.appendingPathComponent(
                "Sources/PlainpostService/PlainpostServiceOperations.swift"
            ),
            encoding: .utf8
        )
        let composition = try String(
            contentsOf: repositoryRootURL.appendingPathComponent(
                "Sources/PlainpostService/PlainpostServiceComposition.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(operations.contains("private let assembly: SQLiteCredentialVaultAssembly"))
        XCTAssertTrue(operations.contains("private var accountRuntime: AccountSetupService?"))
        XCTAssertTrue(operations.contains("private var operationRuntime: LocalOperationRuntime?"))
        XCTAssertTrue(
            operations.contains(
                "private var backgroundOperationRuntime: LocalOperationRuntime?"
            )
        )
        XCTAssertTrue(
            operations.contains(
                "private var localDraftDeliveryRuntime: LocalDraftDeliveryService?"
            )
        )
        XCTAssertTrue(operations.contains("private func accountRuntimeForUse()"))
        XCTAssertTrue(operations.contains("private func operationRuntimeForUse()"))
        XCTAssertTrue(operations.contains("private func backgroundOperationRuntimeForUse()"))
        XCTAssertTrue(operations.contains("private func localDraftDeliveryRuntimeForUse()"))
        XCTAssertTrue(composition.contains("assembly: assembly"))
        XCTAssertFalse(composition.contains("credentials: assembly.vault"))
        XCTAssertEqual(
            composition.components(separatedBy: "SQLiteCredentialVaultAssembly(").count - 1,
            1
        )

        for deletedLegacyRuntime in [
            "PlainpostServiceDeviceCompanionController",
            "PlainpostDeviceCompanionRuntime",
            "listPairedDevices",
        ] {
            XCTAssertFalse(
                operations.contains(deletedLegacyRuntime),
                "legacy runtime boundary was restored: \(deletedLegacyRuntime)"
            )
            XCTAssertFalse(
                composition.contains(deletedLegacyRuntime),
                "legacy composition boundary was restored: \(deletedLegacyRuntime)"
            )
        }
    }

    func testRejectsClientSecretImportAndConcreteSeams() throws {
        try withBoundaryFixture { fixture in
            try fixture.write(
                """
                import PlainpostSecrets

                struct ForbiddenClientSeams {
                    let vault: any CredentialVault
                    let assembly: SQLiteCredentialVaultAssembly
                    let unlocker: CredentialUnlocker
                }
                """,
                to: "Sources/PlainpostUI/ForbiddenClientSeams.swift"
            )
            try fixture.write(
                """
                import PlainpostSecrets

                let previewVault = InMemoryCredentialVault()
                """,
                to: "Sources/PlainpostApp/ForbiddenAppFixture.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "PlainpostUI may not import PlainpostSecrets"
                ),
                result.output
            )
            XCTAssertTrue(
                result.output.contains(
                    "forbidden production client secret type CredentialVault"
                ),
                result.output
            )
            XCTAssertTrue(
                result.output.contains(
                    "forbidden production client secret type CredentialUnlocker"
                ),
                result.output
            )
            XCTAssertTrue(
                result.output.contains(
                    "PlainpostApp may not import PlainpostSecrets"
                ),
                result.output
            )
        }
    }

    func testRejectsQualifiedClientSecretImport() throws {
        try withBoundaryFixture { fixture in
            try fixture.write(
                """
                import struct PlainpostSecrets.CredentialVault
                """,
                to: "Sources/PlainpostUI/QualifiedSecretImport.swift"
            )

            let result = try fixture.run()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(
                result.output.contains(
                    "PlainpostUI may not import PlainpostSecrets"
                ),
                result.output
            )
        }
    }
}

private struct BoundaryFixture {
    struct ProcessResult {
        let status: Int32
        let output: String
    }

    private let rootURL: URL
    private let scannerSourceURL: URL
    private let canonicalCompositionSource: String
    private let canonicalWorkerSource: String
    private let canonicalDesignSnapshotSource: String

    init(rootURL: URL, scannerSourceURL: URL) throws {
        self.rootURL = rootURL
        self.scannerSourceURL = scannerSourceURL
        let repositoryRootURL = scannerSourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.canonicalCompositionSource = try String(
            contentsOf: repositoryRootURL.appendingPathComponent(
                "Sources/PlainpostService/PlainpostServiceComposition.swift"
            ),
            encoding: .utf8
        )
        self.canonicalWorkerSource = try String(
            contentsOf: repositoryRootURL.appendingPathComponent(
                "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
            ),
            encoding: .utf8
        )
        self.canonicalDesignSnapshotSource = try String(
            contentsOf: repositoryRootURL.appendingPathComponent(
                "Sources/PlainpostDesignSnapshot/main.swift"
            ),
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try write(Self.packageManifest, to: "Package.swift")
        try write(
            canonicalCompositionSource,
            to: "Sources/PlainpostService/PlainpostServiceComposition.swift"
        )
        try write(
            canonicalWorkerSource,
            to: "Sources/PlainpostUI/PackagedOperationWorkerSignal.swift"
        )
        try write(
            canonicalDesignSnapshotSource,
            to: "Sources/PlainpostDesignSnapshot/main.swift"
        )
        for target in [
            "PlainpostApp",
            "PlainpostCLI",
            "PlainpostBackgroundAgent",
            "PlainpostBrowserBridge",
            "PlainpostServiceIPC",
            "PlainpostSecrets",
        ] {
            try write(
                "struct \(target)BoundaryFixture {}\n",
                to: "Sources/\(target)/BoundaryFixture.swift"
            )
        }

        let scannerDestination = rootURL.appendingPathComponent(
            "Scripts/plainpost/assert-service-vault-boundary.sh"
        )
        try FileManager.default.createDirectory(
            at: scannerDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: scannerSourceURL,
            to: scannerDestination
        )
        _ = try Self.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "--quiet"],
            currentDirectoryURL: rootURL
        )
        let addResult = try Self.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["add", "--all"],
            currentDirectoryURL: rootURL
        )
        guard addResult.status == 0 else {
            throw BoundaryFixtureError.processFailed(addResult.output)
        }
    }

    func write(_ source: String, to relativePath: String) throws {
        let destination = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: destination, options: .atomic)
    }

    func run() throws -> ProcessResult {
        try Self.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                rootURL.appendingPathComponent(
                    "Scripts/plainpost/assert-service-vault-boundary.sh"
                ).path
            ],
            currentDirectoryURL: rootURL
        )
    }

    func compositionSource(
        insertingAfterAssembly addition: String
    ) throws -> String {
        let marker = """
                let assembly = SQLiteCredentialVaultAssembly(
                    store: store,
                    provider: provider
                )
        """
        return try replacingExactlyOnce(
            marker,
            with: "\(marker)\n\(addition)",
            in: canonicalCompositionSource
        )
    }

    func workerSource(
        appName: String,
        executableName: String,
        processCount: Int
    ) throws -> String {
        let processDeclarations = (0..<processCount)
            .map { index in
                index == 0
                    ? "        let process = Process()"
                    : "        let process\(index) = Process()"
            }
            .joined(separator: "\n")
        var source = try replacingExactlyOnce(
            "\"PlainpostBackgroundAgent.app\"",
            with: "\"\(appName)\"",
            in: canonicalWorkerSource
        )
        source = try replacingExactlyOnce(
            "\"Contents/MacOS/PlainpostBackgroundAgent\"",
            with: "\"Contents/MacOS/\(executableName)\"",
            in: source
        )
        return try replacingExactlyOnce(
            "        let process = Process()",
            with: processDeclarations,
            in: source
        )
    }

    func designSnapshotSource(
        replacingCaptureSetupWith replacement: String,
        insertingBeforeRender declaration: String? = nil
    ) throws -> String {
        let marker = """
                let capture = Process()
                capture.executableURL = .init(fileURLWithPath: "/usr/sbin/screencapture")
        """
        var source = try replacingExactlyOnce(
            marker,
            with: replacement,
            in: canonicalDesignSnapshotSource
        )
        if let declaration {
            let renderMarker = "    private static func render("
            source = try replacingExactlyOnce(
                renderMarker,
                with: "\(declaration)\n\n\(renderMarker)",
                in: source
            )
        }
        return source
    }

    private func replacingExactlyOnce(
        _ target: String,
        with replacement: String,
        in source: String
    ) throws -> String {
        guard source.components(separatedBy: target).count == 2 else {
            throw BoundaryFixtureError.invalidFixtureMarker(target)
        }
        return source.replacingOccurrences(
            of: target,
            with: replacement
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private static let packageManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "PlainpostBoundaryFixture",
        platforms: [.macOS(.v14)],
        targets: [
            .target(name: "PlainpostServiceIPC"),
            .target(name: "PlainpostSecrets"),
            .target(name: "PlainpostTestSupport"),
            .target(
                name: "PlainpostUI",
                dependencies: ["PlainpostServiceIPC"]
            ),
            .target(
                name: "PlainpostApp",
                dependencies: ["PlainpostServiceIPC"]
            ),
            .target(
                name: "PlainpostCLI",
                dependencies: ["PlainpostServiceIPC"]
            ),
            .target(
                name: "PlainpostBackgroundAgent",
                dependencies: ["PlainpostServiceIPC"]
            ),
            .target(
                name: "PlainpostBrowserBridge",
                dependencies: ["PlainpostServiceIPC"]
            ),
            .executableTarget(
                name: "PlainpostService",
                dependencies: ["PlainpostSecrets", "PlainpostServiceIPC"]
            ),
        ]
    )
    """
}

private enum BoundaryFixtureError: Error {
    case processFailed(String)
    case invalidFixtureMarker(String)
}

private func withBoundaryFixture(
    _ body: (BoundaryFixture) throws -> Void
) throws {
    let repositoryRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "PlainpostServiceVaultBoundary-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fixture = try BoundaryFixture(
        rootURL: rootURL,
        scannerSourceURL: repositoryRootURL.appendingPathComponent(
            "Scripts/plainpost/assert-service-vault-boundary.sh"
        )
    )
    try body(fixture)
}
