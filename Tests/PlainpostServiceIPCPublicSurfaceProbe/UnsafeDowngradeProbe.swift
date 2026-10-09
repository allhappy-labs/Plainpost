import Foundation
import PlainpostServiceIPC

private final class DowngradeConnection:
    PlainpostServiceClientConnection,
    @unchecked Sendable
{
    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?

    func activate() {}
    func invalidate() {}

    func remoteService(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> PlainpostServiceXPCProtocol? {
        nil
    }
}

func compileUnsafeDowngradeSurface() {
    _ = PlainpostServiceClient(
        connectionFactory: { DowngradeConnection() }
    )
    _ = PlainpostClientValidator(verifier: .rejecting)
    _ = PlainpostAuditIdentity(
        teamIdentifier: "9XN7WN8JN2",
        bundleIdentifier: "com.marynavdovenko.Plainpost"
    )
}
