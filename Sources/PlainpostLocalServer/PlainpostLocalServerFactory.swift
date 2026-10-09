import Foundation
import PlainpostDB
import PlainpostLocalAPI
import PlainpostOperations

public enum PlainpostLocalServerFactory {
    public static func make(
        socketURL: URL,
        store: SQLiteMailStore,
        lastSync: @escaping @Sendable () -> Date?,
        messageOpening: MessageOpeningService<SQLiteMailStore>,
        inboxSyncer: any PlainpostOperationClientProtocol,
        aiClient: any PlainpostOperationClientProtocol,
        selectedProviderID: @escaping @Sendable () -> String,
        deliveryService: any BrowserReplyDelivering
    ) throws -> LocalAPIUnixServer {
        let router = LocalAPIRouter(routes: [
            SessionStatusRoute(),
            UnreadListRoute(store: store, lastSync: lastSync),
            OpenMessageRoute(opening: messageOpening),
            IncrementalSyncAllRoute(accountIDs: { store.accounts.map(\.id) }, syncer: inboxSyncer),
            AISummarizeRoute(store: store, aiClient: aiClient, selectedProviderID: selectedProviderID),
            ReplyBeginRoute(store: store),
            DraftReadRoute(store: store),
            DraftUpdateRoute(store: store),
            AIDraftReplyRoute(store: store, aiClient: aiClient, selectedProviderID: selectedProviderID),
            ReplySendRoute(deliveryService: deliveryService),
        ])
        return try LocalAPIUnixServer(socketURL: socketURL, router: router)
    }
}
