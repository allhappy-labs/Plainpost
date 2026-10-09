import PlainpostCore
import Foundation

public struct SmartInboxBenchmarkCorrectness: Codable, Equatable, Sendable {
    public let cancellationPassed: Bool
    public let checkpointPassed: Bool
    public let smallerBatchRecoveryPassed: Bool

    public init(
        cancellationPassed: Bool,
        checkpointPassed: Bool,
        smallerBatchRecoveryPassed: Bool
    ) {
        self.cancellationPassed = cancellationPassed
        self.checkpointPassed = checkpointPassed
        self.smallerBatchRecoveryPassed = smallerBatchRecoveryPassed
    }
}

public struct SmartInboxBenchmarkSample: Codable, Equatable, Sendable {
    public let batchSize: Int
    public let categoryMacroF1: Double
    public let priorityAccuracy: Double
    public let actionPrecision: Double
    public let actionRecall: Double
    public let confidenceCalibrationError: Double
    public let rawRequestedIDCoverage: Double
    public let recoveredRequestedIDCoverage: Double
    public let duplicateResultCount: Int
    public let unknownResultCount: Int
    public let totalLatencySeconds: Double
    public let medianLatencyPerMessage: Double
    public let p95LatencyPerMessage: Double
    public let maximumLatencyPerMessage: Double
    public let peakResidentBytes: UInt64?
    public let settledResidentBytes: UInt64?
    public let providerPeakResidentBytes: UInt64?
    public let providerSettledResidentBytes: UInt64?
    public let promptCharacterMinimum: Int
    public let promptCharacterMedian: Int
    public let promptCharacterP95: Int
    public let promptCharacterMaximum: Int
    public let truncationCount: Int
    public let acceptedMessagesPerRequest: Double
    public let warmGrowthBytesPerBatch: Double
    public let hasUnboundedWarmGrowth: Bool
    public let correctness: SmartInboxBenchmarkCorrectness

    public init(
        batchSize: Int,
        categoryMacroF1: Double,
        priorityAccuracy: Double,
        actionPrecision: Double,
        actionRecall: Double,
        confidenceCalibrationError: Double,
        rawRequestedIDCoverage: Double,
        recoveredRequestedIDCoverage: Double,
        duplicateResultCount: Int,
        unknownResultCount: Int,
        totalLatencySeconds: Double,
        medianLatencyPerMessage: Double,
        p95LatencyPerMessage: Double,
        maximumLatencyPerMessage: Double,
        peakResidentBytes: UInt64?,
        settledResidentBytes: UInt64?,
        providerPeakResidentBytes: UInt64?,
        providerSettledResidentBytes: UInt64?,
        promptCharacterMinimum: Int,
        promptCharacterMedian: Int,
        promptCharacterP95: Int,
        promptCharacterMaximum: Int,
        truncationCount: Int,
        acceptedMessagesPerRequest: Double,
        warmGrowthBytesPerBatch: Double,
        hasUnboundedWarmGrowth: Bool,
        correctness: SmartInboxBenchmarkCorrectness
    ) {
        precondition(batchSize > 0)
        self.batchSize = batchSize
        self.categoryMacroF1 = categoryMacroF1
        self.priorityAccuracy = priorityAccuracy
        self.actionPrecision = actionPrecision
        self.actionRecall = actionRecall
        self.confidenceCalibrationError = confidenceCalibrationError
        self.rawRequestedIDCoverage = rawRequestedIDCoverage
        self.recoveredRequestedIDCoverage = recoveredRequestedIDCoverage
        self.duplicateResultCount = duplicateResultCount
        self.unknownResultCount = unknownResultCount
        self.totalLatencySeconds = totalLatencySeconds
        self.medianLatencyPerMessage = medianLatencyPerMessage
        self.p95LatencyPerMessage = p95LatencyPerMessage
        self.maximumLatencyPerMessage = maximumLatencyPerMessage
        self.peakResidentBytes = peakResidentBytes
        self.settledResidentBytes = settledResidentBytes
        self.providerPeakResidentBytes = providerPeakResidentBytes
        self.providerSettledResidentBytes = providerSettledResidentBytes
        self.promptCharacterMinimum = promptCharacterMinimum
        self.promptCharacterMedian = promptCharacterMedian
        self.promptCharacterP95 = promptCharacterP95
        self.promptCharacterMaximum = promptCharacterMaximum
        self.truncationCount = truncationCount
        self.acceptedMessagesPerRequest = acceptedMessagesPerRequest
        self.warmGrowthBytesPerBatch = warmGrowthBytesPerBatch
        self.hasUnboundedWarmGrowth = hasUnboundedWarmGrowth
        self.correctness = correctness
    }
}

public struct SmartInboxBenchmarkAcceptance: Codable, Equatable, Sendable {
    public let profile: SmartInboxBatchProfile
    public let passingBatchSizes: [Int]
    public let usedSizeOneFallback: Bool

    public var selectedBatchSize: Int { profile.maxMessageCount }

    public init(
        profile: SmartInboxBatchProfile,
        passingBatchSizes: [Int],
        usedSizeOneFallback: Bool
    ) {
        self.profile = profile
        self.passingBatchSizes = passingBatchSizes
        self.usedSizeOneFallback = usedSizeOneFallback
    }
}

public struct SmartInboxBenchmarkSummary: Codable, Sendable {
    public let schemaVersion: Int
    public let providerID: String
    public let modelID: String
    public let classifierDiscriminator: String
    public let providerAvailable: Bool
    public let unavailabilityReason: String?
    public let corpusMessageCount: Int
    public let corpusCategoryCounts: [String: Int]
    public let corpusPriorityCounts: [String: Int]
    public let corpusActionCounts: [String: Int]
    public let qualityPasses: Int
    public let warmRepetitions: Int
    public let maxPromptCharacters: Int
    public let absoluteMemoryCeilingBytes: UInt64
    public let generatedAt: Date
    public let samples: [SmartInboxBenchmarkSample]
    public let acceptance: SmartInboxBenchmarkAcceptance

    public init(
        schemaVersion: Int = 1,
        providerID: String,
        modelID: String,
        classifierDiscriminator: String,
        providerAvailable: Bool = true,
        unavailabilityReason: String? = nil,
        corpusMessageCount: Int,
        corpusCategoryCounts: [String: Int],
        corpusPriorityCounts: [String: Int],
        corpusActionCounts: [String: Int],
        qualityPasses: Int,
        warmRepetitions: Int,
        maxPromptCharacters: Int,
        absoluteMemoryCeilingBytes: UInt64,
        generatedAt: Date,
        samples: [SmartInboxBenchmarkSample],
        acceptance: SmartInboxBenchmarkAcceptance
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.modelID = modelID
        self.classifierDiscriminator = classifierDiscriminator
        self.providerAvailable = providerAvailable
        self.unavailabilityReason = unavailabilityReason
        self.corpusMessageCount = corpusMessageCount
        self.corpusCategoryCounts = corpusCategoryCounts
        self.corpusPriorityCounts = corpusPriorityCounts
        self.corpusActionCounts = corpusActionCounts
        self.qualityPasses = qualityPasses
        self.warmRepetitions = warmRepetitions
        self.maxPromptCharacters = maxPromptCharacters
        self.absoluteMemoryCeilingBytes = absoluteMemoryCeilingBytes
        self.generatedAt = generatedAt
        self.samples = samples
        self.acceptance = acceptance
    }
}

public enum SmartInboxBenchmarkEvaluatorError: Error, Equatable, Sendable {
    case missingSizeOneBaseline
}

public enum SmartInboxBenchmarkEvaluator {
    public static func evaluate(
        providerID: String,
        modelID: String,
        classifierDiscriminator: String,
        samples: [SmartInboxBenchmarkSample],
        maxPromptCharacters: Int,
        absoluteMemoryCeilingBytes: UInt64,
        benchmarkedAt: Date
    ) throws -> SmartInboxBenchmarkAcceptance {
        guard let baseline = samples.first(where: { $0.batchSize == 1 }) else {
            throw SmartInboxBenchmarkEvaluatorError.missingSizeOneBaseline
        }

        let passing = samples
            .filter { $0.batchSize > 1 }
            .filter { candidate in
                guard let baselinePeakResidentBytes = baseline.peakResidentBytes,
                      let candidatePeakResidentBytes = candidate.peakResidentBytes else {
                    return false
                }
                let correctness = candidate.correctness
                let passes =
                    candidate.categoryMacroF1 >= baseline.categoryMacroF1 - 0.02 &&
                    candidate.priorityAccuracy >= baseline.priorityAccuracy - 0.02 &&
                    candidate.actionPrecision >= baseline.actionPrecision - 0.02 &&
                    candidate.actionRecall >= baseline.actionRecall - 0.02 &&
                    candidate.confidenceCalibrationError <= baseline.confidenceCalibrationError + 0.02 &&
                    candidate.rawRequestedIDCoverage >= 0.99 &&
                    candidate.recoveredRequestedIDCoverage == 1.0 &&
                    candidate.medianLatencyPerMessage <= baseline.medianLatencyPerMessage * 0.80 &&
                    candidatePeakResidentBytes <= UInt64(Double(baselinePeakResidentBytes) * 1.25) &&
                    candidatePeakResidentBytes <= absoluteMemoryCeilingBytes &&
                    !candidate.hasUnboundedWarmGrowth &&
                    correctness.cancellationPassed &&
                    correctness.checkpointPassed &&
                    correctness.smallerBatchRecoveryPassed
                return passes
            }
            .sorted { $0.batchSize < $1.batchSize }

        let selectedBatchSize = passing.last?.batchSize ?? 1
        let profile = SmartInboxBatchProfile(
            providerID: providerID,
            modelID: modelID,
            classifierDiscriminator: classifierDiscriminator,
            maxMessageCount: selectedBatchSize,
            maxPromptCharacters: maxPromptCharacters,
            memoryCeilingBytes: absoluteMemoryCeilingBytes,
            benchmarkedAt: benchmarkedAt
        )
        return SmartInboxBenchmarkAcceptance(
            profile: profile,
            passingBatchSizes: passing.map(\.batchSize),
            usedSizeOneFallback: passing.isEmpty
        )
    }
}

public struct SmartInboxBenchmarkWarmGrowth: Equatable, Sendable {
    public let reportedSlopeBytesPerBatch: Double
    public let hasUnboundedGrowth: Bool

    public init(reportedSlopeBytesPerBatch: Double, hasUnboundedGrowth: Bool) {
        self.reportedSlopeBytesPerBatch = reportedSlopeBytesPerBatch
        self.hasUnboundedGrowth = hasUnboundedGrowth
    }
}

public enum SmartInboxBenchmarkMeasurements {
    public static func combinedWarmGrowth(
        workerResidentBytes: [UInt64],
        providerResidentBytes: [UInt64]
    ) -> SmartInboxBenchmarkWarmGrowth {
        let worker = growthAnalysis(workerResidentBytes)
        let provider = growthAnalysis(providerResidentBytes)
        return SmartInboxBenchmarkWarmGrowth(
            reportedSlopeBytesPerBatch: max(worker.slope, provider.slope),
            hasUnboundedGrowth: worker.unbounded || provider.unbounded
        )
    }

    private struct GrowthAnalysis {
        let slope: Double
        let unbounded: Bool
    }

    private static func growthAnalysis(_ values: [UInt64]) -> GrowthAnalysis {
        guard values.count >= 2 else { return GrowthAnalysis(slope: 0, unbounded: false) }
        let count = Double(values.count)
        let meanX = Double(values.count - 1) / 2
        let meanY = values.map(Double.init).reduce(0, +) / count
        let numerator = values.enumerated().reduce(0.0) { result, pair in
            result + (Double(pair.offset) - meanX) * (Double(pair.element) - meanY)
        }
        let denominator = values.indices.reduce(0.0) { result, index in
            let distance = Double(index) - meanX
            return result + distance * distance
        }
        let slope = denominator == 0 ? 0 : numerator / denominator
        let monotonic = zip(values, values.dropFirst()).allSatisfy { $1 >= $0 }
        return GrowthAnalysis(slope: slope, unbounded: monotonic && slope > 1_048_576)
    }
}

public struct SmartInboxBenchmarkWarmLatencyMeasurements: Equatable, Sendable {
    public private(set) var perMessageSamples: [Double]

    public init(perMessageSamples: [Double] = []) {
        self.perMessageSamples = perMessageSamples
    }

    public mutating func recordCompletedRequest(
        elapsedSeconds: Double,
        originalMessageCount: Int
    ) {
        precondition(originalMessageCount > 0)
        perMessageSamples.append(elapsedSeconds / Double(originalMessageCount))
    }
}
