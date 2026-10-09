import Foundation
import Testing
@testable import PlainpostAI
@testable import PlainpostCore

@Test func benchmarkEvaluatorAcceptsEveryGateAtItsBoundary() throws {
    let baseline = benchmarkSample(batchSize: 1)
    let candidate = benchmarkSample(
        batchSize: 4,
        categoryMacroF1: 0.88,
        priorityAccuracy: 0.88,
        actionPrecision: 0.88,
        actionRecall: 0.88,
        confidenceCalibrationError: 0.12,
        rawRequestedIDCoverage: 0.99,
        recoveredRequestedIDCoverage: 1,
        medianLatencyPerMessage: 0.08,
        peakResidentBytes: 125,
        hasUnboundedWarmGrowth: false,
        correctness: .init(
            cancellationPassed: true,
            checkpointPassed: true,
            smallerBatchRecoveryPassed: true
        )
    )

    let acceptance = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "foundation",
        modelID: "apple-foundation-system",
        classifierDiscriminator: "foundation:apple-foundation-system:contract",
        samples: [baseline, candidate],
        maxPromptCharacters: 8_000,
        absoluteMemoryCeilingBytes: 125,
        benchmarkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(acceptance.selectedBatchSize == 4)
    #expect(acceptance.passingBatchSizes == [4])
    #expect(!acceptance.usedSizeOneFallback)
    #expect(acceptance.profile.maxMessageCount == 4)
}

@Test(arguments: BenchmarkGateFailure.allCases)
func benchmarkEvaluatorRejectsEachGateIndependently(_ failure: BenchmarkGateFailure) throws {
    let baseline = benchmarkSample(
        batchSize: 1,
        peakResidentBytes: failure == .absoluteMemory ? 200 : 100
    )
    let candidate = failure.failingSample

    let acceptance = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "foundation",
        modelID: "apple-foundation-system",
        classifierDiscriminator: "foundation:apple-foundation-system:contract",
        samples: [baseline, candidate],
        maxPromptCharacters: 8_000,
        absoluteMemoryCeilingBytes: failure == .relativeMemory ? 200 : 125,
        benchmarkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(acceptance.selectedBatchSize == 1)
    #expect(acceptance.passingBatchSizes.isEmpty)
    #expect(acceptance.usedSizeOneFallback)
}

@Test func benchmarkEvaluatorSelectsLargestPassingSize() throws {
    let acceptance = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "ollama",
        modelID: "qwen3:8b",
        classifierDiscriminator: "ollama:qwen3:8b:contract",
        samples: [
            benchmarkSample(batchSize: 1),
            benchmarkSample(batchSize: 4, medianLatencyPerMessage: 0.079),
            benchmarkSample(batchSize: 8, medianLatencyPerMessage: 0.075),
            benchmarkSample(batchSize: 12, medianLatencyPerMessage: 0.081),
        ],
        maxPromptCharacters: 12_000,
        absoluteMemoryCeilingBytes: 200,
        benchmarkedAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(acceptance.selectedBatchSize == 8)
    #expect(acceptance.passingBatchSizes == [4, 8])
    #expect(!acceptance.usedSizeOneFallback)
}

@Test func benchmarkEvaluatorDoesNotCallTheFallbackPassingEvidence() throws {
    let acceptance = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "foundation",
        modelID: "apple-foundation-system",
        classifierDiscriminator: "foundation:apple-foundation-system:contract",
        samples: [benchmarkSample(batchSize: 1)],
        maxPromptCharacters: 8_000,
        absoluteMemoryCeilingBytes: 125,
        benchmarkedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(acceptance.profile.maxMessageCount == 1)
    #expect(acceptance.passingBatchSizes.isEmpty)
    #expect(acceptance.usedSizeOneFallback)
}

@Test func benchmarkGrowthFailsWhenEitherProcessHasUnboundedGrowth() {
    let mebibyte = UInt64(1_048_576)
    let maskedWorkerGrowth = SmartInboxBenchmarkMeasurements.combinedWarmGrowth(
        workerResidentBytes: [0, 2 * mebibyte, 4 * mebibyte, 6 * mebibyte],
        providerResidentBytes: [0, 100 * mebibyte, 1 * mebibyte, 200 * mebibyte]
    )

    #expect(maskedWorkerGrowth.hasUnboundedGrowth)
    #expect(maskedWorkerGrowth.reportedSlopeBytesPerBatch > Double(2 * mebibyte))

    let providerGrowth = SmartInboxBenchmarkMeasurements.combinedWarmGrowth(
        workerResidentBytes: [8 * mebibyte, 8 * mebibyte, 8 * mebibyte],
        providerResidentBytes: [0, 2 * mebibyte, 4 * mebibyte]
    )

    #expect(providerGrowth.hasUnboundedGrowth)
}

@Test func warmLatencyRecordsOneEndToEndSamplePerOuterRecoveredRequest() {
    var measurements = SmartInboxBenchmarkWarmLatencyMeasurements()

    // The outer request may make several recursive provider calls, but its full
    // elapsed duration contributes exactly one sample for its original IDs.
    measurements.recordCompletedRequest(elapsedSeconds: 0.9, originalMessageCount: 3)
    measurements.recordCompletedRequest(elapsedSeconds: 0.4, originalMessageCount: 4)

    #expect(measurements.perMessageSamples.count == 2)
    #expect(measurements.perMessageSamples[0].isApproximatelyEqual(to: 0.3))
    #expect(measurements.perMessageSamples[1].isApproximatelyEqual(to: 0.1))
}

@Test func benchmarkEvaluatorFailsClosedWhenWorkerRSSIsUnavailable() throws {
    let candidateMissingRSS = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "foundation",
        modelID: "apple-foundation-system",
        classifierDiscriminator: "foundation:apple-foundation-system:contract",
        samples: [
            benchmarkSample(batchSize: 1),
            benchmarkSample(batchSize: 4, medianLatencyPerMessage: 0.079, peakResidentBytes: nil),
        ],
        maxPromptCharacters: 8_000,
        absoluteMemoryCeilingBytes: 200,
        benchmarkedAt: Date(timeIntervalSince1970: 1_000)
    )
    #expect(candidateMissingRSS.usedSizeOneFallback)
    #expect(candidateMissingRSS.passingBatchSizes.isEmpty)

    let baselineMissingRSS = try SmartInboxBenchmarkEvaluator.evaluate(
        providerID: "foundation",
        modelID: "apple-foundation-system",
        classifierDiscriminator: "foundation:apple-foundation-system:contract",
        samples: [
            benchmarkSample(batchSize: 1, peakResidentBytes: nil),
            benchmarkSample(batchSize: 4, medianLatencyPerMessage: 0.079),
        ],
        maxPromptCharacters: 8_000,
        absoluteMemoryCeilingBytes: 200,
        benchmarkedAt: Date(timeIntervalSince1970: 1_000)
    )
    #expect(baselineMissingRSS.usedSizeOneFallback)
    #expect(baselineMissingRSS.passingBatchSizes.isEmpty)
}

enum BenchmarkGateFailure: CaseIterable {
    case categoryMacroF1
    case priorityAccuracy
    case actionPrecision
    case actionRecall
    case calibration
    case rawCoverage
    case recoveredCoverage
    case latency
    case relativeMemory
    case absoluteMemory
    case warmGrowth
    case cancellation
    case checkpoint
    case recovery

    var failingSample: SmartInboxBenchmarkSample {
        switch self {
        case .categoryMacroF1: benchmarkSample(batchSize: 4, categoryMacroF1: 0.879)
        case .priorityAccuracy: benchmarkSample(batchSize: 4, priorityAccuracy: 0.879)
        case .actionPrecision: benchmarkSample(batchSize: 4, actionPrecision: 0.879)
        case .actionRecall: benchmarkSample(batchSize: 4, actionRecall: 0.879)
        case .calibration: benchmarkSample(batchSize: 4, confidenceCalibrationError: 0.121)
        case .rawCoverage: benchmarkSample(batchSize: 4, rawRequestedIDCoverage: 0.989)
        case .recoveredCoverage: benchmarkSample(batchSize: 4, recoveredRequestedIDCoverage: 0.999)
        case .latency: benchmarkSample(batchSize: 4, medianLatencyPerMessage: 0.081)
        case .relativeMemory: benchmarkSample(batchSize: 4, peakResidentBytes: 126)
        case .absoluteMemory: benchmarkSample(batchSize: 4, peakResidentBytes: 126)
        case .warmGrowth: benchmarkSample(batchSize: 4, hasUnboundedWarmGrowth: true)
        case .cancellation:
            benchmarkSample(batchSize: 4, correctness: .init(
                cancellationPassed: false, checkpointPassed: true, smallerBatchRecoveryPassed: true
            ))
        case .checkpoint:
            benchmarkSample(batchSize: 4, correctness: .init(
                cancellationPassed: true, checkpointPassed: false, smallerBatchRecoveryPassed: true
            ))
        case .recovery:
            benchmarkSample(batchSize: 4, correctness: .init(
                cancellationPassed: true, checkpointPassed: true, smallerBatchRecoveryPassed: false
            ))
        }
    }
}

private func benchmarkSample(
    batchSize: Int,
    categoryMacroF1: Double = 0.90,
    priorityAccuracy: Double = 0.90,
    actionPrecision: Double = 0.90,
    actionRecall: Double = 0.90,
    confidenceCalibrationError: Double = 0.10,
    rawRequestedIDCoverage: Double = 1,
    recoveredRequestedIDCoverage: Double = 1,
    medianLatencyPerMessage: Double = 0.10,
    peakResidentBytes: UInt64? = 100,
    hasUnboundedWarmGrowth: Bool = false,
    correctness: SmartInboxBenchmarkCorrectness = .init(
        cancellationPassed: true,
        checkpointPassed: true,
        smallerBatchRecoveryPassed: true
    )
) -> SmartInboxBenchmarkSample {
    SmartInboxBenchmarkSample(
        batchSize: batchSize,
        categoryMacroF1: categoryMacroF1,
        priorityAccuracy: priorityAccuracy,
        actionPrecision: actionPrecision,
        actionRecall: actionRecall,
        confidenceCalibrationError: confidenceCalibrationError,
        rawRequestedIDCoverage: rawRequestedIDCoverage,
        recoveredRequestedIDCoverage: recoveredRequestedIDCoverage,
        duplicateResultCount: 0,
        unknownResultCount: 0,
        totalLatencySeconds: 1,
        medianLatencyPerMessage: medianLatencyPerMessage,
        p95LatencyPerMessage: medianLatencyPerMessage,
        maximumLatencyPerMessage: medianLatencyPerMessage,
        peakResidentBytes: peakResidentBytes,
        settledResidentBytes: peakResidentBytes,
        providerPeakResidentBytes: nil,
        providerSettledResidentBytes: nil,
        promptCharacterMinimum: 1_000,
        promptCharacterMedian: 2_000,
        promptCharacterP95: 3_000,
        promptCharacterMaximum: 4_000,
        truncationCount: 0,
        acceptedMessagesPerRequest: Double(batchSize),
        warmGrowthBytesPerBatch: 0,
        hasUnboundedWarmGrowth: hasUnboundedWarmGrowth,
        correctness: correctness
    )
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}
