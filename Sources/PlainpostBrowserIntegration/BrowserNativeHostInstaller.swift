import Darwin
import Foundation

public enum BrowserNativeHostInstallerError: Error, Equatable {
    case invalidExecutable
    case writeFailed
}

public struct BrowserNativeHostInstaller {
    public static let hostName = "com.marynavdovenko.plainpost.browser"
    public static let chromiumDirectories = [
        "Google/Chrome/NativeMessagingHosts",
        "Chromium/NativeMessagingHosts",
        "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "Microsoft Edge/NativeMessagingHosts",
        "Vivaldi/NativeMessagingHosts",
    ]
    public static let geckoDirectories = [
        "Mozilla/NativeMessagingHosts",
        "zen/NativeMessagingHosts",
    ]

    public init() {}

    public func install(executableURL: URL, homeDirectory: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: executableURL.path
        )
        guard executableURL.isFileURL,
              executableURL.baseURL == nil,
              NSString(string: executableURL.path).isAbsolutePath,
              attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BrowserNativeHostInstallerError.invalidExecutable
        }

        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        for relativeDirectory in Self.chromiumDirectories {
            try writeManifest(
                in: applicationSupport.appendingPathComponent(relativeDirectory, isDirectory: true),
                executablePath: executableURL.path,
                allowlistKey: "allowed_origins",
                allowlistValue: BrowserCallerValidator.chromiumOrigin
            )
        }
        for relativeDirectory in Self.geckoDirectories {
            try writeManifest(
                in: applicationSupport.appendingPathComponent(relativeDirectory, isDirectory: true),
                executablePath: executableURL.path,
                allowlistKey: "allowed_extensions",
                allowlistValue: BrowserCallerValidator.geckoExtensionID
            )
        }
    }

    private func writeManifest(
        in directory: URL,
        executablePath: String,
        allowlistKey: String,
        allowlistValue: String
    ) throws {
        let object: [String: Any] = [
            "name": Self.hostName,
            "description": "Plainpost browser integration",
            "path": executablePath,
            "type": "stdio",
            allowlistKey: [allowlistValue],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data([0x0A])
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let destination = directory.appendingPathComponent("\(Self.hostName).json")
        if (try? Data(contentsOf: destination)) == data {
            return
        }

        let temporary = directory.appendingPathComponent(
            ".\(Self.hostName).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw BrowserNativeHostInstallerError.writeFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
