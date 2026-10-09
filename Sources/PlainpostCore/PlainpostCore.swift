public struct PlainpostVersion: Equatable, Sendable {
    public let name: String

    public static let current = PlainpostVersion(name: "Plainpost")
}

public struct PlainpostServiceComponentHealth: Equatable, Sendable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public struct PlainpostServiceHealth: Equatable, Sendable {
    public let name: String
    public let mode: String
    public let ipc: String
    public let approvalRequiredForSMTP: Bool
    public let localOnly: Bool
    public let components: [PlainpostServiceComponentHealth]

    public init(
        name: String = "PlainpostService",
        mode: String = "health",
        ipc: String = "pending_xpc",
        approvalRequiredForSMTP: Bool = true,
        localOnly: Bool = true,
        components: [PlainpostServiceComponentHealth]
    ) {
        self.name = name
        self.mode = mode
        self.ipc = ipc
        self.approvalRequiredForSMTP = approvalRequiredForSMTP
        self.localOnly = localOnly
        self.components = components
    }

    public static let current = PlainpostServiceHealth(
        components: [
            PlainpostServiceComponentHealth(name: "sqlite_cache", status: "ready"),
            PlainpostServiceComponentHealth(name: "keychain_credentials", status: "ready"),
            PlainpostServiceComponentHealth(name: "imap_sync", status: "ready"),
            PlainpostServiceComponentHealth(name: "smtp_approval_queue", status: "ready"),
            PlainpostServiceComponentHealth(name: "mcp_bridge", status: "ready"),
            PlainpostServiceComponentHealth(name: "audit_log", status: "ready"),
            PlainpostServiceComponentHealth(name: "local_ai", status: "ready")
        ]
    )

    public var compactJSONString: String {
        let componentsJSON = components
            .map { #"{"name":"\#($0.name)","status":"\#($0.status)"}"# }
            .joined(separator: ",")
        return #"{"ok":true,"service":{"name":"\#(name)","mode":"\#(mode)","ipc":"\#(ipc)","approval_required_for_smtp":\#(approvalRequiredForSMTP),"local_only":\#(localOnly),"components":[\#(componentsJSON)]}}"#
    }
}
