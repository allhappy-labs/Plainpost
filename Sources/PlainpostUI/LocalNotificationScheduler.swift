import Foundation
import PlainpostAccountProtocol
import PlainpostCore

#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

public struct PlainpostNotification: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let categoryIdentifier: String
    public let userInfo: [String: String]
    public let playsSound: Bool

    public init(
        id: String,
        title: String,
        body: String,
        categoryIdentifier: String,
        userInfo: [String: String],
        playsSound: Bool = true
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.userInfo = userInfo
        self.playsSound = playsSound
    }

    public static func pendingSendApproval(request: SendRequest, input: ComposerDraftInput) -> PlainpostNotification {
        let subject = input.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySubject = subject.isEmpty ? "(No subject)" : subject
        let recipients = [input.to, input.cc, input.bcc]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let recipientSummary = recipients.isEmpty ? "the selected recipients" : recipients

        return PlainpostNotification(
            id: "pending-approval-\(request.id.rawValue)",
            title: "Approval needed",
            body: "\(request.requestedBy) requested approval to send \"\(displaySubject)\" to \(recipientSummary).",
            categoryIdentifier: "send_approval",
            userInfo: [
                "send_request_id": request.id.rawValue,
                "draft_id": request.draftID.rawValue
            ]
        )
    }

    public static func newMail(_ message: MessageSummary) -> PlainpostNotification {
        newMail(
            message,
            id: "new-mail-\(message.id.rawValue)",
            userInfo: ["message_id": message.id.rawValue]
        )
    }

    public static func newMail(
        _ message: MessageSummary,
        accountID: AccountID,
        sourceKind: AccountMailSourceKind,
        sourceGeneration: Int64
    ) -> PlainpostNotification {
        let token = NotificationOpaqueIdentities.messageToken(
            for: message.id.rawValue,
            accountID: accountID.rawValue,
            sourceKind: sourceKind.rawValue,
            sourceGeneration: sourceGeneration
        )
        return newMail(
            message,
            id: "new-mail-\(token)",
            userInfo: ["plainpost.openToken": token]
        )
    }

    private static func newMail(
        _ message: MessageSummary,
        id: String,
        userInfo: [String: String]
    ) -> PlainpostNotification {
        let showsPreview = PlainpostNotificationPreference.newMailPreviewEnabled
        let displaySender = message.fromDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? message.from.rawValue
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = message.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [subject.isEmpty ? "(No subject)" : subject, preview]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")

        return PlainpostNotification(
            id: id,
            title: showsPreview ? displaySender : "New message",
            body: showsPreview ? detail : "Open Plainpost to view it.",
            categoryIdentifier: "new_mail",
            userInfo: userInfo,
            playsSound: PlainpostNotificationPreference.notificationSoundsEnabled
        )
    }

    public static func newMailSummary(account: Account, count: Int) -> PlainpostNotification {
        PlainpostNotification(
            id: "new-mail-summary-\(account.id.rawValue)-\(UUID().uuidString)",
            title: "New mail",
            body: "\(count) new messages arrived for \(account.email.rawValue).",
            categoryIdentifier: "new_mail",
            userInfo: ["account_id": account.id.rawValue],
            playsSound: PlainpostNotificationPreference.notificationSoundsEnabled
        )
    }

    public static func syncCompleted(account: Account, newMessageCount: Int) -> PlainpostNotification {
        let countText = newMessageCount == 1 ? "1 new message" : "\(newMessageCount) new messages"
        return PlainpostNotification(
            id: "sync-completed-\(account.id.rawValue)-\(UUID().uuidString)",
            title: "Mail sync completed",
            body: "\(account.email.rawValue): \(countText).",
            categoryIdentifier: "sync_completed",
            userInfo: ["account_id": account.id.rawValue],
            playsSound: false
        )
    }

    public static func syncFailed(account: Account) -> PlainpostNotification {
        PlainpostNotification(
            id: "sync-failed-\(account.id.rawValue)-\(UUID().uuidString)",
            title: "Mail sync failed",
            body: "Plainpost could not update \(account.email.rawValue). Check Diagnostics for details.",
            categoryIdentifier: "sync_failed",
            userInfo: ["account_id": account.id.rawValue],
            playsSound: PlainpostNotificationPreference.notificationSoundsEnabled
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public protocol LocalNotificationScheduling: Sendable {
    func schedule(_ notification: PlainpostNotification) async throws
}

public struct NoopLocalNotificationScheduler: LocalNotificationScheduling {
    public init() {}
    public func schedule(_ notification: PlainpostNotification) async throws {}
}

public enum LocalNotificationError: Error, Equatable, Sendable {
    case authorizationDenied
}

enum LocalNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case unavailable
}

enum SystemNotificationCenterFailure: Error, Equatable, Sendable {
    case transient
    case permanent
}

protocol SystemNotificationCenterAdapting: Sendable {
    func authorizationStatus() async -> LocalNotificationAuthorization
    func requestAuthorization() async throws -> LocalNotificationAuthorization
    func add(_ notification: PlainpostNotification) async throws
    /// The message tokens of the notifications still in Notification Center: a push names
    /// `plainpost.deepLinkToken`, a local alert `plainpost.openToken`.
    func deliveredMessageTokens() async -> Set<String>
}

extension SystemNotificationCenterAdapting {
    func deliveredMessageTokens() async -> Set<String> { [] }
}

public enum PlainpostNotificationPreference {
    public static let newMailKey = "Plainpost.notifications.newMail"
    public static let newMailPreviewKey = "Plainpost.notifications.newMailPreview"
    public static let notificationSoundsKey = "Plainpost.notifications.sounds"
    public static let pendingSendApprovalsKey = "Plainpost.notifications.pendingSendApprovals"
    public static let syncFailuresKey = "Plainpost.notifications.syncFailures"

    public static var newMailEnabled: Bool { value(forKey: newMailKey, default: true) }
    public static var newMailPreviewEnabled: Bool { value(forKey: newMailPreviewKey, default: true) }
    public static var notificationSoundsEnabled: Bool { value(forKey: notificationSoundsKey, default: true) }
    public static var syncFailuresEnabled: Bool { value(forKey: syncFailuresKey, default: true) }

    public static var pendingSendApprovalsEnabled: Bool {
        value(forKey: pendingSendApprovalsKey, default: true)
    }

    public static func isEnabled(categoryIdentifier: String) -> Bool {
        switch categoryIdentifier {
        case "new_mail": newMailEnabled
        case "send_approval": pendingSendApprovalsEnabled
        case "sync_completed": false
        case "sync_failed": syncFailuresEnabled
        default: true
        }
    }

    private static func value(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

enum PlainpostNotificationSound {
    static let resourceName = "PlainpostNotification.caf"

    static func resolveResourceName(for notification: PlainpostNotification) -> String? {
        notification.playsSound ? resourceName : nil
    }
}

#if canImport(UserNotifications)
final class SystemUserNotificationCenterAdapter: SystemNotificationCenterAdapting,
    @unchecked Sendable
{
    private let center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    init() {
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        guard let center else { return .unavailable }
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        guard let center else { return .unavailable }
        let granted = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return granted ? .authorized : .denied
    }

    func deliveredMessageTokens() async -> Set<String> {
        guard let center else { return [] }
        let delivered = await center.deliveredNotifications()
        return Set(delivered.compactMap { notification in
            let userInfo = notification.request.content.userInfo
            return userInfo["plainpost.deepLinkToken"] as? String ?? userInfo["plainpost.openToken"] as? String
        })
    }

    func add(_ notification: PlainpostNotification) async throws {
        guard let center else { throw SystemNotificationCenterFailure.permanent }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.categoryIdentifier
        content.userInfo = notification.userInfo
        if let resourceName = PlainpostNotificationSound.resolveResourceName(for: notification) {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(resourceName))
        }
        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                center.add(request) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == NSURLErrorDomain,
               [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet].contains(code) {
                throw SystemNotificationCenterFailure.transient
            }
            throw SystemNotificationCenterFailure.permanent
        }
    }
}

public final class UserNotificationsLocalScheduler: LocalNotificationScheduling, @unchecked Sendable {
    private let adapter: any SystemNotificationCenterAdapting

    public init(center: UNUserNotificationCenter = .current()) {
        adapter = SystemUserNotificationCenterAdapter(center: center)
    }

    init(adapter: any SystemNotificationCenterAdapting) {
        self.adapter = adapter
    }

    public func schedule(_ notification: PlainpostNotification) async throws {
        guard PlainpostNotificationPreference.isEnabled(
            categoryIdentifier: notification.categoryIdentifier
        ) else {
            return
        }
        guard await adapter.authorizationStatus() == .authorized else {
            throw LocalNotificationError.authorizationDenied
        }
        try await adapter.add(notification)
    }
}
#endif
