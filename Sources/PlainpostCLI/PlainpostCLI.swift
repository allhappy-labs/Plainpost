import Darwin
import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostServiceIPC

public struct PlainpostCLI: Sendable {
    private let serviceClient: any PlainpostServiceClientProtocol
    private let stdout: @Sendable (String) -> Void
    private let stderr: @Sendable (String) -> Void
    private let mcpReadLine: @Sendable () -> String?

    public init(
        serviceClient: any PlainpostServiceClientProtocol,
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) {
        self.serviceClient = serviceClient
        self.stdout = stdout
        self.stderr = stderr
        mcpReadLine = {
            readLine(strippingNewline: true)
        }
    }

    init(
        serviceClient: any PlainpostServiceClientProtocol,
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void,
        mcpReadLine: @escaping @Sendable () -> String?
    ) {
        self.serviceClient = serviceClient
        self.stdout = stdout
        self.stderr = stderr
        self.mcpReadLine = mcpReadLine
    }

    public func run(_ arguments: [String]) async throws -> Int {
        let runner = PlainpostCLIRunner(
            arguments: arguments,
            serviceClient: serviceClient,
            mcpReadLine: mcpReadLine,
            mcpWrite: stdout
        )
        let output = await runner.run()
        if !output.isEmpty {
            stdout(output)
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let ok = object["ok"] as? Bool
        else {
            return 0
        }
        return ok ? 0 : 1
    }

    public static func run(arguments: [String]) async -> String {
        let cli = PlainpostCLIRunner(
            arguments: arguments,
            serviceClient: PlainpostServiceClient(capability: .cli),
            mcpReadLine: {
                readLine(strippingNewline: true)
            },
            mcpWrite: {
                FileHandle.standardOutput.write(Data($0.utf8))
            }
        )
        return await cli.run()
    }
}

private struct PlainpostCLIRunner {
    let arguments: [String]
    let serviceClient: any PlainpostServiceClientProtocol
    let mcpReadLine: @Sendable () -> String?
    let mcpWrite: @Sendable (String) -> Void
    let store = InMemoryMailStore.seededForStage0()

    func run() async -> String {
        do {
            if arguments.contains("--version") {
                return "\(PlainpostVersion.current.name) 0.0.0\n"
            }
            if isForbiddenCommand {
                return error("PERMISSION_DENIED", "This command is not available. Sending requires local user approval.")
            }

            switch commandKey {
            case ["vault", "status"]:
                return await vaultStatus()
            case ["vault", "unlock"]:
                return await vaultUnlock()
            case ["vault", "lock"]:
                return await vaultLock()
            case ["account", "list"]:
                return success(["accounts": store.accounts.map(accountJSON)])
            case ["account", "test"]:
                return await accountTest()
            case ["account", "add"]:
                return await accountAdd()
            case ["account", "sync"]:
                return await accountSync()
            case ["mailbox", "list"]:
                return success(["mailboxes": store.mailboxes.map(mailboxJSON)])
            case ["mail", "search"]:
                return try await mailSearch()
            case ["mail", "read"]:
                return mailRead()
            case ["mail", "thread"]:
                return mailThread()
            case ["mail", "mark-read"]:
                return await mailAction(action: "mark_read", seen: true, archived: false, deleted: false)
            case ["mail", "mark-unread"]:
                return await mailAction(action: "mark_unread", seen: false, archived: false, deleted: false)
            case ["mail", "archive"]:
                return await mailAction(action: "archive", seen: nil, archived: true, deleted: false)
            case ["mail", "delete"]:
                return await mailAction(action: "delete", seen: nil, archived: false, deleted: true)
            case ["smart-inbox", "show"]:
                return smartInbox()
            case ["smart-inbox", "batch"]:
                return await smartInboxBatch()
            case ["smart-inbox", "recategorize"]:
                return smartInboxRecategorize()
            case ["label", "list"]:
                return labelList()
            case ["label", "add"]:
                return labelAdd()
            case ["label", "remove"]:
                return labelRemove()
            case ["draft", "create"]:
                return try draftCreate()
            case ["draft", "update"]:
                return draftUpdate()
            case ["draft", "delete"]:
                return draftDelete()
            case ["draft", "sync"]:
                return await draftSync()
            case ["send", "request"]:
                if arguments.contains("--help") || arguments.contains("-h") {
                    return sendRequestHelp
                }
                return try sendRequest()
            case ["send", "status"]:
                return try sendStatus()
            case ["send", "cancel"]:
                return try sendCancel()
            case ["service", "launch-agent"]:
                return try serviceLaunchAgent()
            case ["mcp", "serve"]:
                return await mcpServe()
            default:
                return error("VALIDATION_FAILED", "Unsupported command.")
            }
        } catch let mailError as PlainpostError {
            return error(mailError.code, mailError.message)
        } catch {
            return self.error("VALIDATION_FAILED", "\(error)")
        }
    }

    private var commandKey: [String] {
        Array(arguments.filter { !$0.hasPrefix("--") && !$0.hasPrefix("-") }.prefix(2))
    }

    private var isForbiddenCommand: Bool {
        arguments.starts(with: ["send", "now"])
            || arguments.contains("--yes")
            || arguments.starts(with: ["approval", "approve"])
            || arguments.starts(with: ["approve", "send"])
    }

    private func vaultStatus() async -> String {
        do {
            let status = try await serviceClient.status()
            return success([
                "availability": vaultAvailabilityJSON(status.availability),
                "matching_key_item_count": status.matchingKeyItemCount,
            ])
        } catch {
            return serviceError(error)
        }
    }

    private func vaultUnlock() async -> String {
        do {
            try await serviceClient.unlock(
                reason: "Unlock Plainpost for this service session"
            )
            return success(["availability": "unlocked"])
        } catch {
            return serviceError(error)
        }
    }

    private func vaultLock() async -> String {
        do {
            try await serviceClient.lock()
            return success(["availability": "locked"])
        } catch {
            return serviceError(error)
        }
    }

    private func accountTest() async -> String {
        guard
            let imapHost = value(after: "--imap-host"),
            let imapPort = UInt16(value(after: "--imap-port") ?? ""),
            let smtpHost = value(after: "--smtp-host"),
            let smtpPort = Int(value(after: "--smtp-port") ?? ""),
            let username = value(after: "--username"),
            let imapPassword =
                value(after: "--imap-password")
                    ?? value(after: "--password"),
            let smtpPassword =
                value(after: "--smtp-password")
                    ?? value(after: "--password")
        else {
            return error("VALIDATION_FAILED", "Missing account test connection arguments.")
        }

        do {
            let operation = PlainpostForegroundOperation.accountTest(
                PlainpostAccountSetupPayload(
                    displayName: value(after: "--display-name") ?? username,
                    email: value(after: "--email") ?? username,
                    imapHost: imapHost,
                    imapPort: imapPort,
                    smtpHost: smtpHost,
                    smtpPort: smtpPort,
                    username: username,
                    sentMailbox: value(after: "--sent-mailbox") ?? "Sent",
                    imapPassword: imapPassword,
                    smtpPassword: smtpPassword
                )
            )
            guard case .accountTest(let result) =
                try await serviceClient.perform(operation)
            else {
                return error(
                    "SERVICE_UNAVAILABLE",
                    "PlainpostService returned an unexpected account test result."
                )
            }
            return success([
                "service": "PlainpostService",
                "action": "account_test",
                "imap": result.isIMAPVerified,
                "smtp": result.isSMTPVerified,
            ])
        } catch {
            return serviceError(error)
        }
    }

    private func accountAdd() async -> String {
        guard
            let displayName = value(after: "--display-name"),
            let email = value(after: "--email"),
            let imapHost = value(after: "--imap-host"),
            let imapPort = UInt16(value(after: "--imap-port") ?? ""),
            let smtpHost = value(after: "--smtp-host"),
            let smtpPort = Int(value(after: "--smtp-port") ?? ""),
            let username = value(after: "--username"),
            let imapPassword =
                value(after: "--imap-password")
                    ?? value(after: "--password"),
            let smtpPassword =
                value(after: "--smtp-password")
                    ?? value(after: "--password")
        else {
            return error("VALIDATION_FAILED", "Missing account add arguments.")
        }

        do {
            guard case .accountAdd(let result) =
                try await serviceClient.perform(
                    .accountAdd(
                        PlainpostAccountSetupPayload(
                            displayName: displayName,
                            email: email,
                            imapHost: imapHost,
                            imapPort: imapPort,
                            smtpHost: smtpHost,
                            smtpPort: smtpPort,
                            username: username,
                            sentMailbox:
                                value(after: "--sent-mailbox") ?? "Sent",
                            imapPassword: imapPassword,
                            smtpPassword: smtpPassword
                        )
                    )
                )
            else {
                return error(
                    "SERVICE_UNAVAILABLE",
                    "PlainpostService returned an unexpected account add result."
                )
            }
            return success([
                "service": "PlainpostService",
                "action": "account_add",
                "account_id": result.accountID,
                "email": result.email,
                "imap_verified": result.isIMAPVerified,
                "smtp_verified": result.isSMTPVerified,
                "synced_message_count": result.syncedMessageCount,
            ])
        } catch {
            return serviceError(error)
        }
    }

    private func accountSync() async -> String {
        guard let account = positional(after: ["account", "sync"]) else {
            return error("VALIDATION_FAILED", "Missing account sync account.")
        }

        do {
            let result = try await serviceClient.perform(
                .inboxSync(
                    PlainpostInboxSyncInput(
                        accountID: AccountID(account),
                        trigger: .manual
                    )
                )
            )
            guard case .inboxSync(let sync) = result else {
                return error(
                    "SERVICE_UNAVAILABLE",
                    "PlainpostService returned an unexpected account sync result."
                )
            }
            return success([
                "service": "PlainpostService",
                "action": "sync_inbox",
                "account": sync.accountID.rawValue,
                "synced_message_count": sync.syncedMessageCount,
                "newly_discovered_message_count":
                    sync.newlyDiscoveredMessageCount,
                "message_ids":
                    sync.newMessageIDs.map(\.rawValue),
                "mailboxes": sync.mailboxes.map {
                    ["path": $0.path]
                },
                "messages": sync.messages.map {
                    [
                        "message_id": $0.messageID.rawValue,
                        "subject": $0.subject,
                        "preview": $0.preview,
                        "path": $0.path,
                    ]
                },
                "job_id": sync.jobID,
            ])
        } catch {
            return serviceError(error)
        }
    }

    private func mailSearch() async throws -> String {
        if arguments.contains("--help") || arguments.contains("-h") {
            return mailSearchHelp
        }

        let options = try mailSearchOptions()
        let request = MailSearchRequest(
            query: options.query,
            scope: MailSearchSelectionScope(
                accountIDs: options.accountIDs,
                mailboxIDs: options.mailboxIDs
            ),
            mode: options.mode,
            limit: options.limit,
            cursor: options.cursor
        )
        do {
            try request.validate()
        } catch MailSearchError.invalidQuery(let reason, _) {
            throw PlainpostError.validationFailed(reason)
        } catch {
            throw PlainpostError.validationFailed(
                "Mail search accepts at most \(MailSearchScopeContract.maximumAccountCount) unique account IDs and \(MailSearchScopeContract.maximumMailboxCount) unique mailbox IDs; each ID is limited to \(MailSearchScopeContract.maximumIdentifierUTF8Length) UTF-8 bytes."
            )
        }
        do {
            let response = try await localMailSearch(request)
            let data = try MailSearchJSON.encoder().encode(response)
            guard
                let payload = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                throw MailSearchError.unavailable
            }
            if options.json {
                return success(payload)
            }
            return humanMailSearchOutput(response)
        } catch let searchError as MailSearchError {
            return mailSearchError(searchError)
        } catch {
            return self.error("SEARCH_UNAVAILABLE", "Mail search is unavailable.")
        }
    }

    private func localMailSearch(
        _ request: MailSearchRequest
    ) async throws -> MailSearchResponse {
        let (sqliteStore, databasePath) = try sqliteStoreForSearch()
        return try await SQLiteMailSearchService(
            store: sqliteStore,
            databasePath: databasePath
        ).search(request)
    }

    private func mailSearchOptions() throws -> MailSearchCLIOptions {
        guard arguments.count > 2 else {
            throw PlainpostError.validationFailed("Mail search requires one positional QUERY.")
        }
        let query = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !arguments[2].hasPrefix("--") else {
            throw PlainpostError.validationFailed("Mail search requires one positional QUERY immediately after 'mail search'.")
        }

        var accountIDs: [AccountID] = []
        var mailboxIDs: [MailboxID] = []
        var mode = MailSearchMode.conversations
        var limit = MailSearchRequest.defaultLimit
        var cursor: MailSearchCursor?
        var json = false
        var seenMode = false
        var seenLimit = false
        var seenCursor = false
        var seenJSON = false
        var index = 3

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--account", "--mailbox", "--mode", "--limit", "--cursor":
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--"),
                      !arguments[valueIndex].isEmpty
                else {
                    throw PlainpostError.validationFailed("Mail search option \(argument) requires a value.")
                }
                let optionValue = arguments[valueIndex]
                switch argument {
                case "--account":
                    accountIDs.append(AccountID(optionValue))
                case "--mailbox":
                    mailboxIDs.append(MailboxID(optionValue))
                case "--mode":
                    guard !seenMode, let parsedMode = MailSearchMode(rawValue: optionValue) else {
                        throw PlainpostError.validationFailed("Mail search mode must be conversations or messages.")
                    }
                    seenMode = true
                    mode = parsedMode
                case "--limit":
                    guard !seenLimit,
                          let parsedLimit = Int(optionValue),
                          (1...MailSearchRequest.maximumLimit).contains(parsedLimit)
                    else {
                        throw PlainpostError.validationFailed("Mail search limit must be an integer from 1 through 100.")
                    }
                    seenLimit = true
                    limit = parsedLimit
                case "--cursor":
                    guard !seenCursor else {
                        throw PlainpostError.validationFailed("Mail search accepts only one cursor.")
                    }
                    seenCursor = true
                    cursor = MailSearchCursor(rawValue: optionValue)
                default:
                    break
                }
                index += 2
            case "--json":
                guard !seenJSON else {
                    throw PlainpostError.validationFailed("Mail search accepts --json only once.")
                }
                seenJSON = true
                json = true
                index += 1
            default:
                throw PlainpostError.validationFailed("Unknown mail search argument: \(argument).")
            }
        }

        return MailSearchCLIOptions(
            query: query,
            accountIDs: accountIDs,
            mailboxIDs: mailboxIDs,
            mode: mode,
            limit: limit,
            cursor: cursor,
            json: json
        )
    }

    private func humanMailSearchOutput(_ response: MailSearchResponse) -> String {
        var lines = ["Mode: \(response.mode.rawValue.capitalized)"]
        for (offset, hit) in response.hits.enumerated() {
            switch hit {
            case .conversation(let conversation):
                let count = "\(conversation.matchingMessageCount)/\(conversation.totalMessageCount) matching messages"
                let content = [
                    humanSearchText(conversation.subject, fallback: "(no subject)"),
                    humanSearchText(conversation.participants.joined(separator: ", "), fallback: "unknown participants"),
                    humanSearchText(conversation.snippet.text, fallback: "no preview"),
                ].joined(separator: " — ")
                let availableContentLength = max(1, 240 - count.count - 8)
                lines.append(
                    "\(offset + 1). \(boundedHumanSearchText(content, maximum: availableContentLength)) — \(count)"
                )
            case .message(let message):
                let sender = message.senderDisplayName.map { "\($0) <\(message.sender.rawValue)>" }
                    ?? message.sender.rawValue
                let content = [
                    humanSearchText(message.subject, fallback: "(no subject)"),
                    humanSearchText(sender, fallback: "unknown sender"),
                    humanSearchText(message.snippet.text, fallback: "no preview"),
                ].joined(separator: " — ")
                let prefix = "\(offset + 1). "
                lines.append(
                    prefix + boundedHumanSearchText(content, maximum: 240 - prefix.count)
                )
            }
        }
        if let nextCursor = response.nextCursor {
            lines.append("Next cursor: \(nextCursor.rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func humanSearchText(_ value: String, fallback: String) -> String {
        let withoutControls = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(withoutControls))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? fallback : normalized
    }

    private func boundedHumanSearchText(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum - 1)) + "…"
    }

    private func mailRead() -> String {
        guard let messageID = positional(after: ["mail", "read"]),
              let message = store.messages.first(where: { $0.id.rawValue == messageID })
        else {
            return error("MESSAGE_NOT_FOUND", "Message not found.")
        }
        let include = value(after: "--include") ?? "headers"
        var payload = messageJSON(message)
        if include == "body" {
            do {
                try MessageReadPolicy.validateBodyRead(actor: cliActor)
                payload["body"] = message.body
            } catch let mailError as PlainpostError {
                return error(mailError.code, mailError.message)
            } catch {
                return self.error("PERMISSION_DENIED", "\(error)")
            }
        } else if include == "attachments" {
            do {
                try MessageReadPolicy.validateAttachmentRead(actor: cliActor)
                payload["attachments"] = []
            } catch let mailError as PlainpostError {
                return error(mailError.code, mailError.message)
            } catch {
                return self.error("PERMISSION_DENIED", "\(error)")
            }
        } else {
            payload["headers"] = [
                "from": message.from.rawValue,
                "subject": message.subject
            ]
        }
        return success(["message": payload])
    }

    private func mailThread() -> String {
        guard let threadID = positional(after: ["mail", "thread"]),
              let thread = store.threads.first(where: { $0.id.rawValue == threadID })
        else {
            return error("THREAD_NOT_FOUND", "Thread not found.")
        }
        return success([
            "thread": [
                "id": thread.id.rawValue,
                "subject": thread.subjectNormalized.capitalized,
                "participants": thread.participantEmails.map(\.rawValue),
                "message_ids": store.messages.filter { $0.threadID == thread.id }.map { $0.id.rawValue }
            ]
        ])
    }

    private func mailAction(
        action: String,
        seen: Bool?,
        archived: Bool,
        deleted: Bool
    ) async -> String {
        guard let messageID = positional(after: ["mail", action.replacingOccurrences(of: "_", with: "-")]),
              !messageID.isEmpty
        else {
            return error("MESSAGE_NOT_FOUND", "Message not found.")
        }
        do {
            let input = PlainpostMailActionPayload(
                messageID: messageID,
                archiveMailbox: action == "archive"
                    ? value(after: "--archive-mailbox") ?? "Archive"
                    : nil,
                // Erasing needs the explicit flag; a plain delete only moves to Trash.
                permanent: action == "delete" && arguments.contains("--permanent"),
                // The copy to act on, when the message is in several mailboxes.
                sourceMailbox: action == "archive" || action == "delete" ? value(after: "--source-mailbox") : nil,
                sourceUID: action == "archive" || action == "delete" ? value(after: "--source-uid").flatMap { Int($0) } : nil
            )
            let operation: PlainpostForegroundOperation
            switch action {
            case "mark_read":
                operation = .markRead(input)
            case "mark_unread":
                operation = .markUnread(input)
            case "archive":
                operation = .archive(input)
            case "delete":
                operation = .delete(input)
            default:
                return error("VALIDATION_FAILED", "Unsupported mail action.")
            }
            let result = try await serviceClient.perform(operation)
            let actionResult: PlainpostMailActionSemanticResult
            switch result {
            case .markRead(let value), .markUnread(let value),
                 .archive(let value), .delete(let value):
                actionResult = value
            default:
                return error(
                    "SERVICE_UNAVAILABLE",
                    "PlainpostService returned an unexpected mail action result."
                )
            }
            var payload: [String: Any] = [
                "service": "PlainpostService",
                "message_id": actionResult.messageID,
                "action": action,
                "deleted": actionResult.isDeleted,
            ]
            if let seen = actionResult.seen {
                payload["seen"] = seen
            }
            if let mailboxPath = actionResult.mailboxPath {
                payload["mailbox"] = mailboxPath
            }
            if archived {
                payload["archived"] = true
            }
            if deleted {
                PlainpostCLIDeleteReply.describe(actionResult, into: &payload)
            }
            return success(payload)
        } catch {
            return serviceError(error)
        }
    }

    private func smartInbox() -> String {
        let category = value(after: "--category")
        let messages = store.messages.filter { message in
            guard let category else { return true }
            if category == "seen" { return false }
            return message.smartCategory.rawValue == category
        }
        return success([
            "category": category ?? "all",
            "messages": messages.map(messageJSON)
        ])
    }

    private func smartInboxBatch() async -> String {
        guard let rawCategory = positional(after: ["smart-inbox", "batch"]) else {
            return error("VALIDATION_FAILED", "Missing Smart Inbox category.")
        }
        guard let category = SmartInboxBatchCategory(argument: rawCategory) else {
            return error("VALIDATION_FAILED", "Unsupported Smart Inbox category.")
        }
        guard let action = SmartInboxBatchAction(argument: value(after: "--action") ?? "") else {
            return error("VALIDATION_FAILED", "Unsupported Smart Inbox batch action.")
        }

        if let accountID = value(after: "--account") {
            do {
                let result = try await serviceClient.performSmartInboxBatch(
                    PlainpostSmartInboxBatchRequest(
                        accountID: accountID,
                        category: category.rawValue,
                        action: action.rawValue,
                        archiveMailbox:
                            value(after: "--archive-mailbox") ?? "Archive"
                    )
                )
                return success([
                    "service": "PlainpostService",
                    "action": "smart_inbox_batch",
                    "category": result.category,
                    "requested_action": result.action,
                    "message_ids": result.affectedMessageIDs,
                    "affected_count": result.affectedMessageIDs.count,
                    "mailbox": result.archiveMailbox,
                ])
            } catch {
                return serviceError(error)
            }
        }

        seedSmartInboxBatchMessagesIfNeeded()
        do {
            let service = SmartInboxBatchService(store: store)
            let result = try await service.run(
                SmartInboxBatchRequest(category: category, action: action),
                actor: cliActor
            )
            return success([
                "category": result.category.rawValue,
                "action": result.action.rawValue,
                "message_ids": result.affectedMessageIDs.map { $0.rawValue },
                "affected_count": result.affectedCount,
                "mailbox": result.archiveMailbox
            ])
        } catch let mailError as PlainpostError {
            return error(mailError.code, mailError.message)
        } catch {
            return self.error("VALIDATION_FAILED", "\(error)")
        }
    }

    private func smartInboxRecategorize() -> String {
        guard let messageID = positional(after: ["smart-inbox", "recategorize"]),
              let categoryValue = value(after: "--category"),
              let category = SmartCategory(rawValue: categoryValue)
        else {
            return error("VALIDATION_FAILED", "Missing message id or category.")
        }

        do {
            let message = try store.recategorize(MessageID(messageID), as: category, actor: cliActor)
            return success(["message_id": message.id.rawValue, "category": message.smartCategory.rawValue])
        } catch let mailError as PlainpostError {
            return error(mailError.code, mailError.message)
        } catch {
            return self.error("VALIDATION_FAILED", "\(error)")
        }
    }

    private func labelList() -> String {
        let labels = Array(Set(store.messages.flatMap(\.labels))).sorted()
        return success(["labels": labels])
    }

    private func labelAdd() -> String {
        guard let messageID = positional(after: ["label", "add"]),
              arguments.count > 3
        else {
            return error("VALIDATION_FAILED", "Missing message id or label.")
        }

        return mutateLabel(messageID: messageID, label: arguments[3], adding: true)
    }

    private func labelRemove() -> String {
        guard let messageID = positional(after: ["label", "remove"]),
              arguments.count > 3
        else {
            return error("VALIDATION_FAILED", "Missing message id or label.")
        }

        return mutateLabel(messageID: messageID, label: arguments[3], adding: false)
    }

    private func mutateLabel(messageID: String, label: String, adding: Bool) -> String {
        do {
            let message = adding
                ? try store.addLabel(label, to: MessageID(messageID), actor: cliActor)
                : try store.removeLabel(label, from: MessageID(messageID), actor: cliActor)
            return success(["message_id": message.id.rawValue, "labels": message.labels])
        } catch let mailError as PlainpostError {
            return error(mailError.code, mailError.message)
        } catch {
            return self.error("VALIDATION_FAILED", "\(error)")
        }
    }

    private func draftCreate() throws -> String {
        guard let to = value(after: "--to"),
              let subject = value(after: "--subject"),
              let bodyFile = value(after: "--body-file")
        else {
            return error("VALIDATION_FAILED", "Missing draft fields.")
        }
        let body = try String(contentsOfFile: bodyFile, encoding: .utf8)
        let draft = Draft(
            id: DraftID("drf_cli_1"),
            accountID: AccountID(value(after: "--account") ?? "acc_personal"),
            from: EmailAddress(value(after: "--from") ?? "me@example.com"),
            to: [EmailAddress(to)],
            cc: [],
            bcc: [],
            subject: subject,
            bodyPlain: body,
            createdBy: "cli",
            aiGenerated: false,
            sourceThreadID: nil
        )
        let created: Draft
        if let sqliteStore = try sqliteStoreIfRequested() {
            created = try sqliteStore.createDraft(draft, actor: cliActor)
        } else {
            created = try store.createDraft(draft, actor: cliActor)
        }
        return success(["draft_id": created.id.rawValue, "content_hash": created.contentHash])
    }

    private func draftUpdate() -> String {
        guard let draftID = positional(after: ["draft", "update"]) else {
            return error("DRAFT_NOT_FOUND", "Draft not found.")
        }
        guard draftID == PlainpostCLISeed.replyDraft.id.rawValue else {
            return error("DRAFT_NOT_FOUND", "Draft not found.")
        }

        let updated = PlainpostCLISeed.replyDraft.applying(
            DraftPatch(
                subject: value(after: "--subject"),
                bodyPlain: value(after: "--body")
            )
        )
        return success([
            "draft_id": updated.id.rawValue,
            "subject": updated.subject,
            "content_hash": updated.contentHash,
            "sent": false
        ])
    }

    private func draftDelete() -> String {
        guard let draftID = positional(after: ["draft", "delete"]) else {
            return error("DRAFT_NOT_FOUND", "Draft not found.")
        }
        guard draftID == PlainpostCLISeed.replyDraft.id.rawValue else {
            return error("DRAFT_NOT_FOUND", "Draft not found.")
        }
        return success(["draft_id": draftID, "status": "deleted"])
    }

    private func draftSync() async -> String {
        guard
            arguments.contains("--to-server"),
            let draftID = positional(after: ["draft", "sync"])
        else {
            return error("VALIDATION_FAILED", "Missing draft sync arguments.")
        }

        do {
            let mailbox = value(after: "--drafts-mailbox") ?? "Drafts"
            let result = try await serviceClient.syncDraftToServer(
                draftID: draftID,
                mailbox: mailbox
            )
            var payload: [String: Any] = [
                "service": "PlainpostService",
                "action": "draft_sync",
                "draft_id": result.draftID,
                "mailbox": result.mailbox,
                "server_draft_mailbox_id": result.mailbox,
                "synced_to_server": true,
            ]
            payload["server_draft_uid"] =
                result.serverDraftUID ?? NSNull()
            return success(payload)
        } catch {
            return serviceError(error)
        }
    }

    private func sendRequest() throws -> String {
        let agent = value(after: "--agent") ?? "cli"
        let actor = Actor(
            id: agent,
            kind: .cli,
            displayName: agent,
            permissions: .agentRequested(
                readBody: agentReadBodyAllowed,
                readAttachments: agentReadAttachmentsAllowed,
                createDrafts: agentCreateDraftsAllowed,
                requestSend: agentRequestSendAllowed
            )
        )
        if let draftID = value(after: "--draft") {
            if let sqliteStore = try sqliteStoreIfRequested() {
                let request = try sqliteStore.requestSend(
                    draftID: DraftID(draftID),
                    actor: actor,
                    reason: value(after: "--reason")
                )
                return success([
                    "request_id": request.id.rawValue,
                    "status": request.status.rawValue
                ])
            }
            guard draftID == PlainpostCLISeed.replyDraft.id.rawValue else {
                return error("DRAFT_NOT_FOUND", "Draft not found.")
            }
            _ = try ensureReplyDraftInStore()
            let request = try store.requestSend(
                draftID: PlainpostCLISeed.replyDraft.id,
                actor: actor,
                reason: value(after: "--reason")
            )
            return success([
                "request_id": request.id.rawValue,
                "status": request.status.rawValue
            ])
        }

        guard
            let account = value(after: "--account"),
            let from = value(after: "--from"),
            let to = value(after: "--to"),
            let subject = value(after: "--subject"),
            let bodyFile = value(after: "--body-file")
        else {
            return error("DRAFT_NOT_FOUND", "Draft not found.")
        }
        let body = try String(contentsOfFile: bodyFile, encoding: .utf8)
        let draft = Draft(
            id: DraftID("drf_\(UUID().uuidString.lowercased())"),
            accountID: AccountID(account),
            from: EmailAddress(from),
            to: to.split(separator: ",").map {
                EmailAddress($0.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            cc: [],
            bcc: [],
            subject: subject,
            bodyPlain: body,
            createdBy: agent,
            aiGenerated: false,
            sourceThreadID: nil
        )
        if let sqliteStore = try sqliteStoreIfRequested() {
            let created = try sqliteStore.createDraft(draft, actor: actor)
            let request = try sqliteStore.requestSend(
                draftID: created.id,
                actor: actor,
                reason: value(after: "--reason")
            )
            return success([
                "request_id": request.id.rawValue,
                "status": request.status.rawValue
            ])
        }
        let created = try store.createDraft(draft, actor: actor)
        let request = try store.requestSend(
            draftID: created.id,
            actor: actor,
            reason: value(after: "--reason")
        )
        return success([
            "request_id": request.id.rawValue,
            "status": request.status.rawValue
        ])
    }

    private func sendStatus() throws -> String {
        guard let requestID = positional(after: ["send", "status"]) else {
            return error("VALIDATION_FAILED", "Missing request id.")
        }
        if let sqliteStore = try sqliteStoreIfRequested() {
            return success(sendRequestJSON(try sqliteStore.sendRequest(id: SendRequestID(requestID))))
        }
        let request = try sendRequestForRead(requestID: SendRequestID(requestID))
        return success(sendRequestJSON(request))
    }

    private func sendCancel() throws -> String {
        guard let requestID = positional(after: ["send", "cancel"]) else {
            return error("VALIDATION_FAILED", "Missing request id.")
        }
        if let sqliteStore = try sqliteStoreIfRequested() {
            let request = try sqliteStore.cancelSendRequest(id: SendRequestID(requestID), actor: cliActor)
            return success(sendRequestJSON(request))
        }
        try seedDefaultSendRequestIfNeeded(requestID: SendRequestID(requestID), actor: cliActor)
        let request = try store.cancelSendRequest(id: SendRequestID(requestID), actor: cliActor)
        return success(sendRequestJSON(request))
    }

    private func mcpServe() async -> String {
        if arguments.contains("--schema") {
            return success([
                "protocol": "mcp",
                "tools": MCPToolRegistry.default.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": tool.inputSchema.jsonObject,
                        "annotations": tool.annotations.jsonObject
                    ] as [String: Any]
                }
            ])
        }

        return await awaitMCPStdio()
    }

    private func awaitMCPStdio() async -> String {
        while let line = mcpReadLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let response = await handleMCPRequestLine(line)
            mcpWrite(response)
        }
        return ""
    }

    private func handleMCPRequestLine(_ line: String) async -> String {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else {
            return encode(mcpError(id: nil, code: -32700, message: "Parse error."))
        }

        let id = object["id"]
        switch method {
        case "initialize":
            return encode(mcpResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "serverInfo": ["name": "Plainpost", "version": "0.0.0"],
                "capabilities": ["tools": [:], "resources": [:]]
            ]))
        case "tools/list":
            return encode(mcpResult(id: id, result: [
                "tools": MCPToolRegistry.default.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema.jsonObject,
                        "annotations": tool.annotations.jsonObject
                    ] as [String: Any]
                }
            ]))
        case "resources/list":
            return encode(mcpResult(id: id, result: [
                "resources": mcpResources()
            ]))
        case "resources/read":
            guard
                let params = object["params"] as? [String: Any],
                let uri = params["uri"] as? String
            else {
                return encode(mcpError(id: id, code: -32602, message: "Invalid resource read parameters."))
            }
            return handleMCPResourceRead(id: id, uri: uri)
        case "tools/call":
            guard
                let params = object["params"] as? [String: Any],
                let name = params["name"] as? String
            else {
                return encode(mcpError(id: id, code: -32602, message: "Invalid tool call parameters."))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return await handleMCPToolCall(
                id: id,
                name: name,
                arguments: arguments
            )
        default:
            return encode(mcpError(id: id, code: -32601, message: "Unsupported MCP method."))
        }
    }

    private func handleMCPToolCall(
        id: Any?,
        name: String,
        arguments: [String: Any]
    ) async -> String {
        let payload: [String: Any]?
        switch name {
        case "email.list_accounts":
            payload = ["accounts": store.accounts.map(accountJSON)]
        case "email.list_mailboxes":
            payload = ["mailboxes": store.mailboxes.map(mailboxJSON)]
        case "email.search":
            do {
                payload = try await mcpMailSearch(arguments: arguments)
            } catch let error as MCPMailSearchInvocationError {
                return encode(mcpError(
                    id: id,
                    code: error.jsonRPCCode,
                    message: error.safeMessage
                ))
            } catch {
                return encode(mcpError(
                    id: id,
                    code: -32003,
                    message: "Mail search is unavailable."
                ))
            }
        case "email.read":
            do {
                payload = try mcpMailRead(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.read_thread":
            payload = mcpReadThread(arguments: arguments)
        case "email.smart_inbox":
            payload = mcpSmartInbox(arguments: arguments)
        case "email.smart_inbox_batch":
            do {
                payload = try await mcpSmartInboxBatch(arguments: arguments)
            } catch let serviceError as PlainpostServiceClientError {
                return mcpServiceError(id: id, error: serviceError)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.add_label":
            do {
                payload = try mcpAddLabel(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.remove_label":
            do {
                payload = try mcpRemoveLabel(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.mark_seen":
            do {
                payload = try await mcpMarkSeen(
                    arguments: arguments
                )
            } catch let serviceError as PlainpostServiceClientError {
                return mcpServiceError(id: id, error: serviceError)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.archive":
            do {
                payload = try await mcpMailboxAction(
                    action: "archive",
                    arguments: arguments
                )
            } catch let serviceError as PlainpostServiceClientError {
                return mcpServiceError(id: id, error: serviceError)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.delete":
            do {
                payload = try await mcpMailboxAction(
                    action: "delete",
                    arguments: arguments
                )
            } catch let serviceError as PlainpostServiceClientError {
                return mcpServiceError(id: id, error: serviceError)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.recategorize":
            do {
                payload = try mcpRecategorize(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.create_draft":
            do {
                payload = try mcpCreateDraft(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.update_draft":
            do {
                payload = try mcpUpdateDraft(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.delete_draft":
            do {
                payload = try mcpDeleteDraft(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.sync_draft":
            do {
                payload = try await mcpSyncDraft(
                    arguments: arguments
                )
            } catch let serviceError as PlainpostServiceClientError {
                return mcpServiceError(id: id, error: serviceError)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.request_send":
            do {
                payload = try mcpRequestSend(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.send_status":
            do {
                payload = try mcpSendStatus(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.cancel_send_request":
            do {
                payload = try mcpCancelSendRequest(arguments: arguments)
            } catch let mailError as PlainpostError {
                return encode(mcpError(id: id, code: -32003, message: mailError.message))
            } catch {
                return encode(mcpError(id: id, code: -32003, message: "\(error)"))
            }
        case "email.send_now", "email.approve_send", "email.smtp_send":
            return encode(mcpError(id: id, code: -32601, message: "Tool is not available. Sending requires local user approval."))
        default:
            return encode(mcpError(id: id, code: -32601, message: "Unknown MCP tool."))
        }

        guard let payload else {
            return encode(mcpError(id: id, code: -32602, message: "Tool arguments did not match local data."))
        }
        return encode(mcpResult(id: id, result: [
            "content": [
                [
                    "type": "text",
                    "text": encode(payload).trimmingCharacters(in: .newlines)
                ]
            ],
            "structuredContent": payload
        ]))
    }

    private func handleMCPResourceRead(id: Any?, uri: String) -> String {
        let payload: [String: Any]?
        do {
            payload = try mcpResourcePayload(uri: uri)
        } catch let mailError as PlainpostError {
            return encode(mcpError(id: id, code: -32003, message: mailError.message))
        } catch {
            return encode(mcpError(id: id, code: -32003, message: "\(error)"))
        }
        guard let payload else {
            return encode(mcpError(id: id, code: -32002, message: "Resource not found."))
        }
        return encode(mcpResult(id: id, result: [
            "contents": [
                [
                    "uri": uri,
                    "mimeType": "application/json",
                    "text": encode(payload).trimmingCharacters(in: .newlines)
                ]
            ],
            "structuredContent": payload
        ]))
    }

    private func mcpResources() -> [[String: Any]] {
        let messageResources = store.messages.map { message in
            [
                "uri": "email://message/\(message.id.rawValue)",
                "name": message.subject,
                "description": "Local cached email message.",
                "mimeType": "application/json"
            ] as [String: Any]
        }
        let threadResources = store.threads.map { thread in
            [
                "uri": "email://thread/\(thread.id.rawValue)",
                "name": thread.subjectNormalized.capitalized,
                "description": "Local cached email thread.",
                "mimeType": "application/json"
            ] as [String: Any]
        }
        let staticResources: [[String: Any]] = [
            [
                "uri": "email://draft/\(PlainpostCLISeed.replyDraft.id.rawValue)",
                "name": PlainpostCLISeed.replyDraft.subject,
                "description": "Local draft view.",
                "mimeType": "application/json"
            ],
            [
                "uri": "email://send-request/srq_drf_reply_1",
                "name": "Pending send request",
                "description": "Local pending send request view.",
                "mimeType": "application/json"
            ],
            [
                "uri": "email://smart-inbox",
                "name": "Smart Inbox",
                "description": "Local Smart Inbox grouped view.",
                "mimeType": "application/json"
            ]
        ]
        return messageResources + threadResources + staticResources
    }

    private func mcpResourcePayload(uri: String) throws -> [String: Any]? {
        if uri == "email://smart-inbox" {
            return ["uri": uri, "smart_inbox": mcpSmartInbox(arguments: [:])]
        }
        if let messageID = resourceID(from: uri, prefix: "email://message/") {
            guard let message = store.messages.first(where: { $0.id.rawValue == messageID }) else {
                return nil
            }
            var payload = messageJSON(message)
            try MessageReadPolicy.validateBodyRead(actor: cliActor)
            payload["body"] = message.body
            payload["uri"] = uri
            return payload
        }
        if let threadID = resourceID(from: uri, prefix: "email://thread/") {
            guard var payload = mcpReadThread(arguments: ["thread_id": threadID]) else {
                return nil
            }
            payload["uri"] = uri
            return payload
        }
        if let draftID = resourceID(from: uri, prefix: "email://draft/") {
            let draft = (try? store.draft(id: DraftID(draftID))) ?? (draftID == PlainpostCLISeed.replyDraft.id.rawValue ? PlainpostCLISeed.replyDraft : nil)
            guard let draft else {
                return nil
            }
            var payload = draftJSON(draft)
            payload["uri"] = uri
            payload["body"] = draft.bodyPlain
            return payload
        }
        if let requestID = resourceID(from: uri, prefix: "email://send-request/") {
            guard requestID == "srq_drf_reply_1" else {
                return nil
            }
            return [
                "uri": uri,
                "request_id": requestID,
                "draft_id": PlainpostCLISeed.replyDraft.id.rawValue,
                "status": "pending"
            ]
        }
        return nil
    }

    private func mcpMailSearch(
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let request = try mcpMailSearchRequest(arguments: arguments)
        do {
            let response = try await localMailSearch(request)
            let encoded = try MailSearchJSON.encoder().encode(response)
            guard
                let payload = try JSONSerialization.jsonObject(with: encoded)
                    as? [String: Any]
            else {
                throw MCPMailSearchInvocationError.search(.unavailable)
            }
            return payload
        } catch let searchError as MailSearchError {
            throw MCPMailSearchInvocationError.search(searchError)
        }
    }

    private func mcpMailSearchRequest(arguments: [String: Any]) throws -> MailSearchRequest {
        let supportedArguments: Set<String> = [
            "query", "mode", "account_ids", "mailbox_ids", "limit", "cursor",
        ]
        guard Set(arguments.keys).isSubset(of: supportedArguments),
              arguments["query"] == nil || arguments["query"] is String
        else {
            throw MCPMailSearchInvocationError.invalidArguments
        }
        let query = (arguments["query"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let mode: MailSearchMode
        if let rawMode = arguments["mode"] {
            guard let rawMode = rawMode as? String,
                  let parsedMode = MailSearchMode(rawValue: rawMode) else {
                throw MCPMailSearchInvocationError.invalidArguments
            }
            mode = parsedMode
        } else {
            mode = .conversations
        }

        let accountIDs = try mcpMailSearchIDs(
            arguments["account_ids"],
            maximumCount: MailSearchScopeContract.maximumAccountCount
        ) { AccountID($0) }
        let mailboxIDs = try mcpMailSearchIDs(
            arguments["mailbox_ids"],
            maximumCount: MailSearchScopeContract.maximumMailboxCount
        ) { MailboxID($0) }

        let limit: Int
        if let rawLimit = arguments["limit"] {
            guard !(rawLimit is Bool),
                  let parsedLimit = rawLimit as? Int,
                  (1...MailSearchRequest.maximumLimit).contains(parsedLimit) else {
                throw MCPMailSearchInvocationError.invalidArguments
            }
            limit = parsedLimit
        } else {
            limit = MailSearchRequest.defaultLimit
        }

        let cursor: MailSearchCursor?
        if let rawCursor = arguments["cursor"] {
            guard let rawCursor = rawCursor as? String, !rawCursor.isEmpty else {
                throw MCPMailSearchInvocationError.invalidArguments
            }
            cursor = MailSearchCursor(rawValue: rawCursor)
        } else {
            cursor = nil
        }

        let request = MailSearchRequest(
            query: query,
            scope: MailSearchSelectionScope(
                accountIDs: accountIDs,
                mailboxIDs: mailboxIDs
            ),
            mode: mode,
            limit: limit,
            cursor: cursor
        )
        do {
            try request.validate()
        } catch {
            throw MCPMailSearchInvocationError.invalidArguments
        }
        return request
    }

    private func mcpMailSearchIDs<ID>(
        _ value: Any?,
        maximumCount: Int,
        _ makeID: (String) -> ID
    ) throws -> [ID] {
        guard let value else { return [] }
        guard let rawIDs = value as? [Any], rawIDs.count <= maximumCount else {
            throw MCPMailSearchInvocationError.invalidArguments
        }
        return try rawIDs.map { rawID in
            guard let rawID = rawID as? String,
                  MailSearchScopeContract.isValidIdentifier(rawID) else {
                throw MCPMailSearchInvocationError.invalidArguments
            }
            return makeID(rawID)
        }
    }

    private func mcpMailRead(arguments: [String: Any]) throws -> [String: Any]? {
        guard
            let messageID = stringArgument(arguments, keys: ["message_id", "id"]),
            let message = store.messages.first(where: { $0.id.rawValue == messageID })
        else {
            return nil
        }
        var payload = messageJSON(message)
        payload["seen"] = message.isSeen
        let include = stringArgument(arguments, keys: ["include"])
        if include == "body" {
            try MessageReadPolicy.validateBodyRead(actor: cliActor)
            payload["body"] = message.body
        } else if include == "attachments" {
            try MessageReadPolicy.validateAttachmentRead(actor: cliActor)
            payload["attachments"] = []
        }
        return ["message": payload]
    }

    private func mcpReadThread(arguments: [String: Any]) -> [String: Any]? {
        guard
            let threadID = stringArgument(arguments, keys: ["thread_id", "id"]),
            let thread = store.threads.first(where: { $0.id.rawValue == threadID })
        else {
            return nil
        }
        return [
            "thread": [
                "id": thread.id.rawValue,
                "subject": thread.subjectNormalized.capitalized,
                "participants": thread.participantEmails.map(\.rawValue),
                "message_ids": store.messages.filter { $0.threadID == thread.id }.map { $0.id.rawValue }
            ]
        ]
    }

    private func mcpSmartInbox(arguments: [String: Any]) -> [String: Any] {
        let category = stringArgument(arguments, keys: ["category"])
        let messages = store.messages.filter { message in
            guard let category else { return true }
            return message.smartCategory.rawValue == category
        }
        return ["category": category ?? "all", "messages": messages.map(messageJSON)]
    }

    private func mcpSmartInboxBatch(
        arguments: [String: Any]
    ) async throws -> [String: Any]? {
        guard
            let rawCategory = stringArgument(arguments, keys: ["category"]),
            let category = SmartInboxBatchCategory(argument: rawCategory)
        else {
            return nil
        }
        guard
            let rawAction = stringArgument(arguments, keys: ["action"]),
            let action = SmartInboxBatchAction(argument: rawAction)
        else {
            return nil
        }
        if let accountID = stringArgument(
            arguments,
            keys: ["account_id", "account"]
        ) {
            let result = try await serviceClient.performSmartInboxBatch(
                PlainpostSmartInboxBatchRequest(
                    accountID: accountID,
                    category: category.rawValue,
                    action: action.rawValue,
                    archiveMailbox:
                        stringArgument(
                            arguments,
                            keys: ["archive_mailbox", "mailbox"]
                        ) ?? "Archive"
                )
            )
            return [
                "service": "PlainpostService",
                "action": "smart_inbox_batch",
                "category": result.category,
                "requested_action": result.action,
                "message_ids": result.affectedMessageIDs,
                "affected_count": result.affectedMessageIDs.count,
                "mailbox": result.archiveMailbox,
            ]
        }
        seedSmartInboxBatchMessagesIfNeeded()
        let result = try await SmartInboxBatchService(store: store).run(
            SmartInboxBatchRequest(category: category, action: action),
            actor: cliActor
        )
        return [
            "category": result.category.rawValue,
            "action": result.action.rawValue,
            "message_ids": result.affectedMessageIDs.map(\.rawValue),
            "affected_count": result.affectedCount,
            "mailbox": result.archiveMailbox,
        ]
    }

    private func mcpAddLabel(arguments: [String: Any]) throws -> [String: Any]? {
        guard let messageID = stringArgument(arguments, keys: ["message_id", "id"]),
              let label = stringArgument(arguments, keys: ["label", "name"])
        else { return nil }
        let message = try store.addLabel(label, to: MessageID(messageID), actor: cliActor)
        return ["message_id": message.id.rawValue, "labels": message.labels]
    }

    private func mcpRemoveLabel(arguments: [String: Any]) throws -> [String: Any]? {
        guard let messageID = stringArgument(arguments, keys: ["message_id", "id"]),
              let label = stringArgument(arguments, keys: ["label", "name"])
        else { return nil }
        let message = try store.removeLabel(label, from: MessageID(messageID), actor: cliActor)
        return ["message_id": message.id.rawValue, "labels": message.labels]
    }

    private func mcpMarkSeen(
        arguments: [String: Any]
    ) async throws -> [String: Any]? {
        guard let messageID = stringArgument(arguments, keys: ["message_id", "id"]) else {
            return nil
        }
        let seen = boolArgument(arguments, keys: ["seen", "is_seen"]) ?? true
        let input = PlainpostMailActionPayload(messageID: messageID)
        let result = try await serviceClient.perform(
            seen ? .markRead(input) : .markUnread(input)
        )
        switch result {
        case .markRead(let value), .markUnread(let value):
            return [
                "service": "PlainpostService",
                "action": seen ? "mark_read" : "mark_unread",
                "message_id": value.messageID,
                "seen": value.seen ?? seen,
            ]
        default:
            throw PlainpostServiceClientError.operationFailed
        }
    }

    private func mcpMailboxAction(
        action: String,
        arguments: [String: Any]
    ) async throws -> [String: Any]? {
        guard let messageID = stringArgument(arguments, keys: ["message_id", "id"]) else {
            return nil
        }
        let archiveMailbox = action == "archive"
            ? stringArgument(
                arguments,
                keys: ["archive_mailbox", "mailbox"]
            ) ?? "Archive"
            : nil
        let input = PlainpostMailActionPayload(
            messageID: messageID,
            archiveMailbox: archiveMailbox,
            // Erasing needs `permanent: true`; a plain delete only moves to Trash.
            permanent: action == "delete" && (boolArgument(arguments, keys: ["permanent"]) ?? false),
            // The copy to act on, when the message is in several mailboxes.
            sourceMailbox: stringArgument(arguments, keys: ["source_mailbox"]),
            sourceUID: intArgument(arguments, key: "source_uid")
        )
        let result: PlainpostForegroundOperationResult
        switch action {
        case "archive":
            result = try await serviceClient.perform(.archive(input))
            guard case .archive(let value) = result else {
                throw PlainpostServiceClientError.operationFailed
            }
            return [
                "service": "PlainpostService",
                "message_id": value.messageID,
                "action": "archive",
                "mailbox": value.mailboxPath ?? "Archive",
                "archived": true,
                "deleted": value.isDeleted,
            ]
        case "delete":
            result = try await serviceClient.perform(.delete(input))
            guard case .delete(let value) = result else {
                throw PlainpostServiceClientError.operationFailed
            }
            var reply: [String: Any] = [
                "service": "PlainpostService",
                "message_id": value.messageID,
                "action": "delete",
            ]
            PlainpostCLIDeleteReply.describe(value, into: &reply)
            return reply
        default:
            return nil
        }
    }

    private func mcpRecategorize(arguments: [String: Any]) throws -> [String: Any]? {
        guard let messageID = stringArgument(arguments, keys: ["message_id", "id"]),
              let categoryValue = stringArgument(arguments, keys: ["category"]),
              let category = SmartCategory(rawValue: categoryValue)
        else { return nil }
        let message = try store.recategorize(MessageID(messageID), as: category, actor: cliActor)
        return ["message_id": message.id.rawValue, "category": message.smartCategory.rawValue]
    }

    private func mcpCreateDraft(arguments: [String: Any]) throws -> [String: Any]? {
        guard
            let to = stringArgument(arguments, keys: ["to", "recipient"]),
            let subject = stringArgument(arguments, keys: ["subject"]),
            let body = stringArgument(arguments, keys: ["body", "body_plain"])
        else {
            return nil
        }

        let draft = Draft(
            id: DraftID("drf_mcp_1"),
            accountID: AccountID(stringArgument(arguments, keys: ["account", "account_id"]) ?? "acc_personal"),
            from: EmailAddress(stringArgument(arguments, keys: ["from"]) ?? "me@example.com"),
            to: [EmailAddress(to)],
            cc: [],
            bcc: [],
            subject: subject,
            bodyPlain: body,
            createdBy: cliActor.id,
            aiGenerated: false,
            sourceThreadID: nil
        )
        let created: Draft
        if let sqliteStore = try sqliteStoreIfRequested() {
            created = try sqliteStore.createDraft(draft, actor: cliActor)
        } else {
            created = try store.createDraft(draft, actor: cliActor)
        }
        return draftJSON(created)
    }

    private func mcpUpdateDraft(arguments: [String: Any]) throws -> [String: Any]? {
        guard let draftID = stringArgument(arguments, keys: ["draft_id", "id"]) else {
            return nil
        }
        let patch = DraftPatch(
            subject: stringArgument(arguments, keys: ["subject"]),
            bodyPlain: stringArgument(arguments, keys: ["body", "body_plain"])
        )
        let updated: Draft?
        if let sqliteStore = try sqliteStoreIfRequested() {
            guard let existing = try? sqliteStore.draft(id: DraftID(draftID)) else {
                return nil
            }
            updated = try? sqliteStore.updateDraft(
                id: DraftID(draftID),
                expectedHash: existing.contentHash,
                patch: patch,
                actor: cliActor,
                requiredIDPrefix: "drf_mcp_",
                requiredCreatorID: cliActor.id
            )
        } else {
            updated = try? store.updateDraft(
                id: DraftID(draftID),
                patch: patch,
                actor: cliActor
            )
        }
        guard let updated else {
            return nil
        }
        return draftJSON(updated)
    }

    private func mcpDeleteDraft(arguments: [String: Any]) throws -> [String: Any]? {
        guard let draftID = stringArgument(arguments, keys: ["draft_id", "id"]) else {
            return nil
        }
        if let sqliteStore = try sqliteStoreIfRequested() {
            guard let existing = try? sqliteStore.draft(id: DraftID(draftID)),
                  (try? sqliteStore.deleteDraft(
                      id: DraftID(draftID),
                      expectedHash: existing.contentHash,
                      actor: cliActor,
                      requiredIDPrefix: "drf_mcp_",
                      requiredCreatorID: cliActor.id
                  )) != nil
            else {
                return nil
            }
        } else {
            guard (try? store.deleteDraft(
                id: DraftID(draftID),
                actor: cliActor
            )) != nil else {
                return nil
            }
        }
        return ["draft_id": draftID, "status": "deleted"]
    }

    private func mcpSyncDraft(
        arguments: [String: Any]
    ) async throws -> [String: Any]? {
        guard let draftID = stringArgument(arguments, keys: ["draft_id", "id"]) else {
            return nil
        }
        let result = try await serviceClient.syncDraftToServer(
            draftID: draftID,
            mailbox:
                stringArgument(
                    arguments,
                    keys: ["drafts_mailbox", "mailbox"]
                ) ?? "Drafts"
        )
        return [
            "service": "PlainpostService",
            "action": "draft_sync",
            "draft_id": result.draftID,
            "mailbox": result.mailbox,
            "server_draft_mailbox_id": result.mailbox,
            "server_draft_uid": result.serverDraftUID ?? NSNull(),
            "synced_to_server": true,
        ]
    }

    private func mcpRequestSend(
        arguments: [String: Any]
    ) throws -> [String: Any]? {
        let draftID: String
        if let requestedDraftID = stringArgument(
            arguments,
            keys: ["draft_id", "draft"]
        ) {
            draftID = requestedDraftID
        } else if
            let created = try mcpCreateDraft(arguments: arguments),
            let createdDraftID = created["id"] as? String
                ?? created["draft_id"] as? String
        {
            draftID = createdDraftID
        } else {
            draftID = "drf_reply_1"
        }

        if let sqliteStore = try sqliteStoreIfRequested() {
            let request = try sqliteStore.requestSend(
                draftID: DraftID(draftID),
                actor: cliActor,
                reason: stringArgument(arguments, keys: ["reason"])
            )
            return sendRequestJSON(request)
        }
        guard draftID == "drf_reply_1" else { return nil }
        _ = try ensureReplyDraftInStore()
        let request = try store.requestSend(draftID: PlainpostCLISeed.replyDraft.id, actor: cliActor, reason: nil)
        return sendRequestJSON(request)
    }

    private func mcpSendStatus(
        arguments: [String: Any]
    ) throws -> [String: Any]? {
        let requestID = SendRequestID(stringArgument(arguments, keys: ["request_id", "id"]) ?? "srq_drf_reply_1")
        if let sqliteStore = try sqliteStoreIfRequested() {
            let request = try sqliteStore.sendRequest(id: requestID)
            return sendRequestJSON(request)
        }
        let request = try sendRequestForRead(requestID: requestID)
        return sendRequestJSON(request)
    }

    private func mcpCancelSendRequest(
        arguments: [String: Any]
    ) throws -> [String: Any]? {
        let requestID = SendRequestID(stringArgument(arguments, keys: ["request_id", "id"]) ?? "srq_drf_reply_1")
        if let sqliteStore = try sqliteStoreIfRequested() {
            let request = try sqliteStore.cancelSendRequest(id: requestID, actor: cliActor)
            return sendRequestJSON(request)
        }
        try seedDefaultSendRequestIfNeeded(requestID: requestID, actor: cliActor)
        let request = try store.cancelSendRequest(id: requestID, actor: cliActor)
        return sendRequestJSON(request)
    }

    private func mcpResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func mcpError(
        id: Any?,
        code: Int,
        message: String,
        data: [String: Any]? = nil
    ) -> [String: Any] {
        var error: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            error["data"] = data
        }
        return [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error,
        ]
    }

    private func mcpServiceError(
        id: Any?,
        error serviceError: PlainpostServiceClientError
    ) -> String {
        let details = serviceErrorDetails(serviceError)
        return encode(
            mcpError(
                id: id,
                code: -32003,
                message: details.message,
                data: ["code": details.code]
            )
        )
    }

    private func stringArgument(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
        }
        return nil
    }

    private func intArgument(_ arguments: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = arguments[key] as? Int {
                return value
            }
            if let value = arguments[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private func resourceID(from uri: String, prefix: String) -> String? {
        guard uri.hasPrefix(prefix), uri.count > prefix.count else {
            return nil
        }
        return String(uri.dropFirst(prefix.count))
    }

    private func intArgument(_ arguments: [String: Any], key: String) -> Int? {
        if let value = arguments[key] as? Int { return value }
        if let value = arguments[key] as? NSNumber { return value.intValue }
        if let value = arguments[key] as? String { return Int(value) }
        return nil
    }

    private func boolArgument(_ arguments: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = arguments[key] as? Bool {
                return value
            }
            if let value = arguments[key] as? String {
                switch value.lowercased() {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    private func sqliteStoreIfRequested() throws -> SQLiteMailStore? {
        let path: String
        if let explicitPath = value(after: "--db-path") {
            path = explicitPath
        } else if let dataDirectoryPath = ProcessInfo.processInfo.environment["PLAINPOST_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !dataDirectoryPath.isEmpty {
            let directory = URL(fileURLWithPath: dataDirectoryPath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("Plainpost.sqlite").path
        } else {
            return nil
        }
        let sqliteStore = try SQLiteMailStore(path: path)
        try sqliteStore.migrate()
        return sqliteStore
    }

    private func sqliteStoreForSearch() throws -> (SQLiteMailStore, String) {
        if let requested = try sqliteStoreIfRequested() {
            let path: String
            if let explicitPath = value(after: "--db-path") {
                path = explicitPath
            } else if let dataDirectoryPath = ProcessInfo.processInfo
                .environment["PLAINPOST_DATA_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !dataDirectoryPath.isEmpty
            {
                path = URL(fileURLWithPath: dataDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Plainpost.sqlite").path
            } else {
                throw PlainpostError.validationFailed(
                    "Mail search could not resolve its database path."
                )
            }
            return (requested, path)
        }
        let directory: URL
        if let applicationSupportPath = ProcessInfo.processInfo
            .environment["PLAINPOST_APPLICATION_SUPPORT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !applicationSupportPath.isEmpty
        {
            directory = URL(
                fileURLWithPath: applicationSupportPath,
                isDirectory: true
            )
        } else {
            let homePath = ProcessInfo.processInfo.environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedHomePath =
                homePath?.isEmpty == false
                    ? homePath ?? NSHomeDirectory()
                    : NSHomeDirectory()
            directory = URL(
                fileURLWithPath: resolvedHomePath,
                isDirectory: true
            )
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            .appendingPathComponent("Plainpost", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databasePath = directory.appendingPathComponent("Plainpost.sqlite").path
        let sqliteStore = try SQLiteMailStore(path: databasePath)
        try sqliteStore.migrate()
        return (sqliteStore, databasePath)
    }

    private func serviceLaunchAgent() throws -> String {
        guard arguments.contains("--json") else {
            return error("VALIDATION_FAILED", "LaunchAgent commands require --json.")
        }

        switch positional(after: ["service", "launch-agent"]) {
        case "print-plist":
            let configuration = try launchAgentConfiguration()
            return success([
                "label": configuration.label,
                "plist_path": launchAgentPlistURL().path,
                "plist": try PlainpostLaunchAgentPlist.string(for: configuration)
            ])
        case "install":
            let plistURL = launchAgentPlistURL()
            let configuration = try launchAgentConfiguration()
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: configuration.standardOutPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let dataDirectoryPath = configuration.dataDirectoryPath {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: dataDirectoryPath, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try PlainpostLaunchAgentPlist.data(for: configuration).write(to: plistURL, options: .atomic)
            return success([
                "label": configuration.label,
                "plist_path": plistURL.path,
                "installed": true,
                "launchctl_loaded": false
            ])
        case "status":
            let plistURL = launchAgentPlistURL()
            guard FileManager.default.fileExists(atPath: plistURL.path) else {
                return success([
                    "label": PlainpostLaunchAgentConfiguration.defaultLabel,
                    "plist_path": plistURL.path,
                    "installed": false,
                    "launchctl_loaded": false
                ])
            }
            let data = try Data(contentsOf: plistURL)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let label = (propertyList as? [String: Any])?["Label"] as? String
                ?? PlainpostLaunchAgentConfiguration.defaultLabel
            return success([
                "label": label,
                "plist_path": plistURL.path,
                "installed": true,
                "launchctl_loaded": false
            ])
        default:
            return error("VALIDATION_FAILED", "Unsupported LaunchAgent command.")
        }
    }

    private func launchAgentConfiguration() throws -> PlainpostLaunchAgentConfiguration {
        let logDirectoryURL = launchAgentLogDirectoryURL()
        return PlainpostLaunchAgentConfiguration(
            label: value(after: "--label") ?? PlainpostLaunchAgentConfiguration.defaultLabel,
            serviceExecutablePath: try plainpostServiceExecutableURL().path,
            dataDirectoryPath: launchAgentDataDirectoryURL().path,
            standardOutPath: logDirectoryURL.appendingPathComponent("service.out.log").path,
            standardErrorPath: logDirectoryURL.appendingPathComponent("service.err.log").path
        )
    }

    private func launchAgentPlistURL() -> URL {
        if let explicitPath = value(after: "--plist-path") {
            return URL(fileURLWithPath: explicitPath)
        }
        let homePath = nonEmptyEnvironmentValue("HOME") ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(PlainpostLaunchAgentConfiguration.defaultLabel).plist")
    }

    private func launchAgentDataDirectoryURL() -> URL {
        if let explicitPath = value(after: "--data-dir") {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
        }
        if let dataDirectoryPath = nonEmptyEnvironmentValue("PLAINPOST_DATA_DIR") {
            return URL(fileURLWithPath: dataDirectoryPath, isDirectory: true)
        }
        let homePath = nonEmptyEnvironmentValue("HOME") ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Plainpost", isDirectory: true)
    }

    private func launchAgentLogDirectoryURL() -> URL {
        if let explicitPath = value(after: "--log-dir") {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
        }
        let homePath = nonEmptyEnvironmentValue("HOME") ?? NSHomeDirectory()
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Plainpost", isDirectory: true)
    }

    private func nonEmptyEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func stableAccountID(email: String) -> String {
        "acc_" + email.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    private func plainpostServiceExecutableURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["PLAINPOST_SERVICE_EXECUTABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }
        if let explicitPath = value(after: "--service-executable") {
            return URL(fileURLWithPath: explicitPath)
        }
        if let executableURL = Bundle.main.executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            let contentsDirectory = executableDirectory.deletingLastPathComponent()
            if executableDirectory.lastPathComponent != "MacOS"
                || contentsDirectory.lastPathComponent != "Contents" {
                return executableDirectory.appendingPathComponent("PlainpostService")
            }
            return contentsDirectory
                .appendingPathComponent("Library/Helpers", isDirectory: true)
                .appendingPathComponent("PlainpostService.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/PlainpostService")
        }
        throw PlainpostError.validationFailed("PlainpostService executable not found.")
    }

    private var cliActor: Actor {
        Actor(
            id: "plainpost",
            kind: .cli,
            displayName: "plainpost",
            permissions: .agentRequested(
                readBody: agentReadBodyAllowed,
                readAttachments: agentReadAttachmentsAllowed,
                createDrafts: agentCreateDraftsAllowed,
                requestSend: agentRequestSendAllowed,
                addLabels: agentAddLabelsAllowed,
                recategorize: agentRecategorizeAllowed,
                markSeen: agentMarkSeenAllowed
            )
        )
    }

    private var agentReadBodyAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_READ_BODY", defaultValue: true)
    }

    private var agentReadAttachmentsAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_READ_ATTACHMENTS", defaultValue: false)
    }

    private var agentCreateDraftsAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_CREATE_DRAFTS", defaultValue: true)
    }

    private var agentRequestSendAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_REQUEST_SEND", defaultValue: true)
    }

    private var agentAddLabelsAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_ADD_LABELS", defaultValue: true)
    }

    private var agentRecategorizeAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_RECATEGORIZE", defaultValue: true)
    }

    private var agentMarkSeenAllowed: Bool {
        agentBooleanPolicy("PLAINPOST_AGENT_MARK_SEEN", defaultValue: true)
    }

    private func agentBooleanPolicy(_ name: String, defaultValue: Bool) -> Bool {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "false", "0", "no":
            return false
        case "true", "1", "yes":
            return true
        default:
            return defaultValue
        }
    }

    private func accountJSON(_ account: Account) -> [String: Any] {
        [
            "id": account.id.rawValue,
            "display_name": account.displayName,
            "email": account.email.rawValue,
            "imap_host": account.imapHost,
            "smtp_host": account.smtpHost
        ]
    }

    private func mailboxJSON(_ mailbox: Mailbox) -> [String: Any] {
        [
            "id": mailbox.id.rawValue,
            "account_id": mailbox.accountID.rawValue,
            "name": mailbox.name,
            "path": mailbox.path,
            "special_use": mailbox.specialUse ?? NSNull()
        ]
    }

    private func legacyMessageID(for id: MessageID) -> String {
        guard let uid = Int(id.rawValue.split(separator: "_").last ?? "") else { return id.rawValue }
        return "msg_uid_\(uid)"
    }

    private func messageJSON(_ message: MessageSummary) -> [String: Any] {
        [
            "id": message.id.rawValue,
            "thread_id": message.threadID?.rawValue ?? NSNull(),
            "from": message.from.rawValue,
            "subject": message.subject,
            "preview": message.preview,
            "category": message.smartCategory.rawValue,
            "labels": message.labels,
            "mailbox": message.mailboxPath,
            "deleted": message.isDeleted
        ]
    }

    private func seedSmartInboxBatchMessagesIfNeeded() {
        let ids = Set(store.messages.map { $0.id.rawValue })
        if !ids.contains("msg_notification_1") {
            store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_notification_1"),
                    threadID: nil,
                    from: EmailAddress("alerts@example.com"),
                    subject: "Build finished",
                    preview: "Your build completed successfully.",
                    smartCategory: .notification
                )
            )
        }
        if !ids.contains("msg_newsletter_1") {
            store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_newsletter_1"),
                    threadID: nil,
                    from: EmailAddress("newsletter@example.com"),
                    subject: "Weekly Product Updates",
                    preview: "This week in product news.",
                    smartCategory: .newsletter
                )
            )
        }
    }

    private func draftJSON(_ draft: Draft) -> [String: Any] {
        var payload: [String: Any] = [
            "draft_id": draft.id.rawValue,
            "subject": draft.subject,
            "to": draft.to.map(\.rawValue),
            "content_hash": draft.contentHash,
            "sent": false
        ]
        if let uid = draft.serverDraftUID {
            payload["server_draft_uid"] = uid
        }
        if let mailboxID = draft.serverDraftMailboxID {
            payload["server_draft_mailbox_id"] = mailboxID
        }
        return payload
    }

    private func sendRequestJSON(_ request: SendRequest) -> [String: Any] {
        [
            "request_id": request.id.rawValue,
            "draft_id": request.draftID.rawValue,
            "status": request.status.rawValue
        ]
    }

    private func sendRequestForRead(requestID: SendRequestID) throws -> SendRequest {
        try seedDefaultSendRequestIfNeeded(requestID: requestID, actor: cliActor)
        return try store.sendRequest(id: requestID)
    }

    private func seedDefaultSendRequestIfNeeded(requestID: SendRequestID, actor: Actor) throws {
        guard requestID == SendRequestID("srq_\(PlainpostCLISeed.replyDraft.id.rawValue)") else {
            return
        }
        if (try? store.sendRequest(id: requestID)) != nil {
            return
        }
        _ = try ensureReplyDraftInStore()
        _ = try store.requestSend(draftID: PlainpostCLISeed.replyDraft.id, actor: fixtureSeedActor, reason: nil)
    }

    private func ensureReplyDraftInStore() throws -> Draft {
        if let draft = try? store.draft(id: PlainpostCLISeed.replyDraft.id) {
            return draft
        }
        return try store.createDraft(PlainpostCLISeed.replyDraft, actor: fixtureSeedActor)
    }

    private var fixtureSeedActor: Actor {
        Actor(
            id: "fixture",
            kind: .system,
            displayName: "Fixture",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
    }

    private var systemActor: Actor {
        Actor(
            id: "plainpost-system",
            kind: .system,
            displayName: "Plainpost System",
            permissions: .guiUser
        )
    }

    private func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private func positional(after prefix: [String]) -> String? {
        guard arguments.starts(with: prefix), arguments.count > prefix.count else {
            return nil
        }
        let candidate = arguments[prefix.count]
        return candidate.hasPrefix("-") ? nil : candidate
    }

    private func success(_ data: Any) -> String {
        encode(["ok": true, "data": data])
    }

    private func mailSearchError(_ searchError: MailSearchError) -> String {
        switch searchError {
        case .invalidQuery:
            return error("INVALID_QUERY", "Mail search query is invalid.")
        case .unsupportedField:
            return error(
                "UNSUPPORTED_FIELD",
                "Mail search field is not supported."
            )
        case .unsupportedValue:
            return error(
                "UNSUPPORTED_VALUE",
                "Mail search value is not supported."
            )
        case .requestTooLarge:
            return error(
                "REQUEST_TOO_LARGE",
                "Mail search request is too large."
            )
        case .invalidCursor:
            return error("INVALID_CURSOR", "Mail search cursor is invalid.")
        case .staleCursor:
            return error("STALE_CURSOR", "Mail search cursor is stale.")
        case .rebuilding:
            return error("SEARCH_REBUILDING", "Mail search index is rebuilding.")
        case .unavailable:
            return error("SEARCH_UNAVAILABLE", "Mail search is unavailable.")
        case .cancelled:
            return error("SEARCH_CANCELLED", "Mail search was cancelled.")
        }
    }

    private func serviceError(_ caughtError: Error) -> String {
        // A refusal the service explains (no Trash, not in Trash, and so on)
        // is shown as itself, as MCP does, not as an unavailable service.
        if let mailError = caughtError as? PlainpostError {
            return error(mailError.code, mailError.message)
        }
        guard let serviceError = caughtError as? PlainpostServiceClientError else {
            return error(
                "SERVICE_UNAVAILABLE",
                "PlainpostService is unavailable."
            )
        }
        let details = serviceErrorDetails(serviceError)
        return error(details.code, details.message)
    }

    private func serviceErrorDetails(
        _ serviceError: PlainpostServiceClientError
    ) -> (code: String, message: String) {
        switch serviceError {
        case .vaultLocked:
            return (
                "VAULT_LOCKED",
                "Plainpost is locked. Unlock it explicitly before retrying."
            )
        case .authorizationCancelled:
            return (
                "AUTHORIZATION_CANCELLED",
                "Plainpost vault authorization was cancelled."
            )
        case .authorizationFailed:
            return (
                "AUTHORIZATION_FAILED",
                "Plainpost vault authorization failed."
            )
        case .vaultKeyMissing:
            return (
                "VAULT_KEY_MISSING",
                "The Plainpost Vault Key is missing. Open Plainpost and choose Start Over with Saved Sign-ins."
            )
        case .vaultKeyAmbiguous:
            return (
                "VAULT_KEY_AMBIGUOUS",
                "More than one Plainpost Vault Key matches."
            )
        case .ciphertextInvalid:
            return (
                "VAULT_CIPHERTEXT_INVALID",
                "The Plainpost credential vault is corrupt or invalid."
            )
        case .unsupportedVaultVersion(let version):
            return (
                "VAULT_VERSION_UNSUPPORTED",
                "The Plainpost credential vault version \(version) is unsupported."
            )
        case .clientUnauthorized:
            return (
                "CLIENT_UNAUTHORIZED",
                "This Plainpost client is not authorized for that operation."
            )
        case .invalidRequest:
            return (
                "VALIDATION_FAILED",
                "PlainpostService rejected the request."
            )
        case .operationFailed:
            return (
                "OPERATION_FAILED",
                "PlainpostService could not complete the operation."
            )
        case .accountDeletionCleanupPending:
            return (
                "ACCOUNT_DELETION_CLEANUP_PENDING",
                "The account was deleted; Plainpost will retry local audit cleanup."
            )
        case .accountDeletionCompensationFailed:
            return (
                "ACCOUNT_DELETION_COMPENSATION_FAILED",
                "Account deletion failed and credential restoration also failed."
            )
        case .nodeSession:
            return (
                "CLIENT_UNAUTHORIZED",
                "This Plainpost client is not authorized for that operation."
            )
        case .mailActionRefused(let refusal):
            return ("VALIDATION_FAILED", refusal.message)
        case .serviceUnavailable, .timedOut:
            return (
                "SERVICE_UNAVAILABLE",
                "PlainpostService is unavailable."
            )
        }
    }

    private func vaultAvailabilityJSON(
        _ availability: PlainpostVaultStatus.Availability
    ) -> String {
        switch availability {
        case .locked:
            "locked"
        case .unlocked:
            "unlocked"
        case .keyMissing:
            "key_missing"
        case .keyAmbiguous:
            "key_ambiguous"
        case .ciphertextInvalid:
            "ciphertext_invalid"
        case .unsupportedVersion(let version):
            "unsupported_version_\(version)"
        }
    }

    private func error(_ code: String, _ message: String) -> String {
        encode(["ok": false, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private var sendRequestHelp: String {
        """
        plainpost send request --draft <draft-id> --agent <agent-id> [--reason <text>] [--json]

        Creates a pending send request for a local draft. This command requires local user approval before SMTP delivery. It never sends email directly.
        """
    }
}

private struct MailSearchCLIOptions {
    let query: String
    let accountIDs: [AccountID]
    let mailboxIDs: [MailboxID]
    let mode: MailSearchMode
    let limit: Int
    let cursor: MailSearchCursor?
    let json: Bool
}

private let mailSearchHelp = """
Usage:
  plainpost mail search QUERY [--mode conversations|messages]
      [--account ACCOUNT_ID]... [--mailbox MAILBOX_ID]...
      [--limit 1...100] [--cursor CURSOR] [--json]

Search is local and reads the cached Plainpost index. Use AND, OR, NOT, minus, and parentheses to combine or exclude expressions. Quote phrases that must stay together.

Conversations are returned by default. Use --mode messages for individual messages. The default limit is 50 and the maximum is 100.

Pass repeated --account or --mailbox options to narrow the scope. A scope accepts at most 64 unique account IDs and 256 unique mailbox IDs; every ID is limited to 256 UTF-8 bytes. Pass the returned next cursor unchanged to continue paging. Cursors contain authenticated request and scope fingerprints rather than raw scope IDs and expire after 24 hours. If the index changes, a stale cursor must be replaced by starting the search again without --cursor.

QUERY may be empty only when at least one --account or --mailbox scope is present; that returns every non-trash message in the selected structural scope.

Start with people, subject, date, state, or mailbox filters before issuing a very broad body query.

\(MailSearchFieldRegistry.cliGuide)

Examples:
  plainpost mail search 'from:alice is:unread after:2026-07-01'
  plainpost mail search '(subject:budget OR filename:forecast) with:documents' --json
  plainpost mail search 'participants:"Alex Rivera"' --mode messages --limit 25
  plainpost mail search '' --account acc_personal --json
""" + "\n"

private enum MCPMailSearchInvocationError: Error {
    case invalidArguments
    case search(MailSearchError)

    var jsonRPCCode: Int {
        switch self {
        case .invalidArguments:
            -32602
        case .search(let error):
            switch error {
            case .invalidQuery, .unsupportedField, .unsupportedValue, .requestTooLarge,
                 .invalidCursor, .staleCursor:
                -32602
            case .rebuilding:
                -32001
            case .unavailable:
                -32002
            case .cancelled:
                -32800
            }
        }
    }

    var safeMessage: String {
        switch self {
        case .invalidArguments:
            "Invalid email.search arguments."
        case .search(let error):
            switch error {
            case .invalidQuery:
                "Mail search query is invalid."
            case .unsupportedField:
                "Mail search field is not supported."
            case .unsupportedValue:
                "Mail search value is not supported."
            case .requestTooLarge:
                "Mail search request is too large."
            case .invalidCursor:
                "Mail search cursor is invalid."
            case .staleCursor:
                "Mail search cursor is stale."
            case .rebuilding:
                "Mail search index is rebuilding."
            case .unavailable:
                "Mail search is unavailable."
            case .cancelled:
                "Mail search was cancelled."
            }
        }
    }
}

private enum PlainpostCLISeed {
    static let replyDraft = Draft(
        id: DraftID("drf_reply_1"),
        accountID: AccountID("acc_personal"),
        from: EmailAddress("me@example.com"),
        to: [EmailAddress("alice@example.com")],
        cc: [],
        bcc: [],
        subject: "Re: Availability",
        bodyPlain: "Tuesday works for me.",
        createdBy: "codex",
        aiGenerated: true,
        sourceThreadID: ThreadID("thr_alice_1")
    )
}

private extension PlainpostError {
    var code: String {
        switch self {
        case .permissionDenied:
            "PERMISSION_DENIED"
        case .validationFailed:
            "VALIDATION_FAILED"
        case .notFound:
            "MESSAGE_NOT_FOUND"
        }
    }

    var message: String {
        switch self {
        case .permissionDenied(let message), .validationFailed(let message), .notFound(let message):
            message
        }
    }
}

/// What a CLI or MCP delete reply says.
enum PlainpostCLIDeleteReply {
    /// A delete reply says what happened: moved to Trash, already in Trash, or
    /// erased. `deleted` is true only for an erase (or a Sync Node delete).
    static func describe(_ result: PlainpostMailActionSemanticResult, into payload: inout [String: Any]) {
        payload["deleted"] = result.deleteOutcome.map { $0 == .deletedPermanently } ?? result.isDeleted
        if let outcome = result.deleteOutcome {
            payload["outcome"] = outcome.rawValue
            payload["result"] = outcome.summary
        }
        if result.deleteOutcome == .deletedPermanently, !result.isDeleted, let remaining = result.mailboxPath {
            // That copy was erased; the message still has a copy here.
            payload["remaining_mailbox"] = remaining
        } else if let mailboxPath = result.mailboxPath {
            payload["mailbox"] = mailboxPath
        }
    }
}
