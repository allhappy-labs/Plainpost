import PlainpostAccountRuntime
import PlainpostCore
import SwiftUI

/// Pieces of Settings that only the host app can build: the iOS Plainpost-account and Sync Node
/// pages (their models live in the iOS app target), push-notification rows, and the Node mail list.
public struct PlainpostSettingsHost: Sendable {
    public var nodeMailAccounts: [NodeMailAccount] = []
    public var plainpostAccountPage: (@MainActor () -> AnyView)?
    /// Gets the session's Node status model, so the host's page shares it rather than building
    /// a second one (which would take over the authority's status callback).
    public var syncNodePage: (@MainActor (SyncNodeSettingsViewModel?) -> AnyView)?
    public var pushNotificationRows: (@MainActor () -> AnyView)?
    public var connectPlainpostAccount: (@MainActor () -> Void)?
    public var useSyncNodeForAccount: (@MainActor (AccountID) -> Void)?
    public init() {}
}

private struct PlainpostSettingsHostKey: EnvironmentKey {
    static let defaultValue = PlainpostSettingsHost()
}

public extension EnvironmentValues {
    var plainpostSettingsHost: PlainpostSettingsHost {
        get { self[PlainpostSettingsHostKey.self] }
        set { self[PlainpostSettingsHostKey.self] = newValue }
    }
}

public extension View {
    func plainpostSettingsHost(_ host: PlainpostSettingsHost) -> some View {
        environment(\.plainpostSettingsHost, host)
    }
}
