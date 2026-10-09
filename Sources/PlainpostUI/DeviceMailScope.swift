import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB

/// The accounts a device-wide iOS runtime serves, as read at one moment, each with its
/// source generation: every explicit `.direct` account, and every Sync Node account, whose
/// mail the device mirrors while its Node answers and syncs itself while it is in fallback.
struct DeviceMailSources: Equatable, Sendable {
    let generations: [AccountID: Int64]
    /// The served accounts whose mail comes from a Sync Node, in either mode: their changes
    /// go through the device's Node journal, which picks the Node or the provider.
    let nodeAccountIDs: Set<AccountID>
    /// The Sync Node accounts in fallback: their Node is away, so the device syncs them.
    let fallbackAccountIDs: Set<AccountID>

    init(generations: [AccountID: Int64], nodeAccountIDs: Set<AccountID> = [], fallbackAccountIDs: Set<AccountID> = []) {
        self.generations = generations
        self.nodeAccountIDs = nodeAccountIDs
        self.fallbackAccountIDs = fallbackAccountIDs
    }

    var accountIDs: Set<AccountID> { Set(generations.keys) }
    /// The served Direct accounts.
    var directAccountIDs: Set<AccountID> { accountIDs.subtracting(nodeAccountIDs) }
    /// The served accounts this device syncs with the provider itself: Direct ones, and
    /// Sync Node ones in fallback.
    var directSyncAccountIDs: Set<AccountID> { directAccountIDs.union(fallbackAccountIDs) }
}

/// The device-wide iOS runtime's replacement for "the selected account": every account it
/// serves, and a per-owner check that an action's message still belongs to one at the
/// generation the list was read with.
enum DeviceMailScope {
    /// The store's current served accounts. A store whose sources can't be read has none.
    static func current(in store: SQLiteMailStore) -> DeviceMailSources {
        guard let sources = try? store.mailSources() else { return DeviceMailSources(generations: [:]) }
        var generations: [AccountID: Int64] = [:]
        var node: Set<AccountID> = []
        var fallback: Set<AccountID> = []
        for source in sources {
            switch (source.kind, source.mode) {
            case (.direct, _) where (try? store.requireDirectMailSource(accountID: source.accountID)) != nil:
                generations[source.accountID] = source.generation
            case (.nodeBacked, .node?):
                generations[source.accountID] = source.generation
                node.insert(source.accountID)
            case (.nodeBacked, .fallback?):
                generations[source.accountID] = source.generation
                node.insert(source.accountID)
                fallback.insert(source.accountID)
            default:
                continue
            }
        }
        return DeviceMailSources(generations: generations, nodeAccountIDs: node, fallbackAccountIDs: fallback)
    }

    /// `owner`'s current generation, while it is still a served account and, when given,
    /// still at `expected`.
    @discardableResult
    static func requireCurrentOwner(_ owner: AccountID, expected: Int64?, in store: SQLiteMailStore) throws -> Int64 {
        try requireOwner(owner, expected: expected, in: store).generation
    }

    /// `owner`'s current generation, while this device syncs it with the provider itself
    /// (Direct, or a Sync Node account in fallback) and, when given, still at `expected`.
    /// For sync work that talks to the provider.
    @discardableResult
    static func requireCurrentDirectOwner(_ owner: AccountID, expected: Int64?, in store: SQLiteMailStore) throws -> Int64 {
        let current = try requireOwner(owner, expected: expected, in: store)
        guard current.source.runsDirectSync else {
            throw PlainpostError.validationFailed("This account syncs through your Sync Node.")
        }
        return current.source.generation
    }

    /// Whether `owner` is a served Sync Node account right now, in either mode: its changes
    /// go through the device's Node journal.
    static func isNodeOwner(_ owner: AccountID, in store: SQLiteMailStore) -> Bool {
        (try? requireOwner(owner, expected: nil, in: store))?.source.kind == .nodeBacked
    }

    private static func requireOwner(
        _ owner: AccountID, expected: Int64?, in store: SQLiteMailStore
    ) throws -> (generation: Int64, source: AccountMailSource) {
        guard store.accounts.contains(where: { $0.id == owner }) else {
            throw PlainpostError.notFound("The message's account was removed.")
        }
        let source = try store.mailSource(accountID: owner)
        switch (source.kind, source.mode) {
        case (.direct, _):
            try store.requireDirectMailSource(accountID: owner)
        case (.nodeBacked, .node?), (.nodeBacked, .fallback?):
            break
        default:
            throw NodeMailModeStoreError.generationConflict
        }
        if let expected, expected != source.generation { throw NodeMailModeStoreError.generationConflict }
        return (source.generation, source)
    }

    /// The local message a Sync Node push names: the push carries an opaque token of the
    /// Node's message ID, so each served Node account's mirrored Node IDs are checked (the
    /// hinted account's first). Nil when no served Node account mirrors it. A Node's message
    /// IDs are unique across every account it serves (it namespaces each non-primary
    /// account's provider IDs by its logical mailbox), and the device has one Node, so a
    /// match names one account's message.
    static func mirroredMessage(
        notificationToken token: String, logicalMailboxHint: String?, in store: SQLiteMailStore
    ) -> (messageID: MessageID, owner: AccountID)? {
        let served = current(in: store).nodeAccountIDs
        let sources = ((try? store.mailSources()) ?? []).filter { served.contains($0.accountID) }
        let ordered = sources.filter { $0.logicalMailboxID == logicalMailboxHint }
            + sources.filter { $0.logicalMailboxID != logicalMailboxHint }
        for source in ordered {
            var after = ""
            while true {
                guard let page = try? store.mirroredNodeMessageIDs(accountID: source.accountID, after: after, limit: 512),
                      !page.isEmpty else { break }
                if let nodeID = page.first(where: { NotificationOpaqueIdentities.messageToken(for: $0) == token }) {
                    guard let messageID = try? store.messageID(forNodeMessageID: nodeID, accountID: source.accountID) else {
                        return nil
                    }
                    return (messageID, source.accountID)
                }
                guard page.count == 512, let last = page.last else { break }
                after = last
            }
        }
        return nil
    }
}
