import XCTest
@testable import PlainpostUI

final class ConversationAIUITestProviderTests: XCTestCase {
    func testUITestEnvironmentSwapsInTheDeterministicProvider() {
        XCTAssertEqual(PlainpostAppRuntime.uiTestAIProviderID("foundation", environment: [:]), "foundation")
        XCTAssertEqual(
            PlainpostAppRuntime.uiTestAIProviderID(
                "foundation", environment: ["PLAINPOST_UI_TEST_AI_PROVIDER": "deterministic"]
            ),
            "deterministic"
        )
        XCTAssertEqual(
            PlainpostAppRuntime.uiTestAIProviderID("ollama", environment: ["PLAINPOST_UI_TEST_AI_PROVIDER": "other"]),
            "ollama"
        )
    }
}
