import Foundation
import PlainpostCore

/// A device Sync Node bridge that records what reaches it and answers `outcome`.
public actor RecordingDeviceNodeMailBridge: DeviceNodeMailBridging {
    public private(set) var performed: [(MailIntentKind, MessageID)] = []
    public private(set) var performedFolders: [String?] = []
    public private(set) var savedDrafts: [Draft] = []
    public private(set) var sentDrafts: [Draft] = []
    public private(set) var wakes = 0
    public var outcome: DeviceNodeMailOutcome = .confirmed
    public var states: [AccountID: DeviceNodeAccountState] = [:]

    public init() {}

    public func setOutcome(_ outcome: DeviceNodeMailOutcome) { self.outcome = outcome }
    public func setStates(_ states: [AccountID: DeviceNodeAccountState]) { self.states = states }

    public var performedMessageIDs: [MessageID] { performed.map(\.1) }
    public var performedKinds: [MailIntentKind] { performed.map(\.0) }

    public func start() async {}
    public func stop() async {}
    /// Runs on each wake, as a mirror pass would land mail.
    public var onWake: (@Sendable () async -> Void)?
    public func setOnWake(_ hook: @escaping @Sendable () async -> Void) { onWake = hook }

    public func wake() async {
        wakes += 1
        await onWake?()
    }

    public func perform(_ kind: MailIntentKind, messageID: MessageID, folder: String?) async throws -> DeviceNodeMailOutcome {
        performed.append((kind, messageID))
        performedFolders.append(folder)
        return outcome
    }

    public func saveDraft(_ draft: Draft) async throws -> DeviceNodeMailOutcome {
        savedDrafts.append(draft)
        return outcome
    }

    public func send(_ draft: Draft) async throws -> DeviceNodeMailOutcome {
        sentDrafts.append(draft)
        return outcome
    }

    public private(set) var completeHistoryRequests: [AccountID] = []
    public func downloadCompleteHistory(for accountID: AccountID) async throws { completeHistoryRequests.append(accountID) }

    public func accountStates() async -> [AccountID: DeviceNodeAccountState] { states }
}
