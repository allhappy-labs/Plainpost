import CryptoKit
import Foundation
@_spi(Testing) import PlainpostAccountProtocol
import Security
import XCTest
@testable import PlainpostNodeTransport

final class NodeTLSClientTests: XCTestCase {
    func testActivationV3VectorMatchesCanonicalTranscript() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-session-v1/fixtures/session-v3.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
        let activation = try XCTUnwrap(fixture["activation"] as? [String: String])
        let request = try ActivationRequestV3(
            resultWire: try decode(activation, "resultWire"), refreshWire: try decode(activation, "refreshWire"),
            leaseWire: try decode(activation, "leaseWire"), trustCommitWire: try decode(activation, "trustCommitWire"),
            admissionEvidenceWire: try decode(activation, "admissionEvidenceWire"), cleanupCapabilityWire: try decode(activation, "cleanupCapabilityWire"),
            claimProofSignature: try decode(activation, "claimProofSignature"))
        XCTAssertEqual(try NodeSessionTranscript.activationV3(request), try NodeSessionWire.decodeBase64URL(try XCTUnwrap(fixture["activationTranscript"] as? String)))
    }

    func testActivationRetriesTheExactV3BytesOnlyAfterUncertainFailure() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let request = try ActivationRequestV3(resultWire: Data("result".utf8), refreshWire: Data("refresh".utf8), leaseWire: Data("lease".utf8), trustCommitWire: Data("trust".utf8), admissionEvidenceWire: Data("evidence".utf8), cleanupCapabilityWire: Data("capability".utf8), claimProofSignature: Data(repeating: 1, count: 64))
        let transport = ActivationRecordingTransport(statuses: [503, 200])
        let client = NodeActivationClient(endpoint: endpoint, client: NodeTLSClient(transport: transport))
        await XCTAssertThrowsErrorAsync(try await client.activate(request))
        try await client.retryUncertainActivation()
        let bodies = await transport.bodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        let pendingReplay = await client.hasPendingActivationReplay
        XCTAssertTrue(pendingReplay) // local metadata/session completion owns final wipe
        await client.completeActivation()
        let completed = await client.hasPendingActivationReplay
        XCTAssertFalse(completed)
    }

    func testActivationTreatsCanonicalTransportRejectionAsDefinitive() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let request = try ActivationRequestV3(resultWire: Data("result".utf8), refreshWire: Data("refresh".utf8), leaseWire: Data("lease".utf8), trustCommitWire: Data("trust".utf8), admissionEvidenceWire: Data("evidence".utf8), cleanupCapabilityWire: Data("capability".utf8), claimProofSignature: Data(repeating: 1, count: 64))
        let client = NodeActivationClient(endpoint: endpoint, client: NodeTLSClient(transport: NodeHTTPTransportFixture { _ in NodeHTTPResponse(statusCode: 302, url: endpoint.url, headers: [:], body: Data()) }))
        do { try await client.activate(request); XCTFail("expected definitive rejection") }
        catch let error as NodeActivationError { XCTAssertEqual(error, .rejected) }
        let pending = await client.hasPendingActivationReplay
        XCTAssertFalse(pending)
    }

    func testActivationKeepsReplayOnlyForTransportAndFiveHundreds() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let request = try ActivationRequestV3(resultWire: Data("result".utf8), refreshWire: Data("refresh".utf8), leaseWire: Data("lease".utf8), trustCommitWire: Data("trust".utf8), admissionEvidenceWire: Data("evidence".utf8), cleanupCapabilityWire: Data("capability".utf8), claimProofSignature: Data(repeating: 1, count: 64))
        for (name, result, retained) in [
            ("four-hundred", Result<NodeHTTPResponse, Error>.success(NodeHTTPResponse(statusCode: 422, url: endpoint.url, headers: [:], body: Data())), false),
            ("five-hundred", .success(NodeHTTPResponse(statusCode: 503, url: endpoint.url, headers: [:], body: Data())), true),
            ("oversize", .success(NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: [:], body: Data(repeating: 1, count: NodeTLSClient.maximumResponseBytes + 1))), false),
            ("transport", .failure(NodeSessionError.transportFailure), true),
        ] {
            let activation = NodeActivationClient(endpoint: endpoint, client: NodeTLSClient(transport: ResultTransport(result: result)))
            await XCTAssertThrowsErrorAsync(try await activation.activate(request))
            let pending = await activation.hasPendingActivationReplay
            XCTAssertEqual(pending, retained, name)
        }
    }
    func testEndpointCipherRequiresExactSetupCodeAndClaimAAD() throws {
        let binding = try NodeEndpointClaimBinding(
            nodeID: Data(repeating: 1, count: 16),
            signingPublicKey: Data(repeating: 2, count: 65),
            agreementPublicKey: Data(repeating: 3, count: 65),
            noiseStaticPublicKey: Data(repeating: 4, count: 32),
            endpointDigest: Data(SHA256.hash(data: Data("https://node.tail1234.ts.net:8443".utf8))),
            expiresAt: "2026-08-16T12:05:00Z")
        let ciphertext = try NodeEndpointCipher.sealForTesting(
            endpoint: "https://node.tail1234.ts.net:8443",
            setupCode: Data(repeating: 7, count: 32),
            binding: binding,
            nonce: Data(repeating: 8, count: 12))

        XCTAssertEqual(try NodeEndpointCipher.open(ciphertext: ciphertext, setupCode: Data(repeating: 7, count: 32), binding: binding).absoluteString, "https://node.tail1234.ts.net:8443")
        XCTAssertThrowsError(try NodeEndpointCipher.open(ciphertext: ciphertext, setupCode: Data(repeating: 9, count: 32), binding: binding))
        XCTAssertThrowsError(try NodeEndpointCipher.open(ciphertext: ciphertext, setupCode: Data(repeating: 7, count: 32), binding: try NodeEndpointClaimBinding(nodeID: Data(repeating: 9, count: 16), signingPublicKey: Data(repeating: 2, count: 65), agreementPublicKey: Data(repeating: 3, count: 65), noiseStaticPublicKey: Data(repeating: 4, count: 32), endpointDigest: binding.endpointDigest, expiresAt: binding.expiresAt)))
    }

    func testCanonicalNodeEndpointRejectsNonTailscaleAndAmbiguousURLs() throws {
        XCTAssertEqual(try NodeEndpointURL("https://node.tail1234.ts.net:8443").url.absoluteString, "https://node.tail1234.ts.net:8443")
        for value in [
            "http://node.tail1234.ts.net", "https://192.168.1.2", "https://10.0.0.1:443",
            "https://node.example.com", "https://node.tail1234.ts.net/", "https://node.tail1234.ts.net?x=1",
            "https://user@node.tail1234.ts.net", "https://NODE.tail1234.ts.net", "https://node.tail1234.ts.net:0443"
            , "https://node.tail1234.ts.net"
        ] {
            XCTAssertThrowsError(try NodeEndpointURL(value), value)
        }
    }

    func testTLSClientRejectsRedirectAndResponseHostnameSubstitution() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let redirect = NodeTLSClient(transport: NodeHTTPTransportFixture { _ in
            NodeHTTPResponse(statusCode: 302, url: endpoint.url, headers: [:], body: Data())
        })
        await XCTAssertThrowsErrorAsync(try await redirect.send(NodeHTTPRequest(endpoint: endpoint, method: "POST", path: "/v1/activate", body: Data())))

        let substituted = NodeTLSClient(transport: NodeHTTPTransportFixture { _ in
            NodeHTTPResponse(statusCode: 200, url: URL(string: "https://other.tail1234.ts.net")!, headers: [:], body: Data())
        })
        await XCTAssertThrowsErrorAsync(try await substituted.send(NodeHTTPRequest(endpoint: endpoint, method: "POST", path: "/v1/activate", body: Data())))
    }

    func testTLSClientCancelsRejectedStreamingResponses() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        for (name, statusCode, responseURL) in [
            ("redirect", 302, endpoint.url),
            ("substituted-host", 200, URL(string: "https://other.tail1234.ts.net:8443")!),
        ] {
            let cancellation = CancellationProbe()
            let bytes = PlainpostByteStream(capacity: 1, onCancellation: cancellation.markCancelled)
            let client = NodeTLSClient(transport: StreamingResponseTransport(
                response: NodeHTTPStreamResponse(statusCode: statusCode, url: responseURL, headers: [:], bytes: bytes)
            ))

            await XCTAssertThrowsErrorAsync(
                try await client.stream(NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/attachments/item", body: Data()))
            )
            XCTAssertEqual(cancellation.count, 1, name)
        }
    }

    func testStreamingCancellationBeforeHeadersStopsURLSessionProducer() async throws {
        let started = expectation(description: "request started before headers")
        let stopped = expectation(description: "request stopped after cancellation")
        HangingHeadersURLProtocol.configure(started: started, stopped: stopped)
        defer { HangingHeadersURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingHeadersURLProtocol.self]
        let transport = URLSessionNodeHTTPTransport(configuration: configuration)
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let task = Task {
            try await transport.stream(URLRequest(url: endpoint.url), maximumResponseBytes: NodeTLSClient.maximumAttachmentResponseBytes)
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled metadata wait should fail")
        } catch is CancellationError {
            // expected
        } catch {
            // NodeSessionError.transportFailure is also acceptable after URLSession cancellation.
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testRequestScopedCancellationWaitsForOnlyTheStatusRequest() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = RequestScopedCancellationTransport()
        let client = NodeTLSClient(transport: transport)
        let cancellation = NodeHTTPTransportRequestCancellation()
        let status = Task {
            try await client.send(
                NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/status", body: Data()),
                cancellation: cancellation
            )
        }
        await transport.waitUntilStatusStarted()
        let unrelated = Task {
            try await client.send(NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/health", body: Data()))
        }
        await transport.waitUntilUnrelatedStarted()

        await cancellation.cancelAndWait()

        do {
            _ = try await status.value
            XCTFail("the status request must be cancelled")
        } catch is CancellationError {
            // expected
        } catch {
            // URLSession-style transports may map cancellation to transport failure.
        }
        let unrelatedFinishedBeforeRelease = transport.unrelatedFinished()
        XCTAssertFalse(unrelatedFinishedBeforeRelease, "status cancellation must not cancel another request")
        transport.releaseUnrelated()
        _ = try await unrelated.value
        let statusFinished = transport.statusFinished()
        XCTAssertTrue(statusFinished)
    }

    func testRequestScopedCancellationSuppressesLateTransportResult() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = LateResultCancellationTransport()
        let client = NodeTLSClient(transport: transport)
        let cancellation = NodeHTTPTransportRequestCancellation()
        let request = Task {
            try await client.send(
                NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/status", body: Data()),
                cancellation: cancellation
            )
        }

        await transport.waitUntilStarted()
        let cancellationWait = Task { await cancellation.cancelAndWait() }
        await transport.waitUntilCancelled()
        transport.releaseLateSuccess(endpoint: endpoint.url)
        await cancellationWait.value

        do {
            _ = try await request.value
            XCTFail("a late transport result must not win after cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(transport.completionCount(), 1, "request completion must remain exactly once")
    }

    func testRequestScopedCancellationBeforeRunDeliversStoredTerminalResultOnce() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let transport = URLSessionNodeHTTPTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScopedURLSessionProtocol.self]
            return configuration
        }())
        let client = NodeTLSClient(transport: transport)
        let cancellation = NodeHTTPTransportRequestCancellation()
        cancellation.install { }
        let cancellationWait = Task { await cancellation.cancelAndWait() }
        while !cancellation.isCancellationRequested { await Task.yield() }

        let request = Task {
            try await client.send(
                NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/status", body: Data()),
                cancellation: cancellation
            )
        }
        do {
            _ = try await request.value
            XCTFail("pre-run cancellation must fail the request")
        } catch is CancellationError {
            // expected
        }
        await cancellationWait.value
        XCTAssertNil(ScopedURLSessionProtocol.statusTaskIdentifier(), "pre-run cancellation must not resume a URLSessionTask")
    }

    func testURLSessionRequestScopedCancellationLeavesUnrelatedRequestAlive() async throws {
        let started = expectation(description: "status request started")
        let stopped = expectation(description: "status request stopped")
        ScopedURLSessionProtocol.configure(started: started, stopped: stopped)
        defer { ScopedURLSessionProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopedURLSessionProtocol.self]
        let client = NodeTLSClient(transport: URLSessionNodeHTTPTransport(configuration: configuration))
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let cancellation = NodeHTTPTransportRequestCancellation()
        let status = Task {
            try await client.send(
                NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/status", body: Data()),
                cancellation: cancellation
            )
        }
        await fulfillment(of: [started], timeout: 1)

        let health = try await client.send(NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/v1/health", body: Data()))
        XCTAssertEqual(health.statusCode, 200)
        await cancellation.cancelAndWait()
        _ = try? await status.value
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(
            ScopedURLSessionProtocol.statusTaskIdentifier(),
            ScopedURLSessionProtocol.stoppedTaskIdentifier(),
            "the cancellation callback must belong to the status URLSessionTask"
        )
    }

    func testStreamingTransportUsesBoundedChunksForSlowConsumers() async throws {
        let payload = Data(repeating: 0x4a, count: 200 * 1024)
        DataURLProtocol.configure(payload: payload)
        defer { DataURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DataURLProtocol.self]
        let transport = URLSessionNodeHTTPTransport(configuration: configuration)
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:8443")
        let response = try await transport.stream(URLRequest(url: endpoint.url), maximumResponseBytes: payload.count)

        var chunks: [Data] = []
        for try await chunk in response.bytes {
            chunks.append(chunk)
            if chunks.count == 1 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, payload)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count == 64 * 1024 })
    }

    func testBoundedByteStreamSuspendsProducerUntilConsumerResumes() async throws {
        let suspensionProbe = SuspensionProbe()
        let stream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: suspensionProbe.yield)
        let producer = stream.producer
        try await producer.send(Data([1]))
        let blocked = Task {
            do {
                try await producer.send(Data([2]))
                return true
            } catch {
                return false
            }
        }
        guard await nextSuspension(suspensionProbe.reader) == .sender(sequence: 1) else {
            blocked.cancel()
            _ = await blocked.result
            XCTFail("first sender did not park")
            return
        }
        let iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, Data([1]))
        let blockedResult = await blocked.value
        XCTAssertTrue(blockedResult)
        let second = try await iterator.next()
        XCTAssertEqual(second, Data([2]))
        producer.finish()
    }

    func testBoundedByteStreamResumesConcurrentProducersInOrder() async throws {
        let suspensionProbe = SuspensionProbe()
        let stream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: suspensionProbe.yield)
        let producer = stream.producer
        try await producer.send(Data([0]))

        let first = Task {
            try await producer.send(Data([1]))
        }
        guard await nextSuspension(suspensionProbe.reader) == .sender(sequence: 1) else {
            first.cancel()
            _ = await first.result
            XCTFail("first sender did not park")
            return
        }
        let second = Task {
            try await producer.send(Data([2]))
        }
        guard await nextSuspension(suspensionProbe.reader) == .sender(sequence: 2) else {
            first.cancel()
            second.cancel()
            _ = await first.result
            _ = await second.result
            XCTFail("second sender did not park")
            return
        }

        let iterator = stream.makeAsyncIterator()
        let firstValue = try await iterator.next()
        XCTAssertEqual(firstValue, Data([0]))
        try await first.value
        let secondValue = try await iterator.next()
        XCTAssertEqual(secondValue, Data([1]))
        try await second.value
        let thirdValue = try await iterator.next()
        XCTAssertEqual(thirdValue, Data([2]))
        producer.finish()
    }

    func testBoundedByteStreamFinishWakesBlockedSendersAndReceiversExactlyOnce() async throws {
        let senderProbe = SuspensionProbe()
        let completionProbe = CompletionProbe()
        let senderStream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: senderProbe.yield)
        let sender = senderStream.producer
        try await sender.send(Data([0]))
        let firstSender = Task {
            do {
                try await sender.send(Data([1]))
                completionProbe.markSender(1)
            } catch {
                completionProbe.markSender(1)
            }
        }
        let secondSender = Task {
            do {
                try await sender.send(Data([2]))
                completionProbe.markSender(2)
            } catch {
                completionProbe.markSender(2)
            }
        }
        guard await nextSuspension(senderProbe.reader) == .sender(sequence: 1),
              await nextSuspension(senderProbe.reader) == .sender(sequence: 2) else {
            firstSender.cancel()
            secondSender.cancel()
            _ = await firstSender.result
            _ = await secondSender.result
            XCTFail("both senders did not park")
            return
        }

        sender.finish()
        _ = await firstSender.result
        _ = await secondSender.result
        XCTAssertEqual(completionProbe.senderCount(1), 1)
        XCTAssertEqual(completionProbe.senderCount(2), 1)

        let senderIterator = senderStream.makeAsyncIterator()
        let buffered = try await senderIterator.next()
        XCTAssertEqual(buffered, Data([0]))
        let finished = try await senderIterator.next()
        XCTAssertNil(finished)

        let receiverProbe = SuspensionProbe()
        let receiverStream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: receiverProbe.yield)
        let receiverIterator = receiverStream.makeAsyncIterator()
        let receiver = Task {
            do {
                _ = try await receiverIterator.next()
                completionProbe.markReceiver()
            } catch {
                completionProbe.markReceiver()
            }
        }
        guard await nextSuspension(receiverProbe.reader) == .receiver else {
            receiver.cancel()
            _ = await receiver.result
            XCTFail("receiver did not park")
            return
        }
        receiverStream.producer.finish()
        _ = await receiver.result
        XCTAssertEqual(completionProbe.receiverCount, 1)
    }

    func testBoundedByteStreamFailureWakesBlockedSendersAndReceiversExactlyOnce() async throws {
        let failure = NSError(domain: "PlainpostByteStreamTests", code: 7)
        let senderProbe = SuspensionProbe()
        let completionProbe = CompletionProbe()
        let senderStream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: senderProbe.yield)
        let sender = senderStream.producer
        try await sender.send(Data([0]))
        let blockedSender = Task {
            do {
                try await sender.send(Data([1]))
                completionProbe.markSender(1)
            } catch {
                completionProbe.markSender(1)
            }
        }
        guard await nextSuspension(senderProbe.reader) == .sender(sequence: 1) else {
            blockedSender.cancel()
            _ = await blockedSender.result
            XCTFail("sender did not park")
            return
        }
        sender.fail(failure)
        _ = await blockedSender.result
        XCTAssertEqual(completionProbe.senderCount(1), 1)
        let senderIterator = senderStream.makeAsyncIterator()
        do {
            _ = try await senderIterator.next()
            XCTFail("failed stream should throw")
        } catch {
            // expected
        }

        let receiverProbe = SuspensionProbe()
        let receiverStream = PlainpostByteStream(capacity: 1, onCancellation: nil, onSuspension: receiverProbe.yield)
        let receiverIterator = receiverStream.makeAsyncIterator()
        let receiver = Task {
            do {
                _ = try await receiverIterator.next()
                completionProbe.markReceiver()
            } catch {
                completionProbe.markReceiver()
            }
        }
        guard await nextSuspension(receiverProbe.reader) == .receiver else {
            receiver.cancel()
            _ = await receiver.result
            XCTFail("receiver did not park")
            return
        }
        receiverStream.producer.fail(failure)
        _ = await receiver.result
        XCTAssertEqual(completionProbe.receiverCount, 1)
    }

    func testBoundedByteStreamConsumerCancellationInvokesUpstreamCallbackOnce() async throws {
        let cancellationProbe = CancellationProbe()
        let senderProbe = SuspensionProbe()
        let senderStream = PlainpostByteStream(capacity: 1, onCancellation: cancellationProbe.markCancelled, onSuspension: senderProbe.yield)
        let sender = senderStream.producer
        try await sender.send(Data([0]))
        let blockedSender = Task {
            try? await sender.send(Data([1]))
        }
        guard await nextSuspension(senderProbe.reader) == .sender(sequence: 1) else {
            blockedSender.cancel()
            _ = await blockedSender.result
            XCTFail("sender did not park")
            return
        }
        blockedSender.cancel()
        _ = await blockedSender.result
        let senderCancellationCount = cancellationProbe.count
        XCTAssertEqual(senderCancellationCount, 0)

        let receiverProbe = SuspensionProbe()
        let receiverStream = PlainpostByteStream(capacity: 1, onCancellation: cancellationProbe.markCancelled, onSuspension: receiverProbe.yield)
        let receiverIterator = receiverStream.makeAsyncIterator()
        let receiver = Task {
            _ = try? await receiverIterator.next()
        }
        guard await nextSuspension(receiverProbe.reader) == .receiver else {
            receiver.cancel()
            _ = await receiver.result
            XCTFail("receiver did not park")
            return
        }
        receiver.cancel()
        _ = await receiver.result
        let receiverCancellationCount = cancellationProbe.count
        XCTAssertEqual(receiverCancellationCount, 1)
    }

    func testSystemTLSHostnameValidationAcceptsExactCertificateNameAndRejectsMismatch() throws {
        let exactHost = "node.tail1234.ts.net"
        let fixture = try HostnameCertificateFixture(hostname: exactHost)
        defer { fixture.remove() }
        let certificateData = try Data(contentsOf: fixture.derURL)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))

        XCTAssertTrue(try fixture.evaluate(certificate, hostname: exactHost))
        XCTAssertFalse(try fixture.evaluate(certificate, hostname: "other.tail1234.ts.net"))
    }
}

private actor ActivationRecordingTransport: NodeHTTPTransport {
    private var statuses: [Int]; private var received: [Data] = []
    init(statuses: [Int]) { self.statuses = statuses }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        received.append(request.httpBody ?? Data())
        return NodeHTTPResponse(statusCode: statuses.removeFirst(), url: request.url!, headers: [:], body: Data())
    }
    func bodies() -> [Data] { received }
}

private func decode(_ object: [String: String], _ key: String) throws -> Data { try NodeSessionWire.decodeBase64URL(try XCTUnwrap(object[key])) }

private struct NodeHTTPTransportFixture: NodeHTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> NodeHTTPResponse
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> NodeHTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { try await handler(request) }
}

private struct StreamingResponseTransport: NodeHTTPStreamingTransport {
    let response: NodeHTTPStreamResponse

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        fatalError("streaming fixture must use stream(_:maximumResponseBytes:)")
    }

    func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        response
    }
}

private struct ResultTransport: NodeHTTPTransport {
    let result: Result<NodeHTTPResponse, Error>
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { try result.get() }
}

private final class RequestScopedCancellationTransport: NodeHTTPTransportRequestScoped, @unchecked Sendable {
    private let lock = NSLock()
    private var statusStarted = false
    private var statusFinishedValue = false
    private var unrelatedStarted = false
    private var unrelatedFinishedValue = false
    private var statusWaiter: CheckedContinuation<NodeHTTPResponse, Error>?
    private var unrelatedWaiter: CheckedContinuation<NodeHTTPResponse, Error>?

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NodeHTTPResponse, Error>) in
            lock.lock()
            unrelatedStarted = true
            unrelatedWaiter = continuation
            lock.unlock()
        }
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        cancellation.install { [weak self] in self?.cancelStatus() }
        defer { cancellation.markCompleted() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NodeHTTPResponse, Error>) in
            lock.lock()
            statusStarted = true
            statusWaiter = continuation
            lock.unlock()
        }
    }

    private func cancelStatus() {
        lock.lock()
        let continuation = statusWaiter
        statusWaiter = nil
        statusFinishedValue = true
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilStatusStarted() async {
        while !lock.withLock({ statusStarted }) { await Task.yield() }
    }

    func waitUntilUnrelatedStarted() async {
        while !lock.withLock({ unrelatedStarted }) { await Task.yield() }
    }

    func releaseUnrelated() {
        lock.lock()
        let continuation = unrelatedWaiter
        unrelatedWaiter = nil
        unrelatedFinishedValue = true
        lock.unlock()
        continuation?.resume(returning: NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.tail1234.ts.net:8443/v1/health")!, headers: [:], body: Data()))
    }

    func unrelatedFinished() -> Bool { lock.withLock { unrelatedFinishedValue } }
    func statusFinished() -> Bool { lock.withLock { statusFinishedValue } }
}

private final class LateResultCancellationTransport: NodeHTTPTransportRequestScoped, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var continuation: CheckedContinuation<NodeHTTPResponse, Error>?
    private var completions = 0

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        throw NodeSyncClientError.transport
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        cancellation.install { [weak self] in self?.markCancelled() }
        defer {
            cancellation.markCompleted()
            lock.withLock { completions += 1 }
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                started = true
                self.continuation = continuation
            }
        }
    }

    private func markCancelled() {
        lock.withLock { cancelled = true }
    }

    func releaseLateSuccess(endpoint: URL) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: NodeHTTPResponse(statusCode: 200, url: endpoint.appendingPathComponent("v1/status"), headers: [:], body: Data()))
    }

    func waitUntilStarted() async {
        while !lock.withLock({ started }) { await Task.yield() }
    }

    func waitUntilCancelled() async {
        while !lock.withLock({ cancelled }) { await Task.yield() }
    }

    func completionCount() -> Int { lock.withLock { completions } }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected error", file: file, line: line) }
    catch {}
}

/// Test-only trust setup: the ephemeral self-signed certificate is accepted
/// solely as the test anchor. The SSL policy is left to validate hostname, the
/// same system Security evaluation URLSession relies on; production installs
/// no delegate trust override.
private final class HostnameCertificateFixture {
    let directory: URL
    let derURL: URL

    init(hostname: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-node-tls-\(UUID().uuidString)", isDirectory: true)
        derURL = directory.appendingPathComponent("cert.der")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pemURL = directory.appendingPathComponent("cert.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        // The test supplies its own anchor, SAN, and a non-boundary valid
        // time. It therefore exercises Security's hostname policy without
        // depending on the machine trust store or a certificate boundary.
        try Self.runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyURL.path, "-out", pemURL.path, "-days", "30", "-subj", "/CN=\(hostname)", "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature,keyEncipherment", "-addext", "extendedKeyUsage=serverAuth", "-addext", "subjectAltName=DNS:\(hostname)"])
        try Self.runOpenSSL(["x509", "-in", pemURL.path, "-outform", "DER", "-out", derURL.path])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func evaluate(_ certificate: SecCertificate, hostname: String) throws -> Bool {
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust else { throw NodeSessionError.invalidValue }
        guard SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { throw NodeSessionError.invalidValue }
        SecTrustSetVerifyDate(trust, Date(timeIntervalSinceNow: 60) as CFDate)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "NodeTLSClientTests.openssl", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "openssl failed"]) }
    }
}

private final class HangingHeadersURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedExpectation: XCTestExpectation?
    nonisolated(unsafe) private static var stoppedExpectation: XCTestExpectation?
    nonisolated(unsafe) private static var didStop = false

    static func configure(started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.lock()
        startedExpectation = started
        stoppedExpectation = stopped
        didStop = false
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        startedExpectation = nil
        stoppedExpectation = nil
        didStop = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let started = Self.startedExpectation
        Self.lock.unlock()
        started?.fulfill()
    }

    override func stopLoading() {
        Self.lock.lock()
        guard !Self.didStop else {
            Self.lock.unlock()
            return
        }
        Self.didStop = true
        let stopped = Self.stoppedExpectation
        Self.lock.unlock()
        stopped?.fulfill()
    }
}

private final class ScopedURLSessionProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedExpectation: XCTestExpectation?
    nonisolated(unsafe) private static var stoppedExpectation: XCTestExpectation?
    nonisolated(unsafe) private static var statusTaskID: Int?
    nonisolated(unsafe) private static var stoppedTaskID: Int?

    static func configure(started: XCTestExpectation, stopped: XCTestExpectation) {
        lock.withLock {
            startedExpectation = started
            stoppedExpectation = stopped
            statusTaskID = nil
            stoppedTaskID = nil
        }
    }

    static func reset() {
        lock.withLock {
            startedExpectation = nil
            stoppedExpectation = nil
            statusTaskID = nil
            stoppedTaskID = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/v1/status" {
            Self.lock.withLock {
                Self.statusTaskID = task?.taskIdentifier
                Self.startedExpectation?.fulfill()
            }
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.path == "/v1/status" {
            Self.lock.withLock {
                Self.stoppedTaskID = task?.taskIdentifier
                Self.stoppedExpectation?.fulfill()
            }
        }
    }

    static func statusTaskIdentifier() -> Int? { lock.withLock { statusTaskID } }
    static func stoppedTaskIdentifier() -> Int? { lock.withLock { stoppedTaskID } }
}

private final class DataURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var payload = Data()

    static func configure(payload: Data) { self.payload = payload }
    static func reset() { payload = Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(Self.payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SuspensionProbe: @unchecked Sendable {
    let reader: SuspensionReader
    private let continuation: AsyncStream<PlainpostByteStream.SuspensionEvent>.Continuation

    init() {
        let pair = AsyncStream<PlainpostByteStream.SuspensionEvent>.makeStream()
        continuation = pair.continuation
        reader = SuspensionReader(stream: pair.stream)
    }

    func yield(_ event: PlainpostByteStream.SuspensionEvent) {
        continuation.yield(event)
    }
}

private final class SuspensionReader: @unchecked Sendable {
    private var iterator: AsyncStream<PlainpostByteStream.SuspensionEvent>.Iterator

    init(stream: AsyncStream<PlainpostByteStream.SuspensionEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> PlainpostByteStream.SuspensionEvent? {
        await iterator.next()
    }
}

private func nextSuspension(_ reader: SuspensionReader) async -> PlainpostByteStream.SuspensionEvent? {
    await withTaskGroup(of: PlainpostByteStream.SuspensionEvent?.self) { group in
        group.addTask { await reader.next() }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sendCounts: [Int: Int] = [:]
    private var completedReceivers = 0

    func markSender(_ id: Int) {
        lock.lock(); sendCounts[id, default: 0] += 1; lock.unlock()
    }

    func senderCount(_ id: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sendCounts[id, default: 0]
    }

    func markReceiver() {
        lock.lock(); completedReceivers += 1; lock.unlock()
    }

    var receiverCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completedReceivers
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func markCancelled() {
        lock.lock(); value += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
