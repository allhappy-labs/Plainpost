import XCTest
@testable import PlainpostCore

final class MCPToolRegistryTests: XCTestCase {
    func testRegistryIncludesSafeMailAndSendRequestTools() {
        let toolNames = Set(MCPToolRegistry.default.tools.map(\.name))

        XCTAssertTrue(toolNames.contains("email.search"))
        XCTAssertTrue(toolNames.contains("email.read"))
        XCTAssertFalse(toolNames.contains { $0.hasPrefix("email.ai.") })
        XCTAssertTrue(toolNames.contains("email.archive"))
        XCTAssertTrue(toolNames.contains("email.delete"))
        XCTAssertTrue(toolNames.contains("email.smart_inbox_batch"))
        XCTAssertTrue(toolNames.contains("email.create_draft"))
        XCTAssertTrue(toolNames.contains("email.sync_draft"))
        XCTAssertTrue(toolNames.contains("email.request_send"))
        XCTAssertTrue(toolNames.contains("email.send_status"))
        XCTAssertTrue(toolNames.contains("email.cancel_send_request"))
    }

    func testRegistryExcludesDirectSendAndApprovalTools() {
        let toolNames = Set(MCPToolRegistry.default.tools.map(\.name))

        XCTAssertFalse(toolNames.contains("email.send_now"))
        XCTAssertFalse(toolNames.contains("email.approve_send"))
        XCTAssertFalse(toolNames.contains("email.smtp_send"))
    }

    func testEveryToolHasDescriptionAndInputSchema() {
        for tool in MCPToolRegistry.default.tools {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) is missing a description")
            XCTAssertEqual(
                tool.inputSchema.objectValue?["type"],
                .string("object"),
                "\(tool.name) must expose an object schema"
            )
        }
    }

    func testEmailSearchSchemaIsBoundedAndAgentGuidanceIsComplete() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.default.tools.first { $0.name == "email.search" })
        let schema = try XCTUnwrap(tool.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let query = try XCTUnwrap(properties["query"]?.objectValue)
        let mode = try XCTUnwrap(properties["mode"]?.objectValue)
        let accounts = try XCTUnwrap(properties["account_ids"]?.objectValue)
        let mailboxes = try XCTUnwrap(properties["mailbox_ids"]?.objectValue)
        let limit = try XCTUnwrap(properties["limit"]?.objectValue)
        let cursor = try XCTUnwrap(properties["cursor"]?.objectValue)
        guard case .array(let alternatives) = schema["anyOf"] else {
            XCTFail("email.search must express query-or-scope alternatives")
            return
        }

        XCTAssertEqual(schema["type"], .string("object"))
        XCTAssertEqual(schema["additionalProperties"], .boolean(false))
        XCTAssertNil(schema["required"])
        XCTAssertEqual(alternatives.count, 3)
        XCTAssertEqual(
            alternatives.compactMap { $0.objectValue?["required"] },
            [
                .array([.string("query")]),
                .array([.string("account_ids")]),
                .array([.string("mailbox_ids")]),
            ]
        )
        XCTAssertEqual(query["maxLength"], .integer(MailSearchQueryParser.maximumQueryCharacters))
        XCTAssertNil(query["pattern"])
        XCTAssertEqual(
            alternatives[0].objectValue?["properties"]?.objectValue?["query"]?.objectValue?["pattern"],
            .string(#"\S"#)
        )
        XCTAssertEqual(
            alternatives[1].objectValue?["properties"]?.objectValue?["account_ids"]?.objectValue?["minItems"],
            .integer(1)
        )
        XCTAssertEqual(
            alternatives[2].objectValue?["properties"]?.objectValue?["mailbox_ids"]?.objectValue?["minItems"],
            .integer(1)
        )
        XCTAssertEqual(mode["enum"], .array(MailSearchMode.allCases.map { .string($0.rawValue) }))
        XCTAssertEqual(mode["default"], .string(MailSearchMode.conversations.rawValue))
        XCTAssertEqual(accounts["type"], .string("array"))
        XCTAssertEqual(accounts["maxItems"], .integer(MailSearchScopeContract.maximumAccountCount))
        XCTAssertEqual(accounts["uniqueItems"], .boolean(true))
        XCTAssertEqual(accounts["items"]?.objectValue?["minLength"], .integer(1))
        XCTAssertEqual(
            accounts["items"]?.objectValue?["maxLength"],
            .integer(MailSearchScopeContract.maximumIdentifierUTF8Length)
        )
        XCTAssertEqual(mailboxes["type"], .string("array"))
        XCTAssertEqual(mailboxes["maxItems"], .integer(MailSearchScopeContract.maximumMailboxCount))
        XCTAssertEqual(mailboxes["uniqueItems"], .boolean(true))
        XCTAssertEqual(mailboxes["items"]?.objectValue?["minLength"], .integer(1))
        XCTAssertEqual(
            mailboxes["items"]?.objectValue?["maxLength"],
            .integer(MailSearchScopeContract.maximumIdentifierUTF8Length)
        )
        XCTAssertEqual(limit["minimum"], .integer(1))
        XCTAssertEqual(limit["maximum"], .integer(MailSearchRequest.maximumLimit))
        XCTAssertEqual(limit["default"], .integer(MailSearchRequest.defaultLimit))
        XCTAssertEqual(cursor["type"], .string("string"))
        XCTAssertEqual(cursor["minLength"], .integer(1))
        XCTAssertEqual(tool.annotations, .readOnly)

        for field in MailSearchFieldRegistry.all {
            XCTAssertTrue(tool.description.contains("\(field.name):"), field.name)
            for example in field.examples {
                XCTAssertTrue(tool.description.contains(example), example)
            }
        }
        XCTAssertTrue(tool.description.contains("people, subject, date, state, or mailbox"))
        XCTAssertTrue(tool.description.contains("next_cursor"))
        XCTAssertTrue(tool.description.contains("does not return message bodies"))
        XCTAssertTrue(tool.description.contains("64 account IDs"))
        XCTAssertTrue(tool.description.contains("256 mailbox IDs"))
        XCTAssertTrue(tool.description.contains("256 UTF-8 bytes"))
    }

    func testReadOnlyToolsAreExplicitlyAnnotated() throws {
        for name in [
            "email.list_accounts",
            "email.list_mailboxes",
            "email.search",
            "email.read",
            "email.read_thread",
            "email.smart_inbox",
            "email.send_status"
        ] {
            let tool = try XCTUnwrap(MCPToolRegistry.default.tools.first { $0.name == name })
            XCTAssertTrue(tool.annotations.readOnlyHint, "\(name) must run without mutation approval")
            XCTAssertFalse(tool.annotations.destructiveHint, "\(name) must not be marked destructive")
        }
    }

    func testMutatingToolsAreAnnotatedAsPotentiallyDestructive() {
        let destructiveTools = Set(
            MCPToolRegistry.default.tools
                .filter(\.annotations.destructiveHint)
                .map(\.name)
        )

        XCTAssertEqual(destructiveTools, [
            "email.archive",
            "email.cancel_send_request",
            "email.delete",
            "email.delete_draft",
            "email.mark_seen",
            "email.recategorize",
            "email.remove_label",
            "email.smart_inbox_batch",
            "email.update_draft"
        ])
    }

    func testNoMutatingToolClaimsIdempotency() {
        let idempotentMutations = MCPToolRegistry.default.tools.filter {
            !$0.annotations.readOnlyHint && $0.annotations.idempotentHint
        }

        XCTAssertTrue(idempotentMutations.isEmpty)
    }

    func testSendRequestCannotSendAndIsAnnotatedAdditive() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.default.tools.first { $0.name == "email.request_send" })

        XCTAssertFalse(tool.annotations.readOnlyHint)
        XCTAssertFalse(tool.annotations.destructiveHint)
        XCTAssertTrue(tool.description.contains(MCPToolRegistry.directSendWarning))
    }

    func testSendRelatedToolsIncludeRequiredDirectSendWarning() {
        let required = "This tool never sends email directly. It only creates a pending send request that requires local user approval."
        let sendTools = MCPToolRegistry.default.tools.filter { $0.name.contains("send") }

        XCTAssertFalse(sendTools.isEmpty)
        for tool in sendTools {
            XCTAssertTrue(tool.description.contains(required), "\(tool.name) is missing required warning")
        }
    }
}
