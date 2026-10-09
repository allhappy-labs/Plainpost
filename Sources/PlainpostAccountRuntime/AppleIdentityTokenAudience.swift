import Foundation

/// Apple issued a Sign in with Apple token for another app than the one running.
///
/// It happens after an app at the same path changes its bundle ID (a team migration):
/// macOS's AuthKit daemon can keep the path's old app record and issue tokens for the old
/// bundle ID until it restarts (log out and back in, or restart the Mac). Central would reject
/// such a token at its audience check with no detail, so it never leaves the device.
public struct AppleSignInIssuedForAnotherApp: Error, Equatable, Sendable {
    public let issuedFor: String
    public let runningApp: String
}

public enum AppleIdentityTokenAudience {
    /// The running app's bundle ID; nil outside an app bundle (tests, command-line tools),
    /// where no check applies.
    public static var runningApp: String? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleIdentifier : nil
    }

    /// The token's `aud` claim, read without verifying the signature (Central verifies).
    public static func audience(of identityToken: String) -> String? {
        let parts = identityToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["aud"] as? String
    }

    /// Throws when Apple issued `identityToken` for an app other than `runningApp`. A token
    /// whose audience can't be read is left for Central to judge.
    public static func requireIssued(to runningApp: String?, identityToken: String) throws {
        guard let runningApp, let audience = audience(of: identityToken), audience != runningApp else { return }
        throw AppleSignInIssuedForAnotherApp(issuedFor: audience, runningApp: runningApp)
    }
}
