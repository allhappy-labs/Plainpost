import Foundation

/// Owns one notification-service completion callback and makes delivery
/// idempotent when the normal and expiration paths race.
public final class NotificationCompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    public init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    @discardableResult
    public func finish(_ value: Value) -> Bool {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()

        callback?(value)
        return callback != nil
    }
}
