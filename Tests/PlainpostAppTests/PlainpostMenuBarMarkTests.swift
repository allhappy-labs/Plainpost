import SwiftUI
import XCTest
@testable import PlainpostApp

final class PlainpostMenuBarMarkTests: XCTestCase {
    func testGeometryMatchesApprovedConstruction() {
        XCTAssertEqual(PlainpostMenuBarMarkGeometry.canvasSize, 100)
        XCTAssertEqual(PlainpostMenuBarMarkGeometry.strokeWidth, 4.8)
        XCTAssertEqual(
            PlainpostMenuBarMarkGeometry.outerRect,
            CGRect(x: 5, y: 5, width: 90, height: 90)
        )
        XCTAssertEqual(PlainpostMenuBarMarkGeometry.cornerRadius, 25)
        XCTAssertEqual(PlainpostMenuBarMarkGeometry.sealCenter, CGPoint(x: 52, y: 53))
        XCTAssertEqual(PlainpostMenuBarMarkGeometry.sealRadius, 4.8)

        XCTAssertEqual(
            PlainpostMenuBarMarkGeometry.foldSegments,
            [
                .init(start: CGPoint(x: 5, y: 53.5), end: CGPoint(x: 94.4, y: 24.5)),
                .init(start: CGPoint(x: 5, y: 55.7), end: CGPoint(x: 55.2, y: 68.2)),
                .init(start: CGPoint(x: 22.5, y: 93.8), end: CGPoint(x: 95, y: 37.2))
            ]
        )
    }

    func testFoldLinesKeepBalancedClearanceFromSeal() {
        for segment in PlainpostMenuBarMarkGeometry.foldSegments {
            XCTAssertEqual(
                segment.distance(to: PlainpostMenuBarMarkGeometry.sealCenter),
                PlainpostMenuBarMarkGeometry.constructionClearance,
                accuracy: 0.05
            )
        }
    }

    func testLeftPocketFoldMeetsUninterruptedDiagonal() {
        XCTAssertEqual(
            PlainpostMenuBarMarkGeometry.uninterruptedFold.distance(
                to: PlainpostMenuBarMarkGeometry.leftPocketFold.end
            ),
            0,
            accuracy: 0.1
        )
    }

    @MainActor
    func testMarkRendersAtSupportedSizesInLightAndDark() {
        for colorScheme in [ColorScheme.light, .dark] {
            for size in [16.0, 18.0, 20.0, 24.0] {
                let renderer = ImageRenderer(
                    content: PlainpostMenuBarMark()
                        .frame(width: size, height: size)
                        .environment(\.colorScheme, colorScheme)
                )
                renderer.proposedSize = ProposedViewSize(width: size, height: size)
                XCTAssertNotNil(renderer.nsImage)
            }
        }
    }

    @MainActor
    func testMenuBarImageIsAnEighteenPointTemplate() {
        let image = PlainpostMenuBarMarkImage.template

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
