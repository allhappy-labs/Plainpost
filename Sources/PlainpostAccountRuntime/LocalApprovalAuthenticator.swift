import Foundation

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum LocalApprovalAuthenticationError: Error, Equatable, Sendable { case denied, unavailable }
public protocol LocalApprovalAuthenticating: Sendable { func authenticate(reason: String) async throws }
public struct NoopLocalApprovalAuthenticator: LocalApprovalAuthenticating { public init() {}; public func authenticate(reason: String) async throws {} }

#if canImport(LocalAuthentication)
public final class LocalAuthenticationApprovalAuthenticator: LocalApprovalAuthenticating, @unchecked Sendable {
    public init() {}
    public func authenticate(reason: String) async throws {
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw LocalApprovalAuthenticationError.unavailable }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw LocalApprovalAuthenticationError.denied }
    }
}
#endif

public enum LocalApprovalAuthenticatorFactory {
    public static func defaultAuthenticator() -> any LocalApprovalAuthenticating {
        #if canImport(LocalAuthentication)
        return LocalAuthenticationApprovalAuthenticator()
        #else
        return NoopLocalApprovalAuthenticator()
        #endif
    }
}
