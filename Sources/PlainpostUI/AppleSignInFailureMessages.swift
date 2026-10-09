import Foundation
import PlainpostAccountRuntime

/// What a person can do when Apple issued the sign-in to another Plainpost app: after a
/// reinstall that changed the app's identity, the system's sign-in service keeps the old app
/// until it restarts.
public enum AppleSignInFailureMessages {
    public static func issuedForAnotherApp(deviceName: String) -> String {
        #if os(macOS)
        "Apple signed this in for an older Plainpost install. Log out of your Mac user account and back in (or restart this \(deviceName)), then try again."
        #else
        "Apple signed this in for an older Plainpost install. Restart this \(deviceName), then try again."
        #endif
    }

    /// `fallback` unless Apple issued the sign-in to another app.
    public static func message(for error: Error, deviceName: String, fallback: String) -> String {
        error is AppleSignInIssuedForAnotherApp ? issuedForAnotherApp(deviceName: deviceName) : fallback
    }
}
