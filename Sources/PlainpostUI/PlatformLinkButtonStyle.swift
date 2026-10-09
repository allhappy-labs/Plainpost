import SwiftUI

public extension View {
    /// `.link` on macOS; `.borderless` with the accent tint on iOS (LinkButtonStyle is unavailable there).
    @ViewBuilder
    func plainpostLinkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless).tint(.accentColor)
        #endif
    }
}
