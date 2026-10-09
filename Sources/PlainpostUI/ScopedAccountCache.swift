import Foundation
import PlainpostCore
import PlainpostDB

/// The account a single-account runtime serves, read from the store once and again only
/// after the store signals an account change. A list asks for it once per row and per
/// render (Archive or Delete), so it must not open SQLite each time.
final class ScopedAccountCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (accountID: AccountID, account: Account?)?
    private var generation = 0
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Observes `centers` for account changes; the default is the in-process center and, on
    /// macOS, the cross-process one another Plainpost process writes to.
    init(centers: [NotificationCenter] = ScopedAccountCache.defaultCenters) {
        for center in centers {
            let token = center.addObserver(
                forName: MailStoreChangeSignal.notificationName,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                switch MailStoreChangeSignal.scope(from: notification) {
                case .accounts, .all: self?.invalidate()
                case .mailbox, .operations: break
                }
            }
            observations.append((center, token))
        }
    }

    deinit {
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
    }

    static var defaultCenters: [NotificationCenter] {
        #if os(macOS)
        [.default, DistributedNotificationCenter.default()]
        #else
        [.default]
        #endif
    }

    /// The cached account for `accountID`, or `read()`'s answer, kept until the next account
    /// change. A missing account is cached too. A change signalled while `read()` runs
    /// discards its answer, so a stale read never outlives the change.
    func account(_ accountID: AccountID, read: () -> Account?) -> Account? {
        let (hit, startGeneration) = lock.withLock {
            (cached?.accountID == accountID ? cached : nil, generation)
        }
        if let hit { return hit.account }
        let account = read()
        lock.withLock {
            if generation == startGeneration { cached = (accountID, account) }
        }
        return account
    }

    func invalidate() {
        lock.withLock {
            generation += 1
            cached = nil
        }
    }
}
