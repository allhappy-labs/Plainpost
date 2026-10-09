// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Plainpost",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "PlainpostCore", targets: ["PlainpostCore"]),
        .library(name: "PlainpostLocalAPI", targets: ["PlainpostLocalAPI"]),
        .library(name: "PlainpostBrowserIntegration", targets: ["PlainpostBrowserIntegration"]),
        .library(name: "PlainpostLocalServer", targets: ["PlainpostLocalServer"]),
        .library(name: "PlainpostAI", targets: ["PlainpostAI"]),
        .library(name: "PlainpostDB", targets: ["PlainpostDB"]),
        .library(name: "PlainpostSecrets", targets: ["PlainpostSecrets"]),
        .library(name: "PlainpostServiceIPC", targets: ["PlainpostServiceIPC"]),
        .library(name: "PlainpostAccounts", targets: ["PlainpostAccounts"]),
        .library(name: "PlainpostCLI", targets: ["PlainpostCLI"]),
        .library(name: "PlainpostUI", targets: ["PlainpostUI"]),
        .library(name: "PlainpostIOSRuntime", type: .static, targets: ["PlainpostIOSRuntime"]),
        .library(name: "PlainpostOperations", targets: ["PlainpostOperations"]),
        .library(name: "PlainpostOperationRuntime", targets: ["PlainpostOperationRuntime"]),
        .library(name: "PlainpostAccountProtocol", targets: ["PlainpostAccountProtocol"]),
        .library(name: "PlainpostAccountRuntime", targets: ["PlainpostAccountRuntime"]),
        .library(name: "PlainpostNodeTransport", targets: ["PlainpostNodeTransport"]),
        .library(name: "PlainpostNodeMailMode", targets: ["PlainpostNodeMailMode"]),
        .library(name: "PlainpostNotificationRuntime", targets: ["PlainpostNotificationRuntime"]),
        .library(name: "PlainpostRootAuthorityCore", targets: ["PlainpostRootAuthorityCore"]),
        .library(name: "PlainpostTestSupport", targets: ["PlainpostTestSupport"]),
        .executable(name: "PlainpostApp", targets: ["PlainpostApp"]),
        .executable(name: "PlainpostDesignSnapshot", targets: ["PlainpostDesignSnapshot"]),
        .executable(name: "PlainpostIOSMailFixture", targets: ["PlainpostIOSMailFixture"]),
        .executable(name: "PlainpostService", targets: ["PlainpostService"]),
        .executable(name: "PlainpostBackgroundAgent", targets: ["PlainpostBackgroundAgent"]),
        .executable(name: "PlainpostBrowserBridge", targets: ["PlainpostBrowserBridge"]),
        .executable(name: "PlainpostSmartInboxBenchmark", targets: ["PlainpostSmartInboxBenchmark"]),
        .executable(name: "PlainpostSearchBenchmark", targets: ["PlainpostSearchBenchmark"]),
        .executable(name: "plainpost", targets: ["plainpost"]),
        .executable(name: "plainpost-root-authority", targets: ["PlainpostRootAuthority"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "PlainpostComposeHash"),
        .target(name: "PlainpostCore", dependencies: ["PlainpostComposeHash", "PlainpostAccountProtocol"]),
        .target(name: "PlainpostLocalAPI", dependencies: ["PlainpostCore"]),
        .target(name: "PlainpostBrowserIntegration", dependencies: ["PlainpostLocalAPI"]),
        .target(
            name: "PlainpostLocalServer",
            dependencies: [
                "PlainpostAI", "PlainpostAccounts", "PlainpostCore", "PlainpostDB",
                "PlainpostLocalAPI", "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostSecrets",
            ]
        ),
        .target(
            name: "PlainpostAI",
            dependencies: ["PlainpostCore", "PlainpostSecrets"]
        ),
        .target(
            name: "PlainpostDB",
            dependencies: [
                "PlainpostCore",
                "PlainpostSecrets",
                "PlainpostOperations",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(name: "PlainpostSecrets"),
        .target(
            name: "PlainpostXPCObjC",
            path: "Sources/PlainpostXPCObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PlainpostServiceIPC",
            dependencies: [
                "PlainpostCore",
                "PlainpostOperations",
                "PlainpostXPCObjC",
            ]
        ),
        .target(
            name: "PlainpostServiceRuntime",
            dependencies: [
                "PlainpostDB",
                "PlainpostOperations",
                "PlainpostSecrets",
                "PlainpostServiceIPC",
            ]
        ),
        .target(
            name: "PlainpostNotificationRuntime",
            dependencies: ["PlainpostAccountProtocol", "PlainpostAccountRuntime", "PlainpostCore"]
        ),
        .target(
            name: "PlainpostAccounts",
            dependencies: ["PlainpostCore", "PlainpostDB", "PlainpostSecrets"]
        ),
        .target(
            name: "PlainpostCLI",
            dependencies: ["PlainpostAccounts", "PlainpostCore", "PlainpostDB", "PlainpostServiceIPC"]
        ),
        .target(name: "PlainpostCalendarPresentation", dependencies: ["PlainpostNodeTransport"]),
        .testTarget(name: "PlainpostCalendarPresentationTests", dependencies: ["PlainpostCalendarPresentation", "PlainpostNodeTransport"]),
        .target(
            name: "PlainpostUI",
            dependencies: ["PlainpostCalendarPresentation", "PlainpostAI", "PlainpostAccounts", "PlainpostAccountRuntime", "PlainpostBrowserIntegration", "PlainpostCore", "PlainpostDB", "PlainpostLocalServer", "PlainpostServiceIPC", "PlainpostOperations", "PlainpostOperationRuntime"]
        ),
        .target(
            name: "PlainpostIOSRuntime",
            dependencies: ["PlainpostAccounts", "PlainpostCore", "PlainpostDB", "PlainpostLocalServer", "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostSecrets", "PlainpostUI"]
        ),
        .target(
            name: "PlainpostOperations",
            dependencies: ["PlainpostCore"]
        ),
        .target(
            name: "PlainpostOperationRuntime",
            dependencies: ["PlainpostAI", "PlainpostAccounts", "PlainpostCore", "PlainpostDB", "PlainpostSecrets", "PlainpostOperations"]
        ),
        .target(name: "PlainpostAccountProtocol"),
        .target(
            name: "PlainpostRootAuthorityCore",
            dependencies: ["PlainpostAccountProtocol"],
            path: "Tools/PlainpostRootAuthority/Core"
        ),
        .target(name: "PlainpostNodeTransport", dependencies: ["PlainpostAccountProtocol"]),
        .target(
            name: "PlainpostAccountRuntime",
            dependencies: ["PlainpostAccountProtocol", "PlainpostCore", "PlainpostNodeTransport"],
            resources: [
                .copy("Resources/central-bootstrap-manifest-v1.json"),
                .copy("Resources/production-root-descriptor.json"),
                .copy("Resources/production-session-root-descriptor.json"),
                .copy("Resources/production-session-key-manifest-v1.json"),
                .copy("Resources/central-server-config-v1.json"),
            ]
        ),
        .target(
            name: "PlainpostNodeMailMode",
            dependencies: [
                "PlainpostAccountRuntime", "PlainpostAccounts", "PlainpostCore", "PlainpostDB",
                "PlainpostNodeTransport", "PlainpostOperationRuntime", "PlainpostOperations",
                "PlainpostSecrets", "PlainpostServiceIPC",
            ]
        ),
        .target(
            name: "PlainpostTestSupport",
            dependencies: ["PlainpostCore"]
        ),
        .target(
            name: "PlainpostRuntimeTestSupport",
            dependencies: [
                "PlainpostAccounts", "PlainpostCore", "PlainpostDB",
                "PlainpostLocalServer", "PlainpostOperationRuntime",
                "PlainpostOperations", "PlainpostSecrets",
                "PlainpostServiceIPC", "PlainpostUI",
            ],
            path: "Tests/PlainpostRuntimeTestSupport"
        ),
        .target(
            name: "PlainpostAccountDeletionTestSupport",
            dependencies: ["PlainpostCore", "PlainpostDB", "PlainpostOperations", "PlainpostTestSupport"],
            path: "Tests/PlainpostAccountDeletionTestSupport"
        ),
        .executableTarget(
            name: "PlainpostApp",
            dependencies: ["PlainpostUI", "PlainpostAccountRuntime", "PlainpostDB", "PlainpostServiceIPC", "PlainpostTestSupport"]
        ),
        .executableTarget(
            name: "PlainpostDesignSnapshot",
            dependencies: ["PlainpostUI"]
        ),
        .executableTarget(
            name: "PlainpostIOSMailFixture",
            dependencies: ["PlainpostCore", "PlainpostTestSupport"]
        ),
        .executableTarget(
            name: "PlainpostService",
            dependencies: [
                "PlainpostAI", "PlainpostAccounts", "PlainpostCore", "PlainpostDB", "PlainpostLocalServer",
                "PlainpostSecrets", "PlainpostServiceIPC", "PlainpostServiceRuntime",
                "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostNotificationRuntime",
                "PlainpostNodeMailMode", "PlainpostAccountRuntime", "PlainpostNodeTransport",
            ]),
        .executableTarget(
            name: "PlainpostBackgroundAgent",
            dependencies: ["PlainpostAI", "PlainpostCore", "PlainpostDB", "PlainpostOperationRuntime", "PlainpostOperations", "PlainpostServiceIPC"]
        ),
        .executableTarget(
            name: "PlainpostBrowserBridge",
            dependencies: ["PlainpostBrowserIntegration", "PlainpostLocalAPI", "PlainpostServiceIPC"]
        ),
        .executableTarget(
            name: "PlainpostSmartInboxBenchmark",
            dependencies: ["PlainpostCore", "PlainpostAI", "PlainpostDB", "PlainpostOperationRuntime", "PlainpostOperations"]
        ),
        .executableTarget(
            name: "PlainpostSearchBenchmark",
            dependencies: [
                "PlainpostCore", "PlainpostDB", "PlainpostTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "PlainpostLocalServerTestHelper",
            path: "Tests/PlainpostLocalServerTestHelper"
        ),
        .executableTarget(
            name: "plainpost",
            dependencies: ["PlainpostCLI", "PlainpostServiceIPC"]
        ),
        .executableTarget(
            name: "PlainpostRootAuthority",
            dependencies: ["PlainpostAccountProtocol", "PlainpostRootAuthorityCore"],
            path: "Tools/PlainpostRootAuthority/CLI"
        ),
        .testTarget(
            name: "PlainpostCoreTests",
            dependencies: ["PlainpostCore", "PlainpostTestSupport"]
        ),
        .testTarget(
            name: "PlainpostAITests",
            dependencies: ["PlainpostAI", "PlainpostDB", "PlainpostTestSupport"]
        ),
        .testTarget(
            name: "PlainpostDBTests",
            dependencies: [
                "PlainpostAccountDeletionTestSupport",
                "PlainpostAccounts",
                "PlainpostDB",
                "PlainpostSecrets",
                "PlainpostNotificationRuntime",
                "PlainpostTestSupport",
            ]
        ),
        .testTarget(
            name: "PlainpostSearchBenchmarkTests",
            dependencies: [
                "PlainpostCore", "PlainpostDB", "PlainpostSearchBenchmark",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PlainpostSecretsTests",
            dependencies: ["PlainpostSecrets", "PlainpostAccounts", "PlainpostCore"]
        ),
        .testTarget(
            name: "PlainpostUITests",
            dependencies: ["PlainpostCalendarPresentation", "PlainpostUI", "PlainpostIOSRuntime", "PlainpostDesignSnapshot", "PlainpostAccounts", "PlainpostBrowserIntegration", "PlainpostCore", "PlainpostDB", "PlainpostLocalAPI", "PlainpostLocalServer", "PlainpostSecrets", "PlainpostServiceIPC", "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostTestSupport", "PlainpostRuntimeTestSupport", "PlainpostNodeMailMode"]
        ),
        .testTarget(
            name: "PlainpostCLITests",
            dependencies: [
                "PlainpostCLI",
                "PlainpostCore",
                "PlainpostOperations",
                "PlainpostServiceIPC",
                "PlainpostTestSupport",
            ]
        ),
        .testTarget(
            name: "PlainpostIntegrationTests",
            dependencies: ["PlainpostAccounts", "PlainpostCLI", "PlainpostCore", "PlainpostDB", "PlainpostSecrets", "PlainpostService", "PlainpostServiceIPC", "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostTestSupport", "PlainpostRuntimeTestSupport", "PlainpostUI", "PlainpostIOSRuntime"]
        ),
        .testTarget(
            name: "PlainpostOperationsTests",
            dependencies: ["PlainpostAI", "PlainpostAccounts", "PlainpostCore", "PlainpostDB", "PlainpostSecrets", "PlainpostOperations", "PlainpostOperationRuntime", "PlainpostTestSupport"]
        ),
        .testTarget(name: "PlainpostAppTests", dependencies: ["PlainpostApp"]),
        .testTarget(
            name: "PlainpostAccountProtocolTests",
            dependencies: ["PlainpostAccountProtocol"]
        ),
        .testTarget(
            name: "PlainpostRootAuthorityTests",
            dependencies: ["PlainpostAccountProtocol", "PlainpostRootAuthorityCore"],
            path: "Tools/PlainpostRootAuthority/Tests"
        ),
        .testTarget(
            name: "PlainpostNodeTransportTests",
            dependencies: ["PlainpostNodeTransport", "PlainpostAccountProtocol"]
        ),
        .testTarget(
            name: "PlainpostAccountRuntimeTests",
            dependencies: ["PlainpostAccountProtocol", "PlainpostAccountRuntime", "PlainpostNotificationRuntime", "PlainpostNodeMailMode", "PlainpostDB"]
        ),
        .testTarget(
            name: "PlainpostNotificationRuntimeTests",
            dependencies: ["PlainpostAccountProtocol", "PlainpostAccountRuntime", "PlainpostCore", "PlainpostNotificationRuntime"]
        ),
        .testTarget(
            name: "PlainpostLocalAPITests",
            dependencies: [
                "PlainpostCore", "PlainpostDB", "PlainpostLocalAPI", "PlainpostLocalServer",
                "PlainpostLocalServerTestHelper", "PlainpostOperations", "PlainpostTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PlainpostBrowserBridgeTests",
            dependencies: ["PlainpostBrowserIntegration", "PlainpostLocalAPI", "PlainpostTestSupport"]
        ),
        .testTarget(
            name: "PlainpostServiceIPCTests",
            dependencies: [
                "PlainpostCore", "PlainpostDB", "PlainpostOperations", "PlainpostSecrets",
                "PlainpostServiceIPC", "PlainpostServiceRuntime",
            ]
        ),
        .testTarget(
            name: "PlainpostServiceTests",
            dependencies: [
                "PlainpostAccountDeletionTestSupport",
                "PlainpostAccounts", "PlainpostAI", "PlainpostCore", "PlainpostDB",
                "PlainpostLocalServer", "PlainpostOperationRuntime", "PlainpostOperations",
                "PlainpostSecrets", "PlainpostService", "PlainpostServiceIPC", "PlainpostTestSupport",
                "PlainpostNodeMailMode", "PlainpostAccountRuntime", "PlainpostNodeTransport",
            ]
        ),
        .testTarget(
            name: "PlainpostNodeMailModeTests",
            dependencies: [
                "PlainpostAccountRuntime", "PlainpostAccounts", "PlainpostCore", "PlainpostDB",
                "PlainpostNodeMailMode", "PlainpostNodeTransport", "PlainpostOperationRuntime",
                "PlainpostOperations", "PlainpostSecrets", "PlainpostServiceIPC", "PlainpostTestSupport",
                "PlainpostAccountProtocol",
            ]
        ),
    ]
)
