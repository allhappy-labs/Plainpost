import XCTest
import GRDB
import PlainpostCore
import PlainpostDB
@testable import PlainpostSearchBenchmark

final class MailSearchBenchmarkSupportTests: XCTestCase {
    func testProductionCopyProofBuildsProductionShapedV21AndExecutesV22AndV23() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-v23-production-proof-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("production-copy.sqlite")
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("production-shaped-account"),
            displayName: "Production Shaped",
            email: EmailAddress("owner@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let messageID = MessageID("production-shaped-message")
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: messageID,
                threadID: ThreadID("production-shaped-thread"),
                from: EmailAddress("sender@example.com"),
                subject: "Production migration forecast",
                preview: "Quarterly forecast",
                body: "The production-shaped project body remains searchable.",
                smartCategory: .personal
            ),
            metadata: .init(
                to: [account.email],
                cc: [EmailAddress("finance@example.com")],
                bcc: [EmailAddress("legal@example.com")],
                attachments: [.init(filename: "forecast.pdf", mimeType: "application/pdf")],
                messageIdentifiers: ["<production-shaped@example.com>"]
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let preparation = try await store.databasePool.write {
            try MailSearchBenchmarkMigrationProof.prepareV21ProductionShapedCandidate($0)
        }
        let before = try await store.databasePool.read { database in
            (
                try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0,
                try database.tableExists("message_search_metadata"),
                try database.tableExists("message_fts"),
                try database.tableExists("mail_search_documents"),
                try MailSearchBenchmarkMigrationProof.v22MigrationIsRegistered(database),
                try MailSearchBenchmarkMigrationProof.v23MigrationIsRegistered(database)
            )
        }

        XCTAssertEqual(
            preparation.method,
            "transactional-current-backup-to-production-shaped-v21-legacy-reconstruction"
        )
        XCTAssertEqual(preparation.sourceSchemaVersion, 23)
        XCTAssertEqual(preparation.preparedSchemaVersion, 21)
        XCTAssertEqual(preparation.canonicalMessageCount, 1)
        XCTAssertEqual(preparation.legacyMetadataCount, 1)
        XCTAssertEqual(preparation.legacyFTSCount, 1)
        XCTAssertEqual(before.0, 21)
        XCTAssertTrue(before.1)
        XCTAssertTrue(before.2)
        XCTAssertFalse(before.3)
        XCTAssertFalse(before.4)
        XCTAssertFalse(before.5)

        try store.migrate()
        let after = try await store.databasePool.read { database in
            (
                try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0,
                try MailSearchBenchmarkMigrationProof.v22MigrationIsRegistered(database),
                try MailSearchBenchmarkMigrationProof.v23MigrationIsRegistered(database)
            )
        }
        XCTAssertEqual(after.0, 23)
        XCTAssertTrue(after.1)
        XCTAssertTrue(after.2)
        try await store.databasePool.read(SQLiteMailSearchSchema.validate)
        let response = try await SQLiteMailSearchService(store: store).search(
            .init(query: "bcc:legal filename:forecast", mode: .messages)
        )
        let migratedMessageIDs = response.hits.compactMap { hit -> MessageID? in
            guard case .message(let message) = hit else { return nil }
            return message.messageID
        }
        XCTAssertEqual(migratedMessageIDs, [messageID])
    }

    func testSyntheticWorkloadsCompleteWithAndWithoutWarmups() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-search-warmup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for warmups in [0, 2] {
            let configuration = try MailSearchBenchmarkConfiguration.parse(arguments: [
                "--messages", "10000", "--iterations", "1", "--warmups", String(warmups),
                "--output-json", directory.appendingPathComponent("result-\(warmups).json").path,
            ])
            let result = try await MailSearchBenchmarkRunner.run(configuration: configuration)
            XCTAssertTrue(result.correctnessViolations.isEmpty)
            XCTAssertEqual(result.warm.count, 7)
            XCTAssertTrue(result.warm.values.allSatisfy { $0.warmupIterations == warmups && $0.samplesMilliseconds.count == 1 })
        }
    }

    func testWarmupCountIsExplicitAndBounded() throws {
        let base = ["--messages", "10000", "--output-json", "/tmp/result.json"]
        XCTAssertEqual(try MailSearchBenchmarkConfiguration.parse(arguments: base).warmupIterations, 3)
        XCTAssertEqual(try MailSearchBenchmarkConfiguration.parse(arguments: base + ["--warmups", "0"]).warmupIterations, 0)
        XCTAssertEqual(try MailSearchBenchmarkConfiguration.parse(arguments: base + ["--warmups", "7"]).warmupIterations, 7)
        for invalid in ["-1", "1001", "unknown"] {
            XCTAssertThrowsError(try MailSearchBenchmarkConfiguration.parse(arguments: base + ["--warmups", invalid]))
        }
    }

    func testWarmupsRunOutsideMeasuredSampleInventory() async throws {
        var invocations = 0
        let summary = try await MailSearchBenchmarkRunner.measure(iterations: 4, warmupIterations: 2) {
            invocations += 1
        }
        XCTAssertEqual(invocations, 6)
        XCTAssertEqual(summary.warmupIterations, 2)
        XCTAssertEqual(summary.samplesMilliseconds.count, 4)
    }

    func testBenchmarkProvenanceDoesNotInventMissingSourceIdentity() {
        let provenance = MailSearchBenchmarkProvenance.capture(environment: [:])
        XCTAssertNil(provenance.sourceSHA)
        XCTAssertNil(provenance.dirtyPaths)
        XCTAssertNil(provenance.toolchain)
        XCTAssertNil(provenance.cacheIdentity)
        XCTAssertEqual(provenance.commandArguments, [])
    }

    func testPercentileUsesNearestRank() {
        XCTAssertEqual(MailSearchBenchmarkStatistics.percentile([1, 2, 3, 4, 5], 0.95), 5)
        XCTAssertEqual(MailSearchBenchmarkStatistics.percentile([5, 1, 3, 2, 4], 0.50), 3)
        XCTAssertNil(MailSearchBenchmarkStatistics.percentile([Double](), 0.95))
    }

    func testTenThousandMessageBudgetsMatchSpecification() {
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.structuredP95Milliseconds, 75)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.messageP95Milliseconds, 250)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.conversationP95Milliseconds, 400)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.coldFirstPageMilliseconds, 1_000)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.cancellationMilliseconds, 100)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.rssPeakDeltaBytes, 25 * 1_024 * 1_024)
        XCTAssertEqual(MailSearchBenchmarkBudget.tenThousand.searchStructureBytes, 106_900_000)
    }

    func testConfigurationAcceptsOnlySupportedDeterministicDatasetSizes() throws {
        for messageCount in MailSearchBenchmarkDataset.supportedMessageCounts {
            let configuration = try MailSearchBenchmarkConfiguration.parse(arguments: [
                "--messages", String(messageCount),
                "--iterations", "7",
                "--output-json", "/tmp/result-\(messageCount).json",
                "--enforce-budgets",
            ])
            XCTAssertEqual(configuration.messageCount, messageCount)
            XCTAssertEqual(configuration.iterations, 7)
            XCTAssertEqual(configuration.outputJSON.path, "/tmp/result-\(messageCount).json")
            XCTAssertTrue(configuration.enforceBudgets)
            XCTAssertNil(configuration.sourceDatabase)
        }

        XCTAssertThrowsError(try MailSearchBenchmarkConfiguration.parse(arguments: [
            "--messages", "9999", "--output-json", "/tmp/result.json",
        ]))
        XCTAssertThrowsError(try MailSearchBenchmarkConfiguration.parse(arguments: [
            "--messages", "10000", "--iterations", "0", "--output-json", "/tmp/result.json",
        ]))
        XCTAssertThrowsError(try MailSearchBenchmarkConfiguration.parse(arguments: [
            "--messages", "10000",
        ]))
    }

    func testSourceConfigurationRequiresExplicitDestinationAndPreservesSourcePath() throws {
        let configuration = try MailSearchBenchmarkConfiguration.parse(arguments: [
            "--messages", "10000",
            "--iterations", "3",
            "--output-json", "/tmp/result.json",
            "--source-db", "/tmp/source.sqlite",
        ])

        XCTAssertEqual(configuration.sourceDatabase?.path, "/tmp/source.sqlite")
        XCTAssertEqual(configuration.outputJSON.path, "/tmp/result.json")
    }

    func testDatasetGenerationIsSeededAndCoversProductionShapes() {
        let first = MailSearchBenchmarkDataset(messageCount: 10_000)
        let second = MailSearchBenchmarkDataset(messageCount: 10_000)

        XCTAssertEqual(first.seed, second.seed)
        XCTAssertEqual(first.messageCount, 10_000)
        XCTAssertEqual(first.threadCount, 2_000)
        XCTAssertEqual(first.accounts.count, 2)
        XCTAssertEqual(first.mailboxes.count, 8)
        XCTAssertEqual(first.sample(at: 137), second.sample(at: 137))
        XCTAssertNotEqual(first.sample(at: 137), first.sample(at: 138))
        XCTAssertTrue(first.coverage.contains(.attachments))
        XCTAssertTrue(first.coverage.contains(.mailStates))
        XCTAssertTrue(first.coverage.contains(.commonAndRareTerms))
        XCTAssertTrue(first.coverage.contains(.dateDistribution))
        XCTAssertTrue(first.coverage.contains(.multiMessageThreads))
    }

    func testCommonSearchTermIsFrequentButNotUniversal() {
        let dataset = MailSearchBenchmarkDataset(messageCount: 10_000)
        let samples = (0 ..< 100).map(dataset.sample)
        let projectMatches = samples.filter {
            $0.subject.localizedCaseInsensitiveContains("project")
                || $0.body.localizedCaseInsensitiveContains("project")
        }.count

        XCTAssertGreaterThanOrEqual(projectMatches, 10)
        XCTAssertLessThanOrEqual(projectMatches, 25)
    }

    func testStorageAccountingUsesSQLitePageAndDbstatBytes() {
        XCTAssertEqual(
            MailSearchBenchmarkStorageAccounting.databaseBytes(pageCount: 256, pageSize: 4_096),
            1_048_576
        )
        XCTAssertEqual(
            MailSearchBenchmarkStorageAccounting.searchStructureBytes([
                .init(name: "mail_search_documents", bytes: 12_000),
                .init(name: "mail_search_fts_data", bytes: 30_000),
                .init(name: "messages", bytes: 90_000),
                .init(name: "mail_search_documents_account_sort", bytes: 8_000),
            ]),
            50_000
        )
    }

    func testRSSSamplerReturnsCurrentDarwinResidentBytes() throws {
        let bytes = try XCTUnwrap(MailSearchBenchmarkRSS.currentResidentBytes())
        XCTAssertGreaterThan(bytes, 0)
    }

    func testPeakRSSAccumulatorTracksPeakInsteadOfRetainedNetGrowth() throws {
        var accumulator = try MailSearchBenchmarkPeakRSSAccumulator(baselineBytes: 100)
        try accumulator.record(125)
        try accumulator.record(175)
        try accumulator.record(110)

        let summary = accumulator.summary(
            finalBytes: 110,
            periodicSampleCount: 3,
            samplingIntervalNanoseconds: 1_000_000
        )
        XCTAssertEqual(summary.baselineBytes, 100)
        XCTAssertEqual(summary.peakBytes, 175)
        XCTAssertEqual(summary.finalBytes, 110)
        XCTAssertEqual(summary.peakDeltaBytes, 75)
        XCTAssertEqual(summary.periodicSampleCount, 3)
    }

    func testPeakRSSSamplerReturnsInjectedPeakAndStopsAfterSuccessfulOperation() async throws {
        let readings = DelayedSecondRSSReading([100, 175, 110])
        let sampler = MailSearchBenchmarkPeakRSSSampler(
            configuration: .init(
                samplingIntervalNanoseconds: 1_000_000_000,
                maximumPeriodicSamples: 10
            ),
            sampleRSS: { readings.next() }
        )

        let measured = try await sampler.measure {
            XCTAssertEqual(
                readings.completedCallCount,
                2,
                "The first periodic sample must complete before the operation begins"
            )
            return "measured"
        }

        XCTAssertEqual(measured.value, "measured")
        XCTAssertEqual(measured.rss.baselineBytes, 100)
        XCTAssertEqual(measured.rss.peakBytes, 175)
        XCTAssertEqual(measured.rss.finalBytes, 110)
        XCTAssertEqual(measured.rss.peakDeltaBytes, 75)
        XCTAssertEqual(measured.rss.periodicSampleCount, 1)
        XCTAssertEqual(readings.callCount, 3)

        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(readings.callCount, 3)
    }

    func testPeakRSSSamplerFailsClosedWhenItsBoundExpiresBeforeOperation() async throws {
        let readings = LockedRSSReadings([100, 125, 175, 130, 110])
        let sampler = MailSearchBenchmarkPeakRSSSampler(
            configuration: .init(
                samplingIntervalNanoseconds: 1_000_000,
                maximumPeriodicSamples: 3
            ),
            sampleRSS: { readings.next() }
        )

        do {
            _ = try await sampler.measure {
                try await Task.sleep(for: .milliseconds(20))
                return "measured"
            }
            XCTFail("Expected an exhausted sampling window to fail closed")
        } catch {
            XCTAssertEqual(
                String(describing: error),
                "Peak RSS sampling window ended before the benchmark operation completed."
            )
        }

        XCTAssertEqual(readings.callCount, 5)
    }

    func testPeakRSSSamplerFailsClosedForInvalidPeriodicReading() async throws {
        let readings = LockedRSSReadings([100, nil, 110])
        let sampler = MailSearchBenchmarkPeakRSSSampler(
            configuration: .init(
                samplingIntervalNanoseconds: 1_000_000_000,
                maximumPeriodicSamples: 10
            ),
            sampleRSS: { readings.next() }
        )

        do {
            _ = try await sampler.measure {
                await readings.waitForCallCount(2)
                return "measured"
            }
            XCTFail("Expected an invalid periodic RSS reading to fail closed")
        } catch {
            XCTAssertEqual(String(describing: error), "Could not sample Darwin task RSS.")
        }
    }

    func testPeakRSSSamplerFailsClosedForInvalidFinalReading() async throws {
        let readings = LockedRSSReadings([100, 125, nil])
        let sampler = MailSearchBenchmarkPeakRSSSampler(
            configuration: .init(
                samplingIntervalNanoseconds: 1_000_000_000,
                maximumPeriodicSamples: 10
            ),
            sampleRSS: { readings.next() }
        )

        do {
            _ = try await sampler.measure {
                await readings.waitForCallCount(2)
                return "measured"
            }
            XCTFail("Expected an invalid final RSS reading to fail closed")
        } catch {
            XCTAssertEqual(String(describing: error), "Could not sample Darwin task RSS.")
        }
    }

    func testPeakRSSSamplerCancelsAndAwaitsSamplerWhenOperationThrows() async throws {
        enum ExpectedFailure: Error {
            case operation
        }

        let readings = LockedRSSReadings(repeating: 100)
        let sampler = MailSearchBenchmarkPeakRSSSampler(
            configuration: .init(
                samplingIntervalNanoseconds: 1_000_000,
                maximumPeriodicSamples: 1_000
            ),
            sampleRSS: { readings.next() }
        )

        do {
            _ = try await sampler.measure {
                await readings.waitForCallCount(2)
                throw ExpectedFailure.operation
            }
            XCTFail("Expected the benchmark operation to throw")
        } catch ExpectedFailure.operation {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let callCountAfterReturn = readings.callCount
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(readings.callCount, callCountAfterReturn)
    }

    func testBudgetEvaluationAndExitCodesAreStable() {
        let passing = MailSearchBenchmarkBudgetEvaluation.evaluate(
            measurements: .init(
                structuredP95Milliseconds: 75,
                messageP95Milliseconds: 250,
                conversationP95Milliseconds: 400,
                coldFirstPageMilliseconds: 999,
                cancellationMilliseconds: 100,
                rssPeakDeltaBytes: 25 * 1_024 * 1_024 - 1,
                searchStructureBytes: 106_900_000
            ),
            budget: .tenThousand
        )
        XCTAssertTrue(passing.violations.isEmpty)
        XCTAssertEqual(passing.exitCode, MailSearchBenchmarkExitCode.success.rawValue)

        let failing = MailSearchBenchmarkBudgetEvaluation.evaluate(
            measurements: .init(
                structuredP95Milliseconds: 76,
                messageP95Milliseconds: 251,
                conversationP95Milliseconds: 401,
                coldFirstPageMilliseconds: 1_000,
                cancellationMilliseconds: 101,
                rssPeakDeltaBytes: 25 * 1_024 * 1_024,
                searchStructureBytes: 106_900_001
            ),
            budget: .tenThousand
        )
        XCTAssertEqual(failing.violations.count, 7)
        XCTAssertTrue(failing.violations.contains("rss_peak_delta_bytes"))
        XCTAssertEqual(failing.exitCode, MailSearchBenchmarkExitCode.budgetExceeded.rawValue)
        XCTAssertEqual(MailSearchBenchmarkExitCode.invalidArguments.rawValue, 64)
        XCTAssertEqual(MailSearchBenchmarkExitCode.runtimeFailure.rawValue, 1)
    }

    func testNonEnforcedTrackingStillFailsCorrectnessViolations() {
        XCTAssertTrue(MailSearchBenchmarkOutcome.passed(
            enforcePerformanceBudgets: false,
            performanceViolations: ["message_p95"],
            correctnessViolations: []
        ))
        XCTAssertFalse(MailSearchBenchmarkOutcome.passed(
            enforcePerformanceBudgets: false,
            performanceViolations: [],
            correctnessViolations: ["source_changed"]
        ))
        XCTAssertFalse(MailSearchBenchmarkOutcome.passed(
            enforcePerformanceBudgets: true,
            performanceViolations: ["message_p95"],
            correctnessViolations: []
        ))
        XCTAssertEqual(
            MailSearchBenchmarkOutcome.exitCode(
                enforcePerformanceBudgets: false,
                performanceViolations: ["message_p95"],
                correctnessViolations: []
            ),
            MailSearchBenchmarkExitCode.success.rawValue
        )
        XCTAssertEqual(
            MailSearchBenchmarkOutcome.exitCode(
                enforcePerformanceBudgets: false,
                performanceViolations: [],
                correctnessViolations: ["source_changed"]
            ),
            MailSearchBenchmarkExitCode.runtimeFailure.rawValue
        )
        XCTAssertEqual(
            MailSearchBenchmarkOutcome.exitCode(
                enforcePerformanceBudgets: true,
                performanceViolations: ["message_p95"],
                correctnessViolations: []
            ),
            MailSearchBenchmarkExitCode.budgetExceeded.rawValue
        )
    }

    func testProductionStorageBaselineIsACorrectnessInvariant() {
        XCTAssertEqual(
            MailSearchBenchmarkOutcome.productionStorageViolations(
                searchStructureBytes: 106_900_000,
                baselineBytes: 106_900_000
            ),
            []
        )
        XCTAssertEqual(
            MailSearchBenchmarkOutcome.productionStorageViolations(
                searchStructureBytes: 106_900_001,
                baselineBytes: 106_900_000
            ),
            ["production_search_structure_bytes"]
        )
    }

    func testSourcePathSafetyRejectsExactSymlinkHardLinkAndDestinationAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-search-path-safety-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let original = Data("production-source".utf8)
        try original.write(to: source)
        let safeWorkingDirectory = directory.appendingPathComponent("safe-work", isDirectory: true)

        XCTAssertThrowsError(try MailSearchBenchmarkPathSafety.validate(
            sourceDatabase: source,
            outputJSON: source,
            workingDirectory: safeWorkingDirectory
        ))

        let symlink = directory.appendingPathComponent("source-symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertThrowsError(try MailSearchBenchmarkPathSafety.validate(
            sourceDatabase: source,
            outputJSON: symlink,
            workingDirectory: safeWorkingDirectory
        ))

        let hardLink = directory.appendingPathComponent("source-hard-link.json")
        try FileManager.default.linkItem(at: source, to: hardLink)
        XCTAssertThrowsError(try MailSearchBenchmarkPathSafety.validate(
            sourceDatabase: source,
            outputJSON: hardLink,
            workingDirectory: safeWorkingDirectory
        ))

        let collidingSource = directory.appendingPathComponent("production-copy.sqlite")
        try original.write(to: collidingSource)
        XCTAssertThrowsError(try MailSearchBenchmarkPathSafety.validate(
            sourceDatabase: collidingSource,
            outputJSON: directory.appendingPathComponent("result.json"),
            workingDirectory: directory
        ))

        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        XCTAssertThrowsError(try MailSearchBenchmarkPathSafety.validate(
            sourceDatabase: source,
            outputJSON: sourceWAL,
            workingDirectory: safeWorkingDirectory
        ))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: collidingSource), original)
    }

    func testProcessRejectsSourceOutputAliasWithoutChangingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-search-process-safety-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let original = Data("do-not-replace".utf8)
        try original.write(to: source)

        let executable = Bundle(for: MailSearchBenchmarkSupportTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PlainpostSearchBenchmark")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--messages", "10000",
            "--iterations", "1",
            "--source-db", source.path,
            "--output-json", source.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, MailSearchBenchmarkExitCode.runtimeFailure.rawValue)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testWrapperPreservesInterruptAndTerminationExitStatuses() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf:
            repositoryRoot.appendingPathComponent("Scripts/benchmark-mail-search.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("trap cleanup EXIT"))
        XCTAssertTrue(script.contains("trap 'exit 130' INT"))
        XCTAssertTrue(script.contains("trap 'exit 143' TERM"))
    }

    func testSyntheticPopulationUsesDatabasePoolTransactionBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-search-benchmark-support-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("fixture.sqlite").path)
        try store.migrate()

        let dataset = MailSearchBenchmarkDataset(messageCount: 10_000)
        let counts = try MailSearchBenchmarkSyntheticDatabase.populate(
            store: store,
            dataset: dataset,
            limit: 25
        )

        XCTAssertEqual(counts.messages, 25)
        XCTAssertEqual(counts.threads, 5)
        XCTAssertEqual(counts.accounts, 2)
        XCTAssertEqual(counts.mailboxes, 8)
        XCTAssertEqual(counts.projections, 25)
        XCTAssertEqual(counts.ftsRows, 25)
        XCTAssertEqual(counts.coverage, Set(MailSearchBenchmarkDatasetCoverage.allCases))
        XCTAssertTrue(counts.generatorMatchesModel)
        try store.databasePool.writeWithoutTransaction(SQLiteMailSearchSchema.validateFTSIntegrity)
    }
}

private final class DelayedSecondRSSReading: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Int64]
    private var startedCalls = 0
    private var completedCalls = 0

    init(_ readings: [Int64]) {
        self.readings = readings
    }

    var callCount: Int {
        lock.withLock { startedCalls }
    }

    var completedCallCount: Int {
        lock.withLock { completedCalls }
    }

    func next() -> Int64? {
        let call = lock.withLock { () -> (index: Int, reading: Int64?) in
            startedCalls += 1
            return (startedCalls, readings.isEmpty ? nil : readings.removeFirst())
        }
        if call.index == 2 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.withLock {
            completedCalls += 1
        }
        return call.reading
    }
}

private final class LockedRSSReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Int64?]
    private var repeatingReading: Int64?
    private var storedCallCount = 0

    init(_ readings: [Int64?]) {
        self.readings = readings
    }

    init(repeating reading: Int64) {
        readings = []
        repeatingReading = reading
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func next() -> Int64? {
        lock.withLock {
            storedCallCount += 1
            return readings.isEmpty ? repeatingReading : readings.removeFirst()
        }
    }

    func waitForCallCount(_ expectedCallCount: Int) async {
        while callCount < expectedCallCount {
            await Task.yield()
        }
    }
}
