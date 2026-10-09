import Foundation
import Security

public enum PlainpostClientCapability: String, CaseIterable, Equatable, Sendable {
    case app
    case cli
    case browserHost
    case agent
}

struct PlainpostAuditIdentity: Equatable, Sendable {
    let teamIdentifier: String
    let bundleIdentifier: String

    init(teamIdentifier: String, bundleIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

struct PlainpostAuditCodeVerifier: @unchecked Sendable {
    let copyGuestCode: @Sendable (Data) -> AnyObject?
    let createRequirement: @Sendable (String) -> AnyObject?
    let check: @Sendable (AnyObject, AnyObject) -> Bool

    init(
        copyGuestCode: @escaping @Sendable (Data) -> AnyObject?,
        createRequirement: @escaping @Sendable (String) -> AnyObject?,
        check: @escaping @Sendable (AnyObject, AnyObject) -> Bool
    ) {
        self.copyGuestCode = copyGuestCode
        self.createRequirement = createRequirement
        self.check = check
    }

    static let rejecting = Self(
        copyGuestCode: { _ in nil },
        createRequirement: { _ in nil },
        check: { _, _ in false }
    )

    #if os(macOS)
    static let live = Self(
        copyGuestCode: { auditToken in
            var guestCode: SecCode?
            let attributes = [
                kSecGuestAttributeAudit as String: auditToken
            ] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                SecCSFlags(),
                &guestCode
            ) == errSecSuccess, let guestCode else {
                return nil
            }
            return guestCode as AnyObject
        },
        createRequirement: { text in
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                text as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess, let requirement else {
                return nil
            }
            return requirement as AnyObject
        },
        check: { code, requirement in
            guard CFGetTypeID(code) == SecCodeGetTypeID(),
                  CFGetTypeID(requirement) == SecRequirementGetTypeID() else {
                return false
            }
            return SecCodeCheckValidity(
                code as! SecCode,
                SecCSFlags(),
                (requirement as! SecRequirement)
            ) == errSecSuccess
        }
    )
    #else
    static let live = rejecting
    #endif
}

public final class PlainpostClientValidator: @unchecked Sendable {
    public static let teamIdentifier = "9XN7WN8JN2"

    private static let allowedIdentities: [(PlainpostClientCapability, String)] = [
        (.app, "com.marynavdovenko.Plainpost"),
        (.cli, "com.marynavdovenko.Plainpost.CLI"),
        (.browserHost, "com.marynavdovenko.Plainpost.BrowserHost"),
        (.agent, "com.marynavdovenko.Plainpost.BackgroundAgent"),
    ]

    private let verifier: PlainpostAuditCodeVerifier

    public init() {
        verifier = .live
    }

    init(verifier: PlainpostAuditCodeVerifier) {
        self.verifier = verifier
    }

    func capability(
        for identity: PlainpostAuditIdentity
    ) -> PlainpostClientCapability? {
        guard identity.teamIdentifier == Self.teamIdentifier else {
            return nil
        }
        return Self.allowedIdentities.first {
            $0.1 == identity.bundleIdentifier
        }?.0
    }

    public func capability(
        for connection: NSXPCConnection
    ) -> PlainpostClientCapability? {
        guard let auditToken = PlainpostXPCConnectionAuditTokenBridge
            .auditTokenData(for: connection) else {
            return nil
        }
        return capability(forAuditTokenData: auditToken)
    }

    func capability(
        forAuditTokenData auditToken: Data
    ) -> PlainpostClientCapability? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size,
              let code = verifier.copyGuestCode(auditToken) else {
            return nil
        }

        var matches: [PlainpostClientCapability] = []
        for (capability, identifier) in Self.allowedIdentities {
            guard let requirement = verifier.createRequirement(
                Self.requirement(for: identifier)
            ) else {
                return nil
            }
            if verifier.check(code, requirement) {
                matches.append(capability)
            }
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    /// Whether a validated caller may invoke a restricted service method.
    /// Only the app may use the Node session broker, read the Sync Node
    /// mail-mode status or start over after a lost vault key: every other
    /// client is refused before the request reaches the service.
    public static func permits(
        _ method: PlainpostServiceMethod,
        for capability: PlainpostClientCapability
    ) -> Bool {
        switch method {
        case .performNodeSessionRequest, .invalidateNodeSession, .nodeSessionIdentityReadiness,
             .nodeMailModeStatus, .serviceIdentity, .startOverAfterVaultKeyLoss:
            return capability == .app
        }
    }

    static func requirement(for identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"9XN7WN8JN2\" and identifier \"\(identifier)\""
    }
}
