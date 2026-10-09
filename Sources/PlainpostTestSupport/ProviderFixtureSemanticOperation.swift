import Foundation

// Typed semantic fixture values deliberately live in TestSupport. They are
// package-internal test seams, not production provider APIs.
struct ProviderFixtureSemanticOperation: Equatable {
    enum Action: String, Equatable {
        case discover
        case synchronize = "sync"
        case wait
        case setFlags = "set_flags"
        case setLabels = "set_labels"
        case move
        case delete
        case append
        case fetchPart = "fetch_part"
    }

    struct Common: Equatable {
        let provider: String
        let transport: String
        let authentication: String
        let peer: Peer
    }

    /// A closed, action-discriminated input union.  Action-only fields live
    /// exclusively in their corresponding case, so a caller cannot construct
    /// a discover input that also carries a move destination or append data.
    enum Input: Equatable {
        case discover(Common)
        case synchronizeBaseline(Common, mailbox: String, pageSize: Int)
        case synchronizeIncremental(Common, mailbox: String, pageSize: Int, cursor: String)
        case synchronizeReconcile(Common, mailbox: String, pageSize: Int, cursor: String, knownRawIDs: [String])
        case wait(Common, mailbox: String, maximumWaitMilliseconds: Int)
        case setFlags(Common, mailbox: String, rawID: String, addFlags: [String], removeFlags: [String], expectedModSequence: Int?)
        case setLabels(Common, mailbox: String, rawID: String, addLabels: [Label], removeLabels: [Label])
        case move(Common, mailbox: String, rawID: String, destination: String)
        case delete(Common, mailbox: String, rawID: String)
        case append(Common, mailbox: String, destination: String?, flags: [String], messageID: String, appendPurpose: String, appendAttempts: Int)
        case fetchPart(Common, mailbox: String, rawID: String, path: String, pageSize: Int)

        var action: Action {
            switch self {
            case .discover: return .discover
            case .synchronizeBaseline, .synchronizeIncremental, .synchronizeReconcile: return .synchronize
            case .wait: return .wait
            case .setFlags: return .setFlags
            case .setLabels: return .setLabels
            case .move: return .move
            case .delete: return .delete
            case .append: return .append
            case .fetchPart: return .fetchPart
            }
        }

        var common: Common {
            switch self {
            case let .discover(common): return common
            case let .synchronizeBaseline(common, mailbox: _, pageSize: _): return common
            case let .synchronizeIncremental(common, mailbox: _, pageSize: _, cursor: _): return common
            case let .synchronizeReconcile(common, mailbox: _, pageSize: _, cursor: _, knownRawIDs: _): return common
            case let .wait(common, mailbox: _, maximumWaitMilliseconds: _): return common
            case let .setFlags(common, mailbox: _, rawID: _, addFlags: _, removeFlags: _, expectedModSequence: _): return common
            case let .setLabels(common, mailbox: _, rawID: _, addLabels: _, removeLabels: _): return common
            case let .move(common, mailbox: _, rawID: _, destination: _): return common
            case let .delete(common, mailbox: _, rawID: _): return common
            case let .append(common, mailbox: _, destination: _, flags: _, messageID: _, appendPurpose: _, appendAttempts: _): return common
            case let .fetchPart(common, mailbox: _, rawID: _, path: _, pageSize: _): return common
            }
        }
    }

    struct Peer: Equatable {
        struct Mailbox: Equatable {
            let id: String
            let displayName: String
            let selectable: Bool
            let specialUse: String
        }

        let capabilities: [String]
        let mailboxes: [Mailbox]
        let uidValidity: Int
        let idleBehavior: String
        let appendResponses: [String]
        let disconnect: String
        let catalogBehavior: String
        let metadataBehavior: String
        let security: String
        let oauthBehavior: String

        init(
            capabilities: [String],
            mailboxes: [Mailbox],
            uidValidity: Int,
            idleBehavior: String,
            appendResponses: [String],
            disconnect: String,
            catalogBehavior: String,
            metadataBehavior: String = "normal",
            security: String,
            oauthBehavior: String
        ) {
            self.capabilities = capabilities
            self.mailboxes = mailboxes
            self.uidValidity = uidValidity
            self.idleBehavior = idleBehavior
            self.appendResponses = appendResponses
            self.disconnect = disconnect
            self.catalogBehavior = catalogBehavior
            self.metadataBehavior = metadataBehavior
            self.security = security
            self.oauthBehavior = oauthBehavior
        }
    }

    struct Outcome: Equatable {
        let state: String
        let code: String
        let providerReference: String
        let sentCopy: String
        let destinationRawID: String
    }

    struct MailboxRef: Equatable {
        let id: String
        let epoch: Int
    }

    struct MessageRef: Equatable {
        let mailbox: MailboxRef
        let rawID: String
    }

    struct Address: Equatable {
        let displayName: String
        let mailbox: String
    }

    struct Label: Equatable {
        let id: String
        let displayName: String
    }

    struct Body: Equatable {
        let state: String
        let value: String
    }

    struct PartDescriptor: Equatable {
        let path: String
        let filename: String
        let mimeType: String
        let disposition: String
        let contentID: String
        let declaredSize: Int
    }

    struct Message: Equatable {
        let rfcMessageID: String
        let providerStableID: String
        let providerThreadID: String
        let inReplyTo: [String]
        let references: [String]
        let from: [Address]
        let sender: Address?
        let replyTo: [Address]
        let to: [Address]
        let cc: [Address]
        let bcc: [Address]
        let subject: String
        let receivedAt: String
        let sentAt: String?
        let flags: [String]
        let labels: [Label]
        let textBody: Body
        let htmlBody: Body
        let parts: [PartDescriptor]
    }

    struct Change: Equatable {
        let kind: String
        let ref: MessageRef
        let message: Message?
    }

    struct Cursor: Equatable {
        let provider: String
        let mailboxID: String
        let epoch: Int
        let uidValidity: Int
        let lastUID: Int
        let scanUID: Int
    }

    struct Catalog: Equatable {
        let mailboxes: [Peer.Mailbox]
    }

    struct Page: Equatable {
        let mailbox: MailboxRef
        let changes: [Change]
        let nextCursor: Cursor?
        let hasMore: Bool
        let observedUIDValidity: Int
        let epochReset: Bool
    }

    struct Part: Equatable {
        let ref: MessageRef
        let descriptor: PartDescriptor
        let bytesBase64: String
        let bytesRead: Int
        let sha256: String
        let complete: Bool
    }

    struct Wait: Equatable {
        let mailbox: MailboxRef
        let kind: String
    }

    struct Mutation: Equatable {
        let outcomes: [Outcome]
    }

    struct ErrorExpectation: Equatable {
        let tag: String
        let retry: String
        let cause: String
    }

    struct Result: Equatable {
        enum Kind: String, Equatable { case catalog; case page; case part; case wait; case mutation; case error }

        let kind: Kind
        let catalog: Catalog?
        let page: Page?
        let part: Part?
        let wait: Wait?
        let mutation: Mutation?
        let error: ErrorExpectation?

        static func catalog(_ value: Catalog) -> Result {
            .init(kind: .catalog, catalog: value, page: nil, part: nil, wait: nil, mutation: nil, error: nil)
        }

        static func page(_ value: Page) -> Result {
            .init(kind: .page, catalog: nil, page: value, part: nil, wait: nil, mutation: nil, error: nil)
        }

        static func part(_ value: Part) -> Result {
            .init(kind: .part, catalog: nil, page: nil, part: value, wait: nil, mutation: nil, error: nil)
        }

        static func wait(_ value: Wait) -> Result {
            .init(kind: .wait, catalog: nil, page: nil, part: nil, wait: value, mutation: nil, error: nil)
        }

        static func mutation(_ value: Mutation) -> Result {
            .init(kind: .mutation, catalog: nil, page: nil, part: nil, wait: nil, mutation: value, error: nil)
        }

        static func error(_ value: ErrorExpectation) -> Result {
            .init(kind: .error, catalog: nil, page: nil, part: nil, wait: nil, mutation: nil, error: value)
        }
    }

    struct Expected: Equatable {
        let result: Result
    }

    let id: String
    let input: Input
    let expected: Expected

    var provider: String { input.common.provider }
    var transport: String { input.common.transport }
    var authentication: String { input.common.authentication }
}

struct ProviderFixtureSMTPSemanticOperation: Equatable {
    struct Input: Equatable {
        let provider: String
        let transport: String
        let authentication: String
        let envelopeFrom: String
        let recipients: [String]
        let messageID: String
        let messageBase64: String
        let scenario: String
        let capabilities: [String]
        let sentBehavior: String
        let cancellation: String
        let authRejections: Int
    }

    struct Outcome: Equatable {
        let state: String
        let code: String
        let providerReference: String
        let sentCopy: String
        let destinationRawID: String
    }

    struct ErrorExpectation: Equatable {
        let tag: String
        let retry: String
        let cause: String
    }

    struct Result: Equatable {
        enum Kind: String, Equatable { case outcome; case error }

        let kind: Kind
        let outcome: Outcome?
        let error: ErrorExpectation?

        static func outcome(_ value: Outcome) -> Result {
            .init(kind: .outcome, outcome: value, error: nil)
        }

        static func error(_ value: ErrorExpectation) -> Result {
            .init(kind: .error, outcome: nil, error: value)
        }
    }

    struct Expected: Equatable {
        let result: Result
    }

    let id: String
    let input: Input
    let expected: Expected

    var provider: String { input.provider }
    var transport: String { input.transport }
    var authentication: String { input.authentication }
}
