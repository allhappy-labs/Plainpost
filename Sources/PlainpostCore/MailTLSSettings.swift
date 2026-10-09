import Foundation
import Security

enum MailTLSCertificateValidation {
    case systemTrust
    case disabledForLocalTesting
    case testAnchor(Data)
}

enum MailTLSSettings {
    static let minimumTLSLevel = "kCFStreamSocketSecurityLevelTLSv1_2"

    static func sslSettings(
        host: String,
        certificateValidation: MailTLSCertificateValidation
    ) -> NSDictionary {
        var settings: [String: Any] = [
            kCFStreamSSLLevel as String: minimumTLSLevel
        ]

        switch certificateValidation {
        case .systemTrust:
            settings[kCFStreamSSLPeerName as String] = host
        case .disabledForLocalTesting:
            settings[kCFStreamSSLPeerName as String] = NSNull()
            settings[kCFStreamSSLValidatesCertificateChain as String] = false
        case .testAnchor:
            // The stream must complete TLS before exposing its SecTrust. The
            // caller evaluates that trust with this explicit anchor and the
            // requested hostname before sending any authentication bytes.
            settings[kCFStreamSSLPeerName as String] = host
            settings[kCFStreamSSLValidatesCertificateChain as String] = false
        }

        return settings as NSDictionary
    }

    static func validateTestAnchor(_ certificateData: Data, host: String, input: InputStream) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let trust = input.property(forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLPeerTrust as String)) as! SecTrust?
        else { return false }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

extension SecureSMTPClient.CertificateValidation {
    var mailTLSValidation: MailTLSCertificateValidation {
        switch self {
        case .systemTrust:
            return .systemTrust
        case .disabledForLocalTesting:
            return .disabledForLocalTesting
        case .testAnchor(let certificate):
            return .testAnchor(certificate)
        }
    }
}

extension SecureIMAPClient.CertificateValidation {
    var mailTLSValidation: MailTLSCertificateValidation {
        switch self {
        case .systemTrust:
            return .systemTrust
        case .disabledForLocalTesting:
            return .disabledForLocalTesting
        case .testAnchor(let certificate):
            return .testAnchor(certificate)
        }
    }
}
