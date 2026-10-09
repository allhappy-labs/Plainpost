import Foundation

/// Whether a Sync Node serves the multi-account mail-mode routes.
/// A missing capabilities route (404) is an older Node that needs an update;
/// transport, authentication and undecodable responses are only unavailable.
public enum NodeMailModeCompatibility: Equatable, Sendable {
    case compatible(NodeSyncMailCapabilities)
    case updateRequired
    case unavailable

    public static func probe(_ client: NodeSyncClient) async -> NodeMailModeCompatibility {
        do { return .compatible(try await client.mailCapabilities()) }
        catch NodeSyncClientError.notFound { return .updateRequired }
        catch { return .unavailable }
    }
}
