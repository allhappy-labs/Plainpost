public struct MCPToolAnnotations: Equatable, Sendable {
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
    public let idempotentHint: Bool
    public let openWorldHint: Bool

    public init(
        readOnlyHint: Bool = false,
        destructiveHint: Bool = true,
        idempotentHint: Bool = false,
        openWorldHint: Bool = true
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public static let readOnly = MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false
    )

    public static func additive(openWorld: Bool = false) -> MCPToolAnnotations {
        MCPToolAnnotations(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: openWorld
        )
    }

    public static func mutating(openWorld: Bool = false) -> MCPToolAnnotations {
        MCPToolAnnotations(
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: openWorld
        )
    }

    public var jsonObject: [String: Bool] {
        [
            "readOnlyHint": readOnlyHint,
            "destructiveHint": destructiveHint,
            "idempotentHint": idempotentHint,
            "openWorldHint": openWorldHint
        ]
    }
}

public indirect enum MCPJSONValue: Equatable, Sendable, Encodable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case object([String: MCPJSONValue])
    case array([MCPJSONValue])

    public var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var jsonObject: Any {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            value
        case .boolean(let value):
            value
        case .object(let value):
            value.mapValues(\.jsonObject)
        case .array(let value):
            value.map(\.jsonObject)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }
}

public struct MCPToolDescriptor: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: MCPJSONValue
    public let annotations: MCPToolAnnotations

    public init(
        name: String,
        description: String,
        inputSchema: MCPJSONValue = .object(["type": .string("object")]),
        annotations: MCPToolAnnotations = MCPToolAnnotations()
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

public struct MCPToolRegistry: Equatable, Sendable {
    public let tools: [MCPToolDescriptor]

    public init(tools: [MCPToolDescriptor]) {
        self.tools = tools.sorted { $0.name < $1.name }
    }

    public static let directSendWarning = "This tool never sends email directly. It only creates a pending send request that requires local user approval."

    private static let emailSearchDescription = """
    Search local cached mail through PlainpostService. Search returns conversations by default and supports phrases, AND, OR, NOT, minus exclusions, and parentheses. It returns matching metadata and snippets, but does not return message bodies. Start with people, subject, date, state, or mailbox filters before issuing a very broad body query. A scope accepts at most 64 account IDs and 256 mailbox IDs; every ID is limited to 256 UTF-8 bytes. Opaque cursors contain authenticated request and scope fingerprints rather than raw scope IDs and expire after 24 hours.

    \(MailSearchFieldRegistry.mcpGuide)
    """

    private static let emailSearchInputSchema: MCPJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .boolean(false),
        "anyOf": .array([
            .object([
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object(["pattern": .string(#"\S"#)]),
                ]),
            ]),
            .object([
                "required": .array([.string("account_ids")]),
                "properties": .object([
                    "account_ids": .object(["minItems": .integer(1)]),
                ]),
            ]),
            .object([
                "required": .array([.string("mailbox_ids")]),
                "properties": .object([
                    "mailbox_ids": .object(["minItems": .integer(1)]),
                ]),
            ]),
        ]),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "maxLength": .integer(MailSearchQueryParser.maximumQueryCharacters),
                "description": .string("Use the documented field syntax and Boolean operators. The query may be omitted or empty only with a non-empty account_ids or mailbox_ids structural scope. Prefer a focused query such as participants:\"Alex Rivera\" is:unread or date:2026-07-01..2026-07-18."),
            ]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array(MailSearchMode.allCases.map { .string($0.rawValue) }),
                "default": .string(MailSearchMode.conversations.rawValue),
                "description": .string("Return grouped conversations by default, or individual messages when explicitly needed."),
            ]),
            "account_ids": .object([
                "type": .string("array"),
                "maxItems": .integer(MailSearchScopeContract.maximumAccountCount),
                "uniqueItems": .boolean(true),
                "items": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(MailSearchScopeContract.maximumIdentifierUTF8Length),
                ]),
                "description": .string("Optional local account IDs that narrow the search scope; at most 64 unique IDs, each at most 256 UTF-8 bytes."),
            ]),
            "mailbox_ids": .object([
                "type": .string("array"),
                "maxItems": .integer(MailSearchScopeContract.maximumMailboxCount),
                "uniqueItems": .boolean(true),
                "items": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(MailSearchScopeContract.maximumIdentifierUTF8Length),
                ]),
                "description": .string("Optional local mailbox IDs that narrow the search scope; at most 256 unique IDs, each at most 256 UTF-8 bytes."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .integer(1),
                "maximum": .integer(MailSearchRequest.maximumLimit),
                "default": .integer(MailSearchRequest.defaultLimit),
                "description": .string("Maximum page size. Follow next_cursor to continue instead of increasing the limit or inferring an exact total."),
            ]),
            "cursor": .object([
                "type": .string("string"),
                "minLength": .integer(1),
                "description": .string("Opaque next_cursor from the preceding page. Pass it unchanged; restart without it if the cursor becomes stale."),
            ]),
        ]),
    ])

    public static let `default` = MCPToolRegistry(tools: [
        MCPToolDescriptor(name: "email.list_accounts", description: "List configured local mail accounts without credentials.", annotations: .readOnly),
        MCPToolDescriptor(name: "email.list_mailboxes", description: "List local cached mailboxes.", annotations: .readOnly),
        MCPToolDescriptor(
            name: "email.search",
            description: emailSearchDescription,
            inputSchema: emailSearchInputSchema,
            annotations: .readOnly
        ),
        MCPToolDescriptor(name: "email.read", description: "Read a local cached message.", annotations: .readOnly),
        MCPToolDescriptor(name: "email.read_thread", description: "Read a local cached thread summary.", annotations: .readOnly),
        MCPToolDescriptor(name: "email.smart_inbox", description: "Show local smart inbox messages.", annotations: .readOnly),
        MCPToolDescriptor(name: "email.smart_inbox_batch", description: "Run a local Smart Inbox batch action through PlainpostService. archive_read moves Inbox copies to the account's own Archive (Gmail: All Mail). This never sends email.", annotations: .mutating(openWorld: true)),
        MCPToolDescriptor(name: "email.archive", description: "Archive a local cached message or service-backed account message. When the message has copies in several mailboxes, source_mailbox (and optionally source_uid) names the one to archive. It goes to the account's own Archive (Gmail: All Mail); archive_mailbox names another folder, and \"Archive\" always means the account's own Archive. This never sends email.", annotations: .mutating(openWorld: true)),
        MCPToolDescriptor(name: "email.delete", description: "Move a message to Trash. A message already in Trash is left there (outcome already_in_trash). Only permanent: true erases, and only a message that is in Trash. When the message has copies in several mailboxes, source_mailbox (and optionally source_uid) names the one to act on. This never sends email.", annotations: .mutating(openWorld: true)),
        MCPToolDescriptor(name: "email.recategorize", description: "Request local smart category recalculation.", annotations: .mutating()),
        MCPToolDescriptor(name: "email.add_label", description: "Add a local label to a message.", annotations: .additive()),
        MCPToolDescriptor(name: "email.remove_label", description: "Remove a local label from a message.", annotations: .mutating()),
        MCPToolDescriptor(name: "email.create_draft", description: "Create a local draft.", annotations: .additive()),
        MCPToolDescriptor(name: "email.update_draft", description: "Update a local draft.", annotations: .mutating()),
        MCPToolDescriptor(name: "email.delete_draft", description: "Delete a local draft.", annotations: .mutating()),
        MCPToolDescriptor(name: "email.sync_draft", description: "Sync a local draft to the server Drafts mailbox through the local PlainpostService. No email is sent.", annotations: .additive(openWorld: true)),
        MCPToolDescriptor(name: "email.mark_seen", description: "Mark a local cached message as seen.", annotations: .mutating(openWorld: true)),
        MCPToolDescriptor(name: "email.request_send", description: "Request user-approved delivery for a local draft. \(directSendWarning)", annotations: .additive()),
        MCPToolDescriptor(name: "email.send_status", description: "Read a send request status. \(directSendWarning)", annotations: .readOnly),
        MCPToolDescriptor(name: "email.cancel_send_request", description: "Cancel a pending send request. \(directSendWarning)", annotations: .mutating())
    ])
}
