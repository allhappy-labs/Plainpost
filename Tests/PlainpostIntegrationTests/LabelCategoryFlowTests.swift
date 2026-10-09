import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class LabelCategoryFlowTests: XCTestCase {
    func testLabelsAndRecategorizationApplyToIMAPSyncedMessageAndAuditActions() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        let sync = IMAPSyncService(client: client, cache: store)
        _ = try await sync.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        let actor = PlainpostFixtures.codexActor
        let syncedMessageID = try XCTUnwrap(store.messages.first?.id)
        let labeled = try store.addLabel("Needs Reply", to: syncedMessageID, actor: actor)
        XCTAssertEqual(labeled.labels, ["Needs Reply"])

        let recategorized = try store.recategorize(syncedMessageID, as: .support, actor: actor)
        XCTAssertEqual(recategorized.smartCategory, .support)
        XCTAssertEqual(recategorized.labels, ["Needs Reply"])

        let removed = try store.removeLabel("Needs Reply", from: syncedMessageID, actor: actor)
        XCTAssertEqual(removed.labels, [])
        XCTAssertEqual(store.messages.first?.smartCategory, .support)
        XCTAssertEqual(
            store.auditEntries.map(\.action),
            ["label.add", "category.change", "label.remove"]
        )
    }
}
