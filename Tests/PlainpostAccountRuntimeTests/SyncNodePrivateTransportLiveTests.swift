import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

// The acceptance generic provider shares one session across six mailboxes and
// uses the production one-minute poll deadline. A single API request must be
// bounded by that same full-cycle budget so a blocked provider cannot defeat
// the scenario's derived retry bounds.
private let acceptanceProviderRequestTimeoutSeconds = 60 * 6 + 15
private let acceptanceNodeTwoRestartControllerTimeoutSeconds = 75
private let acceptanceNodeTwoDeletionWaitSeconds = 150
private let acceptanceNodeTwoActivationRestartCount = 1
// Match the owner's provider transition scheduling margin so the control
// marker has time to be published after the bounded persistence restart.
private let acceptanceNodeTwoActivationSchedulingMarginSeconds = 15
private let acceptanceNodeTwoActivationWaitSeconds =
    acceptanceNodeTwoRestartControllerTimeoutSeconds * acceptanceNodeTwoActivationRestartCount
        + acceptanceNodeTwoActivationSchedulingMarginSeconds

final class SyncNodePrivateTransportLiveTests: XCTestCase {
    func testNodeTwoActivationWaitContainsPersistenceRestartBudget() {
        XCTAssertEqual(
            acceptanceNodeTwoActivationWaitSeconds,
            acceptanceNodeTwoRestartControllerTimeoutSeconds * acceptanceNodeTwoActivationRestartCount
                + acceptanceNodeTwoActivationSchedulingMarginSeconds
        )
        XCTAssertGreaterThan(
            acceptanceNodeTwoActivationWaitSeconds,
            acceptanceNodeTwoRestartControllerTimeoutSeconds * acceptanceNodeTwoActivationRestartCount
        )
    }

    @MainActor
    func testRealCentralAndNodeProcessesClosePrivateLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_PRIVATE_ACCEPTANCE"] == "enabled" else {
            throw XCTSkip("run through Scripts/test-sync-node-private-transport.sh")
        }
        try CurlAcceptanceStreamDiagnostics.reset()
        try await RealPrivateTransportScenario(environment: ProcessInfo.processInfo.environment).run()
    }

    func testCurlTransportCancelsRejectedServiceUnavailableStreamLifecycle() throws {
        let lifecycle = CurlStreamLifecycleProbe()
        let bytes = PlainpostByteStream(capacity: 1, onCancellation: lifecycle.cancel)
        let response = NodeHTTPStreamResponse(
            statusCode: 503, url: URL(string: "https://node.tail1234.ts.net:8443")!,
            headers: [:], bytes: bytes
        )

        XCTAssertThrowsError(try CurlNodeHTTPTransport.accept(response, failServiceUnavailable: true))
        XCTAssertEqual(lifecycle.cancellations, 1)
    }

    func testCurlRequestHeadersUseExclusiveOwnerOnlyConfigOutsideProcessArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-headers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "acceptance-capability-opaque-value"
        let headerFile = try CurlAcceptanceRequestHeaderFile.create(
            headers: ["Authorization": "Bearer \(secret)", "X-Test": "path\\segment"],
            temporaryRoot: root,
            stem: "request"
        )
        defer { headerFile.remove() }
        var arguments = ["--silent"]
        headerFile.appendArguments(to: &arguments)

        guard !arguments.contains(where: { $0.contains(secret) }) else {
            XCTFail("sensitive header entered process arguments")
            return
        }
        XCTAssertEqual(arguments, ["--silent", "--config", headerFile.url.path])
        let attributes = try FileManager.default.attributesOfItem(atPath: headerFile.url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(mode, 0o600)
        let expected = Data("header = \"Authorization: Bearer \(secret)\"\nheader = \"X-Test: path\\\\segment\"\n".utf8)
        XCTAssertTrue(try Data(contentsOf: headerFile.url) == expected, "curl header config content mismatch")
    }

    func testAcceptanceAccountResponseSummaryUsesAllowlistedRouteClass() async {
        let classifier = AcceptanceAccountResponseClassifier()
        let privateDeviceID = "11111111-1111-1111-1111-111111111111"
        let path = "/v1/trust/admissions/\(privateDeviceID)/offer"
        let response = CurlAcceptanceWire.Response(
            status: 409,
            headers: ["Content-Type": "application/problem+json"],
            body: Data("{}".utf8)
        )

        await classifier.response(response, path: path)

        let summary = await classifier.summary()
        XCTAssertEqual(summary, "class=admission-offer-status=409-body=problem-json")
        XCTAssertFalse(summary.contains(privateDeviceID))

        await classifier.response(
            CurlAcceptanceWire.Response(status: 200, headers: [:], body: Data()),
            path: path
        )
        let clearedSummary = await classifier.summary()
        XCTAssertEqual(clearedSummary, "class=none-status=none-body=none")
    }

    func testAttachmentReleaseFailedControlSignalIsObservedAsTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-attachment-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failedPath = root.appendingPathComponent("attachment-release-probe.failed")
        XCTAssertTrue(FileManager.default.createFile(atPath: failedPath.path, contents: Data()))

        let observation = try await NodeMailAuthorityLiveScenario.observeControlSignalForTesting(
            root,
            action: "attachment-release-probe",
            pollAttempts: 20,
            pollDelayMilliseconds: 10
        )
        XCTAssertEqual(observation, .failed)

        do {
            try await NodeMailAuthorityLiveScenario.waitForControlSignalForTesting(
                root,
                action: "attachment-release-probe",
                pollAttempts: 20,
                pollDelayMilliseconds: 10
            )
            XCTFail("a failed attachment release signal must throw transport")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .transport)
        }
    }

    func testNestedAcceptanceStreamCancellationReleasesLifecycleWhenProducerIgnoresTerm() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-nested-curl-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/python3",
            arguments: [
                "-c", "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); os.write(1, b'x' * 131072); time.sleep(3)"
            ],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 200_000
        )
        do {
            let response = try await stream.start(url: URL(string: "https://example.test")!)

            let cancellation = NestedAcceptanceStreamCancellation(response: response.bytes)
            let outer = PlainpostByteStream(capacity: 1, onCancellation: cancellation.cancel)
            let transfer = Task {
                do {
                    for try await chunk in response.bytes {
                        try await outer.producer.send(chunk)
                    }
                    outer.producer.finish()
                } catch {
                    outer.producer.fail(error)
                }
            }
            cancellation.install(transfer)
            let iterator = outer.makeAsyncIterator()
            let firstChunk = try await iterator.next()
            XCTAssertGreaterThan(firstChunk?.count ?? 0, 0)
            XCTAssertLessThanOrEqual(firstChunk?.count ?? 0, 64 * 1024)
            iterator.cancel()

            let released = await observeRelease(of: stream, lifecycleURL: lifecycleURL)
            XCTAssertTrue(released, "nested cancellation must release the inner lifecycle within the bounded observation")
            await stream.shutdown()
            XCTAssertFalse(stream.isRunningForTesting, "nested cancellation must reap the inner process before shutdown returns")
        } catch {
            await stream.shutdown()
            throw error
        }

        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }
        let freshStream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/python3",
            arguments: [
                "-c", "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); os.write(1, b'x' * 131072); time.sleep(3)"
            ],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 200_000
        )
        do {
            let freshResponse = try await freshStream.start(url: URL(string: "https://example.test")!)
            let freshIterator = freshResponse.bytes.makeAsyncIterator()
            let freshFirstChunk = try await freshIterator.next()
            XCTAssertGreaterThan(freshFirstChunk?.count ?? 0, 0)
            XCTAssertLessThanOrEqual(freshFirstChunk?.count ?? 0, 64 * 1024)
            freshIterator.cancel()
            let released = await observeRelease(of: freshStream, lifecycleURL: lifecycleURL)
            XCTAssertTrue(released, "a fresh stream must release its lifecycle within the bounded observation")
            await freshStream.shutdown()
            XCTAssertFalse(freshStream.isRunningForTesting, "a fresh stream must reap its process before shutdown returns")
        } catch {
            await freshStream.shutdown()
            throw error
        }
    }

    func testNestedAcceptanceStreamCancellationStressReleasesLifecycleAcrossChunkTimings() async throws {
        for iteration in 0..<8 {
            try await runNestedAcceptanceStreamCancellationStressIteration(iteration: iteration)
        }
    }

    func testCurlAcceptanceStreamWaitsForCompletedFinalHeaderBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-partial-headers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        let partialHeaders = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\nContent-Disposition: attachment; filename=photo.bin\r\n\r\nHTTP/1.1 200 OK\r\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data(partialHeaders.utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }
        let processStarted = expectation(description: "curl stream process started")
        let metadataIncomplete = expectation(description: "curl stream observes incomplete final header block")
        let stream = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 2"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024,
            onProcessSpawnBegin: { _ in processStarted.fulfill() },
            onMetadataIncomplete: { metadataIncomplete.fulfill() }
        )
        let responseTask = Task { try await stream.start(url: URL(string: "https://example.test")!) }
        do {
            await fulfillment(of: [processStarted], timeout: 1)
            await fulfillment(of: [metadataIncomplete], timeout: 1)
            let finalHeaders = "Content-Type: application/octet-stream\r\nContent-Length: 4\r\nContent-Disposition: attachment; filename=photo.bin\r\n\r\n"
            let handle = try FileHandle(forWritingTo: headersURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(finalHeaders.utf8))

            let response = try await responseTask.value
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.headers["Content-Type"], "application/octet-stream")
            XCTAssertEqual(response.headers["Content-Length"], "4")
            XCTAssertEqual(response.headers["Content-Disposition"], "attachment; filename=photo.bin")
            response.bytes.cancel()
            responseTask.cancel()
            await stream.shutdown()
        } catch {
            responseTask.cancel()
            await stream.shutdown()
            throw error
        }
    }

    func testCurlAcceptanceStreamClassifiesMetadataTerminationWithoutSensitiveValues() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"] != nil else {
            throw XCTSkip("stream diagnostics are required for this classification regression")
        }
        try CurlAcceptanceStreamDiagnostics.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-metadata-termination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data()))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            arguments: ["-c", "exit 16"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024
        )
        do {
            _ = try await stream.start(url: URL(string: "https://example.test")!)
            XCTFail("a child termination before metadata must fail the stream")
        } catch {
            // expected
        }
        await stream.shutdown()

        let diagnosticsPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"])
        let diagnostics = try String(contentsOf: URL(fileURLWithPath: diagnosticsPath), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("event=stream-termination-failed phase=metadata"))
        XCTAssertFalse(diagnostics.contains("event=process-start-failed"))
        XCTAssertFalse(diagnostics.contains("example.test"))
        XCTAssertFalse(diagnostics.contains(root.path))
        XCTAssertFalse(diagnostics.contains("stderr"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: headersURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleURL.path))
    }

    func testCurlAcceptanceStreamClassifiesNonzeroStreamTerminationWithoutSensitiveValues() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"] != nil else {
            throw XCTSkip("stream diagnostics are required for this classification regression")
        }
        try CurlAcceptanceStreamDiagnostics.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-stream-termination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        let headers = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data(headers.utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            arguments: ["-c", "exit 16"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024
        )
        let response = try await stream.start(url: URL(string: "https://example.test")!)
        _ = response
        let exited = await observeProcessExit(of: stream)
        XCTAssertTrue(exited)
        let released = await observeRelease(of: stream, lifecycleURL: lifecycleURL)
        XCTAssertTrue(released)
        await stream.shutdown()

        let diagnosticsPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"])
        let diagnostics = try String(contentsOf: URL(fileURLWithPath: diagnosticsPath), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("event=stream-termination-failed phase=stream"))
        XCTAssertFalse(diagnostics.contains("event=process-start-failed"))
        XCTAssertFalse(diagnostics.contains("example.test"))
        XCTAssertFalse(diagnostics.contains(root.path))
        XCTAssertFalse(diagnostics.contains("stderr"))
    }

    func testCurlAcceptanceStreamClassifiesProcessRunFailureWithoutSensitiveValues() async throws {
        guard ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"] != nil else {
            throw XCTSkip("stream diagnostics are required for this classification regression")
        }
        try CurlAcceptanceStreamDiagnostics.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-process-run-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data()))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            supervisorExecutable: "/definitely/missing/plainpost-stream-supervisor",
            arguments: ["-c", "exit 16"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024
        )
        do {
            _ = try await stream.start(url: URL(string: "https://example.test")!)
            XCTFail("a missing supervisor executable must fail process.run")
        } catch {
            // expected
        }
        await stream.shutdown()

        let diagnosticsPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"])
        let diagnostics = try String(contentsOf: URL(fileURLWithPath: diagnosticsPath), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("event=process-run-failed"))
        XCTAssertFalse(diagnostics.contains("event=stream-termination-failed"))
        XCTAssertFalse(diagnostics.contains("example.test"))
        XCTAssertFalse(diagnostics.contains(root.path))
        XCTAssertFalse(diagnostics.contains("stderr"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: headersURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleURL.path))
    }

    func testCurlAcceptanceStreamRetainsMetadataArtifactsUntilImmediateExitIsConsumed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-metadata-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        let headers = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Type: application/octet-stream\r\n\r\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data(headers.utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let metadataWaitBegan = expectation(description: "metadata wait began")
        let pumpFinished = expectation(description: "pump finished before metadata was consumed")
        let allowMetadata = DispatchSemaphore(value: 0)
        let stream = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024,
            onMetadataWaitBegin: {
                metadataWaitBegan.fulfill()
                _ = allowMetadata.wait(timeout: .now() + 2)
            },
            onPumpFinished: {
                pumpFinished.fulfill()
            }
        )
        let startTask = Task { try await stream.start(url: URL(string: "https://example.test")!) }
        await fulfillment(of: [metadataWaitBegan], timeout: 1)
        await fulfillment(of: [pumpFinished], timeout: 1)
        allowMetadata.signal()
        let response = try await startTask.value
        XCTAssertEqual(response.statusCode, 200)
        await stream.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: headersURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleURL.path))
    }

    private func runNestedAcceptanceStreamCancellationStressIteration(iteration: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-nested-curl-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        let exitedTiming = iteration % 5 == 0
        let firstBytes = exitedTiming ? 8_192 : 65_536 + iteration * 4_096
        let secondBytes = exitedTiming ? 1_024 : 1_024 + iteration * 257
        let totalBytes = firstBytes + secondBytes
        let producerTail: String
        switch iteration % 5 {
        case 0:
            // Keep this child below the pipe capacity so it deterministically
            // exits before the consumer cancels, while the nested stream may
            // still be draining buffered bytes.
            producerTail = ""
        case 1:
            producerTail = "time.sleep(0.001)"
        case 2:
            producerTail = "time.sleep(0.005)"
        case 3:
            producerTail = "time.sleep(0.020)"
        default:
            // Keep one TERM-ignoring, live child in every five iterations to
            // cover the real acceptance cancellation timing as well.
            producerTail = "time.sleep(3)"
        }
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(totalBytes)\r\nContent-Disposition: attachment; filename=stress.bin\r\n\r\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data(headers.utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/python3",
            arguments: [
                "-c", "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); os.write(1, b'x' * \(firstBytes)); os.write(1, b'y' * \(secondBytes)); \(producerTail)"
            ],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 200_000
        )
        do {
            let response = try await stream.start(url: URL(string: "https://example.test")!)
            let client = NodeSyncClient(sender: CurlAcceptanceAttachmentSender(response: response))
            let download = try await client.attachment(id: "attachment-1")
            let iterator = download.bytes.makeAsyncIterator()
            let firstChunk = try await iterator.next()
            XCTAssertGreaterThan(firstChunk?.count ?? 0, 0, "stress iteration \(iteration) must receive a first chunk")
            XCTAssertLessThanOrEqual(firstChunk?.count ?? 0, 64 * 1024)
            if exitedTiming {
                let exited = await observeProcessExit(of: stream)
                XCTAssertTrue(exited, "exited stress iteration \(iteration) must observe a reaped child before cancellation")
            } else {
                XCTAssertTrue(stream.isRunningForTesting, "live stress iteration \(iteration) must observe a running child before cancellation")
            }
            iterator.cancel()
            let released = await observeRelease(of: stream, lifecycleURL: lifecycleURL)
            XCTAssertTrue(released, "stress iteration \(iteration) must release its lifecycle")
            await stream.shutdown()
            XCTAssertFalse(stream.isRunningForTesting, "stress iteration \(iteration) must reap its process")
        } catch {
            await stream.shutdown()
            throw error
        }
    }

    func testCurlAcceptanceStreamReleasesLifecycleWhenCancelledDuringBlockedRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerDeinitialized = expectation(description: "curl stream owner deinitialized")

        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        var stream: CurlAcceptanceProcessStream? = try CurlAcceptanceProcessStream(
            executable: "/bin/sh",
            arguments: ["-c", "while [ ! -e \"$1\" ]; do /bin/sleep 0.01; done", "stream", root.appendingPathComponent("stop").path],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024,
            onDeinit: { ownerDeinitialized.fulfill() }
        )
        do {
            guard let activeStream = stream else {
                XCTFail("curl stream owner was released before start")
                return
            }
            let response = try await activeStream.start(url: URL(string: "https://example.test")!)
            response.bytes.cancel()
            await activeStream.shutdown()
            XCTAssertFalse(activeStream.isRunningForTesting, "blocked-read cancellation must reap the process before shutdown returns")
        }
        catch {
            await stream?.shutdown()
            stream = nil
            throw error
        }
        stream = nil

        await fulfillment(of: [ownerDeinitialized], timeout: 1)
        for _ in 0..<40 {
            if !FileManager.default.fileExists(atPath: lifecycleURL.path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("cancelled stream did not release its lifecycle marker")
    }

    func testCurlAcceptanceStreamCancellationLeavesProcessTerminationToPump() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-process-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let waitBegan = expectation(description: "pump entered cancellable exit wait")
        let terminationProbe = CurlAcceptanceTerminationProbe()
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        let lifecycleURL = root.appendingPathComponent("stream-active")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        let stream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os, time; os.close(1); time.sleep(3)"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024,
            onPumpWaitBegin: waitBegan.fulfill,
            onTermination: { taskWasCancelled in
                terminationProbe.record(taskWasCancelled: taskWasCancelled)
            }
        )
        let response = try await stream.start(url: URL(string: "https://example.test")!)
        await fulfillment(of: [waitBegan], timeout: 1)
        response.bytes.cancel()

        let released = await observeRelease(of: stream, lifecycleURL: lifecycleURL)
        XCTAssertTrue(released, "cancellation during the process read must complete lifecycle cleanup")
        XCTAssertEqual(terminationProbe.values, [true], "only the cancelled pump may terminate the process")
        await stream.shutdown()
    }

    func testCurlAcceptanceStreamCancellationBeforeSpawnStillReapsSupervisor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-curl-process-spawn-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycleURL = root.appendingPathComponent("stream-active")
        let headersURL = root.appendingPathComponent("headers")
        let stderrURL = root.appendingPathComponent("stderr")
        let requestURL = root.appendingPathComponent("request")
        XCTAssertTrue(FileManager.default.createFile(atPath: headersURL.path, contents: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        for path in [stderrURL, requestURL, lifecycleURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }

        var stream: CurlAcceptanceProcessStream!
        stream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import time; time.sleep(3)"],
            headersURL: headersURL,
            stderrURL: stderrURL,
            requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: root,
            maximumResponseBytes: 1024,
            onProcessSpawnBegin: { $0.cancel() }
        )

        let response = try await stream.start(url: URL(string: "https://example.test")!)
        response.bytes.cancel()
        let released = await observeRelease(of: stream, lifecycleURL: lifecycleURL)
        XCTAssertTrue(released, "spawn cancellation must release the lifecycle")
        await stream.shutdown()
        XCTAssertFalse(stream.isRunningForTesting, "spawn cancellation must reap the supervisor")
        XCTAssertTrue(stream.didReleaseForTesting, "spawn cancellation must release the lifecycle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleURL.path))
    }

    private func observeRelease(of stream: CurlAcceptanceProcessStream, lifecycleURL: URL) async -> Bool {
        for _ in 0..<200 {
            if stream.didReleaseForTesting && !FileManager.default.fileExists(atPath: lifecycleURL.path) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return stream.didReleaseForTesting && !FileManager.default.fileExists(atPath: lifecycleURL.path)
    }

    private func observeProcessExit(of stream: CurlAcceptanceProcessStream) async -> Bool {
        for _ in 0..<200 {
            if !stream.isRunningForTesting { return true }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return !stream.isRunningForTesting
    }

    func testAcceptanceRecordingSenderForwardsStrictSessionCapabilities() async throws {
        let base = CapabilityProbeSender()
        let diagnostics = AcceptanceDiagnosticRecorder()
        let wrapper = RecordingNodeSessionSender(base: base, classifier: AcceptanceResponseClassifier(), diagnostics: diagnostics)
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        try wrapper.setAuthorityEpoch("9", for: logical)
        let pending = try await wrapper.reconcilePendingRequest()
        _ = try await wrapper.send(method: "GET", path: "/v1/mailboxes/assignments", body: Data(), maximumResponseBytes: NodeTLSClient.maximumResponseBytes)

        XCTAssertEqual(pending?.statusCode, 204)
        XCTAssertEqual(base.epochValue, "9")
        XCTAssertEqual(base.logicalMailbox, logical)
        XCTAssertEqual(base.reconciliationCalls, 1)
        XCTAssertEqual(diagnostics.summary(), "pending-request-begin;pending-request-end-status=204;request-begin-class=assignments-method=GET;request-response-class=assignments-method=GET-status=204")
    }

    func testAcceptanceRecordingSenderForwardsRequestScopedCancellation() async throws {
        let base = ScopedCancellationProbeSender()
        let wrapper = RecordingNodeSessionSender(base: base, classifier: AcceptanceResponseClassifier())
        let scoped = try XCTUnwrap(wrapper as? any NodeSessionRequestScopedSending)
        let cancellation = NodeHTTPTransportRequestCancellation()
        let request = Task {
            try await scoped.send(
                method: "GET", path: "/v1/status", body: Data(),
                maximumResponseBytes: NodeTLSClient.maximumResponseBytes,
                cancellation: cancellation
            )
        }

        await base.waitUntilStarted()
        let receivedCancellation = await base.receivedCancellationIs(cancellation)
        XCTAssertTrue(receivedCancellation)
        await cancellation.cancelAndWait()

        do {
            _ = try await request.value
            XCTFail("the scoped request should be cancelled")
        } catch is CancellationError {
            // expected
        }
        let completed = await base.didComplete()
        XCTAssertTrue(completed)
    }

    func testAcceptanceDiagnosticsSummarizeBoundariesWithoutRequestIdentifiers() {
        let diagnostics = AcceptanceDiagnosticRecorder()
        diagnostics.pendingReconciliationBegin(kind: "mutation")
        diagnostics.pendingReconciliationEnd(kind: "mutation", outcome: .response(204))
        diagnostics.requestBegin(method: "PUT", path: "/v1/mailboxes/assignments")
        for _ in 0..<130 {
            diagnostics.requestResponse(method: "GET", path: "/v1/mailboxes/assignments", statusCode: 204)
        }
        diagnostics.pendingReconciliationBegin(kind: "request")
        diagnostics.pendingReconciliationEnd(kind: "request", outcome: .empty)
        diagnostics.requestBegin(method: "GET", path: "/v1/drafts/private-draft-id")
        diagnostics.requestError(method: "GET", path: "/v1/drafts/private-draft-id", error: NodeSyncClientError.problem(.unavailable))
        diagnostics.signingBegin()
        diagnostics.signingError(NodeSyncClientError.transport)
        diagnostics.surfaceError(PlainpostError.validationFailed("The Node is unavailable."))

        let summary = diagnostics.summary()
        XCTAssertFalse(summary.contains("pending-mutation"), "diagnostics should retain a bounded tail")
        XCTAssertEqual(diagnostics.assignmentMutationRequestCount, 1, "dedicated assignment mutation evidence must survive tail eviction")
        XCTAssertTrue(summary.contains("pending-request-begin;pending-request-end-outcome=empty"))
        XCTAssertTrue(summary.hasSuffix("request-begin-class=draft-state-method=GET;request-error-class=draft-state-method=GET-category=node-unavailable;signing-begin;signing-error-category=transport;surface-error-category=validation-failed"))
        XCTAssertFalse(summary.contains("private-draft-id"))
    }

    @MainActor
    func testPrimaryApplicationRejectionRecoveryReconcilesAfterDispatchThenUsesFreshSequence() async throws {
        let recovery = try makePrimaryRecoverySender(behavior: .sequenceConsumedThenMissing)
        var stages: [String] = []

        let response = try await recoverPrimaryApplicationRejection(
            sender: recovery.sender, retryDelay: .zero, stage: { stages.append($0) }
        )

        XCTAssertEqual(response.statusCode, 404)
        let callCount = await recovery.transport.callCount()
        let sequences = await recovery.transport.sequences()
        XCTAssertEqual(callCount, 3, "recovery must remain bounded")
        XCTAssertEqual(sequences, ["1", "1", "2"], "reconciliation replays the exact sequence before the fresh request")
        XCTAssertEqual(stages, [
            "primary-recovery-request-begin", "primary-recovery-transport-failure",
            "primary-recovery-reconcile-delay", "primary-recovery-reconcile-begin",
            "primary-recovery-application-uncertain", "primary-recovery-fresh-request",
            "primary-recovery-fresh-response"
        ])
    }

    @MainActor
    func testPrimaryApplicationRejectionRecoveryRethrowsAuthenticationRejectionWithoutRetry() async throws {
        let recovery = try makePrimaryRecoverySender(behavior: .authenticationRejected)

        do {
            _ = try await recoverPrimaryApplicationRejection(sender: recovery.sender, retryDelay: .zero)
            XCTFail("authentication rejection must not be recovered")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .authenticationRejected)
        }
        let callCount = await recovery.transport.callCount()
        XCTAssertEqual(callCount, 1, "authentication rejection must not retry")
    }

    @MainActor
    func testPrimaryApplicationRejectionRecoveryRethrowsTerminalTransportAfterBoundedExhaustion() async throws {
        let recovery = try makePrimaryRecoverySender(behavior: .alwaysTransportFailure)

        do {
            _ = try await recoverPrimaryApplicationRejection(
                sender: recovery.sender, retryDelay: .zero, maximumReconciliationAttempts: 2
            )
            XCTFail("transport exhaustion must not become an application response")
        } catch let error as NodeSessionError {
            XCTAssertEqual(error, .transportFailureAfterDispatch)
        }
        let callCount = await recovery.transport.callCount()
        XCTAssertEqual(callCount, 3, "exhaustion must stop at initial request plus configured reconciliations")
    }

    private func makePrimaryRecoverySender(
        behavior: PrimaryRecoveryTransportFixture.Behavior
    ) throws -> (sender: NodeSessionTransport, transport: PrimaryRecoveryTransportFixture) {
        let secrets = InMemoryAccountSecretStore()
        let store = try SyncNodeEndpointStore(secretStore: secrets, service: "test.primary-recovery-\(UUID().uuidString)")
        let account = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let node = try AccountDeviceID("22222222-2222-4222-8222-222222222222")
        let clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        let identity = try AccountDeviceIdentity(
            signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]),
            agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8])
        )
        let reference = try SyncNodeEndpointReference(
            accountID: account, nodeID: node, trustEpoch: try AccountTrustEpoch(wire: "1"),
            endpointCiphertext: Data(repeating: 1, count: 48)
        )
        try store.save(reference: reference, session: try SyncNodeStoredSession(
            resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]),
            trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]),
            cleanupCapabilityWire: Data([6]), nextSequence: 1
        ))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = PrimaryRecoveryTransportFixture(endpoint: endpoint.url, behavior: behavior)
        let sender = try NodeSessionTransport(
            reference: reference, clientID: clientID, endpoint: endpoint, store: store,
            identity: identity, client: NodeTLSClient(transport: transport)
        )
        return (sender, transport)
    }
}

@MainActor
private struct RealPrivateTransportScenario {
    private let environment: [String: String]
    private let controlRoot: URL
    private let artifacts: URL
    private let caFile: String
    private let centralConnect: String
    private let nodeOneConnect: String
    private let nodeTwoConnect: String
    private let errorSurfaceRoot: URL

    private struct SecondaryClientContext {
        let client: NodeSyncClient
        let sender: NodeSessionTransport
        let credentials: AccountSessionCredentials
        let identity: AccountDeviceIdentity
    }

    init(environment: [String: String]) throws {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw AccountRuntimeError.transportFailure }
            return value
        }
        self.environment = environment
        controlRoot = URL(fileURLWithPath: try required("PLAINPOST_SYNC_NODE_CONTROL_ROOT"), isDirectory: true)
        artifacts = URL(fileURLWithPath: try required("PLAINPOST_SYNC_NODE_ACCEPTANCE_ARTIFACT_ROOT"), isDirectory: true)
        caFile = try required("PLAINPOST_SYNC_NODE_ACCEPTANCE_CA_FILE")
        centralConnect = try required("PLAINPOST_SYNC_NODE_ACCEPTANCE_CENTRAL_RESOLVE")
        nodeOneConnect = try required("PLAINPOST_SYNC_NODE_ACCEPTANCE_NODE_ONE_RESOLVE")
        nodeTwoConnect = try required("PLAINPOST_SYNC_NODE_ACCEPTANCE_NODE_TWO_RESOLVE")
        errorSurfaceRoot = URL(fileURLWithPath: try required("PLAINPOST_SYNC_NODE_ERROR_SURFACE_ROOT"), isDirectory: true)
    }

    func run() async throws {
        let wire = CurlAcceptanceWire(caFile: caFile, connectRules: [centralConnect, nodeOneConnect, nodeTwoConnect], temporaryRoot: controlRoot, errorSurfaceRoot: errorSurfaceRoot)
        let firstBootstrap = try await fetchBootstrapPresentation(
            profilePath: try requiredPath("PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_ONE"),
            wire: wire
        )
        let firstPresentation = firstBootstrap.presentation
        try appendPrivacyPatterns([
            Data(firstPresentation.setupCode.utf8),
            firstPresentation.claimProofSignature,
            Data(firstPresentation.claimFingerprint.utf8)
        ])
        let accountResponseClassifier = AcceptanceAccountResponseClassifier()
        let accountTransport = CurlAccountHTTPTransport(wire: wire, classifier: accountResponseClassifier)
        let credentialsSecrets = InMemoryAccountSecretStore()
        let credentialsStore = AccountCredentialStore(secretStore: credentialsSecrets, service: "test.real-private.credentials")
        let bootstrap = try bootstrapManifestStore()
        let client = try AccountAPIClient(transport: accountTransport, credentialStore: credentialsStore, manifestStore: bootstrap, baseURL: AccountAPIClient.productionBaseURL)
        let owner = try AccountDeviceIdentity.generate()
        let bootstrapNonce = Data(SHA256.hash(data: Data("real-private-bootstrap".utf8)))
        let bootstrapIdentityToken = try acceptanceToken(nonce: bootstrapNonce)
        try appendPrivacyPatterns([bootstrapNonce, Data(bootstrapIdentityToken.utf8)])
        let activation = try await client.bootstrapAppleCredential(identityToken: bootstrapIdentityToken, nonce: bootstrapNonce, device: owner)
        let initialHead = try XCTUnwrap(activation.currentTrustCommit)
        let credentials = try XCTUnwrap(credentialsStore.loadSession()?.credentials)
        try appendPrivacyPatterns([
            Data(credentials.accessToken.utf8), credentials.refreshCredential,
            Data(credentials.offlineLease.utf8), Data(credentials.accountID.rawValue.utf8),
            Data(credentials.deviceID.rawValue.utf8)
        ])
        let trustSecrets = InMemoryAccountSecretStore()
        let trust = try AccountTrustCoordinator(accountID: activation.accountID, deviceID: activation.deviceID, platform: .macos, deviceIdentity: owner, trustStore: AccountTrustStore(secretStore: trustSecrets, service: "test.real-private.trust"), offlineRootKeyID: "plainpost-root-2026-01", offlineRootPublicKey: try accountRoot())
        try await trust.accept(initialHead)
        let endpointSecrets = InMemoryAccountSecretStore()
        let endpointStore = try SyncNodeEndpointStore(secretStore: endpointSecrets, service: "test.real-private.endpoint")
        let sessionManifest = try sessionManifestVerifier()

        let first = try await enroll(
            presentation: firstPresentation,
            profile: firstBootstrap.profile,
            activeNodeID: nil, client: client, credentials: credentials, owner: owner,
            trust: trust, endpointStore: endpointStore, sessionManifest: sessionManifest,
            nodeClient: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
        )
        try signal("node-one-activated")
        let firstHot = try await waitForHotActivation(
            nodeID: first.nodeID, epoch: first.epoch, client: client,
            credentials: credentials, owner: owner, trust: trust,
            endpointStore: endpointStore, wire: wire
        )
        try signal("node-one-hot-ready")
        try await waitForSignal("node-one-restarted")
        let firstPublished = firstHot.published
        let firstStored = firstHot.stored
        try appendPrivacyPatterns([
            Data(firstPublished.endpoint.absoluteString.utf8),
            firstStored.session.resultWire, firstStored.session.refreshWire,
            firstStored.session.leaseWire, firstStored.session.trustCommitWire,
            firstStored.session.admissionEvidenceWire, firstStored.session.cleanupCapabilityWire
        ])
        try appendPrivacyPatterns(trustSecrets.records.map { $0.value.value })
        var replacementArtifacts: (published: SyncNodePublishedEndpointV1, stored: (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession))?
        var replacementPresentation: SyncNodeEnrollmentPresentation?
        if environment["PLAINPOST_SYNC_NODE_CLIENT_API"] == "enabled" {
            let responseClassifier = AcceptanceResponseClassifier()
            let diagnostics = AcceptanceDiagnosticRecorder()
            let acceptanceSender = try SyncNodeSessionLocator.restore(
                published: firstPublished,
                credentials: credentials,
                device: owner,
                store: endpointStore,
                client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
            )
            let recordingSender = RecordingNodeSessionSender(base: acceptanceSender, classifier: responseClassifier, diagnostics: diagnostics)
            let primaryNodeClient = NodeSyncClient(sender: recordingSender)
            let attachmentFaultProbeClient = NodeSyncClient(sender: recordingSender, maximumAttempts: 1)
            guard let primaryAuthority = try PlainpostNodeMailAuthorityFactory.make(
                client: primaryNodeClient,
                accountID: AccountID(credentials.accountID.rawValue),
                access: .authorized
            ) as? PlainpostNodeMailAuthority else { throw AccountRuntimeError.untrustedResponse }
            let secondary = try await enrollSecondaryClient(
                accountClient: client, credentials: credentials, owner: owner, trust: trust,
                bootstrap: bootstrap, accountTransport: accountTransport, pendingEndpoint: firstStored,
                endpoint: firstPublished.endpoint, wire: wire
            )
            guard let secondaryAuthority = try PlainpostNodeMailAuthorityFactory.make(
                client: secondary.client,
                accountID: AccountID(credentials.accountID.rawValue),
                access: .authorized
            ) as? PlainpostNodeMailAuthority else { throw AccountRuntimeError.untrustedResponse }
            let authorityReplacement: NodeMailAuthorityLiveScenario.AuthorityReplacement = {
                stage("node-two-protected-presentation-begin")
                let secondBootstrap = try await fetchBootstrapPresentation(
                    profilePath: try requiredPath("PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_TWO"),
                    wire: wire
                )
                let secondPresentation = secondBootstrap.presentation
                stage("node-two-protected-presentation-end")
                replacementPresentation = secondPresentation
                try appendPrivacyPatterns([
                    Data(secondPresentation.setupCode.utf8),
                    secondPresentation.claimProofSignature,
                    Data(secondPresentation.claimFingerprint.utf8)
                ])
                stage("node-two-central-enroll-begin")
                await accountTransport.resetFailureSummary()
                let second: (nodeID: AccountDeviceID, epoch: AccountTrustEpoch)
                do {
                    second = try await enroll(
                        presentation: secondPresentation,
                        profile: secondBootstrap.profile,
                        activeNodeID: first.nodeID, client: client, credentials: credentials, owner: owner,
                        trust: trust, endpointStore: endpointStore, sessionManifest: sessionManifest,
                        nodeClient: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
                    )
                } catch {
                    stage("node-two-central-enroll-failure")
                    stageDetail("node-two-central-enroll-response", await accountTransport.failureSummary())
                    throw error
                }
                stage("node-two-central-enroll-end")
                stage("node-two-activation-signal")
                try signal("node-two-activated")
                let secondHot = try await waitForHotActivation(
                    nodeID: second.nodeID, epoch: second.epoch, client: client,
                    credentials: credentials, owner: owner, trust: trust,
                    endpointStore: endpointStore, wire: wire
                )
                try signal("node-two-hot-ready")
                stage("node-two-activation-wait-begin")
                try await waitForSignal("node-two-restarted", timeoutSeconds: acceptanceNodeTwoActivationWaitSeconds)
                stage("node-two-activation-wait-end")
                let secondPublished = secondHot.published
                let secondStored = secondHot.stored
                stage("node-two-replacement-client-begin")
                let secondSender = try NodeSessionTransport(reference: secondStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(secondPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
                let replacementClient = NodeSyncClient(sender: secondSender)
                guard let replacementAuthority = try PlainpostNodeMailAuthorityFactory.make(
                    client: replacementClient,
                    accountID: AccountID(credentials.accountID.rawValue),
                    access: .authorized
                ) as? PlainpostNodeMailAuthority else { throw AccountRuntimeError.untrustedResponse }
                replacementArtifacts = (published: secondPublished, stored: secondStored)
                stage("node-two-replacement-client-end")
                return .init(client: replacementClient, authority: replacementAuthority)
            }
            do {
                try await NodeMailAuthorityLiveScenario.run(authority: primaryAuthority, secondaryAuthority: secondaryAuthority, client: primaryNodeClient, secondaryClient: secondary.client, attachmentFaultProbeClient: attachmentFaultProbeClient, controlRoot: controlRoot, responseClassifier: responseClassifier, authorityReplacement: authorityReplacement)
                XCTAssertEqual(diagnostics.assignmentMutationRequestCount, 0, "generic acceptance must not issue Google assignment mutations")
            } catch {
                diagnostics.surfaceError(error)
                stageDetail("node-client-diagnostics", diagnostics.summary())
                throw error
            }
            let activePrimaryReference = replacementArtifacts?.stored.reference ?? firstStored.reference
            let activePrimaryEndpoint = replacementArtifacts?.published.endpoint ?? firstPublished.endpoint
            try await revokeSecondaryClient(secondary, owner: owner, trust: trust, client: client, credentials: credentials, bootstrap: bootstrap, primaryReference: activePrimaryReference, primaryEndpoint: activePrimaryEndpoint, endpointStore: endpointStore, wire: wire)
        }
        let acceptanceMailScenario = environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO"] ?? ""
        let usesIMAPNodeTwoLifecycle = NodeMailAuthorityLiveScenario.imapMatrixUsesNodeTwoLifecycleForTesting(selector: acceptanceMailScenario)
        if replacementArtifacts == nil && !usesIMAPNodeTwoLifecycle {
            let dropping = DropOneAcceptedResponseTransport(base: CurlNodeHTTPTransport(wire: wire))
            let firstSender = try NodeSessionTransport(reference: firstStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(firstPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: dropping))
            let lostBody = Data("real-lost-response".utf8)
            for _ in 0..<120 {
                do { _ = try await firstSender.send(method: "POST", path: "/v1/private", body: lostBody); XCTFail("accepted response was not dropped") }
                catch { if await dropping.didDropAcceptedResponse() { break }; try await Task.sleep(for: .milliseconds(250)) }
            }
            let droppedAcceptedResponse = await dropping.didDropAcceptedResponse()
            XCTAssertTrue(droppedAcceptedResponse, "real signed request never crossed the post-restore admission gate")
            let restartedFirst = try NodeSessionTransport(reference: firstStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(firstPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
            do { _ = try await restartedFirst.send(method: "POST", path: "/v1/private", body: lostBody); XCTFail("consumed result was presented as known") }
            catch let error as NodeSessionError { XCTAssertEqual(error, .applicationResultUncertain) }
            let application = try await restartedFirst.send(method: "POST", path: "/v1/application-rejection", body: Data())
            XCTAssertEqual(application.statusCode, 404)
            let currentStored = try endpointStore.loadReference(
                accountID: firstStored.reference.accountID,
                nodeID: firstStored.reference.nodeID,
                trustEpoch: firstStored.reference.trustEpoch
            )
            guard currentStored.session.nextSequence < UInt64.max else { throw AccountRuntimeError.corruptSecret }
            try await assertGapRejected(reference: firstStored.reference, endpoint: firstPublished.endpoint, clientID: credentials.deviceID, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)), sequence: currentStored.session.nextSequence + 1)

            try signal("authority-outage")
            try await waitForSignal("authority-unavailable")
            let recoveryBody = Data("real-authority-recovery".utf8)
            let outageSender = try NodeSessionTransport(reference: firstStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(firstPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire, failServiceUnavailable: true)))
            let outageResponse = try await outageSender.send(method: "POST", path: "/v1/private", body: recoveryBody)
            XCTAssertEqual(outageResponse.statusCode, 404, "an existing offline lease remains usable while Central is unavailable")
            try signal("authority-recover")
            try await waitForSignal("authority-restored")
            let recoveredSender = try NodeSessionTransport(reference: firstStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(firstPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
            let recovered = try await recoveredSender.send(method: "POST", path: "/v1/private", body: recoveryBody)
            XCTAssertEqual(recovered.statusCode, 404)
        }

        let secondPresentation: SyncNodeEnrollmentPresentation
        let secondPublished: SyncNodePublishedEndpointV1
        let secondStored: (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession)
        if let replacementArtifacts, let replacementPresentation {
            secondPresentation = replacementPresentation
            secondPublished = replacementArtifacts.published
            secondStored = replacementArtifacts.stored
        } else {
            stage("node-two-protected-presentation-begin")
            let secondBootstrap = try await fetchBootstrapPresentation(
                profilePath: try requiredPath("PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_TWO"),
                wire: wire
            )
            secondPresentation = secondBootstrap.presentation
            stage("node-two-protected-presentation-end")
            try appendPrivacyPatterns([
                Data(secondPresentation.setupCode.utf8),
                secondPresentation.claimProofSignature,
                Data(secondPresentation.claimFingerprint.utf8)
            ])
            let second = try await enroll(
                presentation: secondPresentation,
                profile: secondBootstrap.profile,
                activeNodeID: first.nodeID, client: client, credentials: credentials, owner: owner,
                trust: trust, endpointStore: endpointStore, sessionManifest: sessionManifest,
                nodeClient: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
            )
            try signal("node-two-activated")
            let secondHot = try await waitForHotActivation(
                nodeID: second.nodeID, epoch: second.epoch, client: client,
                credentials: credentials, owner: owner, trust: trust,
                endpointStore: endpointStore, wire: wire
            )
            try signal("node-two-hot-ready")
            try await waitForSignal("node-two-restarted", timeoutSeconds: acceptanceNodeTwoActivationWaitSeconds)
            secondPublished = secondHot.published
            secondStored = secondHot.stored
        }
        if replacementArtifacts == nil {
            let oldNode = try NodeSessionTransport(reference: firstStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(firstPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
            do { _ = try await oldNode.send(method: "POST", path: "/v1/private", body: Data("fenced-old-node".utf8)); XCTFail("replaced Node remained authorized") }
            catch let error as NodeSessionError { XCTAssertEqual(error, .authenticationRejected) }
        }
        let secondSender = try NodeSessionTransport(reference: secondStored.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(secondPublished.endpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
        let replacementResponse = try await secondSender.send(method: "POST", path: "/v1/private", body: Data("replacement-authorized".utf8))
        XCTAssertEqual(replacementResponse.statusCode, 404)

        let lifecycle = try AccountLifecycleController(remote: client, credentialStore: credentialsStore, device: owner, platform: .macos, credentials: credentials, coordinator: trust, recoveryCoordinatorFactory: { _, _, _, _ in trust }, manifestStore: bootstrap, authenticate: { _ in true }, purgeManagedData: { accountID in Data(SHA256.hash(data: Data(("purged:" + accountID.rawValue).utf8))) })
        let deletionNonce = Data(SHA256.hash(data: Data("real-private-deletion".utf8)))
        let deletionIdentityToken = try acceptanceToken(nonce: deletionNonce)
        try appendPrivacyPatterns([deletionNonce, Data(deletionIdentityToken.utf8)])
        _ = try await lifecycle.deleteAccount(identityToken: deletionIdentityToken, appleNonce: deletionNonce)
        try signal("account-deleted")
        try await waitForSignal("node-two-deletion-restarted", timeoutSeconds: acceptanceNodeTwoDeletionWaitSeconds)
        let readiness = try await NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)).send(NodeHTTPRequest(endpoint: try NodeEndpointURL(secondPublished.endpoint.absoluteString), method: "GET", path: "/readyz", body: Data()))
        XCTAssertEqual(readiness.statusCode, 503, "deleted Node must remain fail-closed while purge is unavailable")
        let trustMaterialRecords = trustSecrets.records
            .filter { $0.key.account.contains("trust-material.v3.") }
            .map { $0.value.value }
        try appendPrivacyPatterns([
            Data(secondPresentation.setupCode.utf8), secondPresentation.claimProofSignature,
            Data(secondPresentation.claimFingerprint.utf8),
            Data(firstPublished.endpoint.absoluteString.utf8), Data(secondPublished.endpoint.absoluteString.utf8),
            firstStored.session.resultWire, firstStored.session.refreshWire, firstStored.session.leaseWire,
            secondStored.session.resultWire, secondStored.session.refreshWire, secondStored.session.leaseWire
        ] + trustMaterialRecords)
        try writeReturnedDatabasePrivacyPatterns(sessions: [firstStored.session, secondStored.session])
    }

    private func enrollSecondaryClient(
        accountClient: AccountAPIClient,
        credentials: AccountSessionCredentials,
        owner: AccountDeviceIdentity,
        trust: AccountTrustCoordinator,
        bootstrap: BootstrapKeyManifestStore,
        accountTransport: CurlAccountHTTPTransport,
        pendingEndpoint: (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession),
        endpoint: URL,
        wire: CurlAcceptanceWire
    ) async throws -> SecondaryClientContext {
        let secondaryIdentity = try AccountDeviceIdentity.generate()
        let secondarySecrets = InMemoryAccountSecretStore()
        let secondaryCredentialsStore = AccountCredentialStore(secretStore: secondarySecrets, service: "test.real-private.secondary-credentials")
        let secondaryBootstrap = try bootstrapManifestStore()
        let secondaryAccountClient = try AccountAPIClient(transport: accountTransport, credentialStore: secondaryCredentialsStore, manifestStore: secondaryBootstrap, baseURL: AccountAPIClient.productionBaseURL)
        let bootstrapNonce = Data(SHA256.hash(data: Data("real-private-secondary-bootstrap".utf8)))
        let bootstrapIdentityToken = try acceptanceToken(nonce: bootstrapNonce)
        try appendPrivacyPatterns([bootstrapNonce, Data(bootstrapIdentityToken.utf8)])
        stage("secondary-bootstrap-begin")
        let activation = try await secondaryAccountClient.bootstrapAppleCredential(identityToken: bootstrapIdentityToken, nonce: bootstrapNonce, device: secondaryIdentity)
        stage("secondary-bootstrap-end")
        guard activation.mode == .pending,
              activation.accountID == credentials.accountID,
              let secondaryCredentials = try secondaryCredentialsStore.loadSession()?.credentials
        else { throw AccountRuntimeError.untrustedResponse }

        let ownerRendezvous = CentralAccountAdmissionRendezvous(client: accountClient, credentials: credentials, identity: owner)
        let pending = try await waitForPendingDevice(ownerRendezvous, deviceID: activation.deviceID)
        stage("secondary-offer-begin")
        stage("secondary-offer-local-begin")
        let offer: TrustHandshakeOfferV1
        do {
            offer = try await trust.beginApproval(of: pending)
        } catch {
            stage("secondary-offer-local-error")
            throw error
        }
        stage("secondary-offer-local-end")
        stage("secondary-offer-submit-begin")
        await accountTransport.resetFailureSummary()
        let offered: AccountTrustAdmissionOfferEnvelopeV1
        do {
            offered = try await ownerRendezvous.submitOffer(offer, for: pending.deviceID)
        } catch {
            stage("secondary-offer-submit-error")
            stageDetail("secondary-offer-submit-response", await accountTransport.failureSummary())
            throw error
        }
        stage("secondary-offer-submit-end")
        stage("secondary-offer-end")
        let pendingRendezvous = CentralAccountAdmissionRendezvous(client: secondaryAccountClient, credentials: secondaryCredentials, identity: secondaryIdentity)
        let received = try await pendingRendezvous.fetchOffer(for: pending.deviceID)
        guard received == offered, received.offer == offer else { throw AccountRuntimeError.untrustedResponse }
        let pendingNonce = Data(SHA256.hash(data: Data("real-private-secondary-handshake".utf8)))
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: pendingNonce)
        let responseEnvelope = try AccountTrustAdmissionResponseEnvelopeV1(offerDigest: offered.offerDigest, response: response)
        stage("secondary-response-begin")
        try await pendingRendezvous.submitResponse(responseEnvelope, for: pending.deviceID)
        _ = try await trust.authenticationString(for: response)
        stage("secondary-response-end")
        guard let head = try await trust.currentTrustCommit() else { throw AccountRuntimeError.untrustedResponse }
        let stepUpNonce = Data(SHA256.hash(data: Data("real-private-secondary-admission".utf8)))
        let stepUpIdentityToken = try acceptanceToken(nonce: stepUpNonce)
        try appendPrivacyPatterns([stepUpNonce, Data(stepUpIdentityToken.utf8)])
        stage("secondary-stepup-begin")
        let authorization = try await accountClient.issueStepUp(
            action: .addDevice,
            targetDeviceID: activation.deviceID,
            currentCommitDigest: AccountTranscript.trustCommitDigest(head),
            identityToken: stepUpIdentityToken,
            appleNonce: stepUpNonce,
            credentials: credentials,
            device: owner
        )
        stage("secondary-stepup-end")
        stage("secondary-candidate-begin")
        let candidate = try await trust.makeAdmissionCandidate(response, authenticationConfirmed: true)
        stage("secondary-candidate-end")
        stage("secondary-submit-begin")
        await accountTransport.resetFailureSummary()
        let accepted: AccountTrustHistoryEntryV1
        do {
            accepted = try await accountClient.submitLifecycle(authorization: authorization, candidate: candidate, credentials: credentials, device: owner)
        } catch {
            stage("secondary-submit-failure")
            stageDetail("secondary-submit-response", await accountTransport.failureSummary())
            throw error
        }
        stage("secondary-submit-end")
        guard accepted == candidate else { throw AccountRuntimeError.untrustedResponse }
        stage("secondary-accept-begin")
        try await trust.acceptHistory([accepted])
        stage("secondary-accept-end")

        let secondaryEndpointStore = try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore(), service: "test.real-private.secondary-endpoint")
        let secondarySession = try SyncNodeStoredSession(
            resultWire: pendingEndpoint.session.resultWire,
            refreshWire: pendingEndpoint.session.refreshWire,
            leaseWire: pendingEndpoint.session.leaseWire,
            trustCommitWire: pendingEndpoint.session.trustCommitWire,
            admissionEvidenceWire: pendingEndpoint.session.admissionEvidenceWire,
            cleanupCapabilityWire: pendingEndpoint.session.cleanupCapabilityWire,
            nextSequence: 1
        )
        try appendPrivacyPatterns([
            secondarySession.resultWire, secondarySession.refreshWire, secondarySession.leaseWire,
            secondarySession.trustCommitWire, secondarySession.admissionEvidenceWire,
            secondarySession.cleanupCapabilityWire,
            Data(secondaryCredentials.accessToken.utf8), secondaryCredentials.refreshCredential,
            Data(secondaryCredentials.offlineLease.utf8), Data(secondaryCredentials.accountID.rawValue.utf8),
            Data(secondaryCredentials.deviceID.rawValue.utf8)
        ])
        try secondaryEndpointStore.save(reference: pendingEndpoint.reference, session: secondarySession)
        let secondarySender = try NodeSessionTransport(
            reference: pendingEndpoint.reference,
            clientID: activation.deviceID,
            endpoint: try NodeEndpointURL(endpoint.absoluteString),
            store: secondaryEndpointStore,
            identity: secondaryIdentity,
            client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
        )
        return SecondaryClientContext(client: NodeSyncClient(sender: secondarySender), sender: secondarySender, credentials: secondaryCredentials, identity: secondaryIdentity)
    }

    private func stage(_ name: String) {
        let line = Data("ERROR swift-stage stage=\(name)\n".utf8)
        if let path = environment["PLAINPOST_SYNC_NODE_STAGE_LOG"], !path.isEmpty {
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
            }
        }
        FileHandle.standardError.write(line)
    }

    private func stageDetail(_ label: String, _ value: String) {
        let line = Data("ERROR swift-stage \(label) \(value)\n".utf8)
        if let path = environment["PLAINPOST_SYNC_NODE_STAGE_LOG"], !path.isEmpty,
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
        }
        FileHandle.standardError.write(line)
    }

    private func waitForPendingDevice(_ rendezvous: CentralAccountAdmissionRendezvous, deviceID: AccountDeviceID) async throws -> AccountPendingDevice {
        for _ in 0..<120 {
            if let pending = try await rendezvous.listPending().first(where: { $0.deviceID == deviceID }) { return pending }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AccountRuntimeError.transportFailure
    }

    private func revokeSecondaryClient(
        _ secondary: SecondaryClientContext,
        owner: AccountDeviceIdentity,
        trust: AccountTrustCoordinator,
        client: AccountAPIClient,
        credentials: AccountSessionCredentials,
        bootstrap: BootstrapKeyManifestStore,
        primaryReference: SyncNodeEndpointReference,
        primaryEndpoint: URL,
        endpointStore: SyncNodeEndpointStore,
        wire: CurlAcceptanceWire
    ) async throws {
        let lifecycle = try AccountLifecycleController(remote: client, credentialStore: AccountCredentialStore(secretStore: InMemoryAccountSecretStore(), service: "test.real-private.secondary-revocation"), device: owner, platform: .macos, credentials: credentials, coordinator: trust, recoveryCoordinatorFactory: { _, _, _, _ in trust }, manifestStore: bootstrap, authenticate: { _ in true })
        let nonce = Data(SHA256.hash(data: Data("real-private-secondary-revocation".utf8)))
        let identityToken = try acceptanceToken(nonce: nonce)
        try appendPrivacyPatterns([nonce, Data(identityToken.utf8)])
        stage("central-revoke-begin")
        _ = try await lifecycle.revokeDevice(secondary.credentials.deviceID, identityToken: identityToken, appleNonce: nonce)
        stage("central-revoke-end")
        stage("secondary-rejection-begin")
        do {
            _ = try await secondary.sender.send(method: "POST", path: "/v1/application-rejection", body: Data(), maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
            stage("secondary-rejection-unexpected-success")
            XCTFail("revoked secondary client remained authorized")
        } catch let error as NodeSessionError {
            stage(error == .authenticationRejected ? "secondary-rejection-authentication-rejected" : "secondary-rejection-unexpected-error")
            XCTAssertEqual(error, .authenticationRejected)
        }
        stage("secondary-rejection-end")
        let primarySender = try NodeSessionTransport(reference: primaryReference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(primaryEndpoint.absoluteString), store: endpointStore, identity: owner, client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire)))
        stage("primary-recovery-begin")
        let primaryResponse = try await recoverPrimaryApplicationRejection(sender: primarySender, stage: stage)
        XCTAssertEqual(primaryResponse.statusCode, 404, "revoking the secondary client must not fence the primary")
        stage("primary-recovery-end")
    }

    private func fetchBootstrapPresentation(profilePath: String, wire: CurlAcceptanceWire) async throws -> (profile: SyncNodeBootstrapProfile, presentation: SyncNodeEnrollmentPresentation) {
        var document = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        defer { document.resetBytes(in: document.startIndex ..< document.endIndex) }
        guard document.count <= SyncNodeBootstrapProfile.maximumDocumentBytes else {
            throw AccountRuntimeError.untrustedResponse
        }
        let profile = try SyncNodeBootstrapProfile.decode(document)
        try appendPrivacyPatterns([
            profile.capabilityID, profile.capability, profile.signingKeyDigest,
            Data(profile.canonicalOrigin.url.absoluteString.utf8)
        ])
        let client = SyncNodeEnrollmentPresentationClient(
            client: NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
        )
        return (profile, try await NodeTransportSyncNodeEnrollmentPresenter(client: client).fetchPresentation(for: profile))
    }

    private func waitForHotActivation(
        nodeID: AccountDeviceID,
        epoch: AccountTrustEpoch,
        client: AccountAPIClient,
        credentials: AccountSessionCredentials,
        owner: AccountDeviceIdentity,
        trust: AccountTrustCoordinator,
        endpointStore: SyncNodeEndpointStore,
        wire: CurlAcceptanceWire
    ) async throws -> (
        published: SyncNodePublishedEndpointV1,
        stored: (reference: SyncNodeEndpointReference, session: SyncNodeStoredSession)
    ) {
        stage("hot-activation-discovery-begin")
        let discovered = try await SyncNodeEndpointMetadata.discover(
            remote: client, trust: trust, accountID: credentials.accountID,
            credentials: credentials, device: owner
        )
        let published = try XCTUnwrap(discovered)
        XCTAssertEqual(published.nodeID, nodeID)
        var stored = try endpointStore.loadReference(
            accountID: credentials.accountID, nodeID: nodeID, trustEpoch: epoch
        )
        stage("hot-activation-discovery-end")

        let endpoint = try NodeEndpointURL(published.endpoint.absoluteString)
        let tlsClient = NodeTLSClient(transport: CurlNodeHTTPTransport(wire: wire))
        stage("hot-activation-ready-begin")
        var ready = false
        for attempt in 1 ... 480 {
            do {
                let response = try await tlsClient.send(
                    NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/readyz", body: Data())
                )
                if response.statusCode == 200 {
                    ready = true
                    break
                }
                guard response.statusCode == 503 else { throw AccountRuntimeError.untrustedResponse }
            } catch let error as NodeSessionError {
                guard error == .transportFailure, attempt < 480 else { throw error }
                // The listener and asynchronously started runtime may not yet
                // be observable. Retry only this connection/readiness gate.
            } catch let error as AccountRuntimeError {
                guard error == .transportFailure, attempt < 480 else { throw error }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard ready else { throw AccountRuntimeError.transportFailure }
        stage("hot-activation-ready-end")

        let sender = try NodeSessionTransport(
            reference: stored.reference, clientID: credentials.deviceID,
            endpoint: endpoint, store: endpointStore, identity: owner,
            client: tlsClient
        )
        stage("hot-activation-signed-status-begin")
        _ = try await NodeSyncClient(sender: sender).status()
        stage("hot-activation-signed-status-end")
        stored = try endpointStore.loadReference(
            accountID: credentials.accountID, nodeID: nodeID, trustEpoch: epoch
        )
        return (published, stored)
    }

    private func enroll(presentation: SyncNodeEnrollmentPresentation, profile: SyncNodeBootstrapProfile, activeNodeID: AccountDeviceID?, client: AccountAPIClient, credentials: AccountSessionCredentials, owner: AccountDeviceIdentity, trust: AccountTrustCoordinator, endpointStore: SyncNodeEndpointStore, sessionManifest: SessionKeyManifestVerifier, nodeClient: NodeTLSClient) async throws -> (nodeID: AccountDeviceID, epoch: AccountTrustEpoch) {
        // The audience comes only from the provisioned profile. It must be a
        // deployment label, not the Central host this client connects to.
        guard let centralAudience = profile.centralAudience,
              centralAudience != AccountAPIClient.productionBaseURL.host
        else { throw AccountRuntimeError.untrustedResponse }
        let expectedOrigin = profile.canonicalOrigin
        guard let current = try await trust.currentTrustCommit(), current.state.accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        let activator = try PrivateSyncNodeEnrollmentActivator(remote: client, trust: trust, store: endpointStore, client: nodeClient, credentials: credentials, credentialsProvider: { [credentials] in credentials }, device: owner)
        let coordinator = SyncNodeEnrollmentCoordinator(remote: client, localAuthenticator: PassingSyncNodeAuthenticator(), responseVerifier: ManifestBackedSyncNodeEnrollmentResponseVerifier(manifest: sessionManifest), trust: trust, activation: activator, credentials: credentials, credentialsProvider: { [credentials] in credentials }, device: owner, activeNodeID: activeNodeID)
        if let activeNodeID { coordinator.selectReplacement(of: activeNodeID); coordinator.confirmReplacement(of: activeNodeID) }
        let nonce = Data(SHA256.hash(data: Data(("real-private-step-up:" + presentation.claimFingerprint).utf8)))
        let identityToken = try acceptanceToken(nonce: nonce)
        try appendPrivacyPatterns([nonce, Data(identityToken.utf8)])
        await coordinator.begin(setupCode: presentation.setupCode, proof: try SyncNodeEnrollmentNodeProof(claimProofSignature: presentation.claimProofSignature), expectedOrigin: expectedOrigin, centralAudience: centralAudience, appleAuthorization: try SyncNodeEnrollmentAppleAuthorization(identityToken: identityToken, nonce: nonce))
        guard case .matchingStringConfirmation(let matching) = coordinator.state else { throw AccountRuntimeError.untrustedResponse }
        await coordinator.confirmMatchingString(matching)
        for _ in 0..<3 {
            if coordinator.state == .activationResponseUncertain { await coordinator.retryActivation(); continue }
            if coordinator.state == .commitResponseUncertain { await coordinator.retryCommit(); continue }
            break
        }
        guard case .installed = coordinator.state, let response = coordinator.lastResponse else {
            throw AccountRuntimeError.untrustedResponse
        }
        return (response.result.binding.nodeDeviceID, response.result.binding.trustEpoch)
    }

    private func assertGapRejected(reference: SyncNodeEndpointReference, endpoint: URL, clientID: AccountDeviceID, identity: AccountDeviceIdentity, client: NodeTLSClient, sequence: UInt64) async throws {
        let body = Data("real-gap".utf8), timestamp = Self.timestamp(Date())
        let audience = "\(endpoint.host!):\(endpoint.port!)", epoch = UInt64(reference.trustEpoch.wireValue)!
        let unsigned = try SignedRequestV1(accountID: reference.accountID.rawValue, clientID: clientID.rawValue, nodeID: reference.nodeID.rawValue, trustEpoch: epoch, audience: audience, sequence: sequence, method: "POST", path: "/v1/private", bodySHA256: Data(SHA256.hash(data: body)), issuedAt: timestamp, signature: Data(repeating: 0, count: 64))
        let signed = try SignedRequestV1(accountID: unsigned.accountID, clientID: unsigned.clientID, nodeID: unsigned.nodeID, trustEpoch: unsigned.trustEpoch, audience: unsigned.audience, sequence: unsigned.sequence, method: unsigned.method, path: unsigned.path, bodySHA256: unsigned.bodySHA256, issuedAt: unsigned.issuedAt, signature: identity.signature(for: try NodeSessionTranscript.request(unsigned)))
        let fields: [String: String] = ["kind":"node.signed-request.v1","accountID":signed.accountID,"clientID":signed.clientID,"nodeID":signed.nodeID,"trustEpoch":String(signed.trustEpoch),"audience":signed.audience,"sequence":String(signed.sequence),"method":signed.method,"path":signed.path,"bodySHA256":NodeSessionWire.encodeBase64URL(signed.bodySHA256),"issuedAt":signed.issuedAt,"signature":NodeSessionWire.encodeBase64URL(signed.signature)]
        let header = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let response = try await client.send(NodeHTTPRequest(endpoint: try NodeEndpointURL(endpoint.absoluteString), method: "POST", path: "/v1/private", body: body, additionalHeaders: ["Plainpost-Signed-Request": header]))
        XCTAssertEqual(response.statusCode, 409)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["type"] as? String, "urn:plainpost:node-sequence-rejected")
    }

    private func bootstrapManifestStore() throws -> BootstrapKeyManifestStore {
        let response = try JSONSerialization.jsonObject(with: Data(contentsOf: artifacts.appendingPathComponent("account-manifest.json"))) as! [String: Any]
        let manifest = try JSONSerialization.data(withJSONObject: response["current"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        return try BootstrapKeyManifestStore(bundledManifest: manifest, offlineRootKeyID: "plainpost-root-2026-01", offlineRootPublicKey: try accountRoot(), secretStore: InMemoryAccountSecretStore())
    }
    private func sessionManifestVerifier() throws -> SessionKeyManifestVerifier { try SessionKeyManifestVerifier(document: Data(contentsOf: artifacts.appendingPathComponent("session-manifest.json")), offlineRootKeyID: "session-root-test-1", offlineRootPublicKey: try decodedTextFile("session-root-public.txt")) }
    private func accountRoot() throws -> Data { try decodedTextFile("account-root-public.txt") }
    private func decodedTextFile(_ name: String) throws -> Data { try AccountWireCodec.decodeBase64URL(String(decoding: Data(contentsOf: artifacts.appendingPathComponent(name)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), exactBytes: 65) }
    private func acceptanceToken(nonce: Data) throws -> String {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        let payload = try JSONSerialization.data(withJSONObject: ["audience":"acceptance.plainpost.macos","expiresAt":expires,"nonce":AccountWireCodec.encodeBase64URL(nonce),"subject":"sync-node-real-private"], options: [.sortedKeys, .withoutEscapingSlashes])
        let encoded = AccountWireCodec.encodeBase64URL(payload), signed = Data("plainpost-acceptance-v1.\(encoded)".utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data("plainpost-acceptance-identity-pepper-2026".utf8))))
        return "plainpost-acceptance-v1.\(encoded).\(AccountWireCodec.encodeBase64URL(signature))"
    }
    private func requiredPath(_ name: String) throws -> String { guard let value = environment[name], !value.isEmpty else { throw AccountRuntimeError.transportFailure }; return value }
    private func signal(_ name: String) throws { guard FileManager.default.createFile(atPath: controlRoot.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions:0o600]) else { throw AccountRuntimeError.transportFailure } }
    private func waitForSignal(_ name: String, timeoutSeconds: Int = 60) async throws {
        for _ in 0..<(timeoutSeconds * 4) {
            if FileManager.default.fileExists(atPath: controlRoot.appendingPathComponent(name).path) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AccountRuntimeError.transportFailure
    }
    private func appendPrivacyPatterns(_ values: [Data]) throws {
        guard let path = environment["PLAINPOST_SYNC_NODE_RETURNED_PRIVACY_PATTERNS"], !path.isEmpty else { throw AccountRuntimeError.transportFailure }
        var lines = Set<String>()
        for value in values where value.count >= 12 {
            lines.insert(value.base64EncodedString())
            lines.insert(value.map { String(format: "%02x", $0) }.joined())
            if let raw = String(data: value, encoding: .utf8), !raw.contains("\n"), !raw.contains("\r") { lines.insert(raw) }
        }
        let output = Data((lines.sorted().joined(separator: "\n") + "\n").utf8)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw AccountRuntimeError.transportFailure }
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: output)
    }
    private func writeReturnedDatabasePrivacyPatterns(sessions: [SyncNodeStoredSession]) throws {
        guard let path = environment["PLAINPOST_SYNC_NODE_RETURNED_DATABASE_PRIVACY_PATTERNS"], !path.isEmpty else { throw AccountRuntimeError.transportFailure }
        var lines: [String] = []
        for session in sessions {
            let refresh = try AccountWireCodec.decodeNodeRefreshCredentialV2(session.refreshWire)
            let lease = try AccountWireCodec.decodeNodeOfflineLeaseV2(session.leaseWire)
            lines.append("refresh-credential-base64url\t\(AccountWireCodec.encodeBase64URL(refresh.credential))")
            lines.append("credential-id\t\(refresh.credentialID)")
            lines.append("lease-id\t\(lease.leaseID)")
        }
        let document = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: path, contents: document, attributes: [.posixPermissions: 0o600]) else { throw AccountRuntimeError.transportFailure }
    }
    private static func timestamp(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return formatter.string(from: date) }
}

private actor AcceptanceAccountResponseClassifier {
    private var lastResponse: String?

    func reset() { lastResponse = nil }

    func response(_ response: CurlAcceptanceWire.Response, path: String) {
        if (200..<300).contains(response.status) {
            lastResponse = nil
            return
        }
        let contentType = response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased() ?? "none"
        let bodyClass: String
        if contentType.hasPrefix("application/problem+json") {
            bodyClass = "problem-json"
        } else if contentType.hasPrefix("application/json") {
            bodyClass = "json"
        } else if response.body.isEmpty {
            bodyClass = "empty"
        } else {
            bodyClass = "other"
        }
        lastResponse = "class=\(Self.pathClass(path))-status=\(response.status)-body=\(bodyClass)"
    }

    func summary() -> String { lastResponse ?? "class=none-status=none-body=none" }

    private static func pathClass(_ path: String) -> String {
        switch path {
        case "/v1/account/bootstrap/apple/begin": return "bootstrap-begin"
        case "/v1/account/bootstrap/apple/finalize": return "bootstrap-finalize"
        case "/v1/devices/pending": return "pending-devices"
        default:
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 5,
                  components[0] == "v1",
                  components[1] == "trust",
                  components[2] == "admissions"
            else { return "other" }
            switch components[4] {
            case "offer": return "admission-offer"
            case "response": return "admission-response"
            case "cancel": return "admission-cancel"
            default: break
            }
            return "other"
        }
    }
}

private struct PassingSyncNodeAuthenticator: SyncNodeEnrollmentLocalAuthenticating { func authenticateSyncNodeEnrollment() async throws {} }

actor AcceptanceResponseClassifier {
    private var statuses: [Int: Int] = [:]
    private var bodyClasses: [String: Int] = [:]
    private var transportFailures = 0

    func response(_ response: NodeHTTPResponse) {
        statuses[response.statusCode, default: 0] += 1
        guard response.statusCode >= 400 else { return }
        let bodyClass: String
        if let problem = try? NodeSyncCodec.decodeProblem(response.body) {
            bodyClass = "node-sync-\(problem.category)"
        } else if response.body == Data("{\"status\":503,\"type\":\"about:blank\"}\n".utf8) {
            bodyClass = "http-about-blank"
        } else {
            bodyClass = "other"
        }
        bodyClasses[bodyClass, default: 0] += 1
    }
    func streamResponse(statusCode: Int) {
        statuses[statusCode, default: 0] += 1
        if statusCode >= 400 { bodyClasses["stream-response", default: 0] += 1 }
    }
    func transportFailure() { transportFailures += 1 }
    func summary() -> String {
        let statusSummary = statuses.keys.sorted().map { "status\($0)=\(statuses[$0] ?? 0)" }.joined(separator: "-")
        let bodySummary = bodyClasses.keys.sorted().map { "body-\($0)=\(bodyClasses[$0] ?? 0)" }.joined(separator: "-")
        return "\(statusSummary.isEmpty ? "status-none" : statusSummary)-\(bodySummary.isEmpty ? "body-none" : bodySummary)-transport=\(transportFailures)"
    }
}

private final class AcceptanceDiagnosticRecorder: @unchecked Sendable {
    enum ReconciliationOutcome {
        case empty
        case response(Int)
        case error(Error)
    }

    private let lock = NSLock()
    private var events: [String] = []
    private var assignmentMutationRequests = 0
    private static let maximumEvents = 128

    var assignmentMutationRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return assignmentMutationRequests
    }

    func pendingReconciliationBegin(kind: String) {
        guard Self.validKind(kind) else { return }
        append("pending-\(kind)-begin")
    }

    func pendingReconciliationEnd(kind: String, outcome: ReconciliationOutcome) {
        guard Self.validKind(kind) else { return }
        switch outcome {
        case .empty:
            append("pending-\(kind)-end-outcome=empty")
        case let .response(statusCode):
            append("pending-\(kind)-end-status=\(statusCode)")
        case let .error(error):
            append("pending-\(kind)-error-category=\(Self.errorCategory(error))")
        }
    }

    func requestBegin(method: String, path: String) {
        if Self.isAssignmentMutation(method: method, path: path) {
            lock.lock(); assignmentMutationRequests += 1; lock.unlock()
        }
        guard let pathClass = Self.pathClass(path) else { return }
        append("request-begin-class=\(pathClass)-method=\(Self.method(method))")
    }

    func requestResponse(method: String, path: String, statusCode: Int) {
        guard let pathClass = Self.pathClass(path) else { return }
        append("request-response-class=\(pathClass)-method=\(Self.method(method))-status=\(statusCode)")
    }

    func requestError(method: String, path: String, error: Error) {
        guard let pathClass = Self.pathClass(path) else { return }
        append("request-error-class=\(pathClass)-method=\(Self.method(method))-category=\(Self.errorCategory(error))")
    }

    func signingBegin() { append("signing-begin") }
    func signingEnd() { append("signing-end") }
    func signingError(_ error: Error) { append("signing-error-category=\(Self.errorCategory(error))") }
    func surfaceError(_ error: Error) { append("surface-error-category=\(Self.errorCategory(error))") }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return events.joined(separator: ";")
    }

    private func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        if events.count >= Self.maximumEvents { events.removeFirst() }
        events.append(event)
    }

    private static func validKind(_ kind: String) -> Bool {
        ["request", "mutation"].contains(kind)
    }

    private static func pathClass(_ path: String) -> String? {
        switch path {
        case "/v1/mailboxes/assignments": return "assignments"
        case "/v1/mutations": return "mutation"
        default: return path.hasPrefix("/v1/drafts/") ? "draft-state" : nil
        }
    }

    private static func isAssignmentMutation(method: String, path: String) -> Bool {
        path == "/v1/mailboxes/assignments" && method.uppercased() == "PUT"
    }

    private static func method(_ method: String) -> String {
        let value = method.uppercased()
        return value.isEmpty || value.count > 8 || value.contains(where: { !$0.isASCII || !( $0.isLetter || $0.isNumber || $0 == "-" ) }) ? "other" : value
    }

    private static func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? PlainpostError {
            switch error {
            case .permissionDenied: return "permission-denied"
            case .validationFailed: return "validation-failed"
            case .notFound: return "not-found"
            }
        }
        if let error = error as? NodeSyncClientError {
            switch error {
            case .cancelled: return "cancelled"
            case .conflict: return "conflict"
            case .invalidResponse: return "invalid-response"
            case .notFound: return "not-found"
            case .problem(.invalidRequest): return "node-invalid-request"
            case .problem(.staleCursor): return "node-stale-cursor"
            case .problem(.unauthorized): return "node-unauthorized"
            case .problem(.unavailable): return "node-unavailable"
            case .problem(.conflict): return "node-conflict"
            case .transport: return "transport"
            case .transportAfterDispatch: return "transport-after-dispatch"
            case .cancelledAfterDispatch: return "cancelled-after-dispatch"
            }
        }
        if let error = error as? NodeSessionError {
            switch error {
            case .invalidValue: return "session-invalid-value"
            case .authenticationRejected: return "session-authentication-rejected"
            case .transportFailure: return "session-transport"
            case .transportFailureAfterDispatch: return "session-transport-after-dispatch"
            case .transportCancellationAfterDispatch: return "session-cancelled-after-dispatch"
            case .applicationResultUncertain: return "session-application-uncertain"
            }
        }
        return "other"
    }
}

private struct RecordingNodeSessionSender: NodeSessionStreamingRequestSending, NodeSessionRequestScopedSending {
    let base: any NodeSessionStreamingRequestSending
    let classifier: AcceptanceResponseClassifier
    let diagnostics: AcceptanceDiagnosticRecorder?

    init(base: any NodeSessionStreamingRequestSending, classifier: AcceptanceResponseClassifier, diagnostics: AcceptanceDiagnosticRecorder? = nil) {
        self.base = base
        self.classifier = classifier
        self.diagnostics = diagnostics
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        diagnostics?.requestBegin(method: method, path: path)
        do {
            let response = try await base.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
            diagnostics?.requestResponse(method: method, path: path, statusCode: response.statusCode)
            await classifier.response(response)
            return response
        } catch {
            diagnostics?.requestError(method: method, path: path, error: error)
            await classifier.transportFailure()
            throw error
        }
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        guard let scopedBase = base as? any NodeSessionRequestScopedSending else {
            diagnostics?.requestError(method: method, path: path, error: NodeSyncClientError.transport)
            await classifier.transportFailure()
            throw NodeSyncClientError.transport
        }
        diagnostics?.requestBegin(method: method, path: path)
        do {
            let response = try await scopedBase.send(
                method: method, path: path, body: body,
                maximumResponseBytes: maximumResponseBytes, cancellation: cancellation
            )
            diagnostics?.requestResponse(method: method, path: path, statusCode: response.statusCode)
            await classifier.response(response)
            return response
        } catch {
            diagnostics?.requestError(method: method, path: path, error: error)
            await classifier.transportFailure()
            throw error
        }
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        diagnostics?.requestBegin(method: method, path: path)
        do {
            let response = try await base.stream(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
            diagnostics?.requestResponse(method: method, path: path, statusCode: response.statusCode)
            await classifier.streamResponse(statusCode: response.statusCode)
            return response
        } catch {
            diagnostics?.requestError(method: method, path: path, error: error)
            await classifier.transportFailure()
            throw error
        }
    }
}

private final class CapabilityProbeSender: @unchecked Sendable, NodeSessionStreamingRequestSending, NodeAuthorityEpochUpdating, NodePendingMutationReconciling, NodePendingRequestReconciling {
    private(set) var epochValue: String?
    private(set) var logicalMailbox: LogicalMailboxID?
    private(set) var reconciliationCalls = 0

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 204, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        throw NodeSyncClientError.transport
    }

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        epochValue = epoch
        logicalMailbox = logicalMailboxID
    }

    func reconcilePendingMutation() async throws -> NodeHTTPResponse? {
        try await reconcilePendingRequest()
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        reconciliationCalls += 1
        return NodeHTTPResponse(statusCode: 204, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }
}

private actor ScopedCancellationProbeSender: NodeSessionRequestScopedSending, NodeSessionStreamingRequestSending {
    private var started = false
    private var completed = false
    private var receivedCancellation: NodeHTTPTransportRequestCancellation?
    private var continuation: CheckedContinuation<NodeHTTPResponse, Error>?

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        throw NodeSyncClientError.transport
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        started = true
        receivedCancellation = cancellation
        cancellation.install { [weak self] in
            Task { await self?.cancel() }
        }
        defer {
            cancellation.markCompleted()
            completed = true
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func receivedCancellationIs(_ cancellation: NodeHTTPTransportRequestCancellation) -> Bool {
        receivedCancellation === cancellation
    }

    func didComplete() -> Bool { completed }
}

extension RecordingNodeSessionSender: NodeMutationOperationSigning {
    func signMutation(
        variant: NodeSyncOperationVariant,
        logicalMailboxID: LogicalMailboxID,
        idempotencyKey: String,
        issuedAt: String
    ) throws -> Data {
        guard let signer = base as? any NodeMutationOperationSigning else {
            diagnostics?.signingBegin()
            diagnostics?.signingError(NodeSyncClientError.transport)
            throw NodeSyncClientError.transport
        }
        diagnostics?.signingBegin()
        do {
            let operation = try signer.signMutation(
                variant: variant,
                logicalMailboxID: logicalMailboxID,
                idempotencyKey: idempotencyKey,
                issuedAt: issuedAt
            )
            diagnostics?.signingEnd()
            return operation
        } catch {
            diagnostics?.signingError(error)
            throw error
        }
    }
}

extension RecordingNodeSessionSender: NodeAuthorityEpochUpdating, NodePendingMutationReconciling, NodePendingRequestReconciling {
    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        guard let updater = base as? any NodeAuthorityEpochUpdating else {
            throw NodeSyncClientError.transport
        }
        try updater.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }

    func reconcilePendingMutation() async throws -> NodeHTTPResponse? {
        guard let reconciler = base as? any NodePendingMutationReconciling else {
            diagnostics?.pendingReconciliationBegin(kind: "mutation")
            diagnostics?.pendingReconciliationEnd(kind: "mutation", outcome: .error(NodeSyncClientError.transport))
            throw NodeSyncClientError.transport
        }
        diagnostics?.pendingReconciliationBegin(kind: "mutation")
        do {
            let response = try await reconciler.reconcilePendingMutation()
            diagnostics?.pendingReconciliationEnd(kind: "mutation", outcome: response.map { .response($0.statusCode) } ?? .empty)
            return response
        } catch {
            diagnostics?.pendingReconciliationEnd(kind: "mutation", outcome: .error(error))
            throw error
        }
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        guard let reconciler = base as? any NodePendingRequestReconciling else {
            diagnostics?.pendingReconciliationBegin(kind: "request")
            diagnostics?.pendingReconciliationEnd(kind: "request", outcome: .error(NodeSyncClientError.transport))
            throw NodeSyncClientError.transport
        }
        diagnostics?.pendingReconciliationBegin(kind: "request")
        do {
            let response = try await reconciler.reconcilePendingRequest()
            diagnostics?.pendingReconciliationEnd(kind: "request", outcome: response.map { .response($0.statusCode) } ?? .empty)
            return response
        } catch {
            diagnostics?.pendingReconciliationEnd(kind: "request", outcome: .error(error))
            throw error
        }
    }
}

private actor DropOneAcceptedResponseTransport: NodeHTTPTransport {
    private let base: CurlNodeHTTPTransport
    private var dropped = false
    init(base: CurlNodeHTTPTransport) { self.base = base }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { let response = try await base.send(request, maximumResponseBytes: maximumResponseBytes); if response.statusCode == 503 { throw NodeSessionError.transportFailure }; if !dropped, response.statusCode == 404, request.url?.path == "/v1/private" { dropped = true; throw NodeSessionError.transportFailure }; return response }
    func didDropAcceptedResponse() -> Bool { dropped }
}

private enum PrimaryApplicationRejectionRecoveryError: Error {
    case noRetainedRequest
}

@MainActor
private func recoverPrimaryApplicationRejection(
    sender: NodeSessionTransport,
    retryDelay: Duration = .milliseconds(500),
    maximumReconciliationAttempts: Int = 8,
    stage: (String) -> Void = { _ in }
) async throws -> NodeHTTPResponse {
    let method = "POST"
    let path = "/v1/application-rejection"
    let body = Data()

    do {
        stage("primary-recovery-request-begin")
        let response = try await sender.send(method: method, path: path, body: body, maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
        stage("primary-recovery-request-end")
        return try requirePrimaryApplicationRejection(response)
    } catch let error as NodeSessionError {
        switch error {
        case .applicationResultUncertain:
            stage("primary-recovery-application-uncertain")
            return try await sendFreshPrimaryApplicationRejection(sender: sender, method: method, path: path, body: body, stage: stage)
        case .transportFailure, .transportFailureAfterDispatch:
            stage("primary-recovery-transport-failure")
            return try await reconcilePrimaryApplicationRejection(
                sender: sender, retryDelay: retryDelay, maximumAttempts: maximumReconciliationAttempts,
                method: method, path: path, body: body, stage: stage
            )
        default:
            throw error
        }
    }
}

@MainActor
private func reconcilePrimaryApplicationRejection(
    sender: NodeSessionTransport,
    retryDelay: Duration,
    maximumAttempts: Int,
    method: String,
    path: String,
    body: Data,
    stage: (String) -> Void
) async throws -> NodeHTTPResponse {
    guard maximumAttempts > 0 else { throw NodeSessionError.transportFailureAfterDispatch }
    for attempt in 0..<maximumAttempts {
        stage("primary-recovery-reconcile-delay")
        try await Task.sleep(for: retryDelay)
        do {
            stage("primary-recovery-reconcile-begin")
            guard let response = try await sender.reconcilePendingRequest() else {
                stage("primary-recovery-no-retained-request")
                throw PrimaryApplicationRejectionRecoveryError.noRetainedRequest
            }
            stage("primary-recovery-reconcile-end")
            return try requirePrimaryApplicationRejection(response)
        } catch let error as NodeSessionError {
            switch error {
            case .applicationResultUncertain:
                stage("primary-recovery-application-uncertain")
                return try await sendFreshPrimaryApplicationRejection(sender: sender, method: method, path: path, body: body, stage: stage)
            case .transportFailure, .transportFailureAfterDispatch:
                guard attempt + 1 < maximumAttempts else { throw error }
                stage("primary-recovery-transport-retry")
                continue
            default:
                throw error
            }
        }
    }
    throw NodeSessionError.applicationResultUncertain
}

@MainActor
private func sendFreshPrimaryApplicationRejection(
    sender: NodeSessionTransport,
    method: String,
    path: String,
    body: Data,
    stage: (String) -> Void
) async throws -> NodeHTTPResponse {
    stage("primary-recovery-fresh-request")
    let response = try await sender.send(method: method, path: path, body: body, maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
    stage("primary-recovery-fresh-response")
    return try requirePrimaryApplicationRejection(response)
}

private func requirePrimaryApplicationRejection(_ response: NodeHTTPResponse) throws -> NodeHTTPResponse {
    guard response.statusCode == 404 else { throw NodeSessionError.invalidValue }
    return response
}

private actor PrimaryRecoveryTransportFixture: NodeHTTPTransport {
    enum Behavior: Equatable {
        case sequenceConsumedThenMissing
        case authenticationRejected
        case alwaysTransportFailure
    }

    private let endpoint: URL
    private let behavior: Behavior
    private var requests: [URLRequest] = []

    init(endpoint: URL, behavior: Behavior = .sequenceConsumedThenMissing) {
        self.endpoint = endpoint
        self.behavior = behavior
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        requests.append(request)
        if behavior == .alwaysTransportFailure {
            throw NodeSessionError.transportFailure
        }
        if behavior == .authenticationRejected {
            return NodeHTTPResponse(statusCode: 401, url: endpoint, headers: [:], body: Data("{\"type\":\"urn:plainpost:node-auth-rejected\",\"status\":401}".utf8))
        }
        switch requests.count {
        case 1:
            throw NodeSessionError.transportFailure
        case 2:
            return NodeHTTPResponse(statusCode: 409, url: endpoint, headers: [:], body: Data("{\"type\":\"urn:plainpost:node-sequence-consumed\",\"status\":409}\n".utf8))
        default:
            return NodeHTTPResponse(statusCode: 404, url: endpoint, headers: [:], body: Data())
        }
    }

    func callCount() -> Int { requests.count }

    func sequences() -> [String] {
        requests.compactMap { request in
            guard let header = request.value(forHTTPHeaderField: "Plainpost-Signed-Request"),
                  let fields = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
            else { return nil }
            return fields["sequence"]
        }
    }
}

private struct CurlAccountHTTPTransport: AccountHTTPTransport {
    let wire: CurlAcceptanceWire
    let classifier: AcceptanceAccountResponseClassifier
    func resetFailureSummary() async { await classifier.reset() }
    func failureSummary() async -> String { await classifier.summary() }
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse { try await send(request, maximumResponseBytes: AccountAPIClient.maximumTransportResponseBytes) }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        let response = try await wire.send(request, maximumResponseBytes: maximumResponseBytes)
        await classifier.response(response, path: request.url?.path ?? "unknown")
        return AccountHTTPResponse(statusCode: response.status, headers: response.headers, body: response.body)
    }
}

private struct CurlNodeHTTPTransport: NodeHTTPStreamingTransport {
    let wire: CurlAcceptanceWire
    var failServiceUnavailable = false
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { let response = try await wire.send(request, maximumResponseBytes: maximumResponseBytes); if failServiceUnavailable && response.status == 503 { throw NodeSessionError.transportFailure }; guard let url = request.url else { throw NodeSessionError.transportFailure }; return NodeHTTPResponse(statusCode: response.status, url: url, headers: response.headers, body: response.body) }

    func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        let response = try await wire.stream(request, maximumResponseBytes: maximumResponseBytes)
        return try Self.accept(response, failServiceUnavailable: failServiceUnavailable)
    }

    static func accept(_ response: NodeHTTPStreamResponse, failServiceUnavailable: Bool) throws -> NodeHTTPStreamResponse {
        if failServiceUnavailable && response.statusCode == 503 {
            response.bytes.cancel()
            throw NodeSessionError.transportFailure
        }
        return response
    }
}

private final class CurlStreamLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func cancel() { lock.lock(); value += 1; lock.unlock() }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CurlAcceptanceStreamDiagnosticsState: @unchecked Sendable {
    let lock = NSLock()
    var nextStreamID = 0
}

private enum CurlAcceptanceStreamDiagnostics {
    private static let state = CurlAcceptanceStreamDiagnosticsState()

    static func reset() throws {
        guard let path = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"], !path.isEmpty else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "CurlAcceptanceStreamDiagnostics", code: 1)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        state.nextStreamID = 0
    }

    static func allocateStreamID() -> Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.nextStreamID += 1
        return state.nextStreamID
    }

    static func record(_ event: String) {
        guard let path = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"], !path.isEmpty else { return }
        let line = Data("[DEBUG-sync-node-stream] \(event)\n".utf8)
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: line)
        _ = try? handle.close()
    }

    static func record(streamID: Int, _ event: String) {
        record("stream_id=\(streamID) \(event)")
    }
}

private final class NestedAcceptanceStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let response: PlainpostByteStream
    private var transfer: Task<Void, Never>?

    init(response: PlainpostByteStream) { self.response = response }

    func install(_ transfer: Task<Void, Never>) {
        lock.lock()
        self.transfer = transfer
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let transfer = self.transfer
        lock.unlock()
        CurlAcceptanceStreamDiagnostics.record("event=outer-cancel-arrived response_cancel=begin transfer_present=\(transfer != nil)")
        response.cancel()
        CurlAcceptanceStreamDiagnostics.record("event=outer-response-cancelled")
        transfer?.cancel()
        CurlAcceptanceStreamDiagnostics.record("event=outer-transfer-cancelled")
    }
}

private struct CurlAcceptanceAttachmentSender: NodeSessionStreamingRequestSending {
    let response: NodeHTTPStreamResponse

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        response
    }
}

private final class CurlAcceptanceProcessCancellation: @unchecked Sendable {
    private struct ShutdownResources {
        let processStream: CurlAcceptanceProcessStream?
        let pumpTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let streamID: Int
    private var processStream: CurlAcceptanceProcessStream?
    private var pumpTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var didReleaseState = false

    init(streamID: Int) {
        self.streamID = streamID
    }

    private func record(_ event: String) {
        CurlAcceptanceStreamDiagnostics.record(streamID: streamID, event)
    }

    func install(_ processStream: CurlAcceptanceProcessStream) {
        lock.lock()
        let shouldShutdown = shutdownRequested || didReleaseState
        if !didReleaseState {
            self.processStream = processStream
        }
        lock.unlock()
        record("event=process-installed present=\(!shouldShutdown)")
        if shouldShutdown { record("event=process-install-after-cancel") }
    }

    func install(_ pumpTask: Task<Void, Never>) {
        lock.lock()
        let shouldShutdown = shutdownRequested || didReleaseState
        if !didReleaseState {
            self.pumpTask = pumpTask
        }
        lock.unlock()
        record("event=pump-installed present=\(!shouldShutdown)")
        if shouldShutdown { pumpTask.cancel() }
    }

    func requestShutdown() {
        let resources = beginShutdown()
        record("event=cancel-snapshot process_present=\(resources.processStream != nil) pump_present=\(resources.pumpTask != nil)")
        signalShutdown(resources)
    }

    func shutdown() async {
        let resources = beginShutdown()
        record("event=shutdown-snapshot process_present=\(resources.processStream != nil) pump_present=\(resources.pumpTask != nil)")
        signalShutdown(resources)
        await resources.pumpTask?.value
        record("event=shutdown-pump-joined")
        release()
    }

    var didRelease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReleaseState
    }

    private func beginShutdown() -> ShutdownResources {
        lock.lock()
        shutdownRequested = true
        let resources = ShutdownResources(processStream: processStream, pumpTask: pumpTask)
        lock.unlock()
        return resources
    }

    private func signalShutdown(_ resources: ShutdownResources) {
        resources.pumpTask?.cancel()
    }

    func release() {
        lock.lock()
        guard !didReleaseState else {
            lock.unlock()
            return
        }
        didReleaseState = true
        processStream = nil
        pumpTask = nil
        lock.unlock()
        record("event=cancellation-release")
    }

}

private final class CurlAcceptanceTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    func record(taskWasCancelled: Bool) {
        lock.lock()
        recordedValues.append(taskWasCancelled)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}

private final class CurlAcceptanceProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var didTerminate = false
    private var throwingWaiter: CheckedContinuation<Void, Error>?
    private var nonThrowingWaiter: CheckedContinuation<Void, Never>?

    func markTerminated() {
        lock.lock()
        guard !didTerminate else {
            lock.unlock()
            return
        }
        didTerminate = true
        let throwingWaiter = self.throwingWaiter
        self.throwingWaiter = nil
        let nonThrowingWaiter = self.nonThrowingWaiter
        self.nonThrowingWaiter = nil
        lock.unlock()
        throwingWaiter?.resume()
        nonThrowingWaiter?.resume()
    }

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if didTerminate {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    throwingWaiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWait()
        }
    }

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didTerminate {
                lock.unlock()
                continuation.resume()
            } else {
                nonThrowingWaiter = continuation
                lock.unlock()
            }
        }
    }

    private func cancelWait() {
        lock.lock()
        let continuation = throwingWaiter
        throwingWaiter = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class CurlAcceptanceProcessStream: @unchecked Sendable {
    private let process: Process
    private let processTermination: CurlAcceptanceProcessTermination
    private let phaseLock = NSLock()
    private var didReturnMetadata = false
    private let onProcessSpawnBegin: (@Sendable (CurlAcceptanceProcessStream) -> Void)?
    private let onPumpWaitBegin: (@Sendable () -> Void)?
    private let onMetadataWaitBegin: (@Sendable () -> Void)?
    private let onPumpFinished: (@Sendable () -> Void)?
    private let onTermination: (@Sendable (Bool) -> Void)?
    private let onMetadataIncomplete: (@Sendable () -> Void)?
    private var didObserveMetadataIncomplete = false
    private var didPumpFinish = false
    private var cleanupAllowed = false
    private var didCleanupArtifacts = false
    private let outputPipe: Pipe
    private let outputReadFileDescriptor: Int32
    private let output: PlainpostByteStream
    private let producer: PlainpostByteStream.Producer
    private let headersURL: URL
    private let stderrURL: URL
    private let stderrHandle: FileHandle
    private let requestURL: URL
    private let lifecycleURL: URL
    private let requestHeaderFile: CurlAcceptanceRequestHeaderFile?
    private let maximumResponseBytes: Int
    private let onDeinit: (@Sendable () -> Void)?
    private let cancellation: CurlAcceptanceProcessCancellation
    private let streamID: Int

    init(
        executable: String,
        supervisorExecutable: String = "/usr/bin/python3",
        arguments: [String],
        headersURL: URL,
        stderrURL: URL,
        requestURL: URL,
        lifecycleURL: URL,
        temporaryRoot: URL,
        maximumResponseBytes: Int,
        requestHeaderFile: CurlAcceptanceRequestHeaderFile? = nil,
        onDeinit: (@Sendable () -> Void)? = nil,
        onProcessSpawnBegin: (@Sendable (CurlAcceptanceProcessStream) -> Void)? = nil,
        onPumpWaitBegin: (@Sendable () -> Void)? = nil,
        onMetadataWaitBegin: (@Sendable () -> Void)? = nil,
        onPumpFinished: (@Sendable () -> Void)? = nil,
        onTermination: (@Sendable (Bool) -> Void)? = nil,
        onMetadataIncomplete: (@Sendable () -> Void)? = nil
    ) throws {
        _ = temporaryRoot
        let streamID = CurlAcceptanceStreamDiagnostics.allocateStreamID()
        let cancellation = CurlAcceptanceProcessCancellation(streamID: streamID)
        let output = PlainpostByteStream(capacity: 1, onCancellation: { cancellation.requestShutdown() })
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let configuredProcess = Process()
        let processTermination = CurlAcceptanceProcessTermination()
        let outputPipe = Pipe()
        let outputReadFileDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(outputReadFileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(outputReadFileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NodeSessionError.transportFailure
        }
        self.process = configuredProcess
        self.processTermination = processTermination
        self.onPumpWaitBegin = onPumpWaitBegin
        self.onMetadataWaitBegin = onMetadataWaitBegin
        self.onPumpFinished = onPumpFinished
        self.onTermination = onTermination
        self.onMetadataIncomplete = onMetadataIncomplete
        self.outputPipe = outputPipe
        self.outputReadFileDescriptor = outputReadFileDescriptor
        self.cancellation = cancellation
        self.streamID = streamID
        self.output = output
        self.producer = output.producer
        self.headersURL = headersURL
        self.stderrURL = stderrURL
        self.stderrHandle = stderrHandle
        self.requestURL = requestURL
        self.lifecycleURL = lifecycleURL
        self.requestHeaderFile = requestHeaderFile
        self.maximumResponseBytes = maximumResponseBytes
        self.onDeinit = onDeinit
        self.onProcessSpawnBegin = onProcessSpawnBegin
        // The supervisor is the sole owner of the target process's PID and
        // reaps it after cancellation. The parent only terminates and waits
        // for this supervisor, so it cannot signal a reused target PID or
        // race Foundation's wait/reap state.
        configuredProcess.executableURL = URL(fileURLWithPath: supervisorExecutable)
        configuredProcess.arguments = ["-c", Self.supervisorScript, "plainpost-curl-supervisor", executable] + arguments
        configuredProcess.standardOutput = outputPipe
        configuredProcess.standardError = stderrHandle
        configuredProcess.terminationHandler = { _ in processTermination.markTerminated() }
    }

    private static let supervisorScript = #"""
        import os
        import signal
        import subprocess
        import sys
        import time

        cancelled = False

        def request_cancellation(_signum, _frame):
            global cancelled
            cancelled = True

        signal.signal(signal.SIGTERM, request_cancellation)
        signal.signal(signal.SIGINT, request_cancellation)
        child = subprocess.Popen(sys.argv[2:], stdout=1, stderr=2, close_fds=True)
        for descriptor in (1, 2):
            try:
                os.close(descriptor)
            except OSError:
                pass

        while True:
            return_code = child.poll()
            if return_code is not None:
                sys.exit(143 if cancelled else (return_code if return_code >= 0 else 128 - return_code))
            if cancelled:
                try:
                    child.kill()
                except ProcessLookupError:
                    pass
                child.wait()
                sys.exit(143)
            time.sleep(0.01)
        """#

    deinit { onDeinit?() }

    private func record(_ event: String) {
        CurlAcceptanceStreamDiagnostics.record(streamID: streamID, event)
    }

    func start(url: URL) async throws -> NodeHTTPStreamResponse {
        var processRunSucceeded = false
        do {
            record("event=process-run-begin")
            onProcessSpawnBegin?(self)
            try process.run()
            processRunSucceeded = true
            record("event=process-run-success")
            cancellation.install(self)
            let pumpTask = Task { [self] in await self.pump() }
            cancellation.install(pumpTask)
            // The supervisor and target inherit the pipe's writer, but the
            // parent must release its own writer or EOF can never wake the
            // pump after a naturally completed response.
            try outputPipe.fileHandleForWriting.close()
            record("event=output-writer-closed")
            onMetadataWaitBegin?()
            let metadata = try await waitForMetadata()
            markMetadataReturned()
            return NodeHTTPStreamResponse(statusCode: metadata.statusCode, url: url, headers: metadata.headers, bytes: output)
        } catch {
            record(processRunSucceeded ? "event=stream-termination-failed phase=metadata" : "event=process-run-failed")
            await shutdown()
            permitArtifactCleanup()
            throw error
        }
    }

    func cancel() {
        cancellation.requestShutdown()
    }

    func shutdown() async {
        await cancellation.shutdown()
    }

    var didReleaseForTesting: Bool {
        cancellation.didRelease
    }

    var isRunningForTesting: Bool {
        process.isRunning
    }

    func terminateForCancellation() {
        record("event=terminate-begin")
        onTermination?(Task.isCancelled)
        // The supervisor owns the target PID and performs TERM -> KILL ->
        // wait. The pump is the sole owner of this Foundation Process.
        let supervisorRunning = process.isRunning
        if supervisorRunning { process.terminate() }
        record("event=terminate-end supervisor_signaled=\(supervisorRunning)")
        output.cancel()
    }

    private func waitForMetadata() async throws -> (statusCode: Int, headers: [String: String]) {
        for _ in 0..<500 {
            if let metadata = try parseHeaders() { return metadata }
            if !didObserveMetadataIncomplete {
                didObserveMetadataIncomplete = true
                onMetadataIncomplete?()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NodeSessionError.transportFailure
    }

    private func pump() async {
        var count = 0
        var failure: Error?
        record("event=pump-start")
        do {
            while let chunk = try await readPipeChunk(), !chunk.isEmpty {
                guard count <= maximumResponseBytes - chunk.count else { throw NodeSessionError.invalidValue }
                count += chunk.count
                try await producer.send(chunk)
            }
        } catch is CancellationError {
            failure = CancellationError()
            record("event=pump-catch category=cancellation")
        } catch {
            failure = error
            record("event=pump-catch category=error")
        }
        var terminationRequested = false
        if failure != nil {
            terminateForCancellation()
            terminationRequested = true
        }
        record("event=pump-wait-begin")
        do {
            try await waitForProcessExit()
        } catch is CancellationError {
            failure = CancellationError()
            if !terminationRequested { terminateForCancellation() }
            await processTermination.waitIgnoringCancellation()
        } catch {
            failure = error
            if !terminationRequested { terminateForCancellation() }
            await processTermination.waitIgnoringCancellation()
        }
        let terminationStatus = process.terminationStatus
        record("event=pump-wait-end status=\(terminationStatus)")
        if let failure {
            producer.fail(failure)
        } else if terminationStatus == 0 {
            producer.finish()
        } else {
            if hasReturnedMetadata() {
                record("event=stream-termination-failed phase=stream")
            }
            producer.fail(NodeSessionError.transportFailure)
        }
        try? outputPipe.fileHandleForReading.close()
        try? stderrHandle.close()
        markPumpFinished()
        onPumpFinished?()
        cancellation.release()
    }

    private func markMetadataReturned() {
        phaseLock.lock()
        didReturnMetadata = true
        let shouldCleanup = didPumpFinish
        phaseLock.unlock()
        if shouldCleanup { cleanupArtifacts() }
    }

    private func markPumpFinished() {
        phaseLock.lock()
        didPumpFinish = true
        let shouldCleanup = didReturnMetadata || cleanupAllowed
        phaseLock.unlock()
        if shouldCleanup { cleanupArtifacts() }
    }

    private func permitArtifactCleanup() {
        phaseLock.lock()
        cleanupAllowed = true
        phaseLock.unlock()
        // start() calls this only after shutdown() has joined any pump, so a
        // process-run failure with no pump is safe to clean up immediately.
        cleanupArtifacts()
    }

    private func cleanupArtifacts() {
        phaseLock.lock()
        guard !didCleanupArtifacts else {
            phaseLock.unlock()
            return
        }
        didCleanupArtifacts = true
        phaseLock.unlock()
        try? FileManager.default.removeItem(at: headersURL)
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: lifecycleURL)
        requestHeaderFile?.remove()
        record("event=lifecycle-removed present=\(FileManager.default.fileExists(atPath: lifecycleURL.path))")
    }

    private func hasReturnedMetadata() -> Bool {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return didReturnMetadata
    }

    private func waitForProcessExit() async throws {
        onPumpWaitBegin?()
        try await processTermination.wait()
    }

    private func readPipeChunk() async throws -> Data? {
        try Task.checkCancellation()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(outputReadFileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(bytes[0..<count]) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw NodeSessionError.transportFailure }
            try await Task.sleep(for: .milliseconds(5))
            try Task.checkCancellation()
        }
    }

    private func parseHeaders() throws -> (statusCode: Int, headers: [String: String])? {
        guard let text = try? String(contentsOf: headersURL, encoding: .utf8) else { return nil }
        guard text.hasSuffix("\r\n\r\n") else { return nil }
        let blocks = text.components(separatedBy: "\r\n\r\n")
        guard blocks.count > 1,
              let block = blocks.dropLast().last,
              block.hasPrefix("HTTP/") else { return nil }
        let lines = block.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
              status >= 200 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator])] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }
}

private struct CurlAcceptanceRequestHeaderFile: Sendable {
    let url: URL

    static func create(headers: [String: String], temporaryRoot: URL, stem: String) throws -> Self {
        let url = temporaryRoot.appendingPathComponent(stem + ".curl-config")
        var contents = Data()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }),
                  !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
                throw AccountRuntimeError.transportFailure
            }
            let escaped = "\(name): \(value)"
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\t", with: "\\t")
            contents.append(Data("header = \"\(escaped)\"\n".utf8))
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AccountRuntimeError.transportFailure }
        var writeSucceeded = true
        contents.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    writeSucceeded = false
                    break
                }
            }
        }
        let closeSucceeded = Darwin.close(descriptor) == 0
        contents.resetBytes(in: 0..<contents.count)
        guard writeSucceeded, closeSucceeded else {
            try? FileManager.default.removeItem(at: url)
            throw AccountRuntimeError.transportFailure
        }
        return Self(url: url)
    }

    func appendArguments(to arguments: inout [String]) {
        arguments += ["--config", url.path]
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor CurlAcceptanceWire {
    struct Response { let status: Int; let headers: [String:String]; let body: Data }
    private let caFile: String, connectRules: [String], temporaryRoot: URL, errorSurfaceRoot: URL
    init(caFile: String, connectRules: [String], temporaryRoot: URL, errorSurfaceRoot: URL) { self.caFile = caFile; self.connectRules = connectRules; self.temporaryRoot = temporaryRoot; self.errorSurfaceRoot = errorSurfaceRoot }
    func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        guard let url = request.url, url.scheme == "https", maximumResponseBytes > 0 else { throw AccountRuntimeError.transportFailure }
        let stem = UUID().uuidString
        let stderrURL = errorSurfaceRoot.appendingPathComponent(stem + ".stderr")
        let headersURL = temporaryRoot.appendingPathComponent(stem + ".headers")
        let requestURL = temporaryRoot.appendingPathComponent(stem + ".request")
        let lifecycleURL = temporaryRoot.appendingPathComponent(stem + ".stream-active")
        var requestHeaderFile: CurlAcceptanceRequestHeaderFile?
        var transferredArtifacts = false
        defer {
            if !transferredArtifacts {
                for path in [stderrURL, headersURL, requestURL, lifecycleURL] { try? FileManager.default.removeItem(at: path) }
                requestHeaderFile?.remove()
            }
        }
        let requestBody = request.httpBody ?? Data()
        guard FileManager.default.createFile(atPath: requestURL.path, contents: requestBody, attributes: [.posixPermissions:0o600]) else { throw AccountRuntimeError.transportFailure }
        guard FileManager.default.createFile(atPath: stderrURL.path, contents: Data(), attributes: [.posixPermissions:0o600]),
              FileManager.default.createFile(atPath: headersURL.path, contents: Data(), attributes: [.posixPermissions:0o600]),
              FileManager.default.createFile(atPath: lifecycleURL.path, contents: Data(), attributes: [.posixPermissions:0o600]) else { throw AccountRuntimeError.transportFailure }
        var arguments = ["--silent","--show-error","--noproxy","*","--connect-timeout",String(acceptanceProviderRequestTimeoutSeconds),"--max-time",String(acceptanceProviderRequestTimeoutSeconds),"--max-filesize",String(maximumResponseBytes),"--cacert",caFile,"--request",request.httpMethod ?? "GET","--dump-header",headersURL.path]
        for rule in connectRules { arguments += ["--connect-to", rule] }
        let headerFile = try CurlAcceptanceRequestHeaderFile.create(headers: request.allHTTPHeaderFields ?? [:], temporaryRoot: temporaryRoot, stem: stem)
        requestHeaderFile = headerFile
        headerFile.appendArguments(to: &arguments)
        if !requestBody.isEmpty { arguments += ["--data-binary", "@\(requestURL.path)"] }
        arguments.append(url.absoluteString)
        let stream = try CurlAcceptanceProcessStream(
            executable: "/usr/bin/curl", arguments: arguments,
            headersURL: headersURL, stderrURL: stderrURL, requestURL: requestURL,
            lifecycleURL: lifecycleURL,
            temporaryRoot: temporaryRoot, maximumResponseBytes: maximumResponseBytes,
            requestHeaderFile: headerFile
        )
        transferredArtifacts = true
        return try await stream.start(url: url)
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) throws -> Response {
        guard let url = request.url, url.scheme == "https", maximumResponseBytes > 0 else { throw AccountRuntimeError.transportFailure }
        let stem = UUID().uuidString, bodyURL = errorSurfaceRoot.appendingPathComponent(stem + ".response"), stderrURL = errorSurfaceRoot.appendingPathComponent(stem + ".stderr"), statusURL = temporaryRoot.appendingPathComponent(stem + ".status"), headersURL = temporaryRoot.appendingPathComponent(stem + ".headers"), requestURL = temporaryRoot.appendingPathComponent(stem + ".request")
        var requestHeaderFile: CurlAcceptanceRequestHeaderFile?
        defer {
            for path in [bodyURL, stderrURL, statusURL, headersURL, requestURL] {
                try? FileManager.default.removeItem(at: path)
            }
            requestHeaderFile?.remove()
        }
        let requestBody = request.httpBody ?? Data(); guard FileManager.default.createFile(atPath: requestURL.path, contents: requestBody, attributes: [.posixPermissions:0o600]) else { throw AccountRuntimeError.transportFailure }
        for sink in [bodyURL, stderrURL, statusURL, headersURL] { guard FileManager.default.createFile(atPath: sink.path, contents: Data(), attributes: [.posixPermissions:0o600]) else { throw AccountRuntimeError.transportFailure } }
        var arguments = ["--silent","--show-error","--noproxy","*","--connect-timeout",String(acceptanceProviderRequestTimeoutSeconds),"--max-time",String(acceptanceProviderRequestTimeoutSeconds),"--max-filesize",String(maximumResponseBytes),"--cacert",caFile,"--request",request.httpMethod ?? "GET","--dump-header",headersURL.path,"--output",bodyURL.path,"--write-out","%{http_code}"]
        for rule in connectRules { arguments += ["--connect-to", rule] }
        let headerFile = try CurlAcceptanceRequestHeaderFile.create(headers: request.allHTTPHeaderFields ?? [:], temporaryRoot: temporaryRoot, stem: stem)
        requestHeaderFile = headerFile
        headerFile.appendArguments(to: &arguments)
        if !requestBody.isEmpty { arguments += ["--data-binary", "@\(requestURL.path)"] }
        arguments.append(url.absoluteString)
        let output = try FileHandle(forWritingTo: statusURL), errorOutput = try FileHandle(forWritingTo: stderrURL)
        defer { try? output.close(); try? errorOutput.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/curl"); process.arguments = arguments; process.standardOutput = output; process.standardError = errorOutput
        try process.run(); process.waitUntilExit(); try output.synchronize(); try errorOutput.synchronize()
        let statusText = String(decoding: try Data(contentsOf: statusURL), as: UTF8.self)
        let stderr = (try? Data(contentsOf: stderrURL)) ?? Data()
        let stderrSize = stderr.count
        guard process.terminationStatus == 0, stderrSize <= 65536, let status = Int(statusText), let body = try? Data(contentsOf: bodyURL), body.count <= maximumResponseBytes else {
            let code = curlDiagnosticCode(stderr)
            let line = Data("ERROR swift-curl-failure exit=\(process.terminationStatus) curl_code=\(code) stderr_bytes=\(stderrSize)\n".utf8)
            FileHandle.standardError.write(line)
            throw AccountRuntimeError.transportFailure
        }
        let rawHeaders = (try? String(contentsOf: headersURL, encoding:.utf8)) ?? ""; var headers: [String:String] = [:]
        for line in rawHeaders.components(separatedBy:"\r\n") { guard let separator = line.firstIndex(of:":") else { continue }; headers[String(line[..<separator])] = String(line[line.index(after:separator)...]).trimmingCharacters(in:.whitespaces) }
        if status < 400 { try? FileManager.default.removeItem(at: bodyURL) }
        if stderrSize == 0 { try? FileManager.default.removeItem(at: stderrURL) }
        return Response(status: status, headers: headers, body: body)
    }

    private func curlDiagnosticCode(_ stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        guard let start = text.range(of: "curl: (")?.upperBound,
              let end = text[start...].firstIndex(of: ")") else { return "none" }
        let code = text[start..<end]
        guard !code.isEmpty, code.allSatisfy(\.isNumber) else { return "invalid" }
        return String(code)
    }
}
