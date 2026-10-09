import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 4,
      let pid = Int32(CommandLine.arguments[1]),
      let launchEpoch = TimeInterval(CommandLine.arguments[2]),
      let timeout = TimeInterval(CommandLine.arguments[3]) else {
    exit(2)
}

let deadline = Date().addingTimeInterval(timeout)
repeat {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let isReady = windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else {
            return false
        }
        return width >= 400 && height >= 300
    }
    if isReady {
        print(Date().timeIntervalSince1970 - launchEpoch)
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.05)
} while Date() < deadline

exit(1)
