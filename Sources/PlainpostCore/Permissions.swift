public enum ActorKind: String, Codable, Sendable {
    case user
    case cli
    case mcpAgent
    case system
}

public struct Actor: Equatable, Codable, Sendable {
    public let id: String
    public let kind: ActorKind
    public let displayName: String
    public let permissions: AgentPermissions

    public init(id: String, kind: ActorKind, displayName: String, permissions: AgentPermissions) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.permissions = permissions
    }
}

public struct AgentPermissions: Equatable, Codable, Sendable {
    public let readBody: Bool
    public let readAttachments: Bool
    public let createDrafts: Bool
    public let requestSend: Bool
    public let addLabels: Bool
    public let recategorize: Bool
    public let markSeen: Bool
    public let useAISummary: Bool
    public let useAIDraftReply: Bool
    public let useAISemanticSearch: Bool
    public let useAIClassification: Bool
    public let sendWithoutConfirmation: Bool
    public let approveSend: Bool

    public init(
        readBody: Bool,
        readAttachments: Bool = false,
        createDrafts: Bool,
        requestSend: Bool,
        addLabels: Bool = true,
        recategorize: Bool = true,
        markSeen: Bool = true,
        useAISummary: Bool = true,
        useAIDraftReply: Bool = true,
        useAISemanticSearch: Bool = true,
        useAIClassification: Bool = true,
        sendWithoutConfirmation: Bool,
        approveSend: Bool
    ) {
        self.readBody = readBody
        self.readAttachments = readAttachments
        self.createDrafts = createDrafts
        self.requestSend = requestSend
        self.addLabels = addLabels
        self.recategorize = recategorize
        self.markSeen = markSeen
        self.useAISummary = useAISummary
        self.useAIDraftReply = useAIDraftReply
        self.useAISemanticSearch = useAISemanticSearch
        self.useAIClassification = useAIClassification
        self.sendWithoutConfirmation = sendWithoutConfirmation
        self.approveSend = approveSend
    }

    public static func agentRequested(
        readBody: Bool,
        createDrafts: Bool,
        requestSend: Bool,
        addLabels: Bool = true,
        recategorize: Bool = true,
        markSeen: Bool = true,
        useAISummary: Bool = true,
        useAIDraftReply: Bool = true,
        useAISemanticSearch: Bool = true,
        useAIClassification: Bool = true,
        sendWithoutConfirmation: Bool = false,
        approveSend: Bool = false
    ) -> AgentPermissions {
        agentRequested(
            readBody: readBody,
            readAttachments: false,
            createDrafts: createDrafts,
            requestSend: requestSend,
            addLabels: addLabels,
            recategorize: recategorize,
            markSeen: markSeen,
            useAISummary: useAISummary,
            useAIDraftReply: useAIDraftReply,
            useAISemanticSearch: useAISemanticSearch,
            useAIClassification: useAIClassification,
            sendWithoutConfirmation: sendWithoutConfirmation,
            approveSend: approveSend
        )
    }

    public static func agentRequested(
        readBody: Bool,
        readAttachments: Bool = false,
        createDrafts: Bool,
        requestSend: Bool,
        addLabels: Bool = true,
        recategorize: Bool = true,
        markSeen: Bool = true,
        useAISummary: Bool = true,
        useAIDraftReply: Bool = true,
        useAISemanticSearch: Bool = true,
        useAIClassification: Bool = true,
        sendWithoutConfirmation: Bool = false,
        approveSend: Bool = false
    ) -> AgentPermissions {
        AgentPermissions(
            readBody: readBody,
            readAttachments: readAttachments,
            createDrafts: createDrafts,
            requestSend: requestSend,
            addLabels: addLabels,
            recategorize: recategorize,
            markSeen: markSeen,
            useAISummary: useAISummary,
            useAIDraftReply: useAIDraftReply,
            useAISemanticSearch: useAISemanticSearch,
            useAIClassification: useAIClassification,
            sendWithoutConfirmation: false,
            approveSend: false
        )
    }

    public static func agentRequested(
        readBody: Bool,
        createDrafts: Bool,
        requestSend: Bool,
        addLabels: Bool = true,
        recategorize: Bool = true,
        markSeen: Bool = true,
        sendWithoutConfirmation: Bool = false,
        approveSend: Bool = false
    ) -> AgentPermissions {
        agentRequested(
            readBody: readBody,
            readAttachments: false,
            createDrafts: createDrafts,
            requestSend: requestSend,
            addLabels: addLabels,
            recategorize: recategorize,
            markSeen: markSeen,
            sendWithoutConfirmation: sendWithoutConfirmation,
            approveSend: approveSend
        )
    }

    public static func agentRequested(
        readBody: Bool,
        readAttachments: Bool = false,
        createDrafts: Bool,
        requestSend: Bool,
        addLabels: Bool = true,
        recategorize: Bool = true,
        markSeen: Bool = true,
        sendWithoutConfirmation: Bool = false,
        approveSend: Bool = false
    ) -> AgentPermissions {
        agentRequested(
            readBody: readBody,
            readAttachments: readAttachments,
            createDrafts: createDrafts,
            requestSend: requestSend,
            addLabels: addLabels,
            recategorize: recategorize,
            markSeen: markSeen,
            useAISummary: true,
            useAIDraftReply: true,
            useAISemanticSearch: true,
            useAIClassification: true,
            sendWithoutConfirmation: sendWithoutConfirmation,
            approveSend: approveSend
        )
    }

    public static let guiUser = AgentPermissions(
        readBody: true,
        readAttachments: true,
        createDrafts: true,
        requestSend: true,
        addLabels: true,
        recategorize: true,
        markSeen: true,
        useAISummary: true,
        useAIDraftReply: true,
        useAISemanticSearch: true,
        useAIClassification: true,
        sendWithoutConfirmation: false,
        approveSend: true
    )
}
