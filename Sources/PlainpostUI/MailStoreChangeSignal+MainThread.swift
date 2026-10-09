import Combine
import Foundation
import PlainpostDB

public extension MailStoreChangeSignal {
    /// Store changes for SwiftUI's `onReceive`, delivered on the main thread. `post` runs on
    /// whichever thread wrote the store, usually a background one, and `onReceive` runs its
    /// action on the publisher's thread: an unhopped publisher makes SwiftUI log "Publishing
    /// changes from background threads is not allowed".
    /// One shared `mainThreadPublisher()` for views: the same publisher on every body pass, so
    /// `onReceive` has no reason to resubscribe and drop a change still hopping to main.
    @MainActor static let mainThreadChanges = mainThreadPublisher()

    static func mainThreadPublisher(center: NotificationCenter = .default) -> AnyPublisher<MailStoreChangeScope, Never> {
        center.publisher(for: notificationName)
            .map { scope(from: $0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
