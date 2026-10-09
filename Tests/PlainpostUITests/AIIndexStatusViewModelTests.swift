import XCTest
@testable import PlainpostAI
@testable import PlainpostUI

final class AIIndexStatusViewModelTests: XCTestCase {
    @MainActor
    func testSidebarShowsAIIndexWarningWhenIndexIsStale() {
        let stale = AIIndexStatusSnapshot(
            state: .notBuilt,
            indexedMessageCount: 0,
            providerID: "deterministic",
            modelID: nil,
            isStale: true,
            localOnly: true
        )

        let viewModel = InboxViewModel.preview(aiIndexStatus: stale)

        XCTAssertEqual(viewModel.sidebarItems.first(where: { $0.title == "AI Index Status" })?.badge, 1)
        XCTAssertEqual(viewModel.aiIndexStatus.title, "AI index not built")
        XCTAssertEqual(viewModel.aiIndexStatus.detail, "0 messages indexed")
        XCTAssertTrue(viewModel.aiIndexStatus.needsAttention)
    }

    @MainActor
    func testPausedAIIndexStatusNeedsAttention() {
        let paused = AIIndexStatusSnapshot(
            state: .paused,
            indexedMessageCount: 3,
            providerID: "deterministic",
            modelID: "deterministic-local-embedding",
            isStale: true,
            localOnly: true
        )

        let viewModel = InboxViewModel.preview(aiIndexStatus: paused)

        XCTAssertEqual(viewModel.sidebarItems.first(where: { $0.title == "AI Index Status" })?.badge, 1)
        XCTAssertEqual(viewModel.aiIndexStatus.title, "AI index paused")
        XCTAssertEqual(viewModel.aiIndexStatus.detail, "3 messages indexed")
        XCTAssertTrue(viewModel.aiIndexStatus.needsAttention)
    }
}
