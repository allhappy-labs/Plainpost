import XCTest
@testable import PlainpostAI
@testable import PlainpostDB
import PlainpostTestSupport

final class AIIndexStatusTests: XCTestCase {
    func testStatusStartsStaleAndRebuildIndexesLocalMessages() async throws {
        let store = InMemoryMailStore.seededForStage0()
        let service = LocalAIIndexService(provider: DeterministicAIProvider(), store: store)

        let initial = await service.status()
        XCTAssertEqual(initial.state, .notBuilt)
        XCTAssertTrue(initial.isStale)
        XCTAssertEqual(initial.indexedMessageCount, 0)
        XCTAssertTrue(initial.localOnly)

        let rebuilt = try await service.rebuild(accountID: "personal", actor: PlainpostFixtures.codexActor)
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertFalse(rebuilt.isStale)
        XCTAssertEqual(rebuilt.indexedMessageCount, 1)
        XCTAssertEqual(rebuilt.providerID, "deterministic")
        XCTAssertEqual(rebuilt.modelID, "deterministic-local-embedding")
        XCTAssertTrue(rebuilt.localOnly)
    }
}
