import Foundation

public enum PlainpostAppCommand: String, Sendable {
    case compose
    case commandCenter
    case focusSearch
    case smartInbox
    case approvalQueue
    case settings

    public func post(center: NotificationCenter = .default) {
        center.post(name: .plainpostAppCommand, object: rawValue)
    }
}

public extension Notification.Name {
    static let plainpostAppCommand = Notification.Name("PlainpostAppCommand")
}

extension Notification {
    var plainpostAppCommand: PlainpostAppCommand? {
        guard let rawValue = object as? String else {
            return nil
        }
        return PlainpostAppCommand(rawValue: rawValue)
    }
}
