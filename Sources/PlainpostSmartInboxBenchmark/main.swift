import Darwin
import PlainpostAI
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime
import PlainpostOperations
import Foundation

struct PlainpostSmartInboxBenchmarkCommand {
    static func run() async throws {
        let options = try BenchmarkOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let provider = try options.makeProvider()
        let maxPromptCharacters = options.maxPromptCharacters
            ?? SmartInboxPromptBudget.characters(maxContextTokens: provider.capabilities.maxContextTokens)
        let discriminator = SmartInboxClassifierContract.discriminator(
            providerID: provider.id,
            modelID: options.modelID
        )
        let generatedAt = Date()

        let availability = await options.availability(provider: provider, maxPromptCharacters: maxPromptCharacters)
        guard availability.available else {
            let acceptance = fallbackAcceptance(
                providerID: provider.id,
                modelID: options.modelID,
                discriminator: discriminator,
                maxPromptCharacters: maxPromptCharacters,
                memoryCeilingBytes: options.absoluteMemoryBytes,
                generatedAt: generatedAt
            )
            let summary = makeSummary(
                options: options,
                providerID: provider.id,
                discriminator: discriminator,
                maxPromptCharacters: maxPromptCharacters,
                generatedAt: generatedAt,
                providerAvailable: false,
                unavailabilityReason: availability.reason,
                samples: [],
                acceptance: acceptance
            )
            try write(summary: summary, to: options.outputURL)
            print("Provider unavailable; wrote an unbenchmarked size-one fallback summary to \(options.outputURL.path).")
            if options.approvalDatabasePath != nil {
                print("No profile was approved because the provider was unavailable.")
            }
            return
        }

        let samples = try await BenchmarkRunner(
            provider: provider,
            corpus: BenchmarkCorpus.fixed,
            batchSizes: options.batchSizes,
            qualityPasses: options.qualityPasses,
            warmRepetitions: options.repetitions,
            maxPromptCharacters: maxPromptCharacters,
            providerPID: options.providerPID
        ).run()
        let acceptance = try SmartInboxBenchmarkEvaluator.evaluate(
            providerID: provider.id,
            modelID: options.modelID,
            classifierDiscriminator: discriminator,
            samples: samples,
            maxPromptCharacters: maxPromptCharacters,
            absoluteMemoryCeilingBytes: options.absoluteMemoryBytes,
            benchmarkedAt: generatedAt
        )
        let summary = makeSummary(
            options: options,
            providerID: provider.id,
            discriminator: discriminator,
            maxPromptCharacters: maxPromptCharacters,
            generatedAt: generatedAt,
            providerAvailable: true,
            unavailabilityReason: nil,
            samples: samples,
            acceptance: acceptance
        )
        try write(summary: summary, to: options.outputURL)

        if let databasePath = options.approvalDatabasePath {
            let store = try SQLiteMailStore(path: databasePath)
            try store.saveSmartInboxBatchProfile(acceptance.profile)
            print("Approved aggregate profile for batch size \(acceptance.selectedBatchSize) in the explicit database.")
        }
        let evidence = acceptance.passingBatchSizes.isEmpty
            ? "no size above one passed; using the size-one fallback"
            : "passing sizes \(acceptance.passingBatchSizes.map(String.init).joined(separator: ","))"
        print("Benchmark complete: selected \(acceptance.selectedBatchSize) (\(evidence)).")
        print("Aggregate-only JSON: \(options.outputURL.path)")
    }
}

private struct ProviderAvailability: Sendable {
    let available: Bool
    let reason: String?
}

private struct BenchmarkOptions {
    let providerName: String
    let modelID: String
    let ollamaURL: URL
    let batchSizes: [Int]
    let qualityPasses: Int
    let repetitions: Int
    let maxPromptCharacters: Int?
    let absoluteMemoryBytes: UInt64
    let providerPID: Int32?
    let outputURL: URL
    let approvalDatabasePath: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        let supported = Set([
            "--provider", "--model", "--ollama-url", "--batch-sizes", "--quality-passes",
            "--repetitions", "--max-prompt-characters", "--absolute-memory-mb", "--provider-pid",
            "--output", "--approve-database",
        ])
        while index < arguments.count {
            let key = arguments[index]
            guard supported.contains(key) else { throw BenchmarkCLIError.invalidArgument(key) }
            guard values[key] == nil else { throw BenchmarkCLIError.duplicateArgument(key) }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { throw BenchmarkCLIError.missingValue(key) }
            values[key] = arguments[valueIndex]
            index += 2
        }

        guard let providerName = values["--provider"], ["foundation", "ollama"].contains(providerName) else {
            throw BenchmarkCLIError.missingOrInvalidProvider
        }
        guard let modelID = values["--model"], !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchmarkCLIError.missingArgument("--model")
        }
        guard let outputPath = values["--output"], !outputPath.isEmpty else {
            throw BenchmarkCLIError.missingArgument("--output")
        }
        if providerName == "foundation", modelID != "apple-foundation-system" {
            throw BenchmarkCLIError.invalidFoundationModel(modelID)
        }

        self.providerName = providerName
        self.modelID = modelID
        guard let ollamaURL = URL(string: values["--ollama-url"] ?? "http://127.0.0.1:11434") else {
            throw BenchmarkCLIError.invalidArgument("--ollama-url")
        }
        self.ollamaURL = ollamaURL
        batchSizes = try Self.positiveIntegerList(values["--batch-sizes"] ?? "1,4,8,12,16", key: "--batch-sizes")
        guard batchSizes.contains(1) else { throw BenchmarkCLIError.sizeOneRequired }
        qualityPasses = try Self.positiveInteger(values["--quality-passes"] ?? "3", key: "--quality-passes")
        repetitions = try Self.positiveInteger(values["--repetitions"] ?? "20", key: "--repetitions")
        guard repetitions >= 20 else { throw BenchmarkCLIError.minimumWarmRepetitions }
        if let rawPromptCharacters = values["--max-prompt-characters"] {
            maxPromptCharacters = try Self.positiveInteger(rawPromptCharacters, key: "--max-prompt-characters")
        } else {
            maxPromptCharacters = nil
        }
        let memoryMB = try Self.positiveInteger(values["--absolute-memory-mb"] ?? "1024", key: "--absolute-memory-mb")
        guard UInt64(memoryMB) <= UInt64.max / 1_048_576 else {
            throw BenchmarkCLIError.invalidArgument("--absolute-memory-mb")
        }
        absoluteMemoryBytes = UInt64(memoryMB) * 1_048_576
        if let rawPID = values["--provider-pid"] {
            let pid = try Self.positiveInteger(rawPID, key: "--provider-pid")
            guard pid <= Int(Int32.max) else { throw BenchmarkCLIError.invalidArgument("--provider-pid") }
            providerPID = Int32(pid)
        } else {
            providerPID = nil
        }
        outputURL = URL(fileURLWithPath: outputPath)
        approvalDatabasePath = values["--approve-database"]
    }

    func makeProvider() throws -> any AIProvider {
        switch providerName {
        case "foundation": FoundationModelsAIProvider()
        case "ollama":
            OllamaProvider(configuration: try OllamaProviderConfiguration(
                baseURL: ollamaURL,
                chatModelID: modelID
            ))
        default:
            throw BenchmarkCLIError.missingOrInvalidProvider
        }
    }

    func availability(
        provider: any AIProvider,
        maxPromptCharacters: Int
    ) async -> ProviderAvailability {
        if providerName == "foundation" {
            let availability = FoundationModelsAvailability.current()
            if availability != .available {
                return ProviderAvailability(
                    available: false,
                    reason: AIProviderStatusService.foundation(availability: availability).detail
                )
            }
        }
        do {
            let request = try SmartInboxBatchBuilder.makeRequests(
                messages: [BenchmarkCorpus.fixed[0].message],
                limits: .init(maxMessages: 1, maxPromptCharacters: maxPromptCharacters)
            )[0]
            _ = try await provider.classifyBatch(request)
            return ProviderAvailability(available: true, reason: nil)
        } catch {
            return ProviderAvailability(available: false, reason: "The selected local provider failed its synthetic preflight request.")
        }
    }

    private static func positiveInteger(_ raw: String, key: String) throws -> Int {
        guard let value = Int(raw), value > 0 else { throw BenchmarkCLIError.invalidArgument(key) }
        return value
    }

    private static func positiveIntegerList(_ raw: String, key: String) throws -> [Int] {
        let values = try raw.split(separator: ",", omittingEmptySubsequences: false).map {
            try positiveInteger(String($0), key: key)
        }
        guard !values.isEmpty, Set(values).count == values.count else {
            throw BenchmarkCLIError.invalidArgument(key)
        }
        return values.sorted()
    }
}

private enum BenchmarkCLIError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case duplicateArgument(String)
    case missingValue(String)
    case missingArgument(String)
    case missingOrInvalidProvider
    case invalidFoundationModel(String)
    case sizeOneRequired
    case minimumWarmRepetitions

    var description: String {
        switch self {
        case .invalidArgument(let key): "Invalid benchmark argument: \(key)."
        case .duplicateArgument(let key): "Benchmark argument appears more than once: \(key)."
        case .missingValue(let key): "Benchmark argument requires a value: \(key)."
        case .missingArgument(let key): "Required benchmark argument is missing: \(key)."
        case .missingOrInvalidProvider: "Use --provider foundation|ollama."
        case .invalidFoundationModel(let model): "Foundation supports only apple-foundation-system, not \(model)."
        case .sizeOneRequired: "--batch-sizes must include the size-one baseline."
        case .minimumWarmRepetitions: "--repetitions must be at least 20 for the warm-growth gate."
        }
    }
}

private final class BenchmarkRunner {
    private let provider: any AIProvider
    private let corpus: [BenchmarkCorpusItem]
    private let batchSizes: [Int]
    private let qualityPasses: Int
    private let warmRepetitions: Int
    private let maxPromptCharacters: Int
    private let providerPID: Int32?

    init(
        provider: any AIProvider,
        corpus: [BenchmarkCorpusItem],
        batchSizes: [Int],
        qualityPasses: Int,
        warmRepetitions: Int,
        maxPromptCharacters: Int,
        providerPID: Int32?
    ) {
        self.provider = provider
        self.corpus = corpus
        self.batchSizes = batchSizes
        self.qualityPasses = qualityPasses
        self.warmRepetitions = warmRepetitions
        self.maxPromptCharacters = maxPromptCharacters
        self.providerPID = providerPID
    }

    func run() async throws -> [SmartInboxBenchmarkSample] {
        var samples: [SmartInboxBenchmarkSample] = []
        for batchSize in batchSizes {
            print("Benchmarking aggregate batch size \(batchSize)...")
            let accumulator = BenchmarkAccumulator(providerPID: providerPID)
            var scored: [ScoredPrediction] = []
            var rawValid = 0
            var rawRequested = 0
            var recoveredValid = 0
            var recoveredRequested = 0

            for pass in 0..<qualityPasses {
                let ordered = deterministicShuffle(corpus, seed: UInt64(pass + 1))
                let sourceByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.message.id, $0) })
                let requests = try SmartInboxBatchBuilder.makeRequests(
                    messages: ordered.map(\.message),
                    limits: .init(maxMessages: batchSize, maxPromptCharacters: maxPromptCharacters)
                )
                var predictions: [MessageID: SmartInboxClassification] = [:]
                for request in requests {
                    let execution = await execute(
                        request: request,
                        sourceByID: sourceByID,
                        accumulator: accumulator
                    )
                    rawValid += execution.rawValidCount
                    rawRequested += request.messages.count
                    for classification in execution.classifications {
                        predictions[classification.messageID] = classification
                    }
                }
                recoveredValid += predictions.count
                recoveredRequested += ordered.count
                scored.append(contentsOf: ordered.map { item in
                    ScoredPrediction(expected: item, actual: predictions[item.message.id])
                })
            }

            let warmOrder = deterministicShuffle(corpus, seed: 1)
            let warmSourceByID = Dictionary(uniqueKeysWithValues: warmOrder.map { ($0.message.id, $0) })
            let warmRequests = try SmartInboxBatchBuilder.makeRequests(
                messages: warmOrder.map(\.message),
                limits: .init(maxMessages: batchSize, maxPromptCharacters: maxPromptCharacters)
            )
            if let warmup = warmRequests.first {
                _ = await execute(
                    request: warmup,
                    sourceByID: warmSourceByID,
                    accumulator: accumulator
                )
            }
            for repetition in 0..<warmRepetitions {
                let request = warmRequests[repetition % warmRequests.count]
                let clock = ContinuousClock()
                let started = clock.now
                _ = await execute(
                    request: request,
                    sourceByID: warmSourceByID,
                    accumulator: accumulator
                )
                accumulator.recordWarmRequest(
                    elapsedSeconds: durationSeconds(started.duration(to: clock.now)),
                    originalMessageCount: request.messages.count
                )
                accumulator.recordWarmSettledMemory()
            }

            let correctness = batchSize > 1
                ? await scriptedCorrectness(batchSize: batchSize, maxPromptCharacters: maxPromptCharacters)
                : SmartInboxBenchmarkCorrectness(
                    cancellationPassed: true,
                    checkpointPassed: true,
                    smallerBatchRecoveryPassed: true
                )
            let sample = accumulator.sample(
                batchSize: batchSize,
                scored: scored,
                rawCoverage: fraction(rawValid, rawRequested),
                recoveredCoverage: fraction(recoveredValid, recoveredRequested),
                correctness: correctness
            )
            samples.append(sample)
            print(
                "Completed batch size \(batchSize): raw coverage \(sample.rawRequestedIDCoverage), " +
                "recovered coverage \(sample.recoveredRequestedIDCoverage)."
            )
        }
        return samples
    }

    private func execute(
        request: AIClassificationBatchRequest,
        sourceByID: [MessageID: BenchmarkCorpusItem],
        accumulator: BenchmarkAccumulator
    ) async -> RequestExecution {
        let outcome = await accumulator.call(
            provider: provider,
            request: request,
            sourceByID: sourceByID
        )
        let validation: SmartInboxBatchValidation
        if let response = outcome.response {
            validation = SmartInboxBatchValidator.validate(request: request, response: response)
            accumulator.record(validation: validation, requestCount: request.messages.count)
        } else {
            validation = SmartInboxBatchValidation(
                valid: [],
                unresolved: request.messages.map(\.id),
                diagnostics: []
            )
            accumulator.recordFailedRequest()
        }

        var classifications = validation.valid
        let unresolvedSet = Set(validation.unresolved)
        let unresolved = request.messages.compactMap { message -> MailboxListMessage? in
            guard unresolvedSet.contains(message.id) else { return nil }
            return sourceByID[message.id]?.message
        }
        if !unresolved.isEmpty, !(unresolved.count == 1 && request.messages.count == 1) {
            let nextCount = max(1, min(request.messages.count / 2, unresolved.count))
            do {
                let recoveryRequests = try SmartInboxBatchBuilder.makeRequests(
                    messages: unresolved,
                    limits: .init(maxMessages: nextCount, maxPromptCharacters: maxPromptCharacters)
                )
                for recoveryRequest in recoveryRequests {
                    let recovered = await execute(
                        request: recoveryRequest,
                        sourceByID: sourceByID,
                        accumulator: accumulator
                    )
                    classifications.append(contentsOf: recovered.classifications)
                }
            } catch {
                // An input that cannot fit is unresolved and fails the coverage gate.
            }
        }
        return RequestExecution(classifications: classifications, rawValidCount: validation.valid.count)
    }
}

private struct RequestExecution {
    let classifications: [SmartInboxClassification]
    let rawValidCount: Int
}

private struct ProviderCallOutcome {
    let response: AIClassificationBatchResponse?
}

private struct ScoredPrediction {
    let expected: BenchmarkCorpusItem
    let actual: SmartInboxClassification?
}

private final class BenchmarkAccumulator {
    private let providerPID: Int32?
    private var totalLatencySeconds = 0.0
    private var warmLatency = SmartInboxBenchmarkWarmLatencyMeasurements()
    private var promptCharacters: [Int] = []
    private var truncationCount = 0
    private var acceptedMessageCounts: [Int] = []
    private var duplicateResultCount = 0
    private var unknownResultCount = 0
    private var peakResidentBytes: UInt64?
    private var settledResidentBytes: UInt64?
    private var workerRSSSamplingFailed = false
    private var providerPeakResidentBytes: UInt64?
    private var providerSettledResidentBytes: UInt64?
    private var warmSettledResidentBytes: [UInt64] = []
    private var warmProviderSettledResidentBytes: [UInt64] = []

    init(providerPID: Int32?) {
        self.providerPID = providerPID
    }

    func call(
        provider: any AIProvider,
        request: AIClassificationBatchRequest,
        sourceByID: [MessageID: BenchmarkCorpusItem]
    ) async -> ProviderCallOutcome {
        sampleMemory()
        let promptCount = SmartInboxClassificationPrompt.render(request).count
        promptCharacters.append(promptCount)
        truncationCount += request.messages.reduce(into: 0) { count, message in
            guard let source = sourceByID[message.id]?.message else { return }
            if message.senderAddress != source.from.rawValue ||
                message.senderDisplayName != source.fromDisplayName ||
                message.subject != source.subject ||
                message.preview != source.preview {
                count += 1
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let response: AIClassificationBatchResponse?
        do {
            response = try await provider.classifyBatch(request)
        } catch {
            response = nil
        }
        let elapsed = durationSeconds(started.duration(to: clock.now))
        totalLatencySeconds += elapsed
        sampleMemory()
        return ProviderCallOutcome(response: response)
    }

    func record(validation: SmartInboxBatchValidation, requestCount: Int) {
        acceptedMessageCounts.append(validation.valid.count)
        for diagnostic in validation.diagnostics {
            switch diagnostic.code {
            case .duplicateResult: duplicateResultCount += diagnostic.count
            case .unknownResult: unknownResultCount += diagnostic.count
            default: break
            }
        }
    }

    func recordFailedRequest() {
        acceptedMessageCounts.append(0)
    }

    func recordWarmRequest(elapsedSeconds: Double, originalMessageCount: Int) {
        warmLatency.recordCompletedRequest(
            elapsedSeconds: elapsedSeconds,
            originalMessageCount: originalMessageCount
        )
    }

    func recordWarmSettledMemory() {
        if let current = currentResidentBytes(), !workerRSSSamplingFailed {
            settledResidentBytes = current
            warmSettledResidentBytes.append(current)
        } else {
            workerRSSSamplingFailed = true
            settledResidentBytes = nil
            peakResidentBytes = nil
            warmSettledResidentBytes.removeAll()
        }
        if let providerPID, let providerCurrent = processResidentBytes(pid: providerPID) {
            providerSettledResidentBytes = providerCurrent
            warmProviderSettledResidentBytes.append(providerCurrent)
        }
    }

    func sample(
        batchSize: Int,
        scored: [ScoredPrediction],
        rawCoverage: Double,
        recoveredCoverage: Double,
        correctness: SmartInboxBenchmarkCorrectness
    ) -> SmartInboxBenchmarkSample {
        let latency = warmLatency.perMessageSamples
        let growth = SmartInboxBenchmarkMeasurements.combinedWarmGrowth(
            workerResidentBytes: warmSettledResidentBytes,
            providerResidentBytes: warmProviderSettledResidentBytes
        )
        return SmartInboxBenchmarkSample(
            batchSize: batchSize,
            categoryMacroF1: categoryMacroF1(scored),
            priorityAccuracy: accuracy(scored) { expected, actual in
                actual?.priority == expected.expectedPriority
            },
            actionPrecision: actionPrecision(scored),
            actionRecall: actionRecall(scored),
            confidenceCalibrationError: calibrationError(scored),
            rawRequestedIDCoverage: rawCoverage,
            recoveredRequestedIDCoverage: recoveredCoverage,
            duplicateResultCount: duplicateResultCount,
            unknownResultCount: unknownResultCount,
            totalLatencySeconds: totalLatencySeconds,
            medianLatencyPerMessage: percentile(latency, 0.50),
            p95LatencyPerMessage: percentile(latency, 0.95),
            maximumLatencyPerMessage: latency.max() ?? 0,
            peakResidentBytes: peakResidentBytes,
            settledResidentBytes: settledResidentBytes,
            providerPeakResidentBytes: providerPeakResidentBytes,
            providerSettledResidentBytes: providerSettledResidentBytes,
            promptCharacterMinimum: promptCharacters.min() ?? 0,
            promptCharacterMedian: Int(percentile(promptCharacters.map(Double.init), 0.50).rounded()),
            promptCharacterP95: Int(percentile(promptCharacters.map(Double.init), 0.95).rounded()),
            promptCharacterMaximum: promptCharacters.max() ?? 0,
            truncationCount: truncationCount,
            acceptedMessagesPerRequest: acceptedMessageCounts.isEmpty
                ? 0
                : Double(acceptedMessageCounts.reduce(0, +)) / Double(acceptedMessageCounts.count),
            warmGrowthBytesPerBatch: growth.reportedSlopeBytesPerBatch,
            hasUnboundedWarmGrowth: growth.hasUnboundedGrowth,
            correctness: correctness
        )
    }

    private func sampleMemory() {
        if let current = currentResidentBytes(), !workerRSSSamplingFailed {
            settledResidentBytes = current
            peakResidentBytes = max(peakResidentBytes ?? 0, current)
        } else {
            workerRSSSamplingFailed = true
            settledResidentBytes = nil
            peakResidentBytes = nil
            warmSettledResidentBytes.removeAll()
        }
        if let providerPID, let providerCurrent = processResidentBytes(pid: providerPID) {
            providerSettledResidentBytes = providerCurrent
            providerPeakResidentBytes = max(providerPeakResidentBytes ?? 0, providerCurrent)
        }
    }
}

private func scriptedCorrectness(
    batchSize: Int,
    maxPromptCharacters: Int
) async -> SmartInboxBenchmarkCorrectness {
    let cancellationPassed = await scriptedCancellation(
        batchSize: batchSize,
        maxPromptCharacters: maxPromptCharacters
    )
    let checkpointPassed = await scriptedCheckpoint(
        batchSize: batchSize,
        maxPromptCharacters: maxPromptCharacters
    )
    let recoveryPassed = await scriptedRecovery(
        batchSize: batchSize,
        maxPromptCharacters: maxPromptCharacters
    )
    return SmartInboxBenchmarkCorrectness(
        cancellationPassed: cancellationPassed,
        checkpointPassed: checkpointPassed,
        smallerBatchRecoveryPassed: recoveryPassed
    )
}

private func scriptedCancellation(batchSize: Int, maxPromptCharacters: Int) async -> Bool {
    let fixtures = runtimeFixtures(count: min(2, batchSize))
    let recorder = PersistenceRecorder()
    let task = Task {
        try await SmartInboxBatchRunner().run(
            items: fixtures.items,
            messagesByID: fixtures.messages,
            limits: .init(maxMessages: batchSize, maxPromptCharacters: maxPromptCharacters),
            classify: { _ in
                try await Task.sleep(for: .seconds(10))
                return AIClassificationBatchResponse(results: [])
            },
            persist: { item, _ in recorder.append(item.messageID) },
            shouldYield: { false }
        )
    }
    try? await Task.sleep(for: .milliseconds(5))
    task.cancel()
    do {
        _ = try await task.value
        return false
    } catch is CancellationError {
        return recorder.messageIDs.isEmpty
    } catch {
        return false
    }
}

private func scriptedCheckpoint(batchSize: Int, maxPromptCharacters: Int) async -> Bool {
    let fixtures = runtimeFixtures(count: 2)
    let recorder = PersistenceRecorder()
    let probe = YieldAfterProbe(check: 3)
    do {
        _ = try await SmartInboxBatchRunner().run(
            items: fixtures.items,
            messagesByID: fixtures.messages,
            limits: .init(maxMessages: max(2, batchSize), maxPromptCharacters: maxPromptCharacters),
            classify: { request in
                AIClassificationBatchResponse(results: request.messages.prefix(1).map(validCandidate))
            },
            persist: { item, _ in recorder.append(item.messageID) },
            shouldYield: { await probe.shouldYield() }
        )
        return false
    } catch SmartInboxBatchRunnerError.yieldRequested {
        return recorder.messageIDs == ["scripted-0"]
    } catch {
        return false
    }
}

private func scriptedRecovery(batchSize: Int, maxPromptCharacters: Int) async -> Bool {
    let count = min(4, batchSize)
    guard count > 1 else { return true }
    let fixtures = runtimeFixtures(count: count)
    let recorder = PersistenceRecorder()
    let requestRecorder = RequestCountRecorder()
    do {
        let report = try await SmartInboxBatchRunner().run(
            items: fixtures.items,
            messagesByID: fixtures.messages,
            limits: .init(maxMessages: count, maxPromptCharacters: maxPromptCharacters),
            classify: { request in
                await requestRecorder.append(request.messages.count)
                if request.messages.count == count {
                    throw AIProviderError.unavailable
                }
                return AIClassificationBatchResponse(results: request.messages.map(validCandidate))
            },
            persist: { item, _ in recorder.append(item.messageID) },
            shouldYield: { false }
        )
        let requestCounts = await requestRecorder.counts
        return report.terminalFailures.isEmpty &&
            recorder.messageIDs.count == count &&
            requestCounts.first == count &&
            requestCounts.dropFirst().allSatisfy { $0 < count }
    } catch {
        return false
    }
}

private func runtimeFixtures(
    count: Int
) -> (items: [PlainpostSmartInboxWorkItem], messages: [MessageID: MailboxListMessage]) {
    let messages = BenchmarkCorpus.fixed.prefix(count).enumerated().map { index, item in
        MailboxListMessage(
            id: MessageID("scripted-\(index)"),
            threadID: nil,
            from: item.message.from,
            fromDisplayName: item.message.fromDisplayName,
            subject: item.message.subject,
            preview: item.message.preview,
            smartCategory: .unknown
        )
    }
    let items = messages.enumerated().map { index, message in
        PlainpostSmartInboxWorkItem(
            jobID: "synthetic-benchmark",
            ordinal: index,
            messageID: message.id.rawValue,
            sourceFingerprint: "synthetic-fingerprint-\(index)",
            state: .pending
        )
    }
    return (items, Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }))
}

private func validCandidate(_ message: AIClassificationMessage) -> AIClassificationCandidate {
    AIClassificationCandidate(
        id: message.id.rawValue,
        category: SmartCategory.personal.rawValue,
        priority: SmartPriority.normal.rawValue,
        requiresAction: false,
        confidence: 0.9
    )
}

private final class PersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var messageIDs: [String] { lock.withLock { storage } }
    func append(_ messageID: String) { lock.withLock { storage.append(messageID) } }
}

private actor YieldAfterProbe {
    private let target: Int
    private var current = 0
    init(check: Int) { target = check }
    func shouldYield() -> Bool {
        current += 1
        return current >= target
    }
}

private actor RequestCountRecorder {
    private(set) var counts: [Int] = []
    func append(_ count: Int) { counts.append(count) }
}

private func categoryMacroF1(_ scored: [ScoredPrediction]) -> Double {
    let scores = SmartCategory.allCases.map { category -> Double in
        let truePositive = scored.filter {
            $0.expected.expectedCategory == category && $0.actual?.category == category
        }.count
        let falsePositive = scored.filter {
            $0.expected.expectedCategory != category && $0.actual?.category == category
        }.count
        let falseNegative = scored.filter {
            $0.expected.expectedCategory == category && $0.actual?.category != category
        }.count
        let precision = fraction(truePositive, truePositive + falsePositive)
        let recall = fraction(truePositive, truePositive + falseNegative)
        return precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
    }
    return scores.reduce(0, +) / Double(max(1, scores.count))
}

private func accuracy(
    _ scored: [ScoredPrediction],
    matches: (BenchmarkCorpusItem, SmartInboxClassification?) -> Bool
) -> Double {
    fraction(scored.filter { matches($0.expected, $0.actual) }.count, scored.count)
}

private func actionPrecision(_ scored: [ScoredPrediction]) -> Double {
    let predictedPositive = scored.filter { $0.actual?.requiresAction == true }
    let truePositive = predictedPositive.filter { $0.expected.expectedRequiresAction }.count
    return fraction(truePositive, predictedPositive.count)
}

private func actionRecall(_ scored: [ScoredPrediction]) -> Double {
    let actualPositive = scored.filter { $0.expected.expectedRequiresAction }
    let truePositive = actualPositive.filter { $0.actual?.requiresAction == true }.count
    return fraction(truePositive, actualPositive.count)
}

private func calibrationError(_ scored: [ScoredPrediction]) -> Double {
    let predictions = scored.compactMap { score -> (confidence: Double, correct: Bool)? in
        guard let actual = score.actual else { return nil }
        let correct = actual.category == score.expected.expectedCategory &&
            actual.priority == score.expected.expectedPriority &&
            actual.requiresAction == score.expected.expectedRequiresAction
        return (actual.confidence, correct)
    }
    guard !predictions.isEmpty else { return 1 }
    return (0..<10).reduce(0.0) { total, bin in
        let lower = Double(bin) / 10
        let upper = Double(bin + 1) / 10
        let members = predictions.filter {
            $0.confidence >= lower && (bin == 9 ? $0.confidence <= upper : $0.confidence < upper)
        }
        guard !members.isEmpty else { return total }
        let confidence = members.map(\.confidence).reduce(0, +) / Double(members.count)
        let accuracy = Double(members.filter(\.correct).count) / Double(members.count)
        return total + abs(confidence - accuracy) * Double(members.count) / Double(predictions.count)
    }
}

private func fraction(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
    return sorted[min(max(0, index), sorted.count - 1)]
}

private func currentResidentBytes() -> UInt64? {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
}

private func processResidentBytes(pid: Int32) -> UInt64? {
    var info = proc_taskinfo()
    let expected = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, expected)
    }
    return result == expected ? info.pti_resident_size : nil
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func deterministicShuffle<T>(_ values: [T], seed: UInt64) -> [T] {
    var generator = SeededRandomNumberGenerator(seed: seed)
    return values.shuffled(using: &generator)
}

private func fallbackAcceptance(
    providerID: String,
    modelID: String,
    discriminator: String,
    maxPromptCharacters: Int,
    memoryCeilingBytes: UInt64,
    generatedAt: Date
) -> SmartInboxBenchmarkAcceptance {
    SmartInboxBenchmarkAcceptance(
        profile: SmartInboxBatchProfile(
            providerID: providerID,
            modelID: modelID,
            classifierDiscriminator: discriminator,
            maxMessageCount: 1,
            maxPromptCharacters: maxPromptCharacters,
            memoryCeilingBytes: memoryCeilingBytes,
            benchmarkedAt: generatedAt
        ),
        passingBatchSizes: [],
        usedSizeOneFallback: true
    )
}

private func makeSummary(
    options: BenchmarkOptions,
    providerID: String,
    discriminator: String,
    maxPromptCharacters: Int,
    generatedAt: Date,
    providerAvailable: Bool,
    unavailabilityReason: String?,
    samples: [SmartInboxBenchmarkSample],
    acceptance: SmartInboxBenchmarkAcceptance
) -> SmartInboxBenchmarkSummary {
    SmartInboxBenchmarkSummary(
        providerID: providerID,
        modelID: options.modelID,
        classifierDiscriminator: discriminator,
        providerAvailable: providerAvailable,
        unavailabilityReason: unavailabilityReason,
        corpusMessageCount: BenchmarkCorpus.fixed.count,
        corpusCategoryCounts: BenchmarkCorpus.categoryCounts,
        corpusPriorityCounts: BenchmarkCorpus.priorityCounts,
        corpusActionCounts: BenchmarkCorpus.actionCounts,
        qualityPasses: options.qualityPasses,
        warmRepetitions: options.repetitions,
        maxPromptCharacters: maxPromptCharacters,
        absoluteMemoryCeilingBytes: options.absoluteMemoryBytes,
        generatedAt: generatedAt,
        samples: samples,
        acceptance: acceptance
    )
}

private func write(summary: SmartInboxBenchmarkSummary, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(summary).write(to: url, options: .atomic)
}

try await PlainpostSmartInboxBenchmarkCommand.run()
