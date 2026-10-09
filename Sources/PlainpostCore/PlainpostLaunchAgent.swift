import Foundation

public struct PlainpostLaunchAgentConfiguration: Equatable, Sendable {
    public static let defaultLabel = "com.marynavdovenko.Plainpost.BackgroundAgent"

    public var label: String
    public var serviceExecutablePath: String
    public var dataDirectoryPath: String?
    public var standardOutPath: String
    public var standardErrorPath: String
    public var runAtLoad: Bool
    public var keepAlive: Bool

    public init(
        label: String = Self.defaultLabel,
        serviceExecutablePath: String,
        dataDirectoryPath: String? = nil,
        standardOutPath: String,
        standardErrorPath: String,
        runAtLoad: Bool = true,
        keepAlive: Bool = true
    ) {
        self.label = label
        self.serviceExecutablePath = serviceExecutablePath
        self.dataDirectoryPath = dataDirectoryPath
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
    }
}

public enum PlainpostLaunchAgentPlist {
    public static func data(for configuration: PlainpostLaunchAgentConfiguration) throws -> Data {
        let propertyList = try propertyList(for: configuration)
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    public static func string(for configuration: PlainpostLaunchAgentConfiguration) throws -> String {
        String(decoding: try data(for: configuration), as: UTF8.self)
    }

    public static func propertyList(for configuration: PlainpostLaunchAgentConfiguration) throws -> [String: Any] {
        try validateNonEmpty(configuration.label, field: "LaunchAgent label")
        try validateNonEmpty(configuration.serviceExecutablePath, field: "PlainpostService executable path")
        try validateNonEmpty(configuration.standardOutPath, field: "LaunchAgent standard output path")
        try validateNonEmpty(configuration.standardErrorPath, field: "LaunchAgent standard error path")

        var plist: [String: Any] = [
            "Label": configuration.label,
            "ProgramArguments": [
                configuration.serviceExecutablePath,
                "--xpc-service"
            ],
            "MachServices": [
                "com.marynavdovenko.Plainpost.Service": true
            ],
            "RunAtLoad": configuration.runAtLoad,
            "KeepAlive": configuration.keepAlive
                ? ["SuccessfulExit": false]
                : false,
            "StandardOutPath": configuration.standardOutPath,
            "StandardErrorPath": configuration.standardErrorPath,
            "ProcessType": "Background"
        ]

        if let dataDirectoryPath = configuration.dataDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dataDirectoryPath.isEmpty {
            plist["EnvironmentVariables"] = [
                "PLAINPOST_DATA_DIR": dataDirectoryPath
            ]
        }

        return plist
    }

    private static func validateNonEmpty(_ value: String, field: String) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw PlainpostError.validationFailed("\(field) is required.")
        }
    }
}

/// Restores the per-user launchd registration from the service embedded in
/// the app that is running now. Reinstalling Plainpost can replace that helper
/// after the previous registration has been stopped, so each fresh GUI launch
/// deliberately boots a new instance before the app opens the XPC connection.
public struct PlainpostPackagedServiceRestorer: Sendable {
    public static let bundledPlistName = "com.marynavdovenko.Plainpost.BackgroundAgent.plist"
    public typealias ServiceRegistrar = @Sendable () async throws -> Void

    private let appBundleURL: URL
    private let legacyPlistURL: URL?
    private let registerService: ServiceRegistrar

    public init(
        appBundleURL: URL,
        legacyPlistURL: URL? = nil,
        registerService: @escaping ServiceRegistrar
    ) {
        self.appBundleURL = appBundleURL
        self.legacyPlistURL = legacyPlistURL
        self.registerService = registerService
    }

    /// Returns false for source/test executables that do not contain the
    /// packaged service. A packaged app either restores the job or throws.
    public func restore() async throws -> Bool {
        let serviceURL = appBundleURL.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
        )
        guard FileManager.default.fileExists(atPath: serviceURL.path) else { return false }
        let values = try serviceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: serviceURL.path)
        else {
            throw PlainpostError.validationFailed("The packaged Plainpost service is invalid.")
        }
        let bundledPlistURL = appBundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(Self.bundledPlistName)"
        )
        let plistValues = try bundledPlistURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard plistValues.isRegularFile == true,
              plistValues.isSymbolicLink != true
        else { throw PlainpostError.validationFailed("The packaged Plainpost service is invalid.") }
        if let legacyPlistURL,
           FileManager.default.fileExists(atPath: legacyPlistURL.path) {
            try FileManager.default.removeItem(at: legacyPlistURL)
        }
        try await registerService()
        return true
    }
}
