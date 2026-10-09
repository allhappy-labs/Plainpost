import Foundation
import PlainpostAI
import PlainpostCore
import PlainpostOperations

public enum SmartInboxBatchRunnerError: Error, Equatable, Sendable {
    case yieldRequested
    case missingMessage(MessageID)
    case missingWorkItem(MessageID)
}

public struct SmartInboxSchedulerControlError: Error, @unchecked Sendable {
    public let underlying: any Error

    public init(_ underlying: any Error) {
        self.underlying = underlying
    }
}

public struct SmartInboxBatchRunReport: Equatable, Sendable {
    public let terminalFailures: [PlainpostSmartInboxWorkItem]
    public let terminalFailureDiagnostics: [String: [String]]

    public init(
        terminalFailures: [PlainpostSmartInboxWorkItem],
        terminalFailureDiagnostics: [String: [String]] = [:]
    ) {
        self.terminalFailures = terminalFailures
        self.terminalFailureDiagnostics = terminalFailureDiagnostics
    }
}

public struct SmartInboxBatchRunner: Sendable {
    public init() {}

    public func run(
        items: [PlainpostSmartInboxWorkItem],
        inputsByID: [MessageID: SmartInboxClassificationInput],
        catalog: MailLabelCatalogSnapshot,
        limits: SmartInboxBatchLimits,
        classify: @Sendable (AIClassificationBatchRequest) async throws -> AIClassificationBatchResponse,
        persist: @Sendable (PlainpostSmartInboxWorkItem, SmartInboxClassification) throws -> Void,
        shouldYield: @Sendable () async throws -> Bool
    ) async throws -> SmartInboxBatchRunReport {
        var terminalFailures: [PlainpostSmartInboxWorkItem] = []
        var terminalFailureDiagnostics: [String: Set<String>] = [:]

        func recordTerminalFailure(
            _ item: PlainpostSmartInboxWorkItem,
            codes: [String]
        ) {
            terminalFailures.append(item)
            terminalFailureDiagnostics[item.messageID, default: []]
                .formUnion(codes.isEmpty ? ["validation.invalid_response"] : codes)
        }

        func classifySlice(
            _ slice: [PlainpostSmartInboxWorkItem],
            maxCount: Int
        ) async throws {
            guard !slice.isEmpty else { return }
            try Task.checkCancellation()
            if try await shouldYield() {
                throw SmartInboxBatchRunnerError.yieldRequested
            }

            let orderedInputs = try slice.map { item in
                let id = MessageID(item.messageID)
                guard let input = inputsByID[id] else {
                    throw SmartInboxBatchRunnerError.missingMessage(id)
                }
                return input
            }
            let requests = try SmartInboxBatchBuilder.makeRequests(
                inputs: orderedInputs,
                catalog: catalog,
                limits: SmartInboxBatchLimits(
                    maxMessages: maxCount,
                    maxPromptCharacters: limits.maxPromptCharacters
                )
            )

            for request in requests {
                try Task.checkCancellation()
                if try await shouldYield() {
                    throw SmartInboxBatchRunnerError.yieldRequested
                }
                let requestItems = try request.messages.map { message in
                    guard let item = slice.first(where: { $0.messageID == message.id.rawValue }) else {
                        throw SmartInboxBatchRunnerError.missingWorkItem(message.id)
                    }
                    return item
                }

                let validation: SmartInboxBatchValidation
                do {
                    let response = try await classify(request)
                    try Task.checkCancellation()
                    validation = SmartInboxBatchValidator.validate(request: request, response: response)
                } catch SmartInboxBatchRunnerError.yieldRequested {
                    throw SmartInboxBatchRunnerError.yieldRequested
                } catch let error as SmartInboxSchedulerControlError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if requestItems.count == 1 {
                        let item = requestItems[0]
                        if let fallback = Self.conservativeFallback(
                            messageID: MessageID(item.messageID),
                            for: error
                        ) {
                            try persist(item, fallback)
                        } else {
                            recordTerminalFailure(
                                item,
                                codes: [Self.providerFailureCode(error)]
                            )
                        }
                    } else {
                        try await classifySlice(
                            requestItems,
                            maxCount: max(1, requestItems.count / 2)
                        )
                    }
                    continue
                }

                for result in validation.valid {
                    guard let item = requestItems.first(where: { $0.messageID == result.messageID.rawValue }) else {
                        throw SmartInboxBatchRunnerError.missingWorkItem(result.messageID)
                    }
                    try persist(item, result)
                }

                let unresolvedIDs = Set(validation.unresolved)
                let unresolved = requestItems.filter {
                    unresolvedIDs.contains(MessageID($0.messageID))
                }
                if unresolved.count == 1, requestItems.count == 1 {
                    recordTerminalFailure(
                        unresolved[0],
                        codes: validation.diagnostics.map {
                            "validation.\($0.code.rawValue)"
                        }
                    )
                } else if !unresolved.isEmpty {
                    try await classifySlice(
                        unresolved,
                        maxCount: max(1, min(requestItems.count / 2, unresolved.count))
                    )
                }
            }
        }

        try await classifySlice(items, maxCount: limits.maxMessages)
        return SmartInboxBatchRunReport(
            terminalFailures: terminalFailures,
            terminalFailureDiagnostics: terminalFailureDiagnostics.mapValues { $0.sorted() }
        )
    }

    private static func conservativeFallback(
        messageID: MessageID,
        for error: any Error
    ) -> SmartInboxClassification? {
        switch error as? AIProviderError {
        case .guardrailViolation, .unsupportedLanguageOrLocale:
            return SmartInboxClassification(
                messageID: messageID,
                category: .unknown,
                priority: .high,
                requiresAction: true,
                confidence: 0
            )
        default:
            return nil
        }
    }

    private static func providerFailureCode(_ error: any Error) -> String {
        switch error as? AIProviderError {
        case .unavailable:
            return "provider.unavailable"
        case .remoteEndpointDisallowed:
            return "provider.remote_endpoint_disallowed"
        case .notFound:
            return "provider.not_found"
        case .guardrailViolation:
            return "provider.guardrail_violation"
        case .unsupportedLanguageOrLocale:
            return "provider.unsupported_language_or_locale"
        case nil:
            return "provider.error"
        }
    }

    public func run(
        items: [PlainpostSmartInboxWorkItem],
        messagesByID: [MessageID: MailboxListMessage],
        limits: SmartInboxBatchLimits,
        classify: @Sendable (AIClassificationBatchRequest) async throws -> AIClassificationBatchResponse,
        persist: @Sendable (PlainpostSmartInboxWorkItem, SmartInboxClassification) throws -> Void,
        shouldYield: @Sendable () async throws -> Bool
    ) async throws -> SmartInboxBatchRunReport {
        let inputsByID = messagesByID.mapValues {
            SmartInboxClassificationInput(
                message: $0,
                accountID: AccountID(""),
                recipients: [],
                bodyExcerpt: ""
            )
        }
        return try await run(
            items: items,
            inputsByID: inputsByID,
            catalog: MailLabelCatalogSnapshot(
                labels: [],
                fingerprint: "",
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            limits: limits,
            classify: classify,
            persist: persist,
            shouldYield: shouldYield
        )
    }
}
