import Foundation
import PlainpostCore

public enum LocalAPIProtocol {
    public static let version = 1
    public static let maximumFrameSize = 1_048_576
    public static let maximumMessageBodyBytes = 262_144
}

public enum LocalAPIJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public enum LocalAPIMethod: String, Codable, CaseIterable, Sendable {
    case sessionStatus = "session.status"
    case mailUnreadList = "mail.unreadList"
    case mailOpen = "mail.open"
    case syncIncrementalAll = "sync.incrementalAll"
    case aiSummarize = "ai.summarize"
    case replyBegin = "reply.begin"
    case draftRead = "draft.read"
    case draftUpdate = "draft.update"
    case aiDraftReply = "ai.draftReply"
    case replySend = "reply.send"
}

public struct LocalAPIRequestHeader: Codable, Sendable {
    public let apiVersion: Int
    public let requestID: String
    public let method: LocalAPIMethod
}

public struct LocalAPIRequest<Parameters: Codable & Sendable>: Codable, Sendable {
    public let apiVersion: Int
    public let requestID: String
    public let method: LocalAPIMethod
    public let parameters: Parameters

    public init(requestID: String, method: LocalAPIMethod, parameters: Parameters) {
        self.apiVersion = LocalAPIProtocol.version
        self.requestID = requestID
        self.method = method
        self.parameters = parameters
    }
}

public struct LocalAPISuccess<Result: Codable & Sendable>: Codable, Sendable {
    public let apiVersion: Int
    public let requestID: String
    public let ok: Bool
    public let result: Result

    public init(requestID: String, result: Result) {
        self.apiVersion = LocalAPIProtocol.version
        self.requestID = requestID
        self.ok = true
        self.result = result
    }
}

public enum LocalAPIErrorCode: String, Codable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case permissionDenied = "PERMISSION_DENIED"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case unavailable = "UNAVAILABLE"
    case clientUpdateRequired = "CLIENT_UPDATE_REQUIRED"
    case serverUpdateRequired = "SERVER_UPDATE_REQUIRED"
    case deliveryUncertain = "DELIVERY_UNCERTAIN"
    case operationFailed = "OPERATION_FAILED"
}

public struct LocalAPIFailure: Codable, Sendable {
    public struct Payload: Codable, Sendable {
        public let code: LocalAPIErrorCode
        public let message: String
    }
    public let apiVersion: Int
    public let requestID: String?
    public let ok: Bool
    public let error: Payload
}

public struct LocalAPIUnreadListParameters: Codable, Sendable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

public struct LocalAPIEmptyParameters: Codable, Sendable {
    public init() {}
}

public struct LocalAPISessionStatus: Codable, Equatable, Sendable {
    public let ready: Bool

    public init(ready: Bool) {
        self.ready = ready
    }
}

public struct LocalAPIUnreadMessage: Codable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let senderName: String?
    public let subject: String
    public let preview: String
    public let sentAt: Date?

    public init(
        id: String,
        sender: String,
        senderName: String?,
        subject: String,
        preview: String,
        sentAt: Date?
    ) {
        self.id = id
        self.sender = sender
        self.senderName = senderName
        self.subject = subject
        self.preview = preview
        self.sentAt = sentAt
    }
}

public struct LocalAPIUnreadListResult: Codable, Equatable, Sendable {
    public let messages: [LocalAPIUnreadMessage]
    public let lastSuccessfulSyncAt: Date?

    public init(messages: [LocalAPIUnreadMessage], lastSuccessfulSyncAt: Date?) {
        self.messages = messages
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }
}

public struct LocalAPIOpenMessageParameters: Codable, Sendable {
    public let messageID: String

    public init(messageID: String) {
        self.messageID = messageID
    }
}

public struct LocalAPIMessageDetail: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String?
    public let sender: String
    public let senderName: String?
    public let subject: String
    public let bodyPlain: String
    public let isSeen: Bool

    public init(
        id: String,
        threadID: String?,
        sender: String,
        senderName: String?,
        subject: String,
        bodyPlain: String,
        isSeen: Bool
    ) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.senderName = senderName
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.isSeen = isSeen
    }
}

public struct LocalAPISyncResult: Codable, Equatable, Sendable {
    public let completedAccountIDs: [String]
    public let failedAccountIDs: [String]
    public let newMessageCount: Int

    public init(
        completedAccountIDs: [String],
        failedAccountIDs: [String],
        newMessageCount: Int
    ) {
        self.completedAccountIDs = completedAccountIDs
        self.failedAccountIDs = failedAccountIDs
        self.newMessageCount = newMessageCount
    }
}
