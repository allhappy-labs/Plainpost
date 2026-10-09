import Foundation

public enum SmartPriority: String, CaseIterable, Codable, Sendable {
    case high
    case normal
    case low
}

public struct SmartInboxClassification: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let category: SmartCategory
    public let priority: SmartPriority
    public let requiresAction: Bool
    public let confidence: Double
    public let labelMatches: [SmartInboxLabelMatch]

    public init(
        messageID: MessageID,
        category: SmartCategory,
        priority: SmartPriority,
        requiresAction: Bool,
        confidence: Double,
        labelMatches: [SmartInboxLabelMatch] = []
    ) {
        self.messageID = messageID
        self.category = category
        self.priority = priority
        self.requiresAction = requiresAction
        self.confidence = confidence
        self.labelMatches = labelMatches
    }
}

public struct SmartInboxBatchProfile: Equatable, Codable, Sendable {
    public let providerID: String
    public let modelID: String
    public let classifierDiscriminator: String
    public let maxMessageCount: Int
    public let maxPromptCharacters: Int
    public let memoryCeilingBytes: UInt64?
    public let benchmarkedAt: Date

    public init(
        providerID: String,
        modelID: String,
        classifierDiscriminator: String,
        maxMessageCount: Int,
        maxPromptCharacters: Int,
        memoryCeilingBytes: UInt64?,
        benchmarkedAt: Date
    ) {
        precondition(maxMessageCount > 0)
        precondition(maxPromptCharacters > 0)
        self.providerID = providerID
        self.modelID = modelID
        self.classifierDiscriminator = classifierDiscriminator
        self.maxMessageCount = maxMessageCount
        self.maxPromptCharacters = maxPromptCharacters
        self.memoryCeilingBytes = memoryCeilingBytes
        self.benchmarkedAt = benchmarkedAt
    }
}

public struct SmartInboxClassifierIdentity: Equatable, Codable, Sendable {
    public let providerID: String
    public let modelID: String
    public let schemaVersion: String
    public let promptVersion: String

    public var discriminator: String {
        [providerID, modelID, schemaVersion, promptVersion].joined(separator: ":")
    }

    public init(
        providerID: String,
        modelID: String,
        schemaVersion: String,
        promptVersion: String
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
    }

    public static func resolve(
        providerID: String,
        modelID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SmartInboxClassifierIdentity {
        let explicitModelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let concreteModelID: String
        if let explicitModelID, !explicitModelID.isEmpty {
            concreteModelID = explicitModelID
        } else {
            switch providerID {
            case "foundation":
                concreteModelID = "apple-foundation-system"
            case "ollama":
                let configured = environment["PLAINPOST_OLLAMA_CHAT_MODEL"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let configured, !configured.isEmpty {
                    concreteModelID = configured
                } else {
                    concreteModelID = "qwen3:8b"
                }
            case "deterministic":
                concreteModelID = "deterministic-local"
            default:
                concreteModelID = providerID
            }
        }
        return SmartInboxClassifierContract.identity(
            providerID: providerID,
            modelID: concreteModelID
        )
    }
}

public enum SmartInboxClassifierContract {
    public static let schemaVersion = "smart-inbox-triage-labels-v2"
    public static let promptVersion = "2026-09-09"
    public static let legacyDiscriminator = "legacy:smart-inbox-v3"

    public static func identity(providerID: String, modelID: String) -> SmartInboxClassifierIdentity {
        SmartInboxClassifierIdentity(
            providerID: providerID,
            modelID: modelID,
            schemaVersion: schemaVersion,
            promptVersion: promptVersion
        )
    }

    public static func discriminator(providerID: String, modelID: String) -> String {
        identity(providerID: providerID, modelID: modelID).discriminator
    }
}
