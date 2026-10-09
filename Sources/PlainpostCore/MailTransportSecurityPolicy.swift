import Foundation

public enum MailTransportSecurityPolicy {
    public static func validateCleartextHarnessHost(_ host: String) throws {
        guard isLoopback(host) else {
            throw PlainpostError.validationFailed(
                "Cleartext mail transport is only allowed for loopback test harnesses."
            )
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized.hasPrefix("127.")
    }
}
