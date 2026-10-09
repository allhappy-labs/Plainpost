import SwiftUI

enum MailboxCanvasSurfaceRole: Equatable, Sendable {
    case workArea

    var color: Color {
        switch self {
        case .workArea:
            MailDesign.workArea
        }
    }
}

enum MailboxCanvasLayout {
    static let maximumWidth: CGFloat = .infinity
    static let maximumHeight: CGFloat = .infinity
    static let listBackgroundVisibility: Visibility = .hidden
    static let surfaceRole: MailboxCanvasSurfaceRole = .workArea
    static let emptyStateMaximumWidth: CGFloat = .infinity
    static let emptyStateMaximumHeight: CGFloat = .infinity
    static let readerContentMaximumWidth: CGFloat = .infinity
    static let readerColumnMaximumWidth: CGFloat = .infinity
}

extension View {
    func mailboxCanvas() -> some View {
        MailboxCanvas(
            content: self,
            maximumWidth: MailboxCanvasLayout.maximumWidth
        )
    }

    func mailboxReaderCanvas() -> some View {
        MailboxCanvas(
            content: self,
            maximumWidth: MailboxCanvasLayout.readerColumnMaximumWidth
        )
    }

    func mailboxListCanvas() -> some View {
        MailboxListCanvas(content: self)
    }

    func mailboxEmptyStateFrame() -> some View {
        frame(
            maxWidth: MailboxCanvasLayout.emptyStateMaximumWidth,
            maxHeight: MailboxCanvasLayout.emptyStateMaximumHeight
        )
    }
}

private struct MailboxCanvas<Content: View>: View {
    let content: Content
    let maximumWidth: CGFloat

    var body: some View {
        content.frame(
            maxWidth: maximumWidth,
            maxHeight: MailboxCanvasLayout.maximumHeight,
            alignment: .topLeading
        )
        .background(MailboxCanvasLayout.surfaceRole.color)
    }
}

private struct MailboxListCanvas<Content: View>: View {
    let content: Content

    var body: some View {
        content.scrollContentBackground(
            MailboxCanvasLayout.listBackgroundVisibility
        )
        .background(MailboxCanvasLayout.surfaceRole.color)
    }
}
