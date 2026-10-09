import SwiftUI

struct PlainpostMenuBarMarkGeometry {
    struct Segment: Equatable {
        let start: CGPoint
        let end: CGPoint

        func distance(to point: CGPoint) -> CGFloat {
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let denominator = hypot(deltaX, deltaY)
            precondition(denominator > 0)
            let doubledArea = abs(
                deltaX * (start.y - point.y) -
                (start.x - point.x) * deltaY
            )
            return doubledArea / denominator
        }
    }

    static let canvasSize: CGFloat = 100
    static let strokeWidth: CGFloat = 4.8
    static let outerRect = CGRect(x: 5, y: 5, width: 90, height: 90)
    static let cornerRadius: CGFloat = 25
    static let sealCenter = CGPoint(x: 52, y: 53)
    static let sealRadius: CGFloat = 4.8
    static let constructionClearance: CGFloat = 14

    static let upperGlassEdge = Segment(
        start: CGPoint(x: 5, y: 53.5),
        end: CGPoint(x: 94.4, y: 24.5)
    )
    static let leftPocketFold = Segment(
        start: CGPoint(x: 5, y: 55.7),
        end: CGPoint(x: 55.2, y: 68.2)
    )
    static let uninterruptedFold = Segment(
        start: CGPoint(x: 22.5, y: 93.8),
        end: CGPoint(x: 95, y: 37.2)
    )
    static let foldSegments = [upperGlassEdge, leftPocketFold, uninterruptedFold]

    static func drawingSquare(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
    }

    static func scale(in rect: CGRect) -> CGFloat {
        drawingSquare(in: rect).width / canvasSize
    }

    static func point(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let square = drawingSquare(in: rect)
        let scale = scale(in: rect)
        return CGPoint(
            x: square.minX + point.x * scale,
            y: square.minY + point.y * scale
        )
    }

    static func scaledRect(_ normalizedRect: CGRect, in rect: CGRect) -> CGRect {
        let square = drawingSquare(in: rect)
        let scale = scale(in: rect)
        return CGRect(
            x: square.minX + normalizedRect.minX * scale,
            y: square.minY + normalizedRect.minY * scale,
            width: normalizedRect.width * scale,
            height: normalizedRect.height * scale
        )
    }
}

private struct PlainpostMenuBarMarkStrokeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        for segment in PlainpostMenuBarMarkGeometry.foldSegments {
            path.move(to: PlainpostMenuBarMarkGeometry.point(segment.start, in: rect))
            path.addLine(to: PlainpostMenuBarMarkGeometry.point(segment.end, in: rect))
        }

        let scale = PlainpostMenuBarMarkGeometry.scale(in: rect)
        path.addRoundedRect(
            in: PlainpostMenuBarMarkGeometry.scaledRect(
                PlainpostMenuBarMarkGeometry.outerRect,
                in: rect
            ),
            cornerSize: CGSize(
                width: PlainpostMenuBarMarkGeometry.cornerRadius * scale,
                height: PlainpostMenuBarMarkGeometry.cornerRadius * scale
            )
        )
        return path
    }
}

private struct PlainpostMenuBarSealShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = PlainpostMenuBarMarkGeometry.scale(in: rect)
        let center = PlainpostMenuBarMarkGeometry.point(
            PlainpostMenuBarMarkGeometry.sealCenter,
            in: rect
        )
        let radius = PlainpostMenuBarMarkGeometry.sealRadius * scale
        return Path(
            ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }
}

struct PlainpostMenuBarMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = PlainpostMenuBarMarkGeometry.strokeWidth *
                side / PlainpostMenuBarMarkGeometry.canvasSize

            ZStack {
                PlainpostMenuBarMarkStrokeShape()
                    .stroke(
                        ForegroundStyle(),
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .butt,
                            lineJoin: .miter
                        )
                    )
                PlainpostMenuBarSealShape()
                    .fill(ForegroundStyle())
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

@MainActor
enum PlainpostMenuBarMarkImage {
    static let template: NSImage = {
        let size = CGSize(width: 18, height: 18)
        let renderer = ImageRenderer(
            content: PlainpostMenuBarMark()
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.black)
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            preconditionFailure("Unable to render the Plainpost menu bar mark")
        }
        image.size = size
        image.isTemplate = true
        return image
    }()
}
