import SwiftUI
import XCTest
@testable import PlainpostUI

final class PlatformLinkButtonStyleTests: XCTestCase {
    @MainActor
    func testLinkStyleHelperRendersOnThisPlatform() {
        let view = Button("Change Server") {}.plainpostLinkButtonStyle()
        let size = NSHostingView(rootView: view).fittingSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }
}
