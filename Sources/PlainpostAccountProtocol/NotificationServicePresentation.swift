import CryptoKit
import Foundation

/// The local privacy choice applied after an envelope has been authenticated.
/// The extension never attempts to infer this from untrusted notification data.
public enum NotificationPreviewPolicy: String, Codable, Equatable, Sendable {
    case rich
    case senderAndSubject
    case generic
    case off
}

public struct NotificationPresentation: Equatable, Sendable {
    public let title: String?
    public let subtitle: String?
    public let body: String
    public let badge: NSNumber?
    public let threadIdentifier: String?
    public let categoryIdentifier: String?
    public let deepLinkToken: String?
    public let mailboxToken: String?
    public let threadToken: String?
    public let messageToken: String?

    public static let fallback = NotificationPresentation(
        title: nil,
        subtitle: nil,
        body: "New mail is available.",
        badge: nil,
        threadIdentifier: nil,
        categoryIdentifier: nil,
        deepLinkToken: nil
    )

    public init(title: String?, subtitle: String? = nil, body: String, badge: NSNumber? = nil, threadIdentifier: String? = nil, categoryIdentifier: String? = nil, deepLinkToken: String? = nil, mailboxToken: String? = nil, threadToken: String? = nil, messageToken: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.badge = badge
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.deepLinkToken = deepLinkToken
        self.mailboxToken = mailboxToken
        self.threadToken = threadToken
        self.messageToken = messageToken
    }
}

/// Durable recipient-side authority for one logical mailbox. The extension
/// stores a bounded array of these records in the shared device-only
/// keychain; no local provider account or mailbox path is part of the key.
public struct NotificationMailboxContextRecord: Codable, Equatable, Sendable {
    public let logicalMailboxID: Data
    public let recipientAgreementPrivateKey: Data
    public let recipientDeviceID: String
    public let producerDeviceID: String
    public let producerSigningPublicKey: Data
    public let assignmentGeneration: UInt64
    public let trustEpoch: UInt64
    public let trustRevision: UInt64
    public let trustHead: Data
    public let policy: NotificationPreviewPolicy

    public init(logicalMailboxID: Data, recipientAgreementPrivateKey: Data, recipientDeviceID: String, producerDeviceID: String, producerSigningPublicKey: Data, assignmentGeneration: UInt64, trustEpoch: UInt64, trustRevision: UInt64, trustHead: Data, policy: NotificationPreviewPolicy) throws {
        guard logicalMailboxID.count == 32, logicalMailboxID.contains(where: { $0 != 0 }),
              recipientAgreementPrivateKey.count == 32,
              (try? AccountDeviceID(recipientDeviceID)) != nil,
              (try? AccountDeviceID(producerDeviceID)) != nil,
              AccountP256SEC1Validator.isValidUncompressedPoint(producerSigningPublicKey),
              assignmentGeneration > 0, trustEpoch > 0, trustRevision > 0,
              trustHead.count == 32, trustHead.contains(where: { $0 != 0 }) else {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }
        self.logicalMailboxID = logicalMailboxID
        self.recipientAgreementPrivateKey = recipientAgreementPrivateKey
        self.recipientDeviceID = recipientDeviceID
        self.producerDeviceID = producerDeviceID
        self.producerSigningPublicKey = producerSigningPublicKey
        self.assignmentGeneration = assignmentGeneration
        self.trustEpoch = trustEpoch
        self.trustRevision = trustRevision
        self.trustHead = trustHead
        self.policy = policy
    }
}

public protocol NotificationReplayProtecting: Sendable {
    /// Claims an opaque replay identifier. `false` means it was already seen.
    func claim(_ replayID: Data) -> Bool
}

public final class InMemoryNotificationReplayStore: NotificationReplayProtecting, @unchecked Sendable {
    public static let lifetime: TimeInterval = 24 * 60 * 60
    private let lock = NSLock()
    private var values: [Data: Date] = [:]
    private let capacity: Int
    private let clock: @Sendable () -> Date

    public init(capacity: Int = 128, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    public func claim(_ replayID: Data) -> Bool {
        guard replayID.count == 32 else { return false }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        values = values.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        guard values[replayID] == nil else { return false }
        if values.count >= capacity,
           let oldest = values.min(by: { left, right in
               if left.value != right.value { return left.value < right.value }
               return left.key.lexicographicallyPrecedes(right.key)
           }) {
            values.removeValue(forKey: oldest.key)
        }
        values[replayID] = now
        return true
    }
}

#if canImport(Security)
import Security

/// Shared device-only state used by the app and the notification extension.
/// The access group is supplied by the extension target; no App Group or
/// synchronizable Keychain item is required for the encrypted envelope path.
public final class NotificationSharedKeychainStore: @unchecked Sendable {
    static let managedAccounts = [
        "agreementPrivateKey", "agreementPublicKey", "attestKeyID", "pendingAttestation",
        "routingHandle", "recipientDeviceID", "nodeDeviceID", "nodeSigningPublicKey",
        "trustEpoch", "trustRevision", "trustHead", "previewPolicy", "deepLinkMapping",
        "registrationState", "mailboxContexts",
    ]
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.marynavdovenko.Plainpost.notifications", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NotificationSharedStateError.unavailable }
        return data
    }

    public func save(_ value: Data, account: String) throws {
        guard !value.isEmpty else { throw NotificationSharedStateError.invalid }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NotificationSharedStateError.unavailable }
        var add = query
        add.merge(attributes) { _, replacement in replacement }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw NotificationSharedStateError.unavailable }
    }

    /// Atomically claims a replay account. Keychain's duplicate-item result
    /// is the cross-process compare-and-set; no process-local lock is used.
    func addIfAbsent(_ value: Data, account: String) throws -> Bool {
        guard !value.isEmpty else { throw NotificationSharedStateError.invalid }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw NotificationSharedStateError.unavailable }
        return true
    }

    fileprivate struct ReplayRecord {
        let account: String
        let creationDate: Date?
    }

    fileprivate func replayRecords() throws -> [ReplayRecord] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let records = result as? [[String: Any]] else { throw NotificationSharedStateError.unavailable }
        return records.compactMap { record in
            guard let account = record[kSecAttrAccount as String] as? String, account.hasPrefix("replay.") else { return nil }
            return ReplayRecord(account: account, creationDate: record[kSecAttrCreationDate as String] as? Date)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotificationSharedStateError.unavailable }
    }

    /// Removes all app/notification-extension registration material and every
    /// replay marker from this device-only shared group. Account deletion is a
    /// terminal boundary, so retaining any one of these values could let a
    /// deleted account survive a later process launch.
    public func purgeAll() throws {
        for account in Self.managedAccounts { try delete(account: account) }
        for record in try replayRecords() { try delete(account: record.account) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public enum NotificationSharedStateError: Error, Equatable, Sendable { case unavailable, invalid }

protocol NotificationReplayAtomicStoring: Sendable {
    func addIfAbsent(_ replayID: Data) throws -> Bool
    func prune(maximum: Int, preserving replayID: Data) throws
    func purgeExpired(before: Date) throws
}

private final class KeychainNotificationReplayBacking: NotificationReplayAtomicStoring, @unchecked Sendable {
    private let store: NotificationSharedKeychainStore
    init(store: NotificationSharedKeychainStore) { self.store = store }

    func addIfAbsent(_ replayID: Data) throws -> Bool {
        try store.addIfAbsent(Data([1]), account: NotificationReplayKeychainStore.accountName(for: replayID))
    }

    func prune(maximum: Int, preserving replayID: Data) throws {
        let records = try store.replayRecords()
        guard records.count > maximum else { return }
        let preserved = NotificationReplayKeychainStore.accountName(for: replayID)
        let removable = records
            .filter { $0.account != preserved }
            .sorted {
                switch ($0.creationDate, $1.creationDate) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    return $0.account < $1.account
                }
            }
        let removeCount = min(records.count - maximum, removable.count)
        for record in removable.prefix(removeCount) { try store.delete(account: record.account) }
    }

    func purgeExpired(before date: Date) throws {
        let cutoff = date.addingTimeInterval(-InMemoryNotificationReplayStore.lifetime)
        for record in try store.replayRecords() {
            if let created = record.creationDate, created <= cutoff { try store.delete(account: record.account) }
        }
    }
}

public final class NotificationReplayKeychainStore: NotificationReplayProtecting, @unchecked Sendable {
    private let backing: any NotificationReplayAtomicStoring
    private let clock: @Sendable () -> Date

    public init(store: NotificationSharedKeychainStore = NotificationSharedKeychainStore()) {
        backing = KeychainNotificationReplayBacking(store: store)
        clock = { Date() }
    }
    init(backing: any NotificationReplayAtomicStoring, clock: @escaping @Sendable () -> Date = { Date() }) { self.backing = backing; self.clock = clock }

    static func accountName(for replayID: Data) -> String {
        "replay.\(AccountWireCodec.encodeBase64URL(replayID))"
    }

    public func claim(_ replayID: Data) -> Bool {
        guard replayID.count == 32 else { return false }
        try? backing.purgeExpired(before: clock())
        guard (try? backing.addIfAbsent(replayID)) == true else { return false }
        try? backing.prune(maximum: 128, preserving: replayID)
        return true
    }
}
#endif

public enum NotificationServicePresentation {
    public static let fallback = NotificationPresentation.fallback

    /// The extension may blank an APNs alert only when the authenticated local
    /// policy is Off. Authentication, expiry, replay, and trust failures must
    /// retain the provider's fixed generic fallback.
    public static func shouldSuppressFallback(policy: NotificationPreviewPolicy) -> Bool {
        policy == .off
    }

    public static func groupIdentifier(mailboxToken: String, threadToken: String) -> String? {
        guard !mailboxToken.isEmpty, !threadToken.isEmpty,
              mailboxToken.utf8.count <= 256, threadToken.utf8.count <= 256,
              !mailboxToken.contains(where: { $0 == "\0" || $0.isNewline }),
              !threadToken.contains(where: { $0 == "\0" || $0.isNewline }) else { return nil }
        let input = Data((mailboxToken + "\u{0}" + threadToken).utf8)
        let digest = Data(SHA256.hash(data: input))
        return "plainpost-mail-" + AccountWireCodec.encodeBase64URL(digest)
    }

    public struct Context: Sendable {
        public let recipientAgreementPrivateKey: Data
        public let authority: RichNotificationEnvelope.Authority
        public let trustEpoch: UInt64
        public let trustRevision: UInt64
        public let trustHead: Data
        public let policy: NotificationPreviewPolicy
        public let replay: any NotificationReplayProtecting

        public init(recipientAgreementPrivateKey: Data, authority: RichNotificationEnvelope.Authority, trustEpoch: UInt64, trustRevision: UInt64, trustHead: Data, policy: NotificationPreviewPolicy, replay: any NotificationReplayProtecting) {
            self.recipientAgreementPrivateKey = recipientAgreementPrivateKey
            self.authority = authority
            self.trustEpoch = trustEpoch
            self.trustRevision = trustRevision
            self.trustHead = trustHead
            self.policy = policy
            self.replay = replay
        }

        #if DEBUG
        static func testFixture(policy: NotificationPreviewPolicy, replay: NotificationReplayProtecting = InMemoryNotificationReplayStore()) -> Context {
            let nodeKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
            let authority = try! RichNotificationEnvelope.Authority(
                recipientDeviceID: try! AccountDeviceID("20000000-0000-4000-8000-000000000002"),
                nodeID: try! AccountDeviceID("30000000-0000-4000-8000-000000000003"),
                nodeSigningPublicKey: nodeKey.publicKey.x963Representation
            )
            return Context(
                recipientAgreementPrivateKey: Data(repeating: 0, count: 31) + Data([2]),
                authority: authority,
                trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32), policy: policy, replay: replay
            )
        }
        #endif
    }

    /// Reads only the opaque envelope field. Plaintext sender/subject/body
    /// fields in an APNs payload are intentionally ignored.
    public static func render(userInfo: [AnyHashable: Any], context: Context, now: Date = Date()) throws -> NotificationPresentation {
        guard context.policy != .off,
              let encoded = envelopeString(in: userInfo),
              let wire = try? AccountWireCodec.decodeBase64URL(encoded, exactBytes: nil),
              wire.count <= 4096,
              let opened = try? RichNotificationEnvelope.open(wire, recipientAgreementPrivateKey: context.recipientAgreementPrivateKey, authority: context.authority, now: now),
              opened.header.trustEpoch == context.trustEpoch,
              opened.header.trustRevision == context.trustRevision,
              opened.header.trustHead == context.trustHead,
              context.replay.claim(opened.header.replayID)
        else { return .fallback }

        let content = opened.content
        let title: String?
        let subtitle: String?
        let body: String
        switch context.policy {
        case .rich:
            title = content.sender
            subtitle = content.subject
            body = content.preview
        case .senderAndSubject:
            title = content.sender
            subtitle = content.subject
            body = ""
        case .generic:
            title = nil
            subtitle = nil
            body = "New mail is available."
        case .off:
            return .fallback
        }
        return NotificationPresentation(title: title, subtitle: subtitle, body: body, badge: NSNumber(value: Int(content.badge)), threadIdentifier: groupIdentifier(mailboxToken: content.mailboxToken, threadToken: content.threadToken), categoryIdentifier: "PLAINPOST_MAIL", deepLinkToken: content.messageToken, mailboxToken: content.mailboxToken, threadToken: content.threadToken, messageToken: content.messageToken)
    }

    /// Selects a mailbox-scoped authority using only the opaque wire mailbox
    /// coordinate, then delegates to the authenticated single-context path.
    /// Missing or malformed coordinates intentionally retain the generic
    /// fallback and never reveal which mailbox contexts are installed.
    public static func render(userInfo: [AnyHashable: Any], contexts: [Data: Context], now: Date = Date()) throws -> NotificationPresentation {
        guard let encoded = envelopeString(in: userInfo),
              let wire = try? AccountWireCodec.decodeBase64URL(encoded, exactBytes: nil),
              wire.count <= 4096,
              let mailboxID = try? RichNotificationEnvelope.mailboxID(in: wire),
              let context = contexts[mailboxID] else {
            return .fallback
        }
        return try render(userInfo: userInfo, context: context, now: now)
    }

    private static func envelopeString(in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo["plainpost.envelope"] as? String { return value }
        if let value = userInfo["envelope"] as? String { return value }
        if let nested = userInfo["plainpost"] as? [AnyHashable: Any] { return nested["envelope"] as? String }
        if let nested = userInfo["plainpost"] as? [String: Any] { return nested["envelope"] as? String }
        return nil
    }
}
