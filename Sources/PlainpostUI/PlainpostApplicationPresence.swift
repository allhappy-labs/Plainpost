#if os(macOS)
import AppKit

struct PlainpostWindowPresence: Equatable, Sendable {
    let canBecomeMain: Bool
    let isVisible: Bool
    let isMiniaturized: Bool

    init(
        canBecomeMain: Bool,
        isVisible: Bool,
        isMiniaturized: Bool
    ) {
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }
}

@MainActor
public enum PlainpostApplicationPresence {
    nonisolated static func isUserFacingWindow(_ window: PlainpostWindowPresence) -> Bool {
        window.canBecomeMain && (window.isVisible || window.isMiniaturized)
    }

    nonisolated static func hasUserFacingWindow(in windows: [PlainpostWindowPresence]) -> Bool {
        windows.contains(where: isUserFacingWindow)
    }

    /// A window the user can see right now. A minimized window keeps the
    /// Dock icon (`isUserFacingWindow`) but does not count here: background
    /// session retries keep running while the mailbox is minimized.
    nonisolated static func isOnScreenWindow(_ window: PlainpostWindowPresence) -> Bool {
        window.canBecomeMain && window.isVisible && !window.isMiniaturized
    }

    nonisolated static func hasOnScreenWindow(in windows: [PlainpostWindowPresence]) -> Bool {
        windows.contains(where: isOnScreenWindow)
    }

    public static func hasOnScreenWindow(in windows: [NSWindow]) -> Bool {
        hasOnScreenWindow(in: windows.map {
            PlainpostWindowPresence(canBecomeMain: $0.canBecomeMain, isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized)
        })
    }

    public static func isUserFacingWindow(_ window: NSWindow) -> Bool {
        isUserFacingWindow(
            PlainpostWindowPresence(
                canBecomeMain: window.canBecomeMain,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized
            )
        )
    }

    public static func hasUserFacingWindow(in windows: [NSWindow]) -> Bool {
        windows.contains(where: isUserFacingWindow)
    }
}
#endif
