import Foundation
import XCTest
import PlainpostCore
import PlainpostDB

final class MailSearchServiceTransportTests: XCTestCase {
    func testCLIRejectsCanonicalScopeBoundsBeforeOpeningStore() throws {
        let missingDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-search-\(UUID().uuidString)", isDirectory: true)
        let arguments = ["mail", "search", "project"]
            + (0 ... MailSearchScopeContract.maximumMailboxCount).flatMap {
                ["--mailbox", "mailbox-\($0)"]
            }
            + ["--json"]

        let result = try MailSearchCLIProcess.run(
            arguments,
            environment: ["PLAINPOST_DATA_DIR": missingDataDirectory.path]
        )
        let response = try JSONDecoder().decode(
            ServiceCodeFailure.self,
            from: Data(result.output.utf8)
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error.code, "VALIDATION_FAILED")
        XCTAssertTrue(response.error.message.contains("accepts at most"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDataDirectory.path))
    }

    func testSearchReturnsCanonicalConversationResponseWithSortedKeys() throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }

        let result = try MailSearchCLIProcess.run(
            ["mail", "search", "project", "--json"],
            environment: ["PLAINPOST_DATA_DIR": fixture.directory.path]
        )
        let response = try decodeSuccess(MailSearchResponse.self, from: result.output)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(
            response.data.hits.first?.id,
            MailSearchStableIdentity.thread(
                accountID: fixture.account.id,
                threadID: fixture.projectThread.id
            )
        )
        XCTAssertEqual(
            canonicalizedJSON(result.output),
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testSearchSuggestionsReturnsCanonicalSections() async throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let request = MailSearchSuggestionRequest(
            query: "from:ali",
            recentQueries: [],
            activeRange: .init(location: 5, length: 3)
        )

        let response = try await fixture.makeSearchService().suggestions(request)
        let people = response.first { $0.kind == .people }?.items ?? []

        XCTAssertEqual(people.first { $0.title == "Alice" }?.insertion, "alice@example.com")
        XCTAssertEqual(
            people.first { $0.title == "Alice" }?.replacementRange,
            .init(location: 5, length: 3)
        )
    }

    func testIndexStateAndRebuildReturnCanonicalReadyState() async throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let service = try fixture.makeSearchService()

        let before = await service.indexState()
        try await service.rebuildIndex()
        let after = await service.indexState()

        XCTAssertEqual(before, .ready)
        XCTAssertEqual(after, .ready)
    }

    func testInvalidQueryPreservesCanonicalCodeAndUTF16RangeWithoutQueryText() async throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let privateQuery = #""private\q""#

        do {
            _ = try await fixture.makeSearchService().search(
                MailSearchRequest(query: privateQuery)
            )
            XCTFail("Expected the canonical invalid-query error.")
        } catch let error as MailSearchError {
            XCTAssertEqual(
                error,
                .invalidQuery(
                    reason: "Quoted phrase contains an unsupported escape.",
                    range: .init(location: 8, length: 2)
                )
            )
        }

        let result = try MailSearchCLIProcess.run(
            ["mail", "search", privateQuery, "--json"],
            environment: ["PLAINPOST_DATA_DIR": fixture.directory.path]
        )
        let codedResponse = try JSONDecoder().decode(
            ServiceCodeFailure.self,
            from: Data(result.output.utf8)
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertFalse(codedResponse.ok)
        XCTAssertEqual(codedResponse.error.code, "INVALID_QUERY")
        XCTAssertEqual(codedResponse.error.message, "Mail search query is invalid.")
        XCTAssertFalse(result.output.contains(privateQuery))
    }

    func testSearchReturnsStaleCursorCodeAfterProjectionRevisionChanges() async throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let request = MailSearchRequest(query: "project", mode: .messages, limit: 1)
        let first = try await fixture.makeSearchService().search(request)
        let cursor = try XCTUnwrap(first.nextCursor)

        try fixture.insertRevisionChangingMessage()

        do {
            _ = try await fixture.makeSearchService().search(
                MailSearchRequest(
                    query: request.query,
                    scope: request.scope,
                    mode: request.mode,
                    limit: request.limit,
                    cursor: cursor
                )
            )
            XCTFail("Expected a stale cursor after the search projection changed.")
        } catch let error as MailSearchError {
            XCTAssertEqual(error, .staleCursor)
        }
    }

    func testCursorAuthenticationUsesPersistedOwnerOnlyDatabaseSecret() async throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let keyURL = URL(fileURLWithPath: fixture.databasePath)
            .appendingPathExtension("search-cursor-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))

        _ = try await fixture.makeSearchService().search(
            MailSearchRequest(query: "project", mode: .messages, limit: 1)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertEqual(try Data(contentsOf: keyURL).count, 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testCursorKeyPublicationFailsClosedWhenParentDirectoryCannotBeSynced() throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o300],
            ofItemAtPath: fixture.directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.directory.path
            )
        }

        XCTAssertThrowsError(try fixture.makeSearchService())
    }

    func testUnavailableDatabaseReturnsCanonicalCodeWithoutQueryOrSnippet() throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let privateQuery = "private-project-query"
        let privateSnippet = "private-project-snippet"

        let result = try MailSearchCLIProcess.run(
            ["mail", "search", privateQuery, "--json"],
            environment: ["PLAINPOST_DATA_DIR": fixture.databasePath]
        )
        let response = try JSONDecoder().decode(
            ServiceCodeFailure.self,
            from: Data(result.output.utf8)
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error.code, "SEARCH_UNAVAILABLE")
        XCTAssertEqual(response.error.message, "Mail search is unavailable.")
        XCTAssertFalse(result.output.contains(privateQuery))
        XCTAssertFalse(result.output.contains(privateSnippet))
    }

    func testPlainpostServiceRejectsRetiredMailSearchCommandTransport() throws {
        let fixture = try MailSearchServiceTransportFixture()
        defer { fixture.removeArtifacts() }
        let cases = [
            ["mail", "search", "--db-path", fixture.databasePath, "--json"],
            ["mail", "search-suggestions", "--db-path", fixture.databasePath, "--json"],
            ["mail", "search-index-state", "--json"],
            ["mail", "search-index-rebuild", "--db-path", fixture.databasePath],
        ]

        for arguments in cases {
            let output = try PlainpostServiceProcess.run(arguments)
            XCTAssertTrue(
                output.hasPrefix(
                    "PlainpostService supports only --xpc-service and --version.\n"
                ),
                "\(arguments): \(output)"
            )
            XCTAssertTrue(output.contains("<PlainpostService status=64"), output)
        }
    }

    func testPlainpostServiceRejectsRetiredGenericStdioTransport() throws {
        let output = try PlainpostServiceProcess.run(["serve", "--stdio", "--json"])

        XCTAssertTrue(
            output.hasPrefix(
                "PlainpostService supports only --xpc-service and --version.\n"
            ),
            output
        )
        XCTAssertTrue(output.contains("<PlainpostService status=64"), output)
    }

    private func decodeSuccess<Value: Decodable>(
        _ type: Value.Type,
        from output: String
    ) throws -> ServiceSuccess<Value> {
        try MailSearchJSON.decoder().decode(ServiceSuccess<Value>.self, from: Data(output.utf8))
    }

    private func canonicalizedJSON(_ output: String) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ServiceSuccess<Value: Decodable>: Decodable {
    let ok: Bool
    let data: Value
}

private struct ServiceCodeFailure: Decodable {
    struct ErrorPayload: Decodable {
        let code: String
        let message: String
    }

    let ok: Bool
    let error: ErrorPayload
}

private final class MailSearchServiceTransportFixture {
    let directory: URL
    let databasePath: String
    let account = Account(
        id: AccountID("acc_search"),
        displayName: "Search",
        email: EmailAddress("me@example.com"),
        imapHost: "127.0.0.1",
        smtpHost: "127.0.0.1"
    )
    let projectThread = MailThread(
        id: ThreadID("thr_project"),
        accountID: AccountID("acc_search"),
        subjectNormalized: "project",
        participantEmails: [EmailAddress("alice@example.com"), EmailAddress("me@example.com")]
    )
    private let otherThread = MailThread(
        id: ThreadID("thr_other"),
        accountID: AccountID("acc_search"),
        subjectNormalized: "other project",
        participantEmails: [EmailAddress("bob@example.com"), EmailAddress("me@example.com")]
    )
    private let store: SQLiteMailStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-search-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("Plainpost.sqlite").path
        store = try SQLiteMailStore(path: databasePath)
        try store.migrate()
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx_search_inbox"),
                accountID: account.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
        ])
        try store.cacheThreads([projectThread, otherThread])
        try insert(
            MessageSummary(
                id: MessageID("msg_project"),
                threadID: projectThread.id,
                from: EmailAddress("alice@example.com"),
                fromDisplayName: "Alice",
                subject: "Project Alpha",
                preview: "Private project snippet",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            uid: 1
        )
        try insert(
            MessageSummary(
                id: MessageID("msg_other_project"),
                threadID: otherThread.id,
                from: EmailAddress("bob@example.com"),
                fromDisplayName: "Bob",
                subject: "Project Beta",
                preview: "Second project result",
                smartCategory: .notification,
                sentAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            uid: 2
        )
    }

    func insertRevisionChangingMessage() throws {
        try insert(
            MessageSummary(
                id: MessageID("msg_revision_change"),
                threadID: projectThread.id,
                from: EmailAddress("alice@example.com"),
                fromDisplayName: "Alice",
                subject: "Project revision change",
                preview: "New local content",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1_950_000_000)
            ),
            uid: 3
        )
    }

    func removeArtifacts() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeSearchService() throws -> SQLiteMailSearchService {
        try SQLiteMailSearchService(
            store: store,
            databasePath: databasePath
        )
    }

    private func insert(_ message: MessageSummary, uid: Int) throws {
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [account.email],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: uid,
            notificationEligible: false
        )
    }
}

private enum MailSearchCLIProcess {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("plainpost")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment
        ) { _, new in new }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find products directory")
    }
}
