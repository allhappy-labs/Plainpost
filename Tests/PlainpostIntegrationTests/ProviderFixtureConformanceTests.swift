import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostTestSupport

/// Integration-target ownership runs the language-neutral Task 4 corpus
/// through the shared strict decoder and then real semantic transports.
final class ProviderFixtureConformanceTests: XCTestCase {
    func testStrictlyDecodesEverySharedFixture() throws {
        for name in Self.documents {
            let document = try ProviderFixtureDocumentDecoder.load(name)
            XCTAssertEqual(document.schemaVersion, 1, name)
            XCTAssertEqual(document.caseIDs.count, document.cases.count, name)
            switch document.kind {
            case .imap:
                XCTAssertEqual(Set(try ProviderFixtureDocumentDecoder.imapOperations(document).map(\.id)), document.caseIDs, name)
            case .smtp:
                XCTAssertEqual(Set(try ProviderFixtureDocumentDecoder.smtpOperations(document).map(\.id)), document.caseIDs, name)
            case .mime:
                XCTAssertTrue(document.operations.isEmpty, name)
            }
        }
    }

    func testMIMEFixtureDecoderRejectsMalformedGeneratorShapes() throws {
        let validGenerator: [String: Any] = [
            "kind": "repeated_parts",
            "dimension": "attachment_count",
            "accepted": 256,
            "rejected": 257,
        ]
        let malformedPluralShapes: [(String, Any)] = [
            ("wrong-type", "repeated_parts"),
            ("empty", [] as [Any]),
            ("multiple", [validGenerator, validGenerator, validGenerator]),
            ("unknown", [validGenerator.merging(["unexpected": true]) { _, replacement in replacement }]),
        ]
        for (name, shape) in malformedPluralShapes {
            var root = try Self.root("mime-corpus.json")
            var cases = try Self.rawCases(root)
            guard let index = cases.firstIndex(where: { $0["inputBase64"] != nil }) else {
                throw FixtureError.invalid
            }
            cases[index]["generators"] = shape
            root["cases"] = cases

            XCTAssertThrowsError(try Self.document(root, named: "mime-corpus.json"), name)
        }

        let malformedSingularShapes: [(String, Any)] = [
            ("wrong-type", "repeated_parts"),
            ("empty", [String: Any]()),
            ("multiple", [validGenerator, validGenerator]),
            ("unknown", validGenerator.merging(["unexpected": true]) { _, replacement in replacement }),
            ("unknown-kind", [
                "kind": "unknown",
                "dimension": "part_count",
                "accepted": 2_000,
                "rejected": 2_001,
            ]),
            ("malformed-attachment-boundaries", [
                "kind": "repeated_parts",
                "dimension": "attachment_boundaries",
                "attachmentCount": ["accepted": 256, "rejected": 257],
                "attachmentMetadataBytes": ["accepted": 65_536, "rejected": 65_538],
            ]),
        ]
        for (name, shape) in malformedSingularShapes {
            var root = try Self.root("mime-corpus.json")
            var cases = try Self.rawCases(root)
            guard let index = cases.firstIndex(where: {
                $0["id"] as? String == "attachments-256-and-metadata-64kib-boundaries"
            }) else { throw FixtureError.invalid }
            cases[index].removeValue(forKey: "generators")
            cases[index]["generator"] = shape
            root["cases"] = cases

            XCTAssertThrowsError(try Self.document(root, named: "mime-corpus.json"), name)
        }
    }

    func testIMAPSemanticDecoderRejectsCrossActionProperty() throws {
        var root = try Self.root("imap-transcripts.json")
        var operations = try Self.rawOperations(root)
        guard let index = operations.firstIndex(where: {
            $0["id"] as? String == "gmail-oauth-refresh-rotation-symbolic"
        }), var input = operations[index]["input"] as? [String: Any]
        else { throw FixtureError.invalid }
        input["destination"] = "Archive"
        operations[index]["input"] = input
        root["operations"] = operations

        let document = try Self.document(root, named: "imap-transcripts.json")
        XCTAssertThrowsError(try ProviderFixtureDocumentDecoder.imapOperations(document))
    }

    func testTypedIMAPInputUsesAnActionVariant() {
        let common = ProviderFixtureSemanticOperation.Common(
            provider: "generic",
            transport: "loopback_fixture",
            authentication: "password",
            peer: .init(
                capabilities: [],
                mailboxes: [],
                uidValidity: 1,
                idleBehavior: "unsupported",
                appendResponses: [],
                disconnect: "none",
                catalogBehavior: "normal",
                security: "verified",
                oauthBehavior: "none"
            )
        )
        let input: ProviderFixtureSemanticOperation.Input = .discover(common)
        guard case .discover = input else {
            return XCTFail("discover must be represented by its closed input variant")
        }
    }

    func testIMAPSemanticDecoderRejectsSubmitOnlySentCopy() throws {
        var root = try Self.root("imap-transcripts.json")
        var operations = try Self.rawOperations(root)
        guard let index = operations.firstIndex(where: {
            $0["id"] as? String == "gmail-provider-managed-sent-no-append"
        }), var expected = operations[index]["expected"] as? [String: Any],
              var result = expected["result"] as? [String: Any],
              var mutation = result["mutation"] as? [String: Any],
              var outcomes = mutation["outcomes"] as? [[String: Any]],
              !outcomes.isEmpty
        else { throw FixtureError.invalid }
        outcomes[0]["sentCopy"] = "provider_managed"
        mutation["outcomes"] = outcomes
        result["mutation"] = mutation
        expected["result"] = result
        operations[index]["expected"] = expected
        root["operations"] = operations

        let document = try Self.document(root, named: "imap-transcripts.json")
        XCTAssertThrowsError(try ProviderFixtureDocumentDecoder.imapOperations(document))
    }

    func testIMAPSemanticDecoderAcceptsFrozenOutcomeAndScanCheckpoint() throws {
        var root = try Self.root("imap-transcripts.json")
        var operations = try Self.rawOperations(root)
        guard let moveIndex = operations.firstIndex(where: {
            $0["id"] as? String == "move-without-safe-expunge-is-unsupported"
        }), var moveExpected = operations[moveIndex]["expected"] as? [String: Any],
              var moveResult = moveExpected["result"] as? [String: Any],
              var moveMutation = moveResult["mutation"] as? [String: Any],
              var moveOutcomes = moveMutation["outcomes"] as? [[String: Any]],
              !moveOutcomes.isEmpty,
              let syncIndex = operations.firstIndex(where: {
                  $0["id"] as? String == "generic-incremental-cursor-page"
              }), var syncExpected = operations[syncIndex]["expected"] as? [String: Any],
              var syncResult = syncExpected["result"] as? [String: Any],
              var page = syncResult["page"] as? [String: Any],
              var cursor = page["nextCursor"] as? [String: Any]
        else { throw FixtureError.invalid }
        moveOutcomes[0]["code"] = "not_found"
        moveMutation["outcomes"] = moveOutcomes
        moveResult["mutation"] = moveMutation
        moveExpected["result"] = moveResult
        operations[moveIndex]["expected"] = moveExpected
        cursor["lastUID"] = 4
        cursor["scanUID"] = 2
        page["nextCursor"] = cursor
        syncResult["page"] = page
        syncExpected["result"] = syncResult
        operations[syncIndex]["expected"] = syncExpected
        root["operations"] = operations

        let document = try Self.document(root, named: "imap-transcripts.json")
        XCTAssertNoThrow(try ProviderFixtureDocumentDecoder.imapOperations(document))
    }

    func testIMAPNormalizedExpectations() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("imap-transcripts.json")
        let operations = try ProviderFixtureDocumentDecoder.imapOperations(document)
        try await ProviderFixtureSemanticHarness.run(
            operations: operations,
            fixtureIDs: document.caseIDs
        )
    }

    func testSMTPAcceptanceExpectations() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("smtp-transcripts.json")
        try await Self.assertSMTPTranscript("smtp-transcripts.json")
        try await ProviderFixtureSMTPSemanticHarness.run(
            operations: ProviderFixtureDocumentDecoder.smtpOperations(document),
            fixtureIDs: document.caseIDs
        )
    }

    func testIMAPSemanticOperationIgnoresMutatedTranscriptFinalClientWire() async throws {
        var root = try Self.root("imap-transcripts.json")
        var cases = try Self.rawCases(root)
        guard let fixtureIndex = cases.firstIndex(where: {
            $0["id"] as? String == "generic-incremental-cursor-page"
        }) else { throw FixtureError.invalid }
        var fixture = cases[fixtureIndex]
        guard var script = fixture["script"] as? [[String: Any]],
              let index = script.lastIndex(where: {
                  $0["kind"] as? String == "wire" && $0["direction"] as? String == "client"
              })
        else { throw FixtureError.invalid }
        script[index]["bytesBase64"] = Data("A9999 NOOP\r\n".utf8).base64EncodedString()
        fixture["script"] = script
        cases[fixtureIndex] = fixture
        root["cases"] = cases
        let document = try Self.document(root, named: "imap-transcripts.json")
        guard let input = try ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "generic-incremental-cursor-page"
        }) else { throw FixtureError.invalid }
        try await ProviderFixtureSemanticHarness.assertOperation(input)
    }

    func testIMAPSemanticExpectedResultMutationFailsWithoutChangingPeerInput() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("imap-transcripts.json")
        let operation = try XCTUnwrap(ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "generic-incremental-cursor-page"
        }))
        let mutated = ProviderFixtureSemanticOperation(
            id: operation.id,
            input: operation.input,
            expected: .init(result: .error(.init(tag: "unavailable", retry: "safe", cause: "")))
        )
        do {
            try await ProviderFixtureSemanticHarness.assertOperation(mutated)
            XCTFail("expected-only IMAP result mutation was accepted")
        } catch ProviderFixtureTransportHarness.FixtureHarnessError.transcript {
            // The peer input and public operation remain unchanged; only the
            // independently observed output makes the mutation fail.
        }
    }

    func testTypedIMAPMutationStimuliDriveFlagDeltasAndGmailLabels() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("imap-transcripts.json")
        let gmail = try XCTUnwrap(ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "gmail-special-use-and-labels"
        }))
        let generic = try XCTUnwrap(ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "generic-incremental-cursor-page"
        }))
        let applied = ProviderFixtureSemanticOperation.Expected(result: .mutation(.init(outcomes: [.init(
            state: "applied", code: "applied", providerReference: "", sentCopy: "not_applicable", destinationRawID: ""
        )])))
        guard case let .synchronizeIncremental(genericCommon, mailbox: genericMailbox, pageSize: _, cursor: _) = generic.input,
              case let .synchronizeBaseline(gmailCommon, mailbox: gmailMailbox, pageSize: _) = gmail.input
        else { throw FixtureError.invalid }
        let flagOperation = ProviderFixtureSemanticOperation(
            id: "typed-conditional-flag-deltas",
            input: .setFlags(
                genericCommon,
                mailbox: genericMailbox,
                rawID: "1",
                addFlags: ["flagged"],
                removeFlags: ["seen"],
                expectedModSequence: 7
            ),
            expected: applied
        )
        try await ProviderFixtureSemanticHarness.assertOperation(flagOperation)

        let labelOperation = ProviderFixtureSemanticOperation(
            id: "typed-gmail-label-deltas",
            input: .setLabels(
                gmailCommon,
                mailbox: gmailMailbox,
                rawID: "1",
                addLabels: [.init(id: "Team", displayName: "Team")],
                removeLabels: [.init(id: "\\Inbox", displayName: "\\Inbox")]
            ),
            expected: applied
        )
        try await ProviderFixtureSemanticHarness.assertOperation(labelOperation)
    }

    func testIMAPSemanticPeerUIDValidityMutationFailsAgainstFixedExpectedResult() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("imap-transcripts.json")
        let operation = try XCTUnwrap(ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "generic-incremental-cursor-page"
        }))
        guard case let .synchronizeIncremental(common, mailbox: mailbox, pageSize: pageSize, cursor: cursor) = operation.input else {
            throw FixtureError.invalid
        }
        let peer = common.peer
        let mutatedPeer = ProviderFixtureSemanticOperation.Peer(
            capabilities: peer.capabilities,
            mailboxes: peer.mailboxes,
            uidValidity: peer.uidValidity + 1,
            idleBehavior: peer.idleBehavior,
            appendResponses: peer.appendResponses,
            disconnect: peer.disconnect,
            catalogBehavior: peer.catalogBehavior,
            metadataBehavior: peer.metadataBehavior,
            security: peer.security,
            oauthBehavior: peer.oauthBehavior
        )
        let mutatedCommon = ProviderFixtureSemanticOperation.Common(
            provider: common.provider,
            transport: common.transport,
            authentication: common.authentication,
            peer: mutatedPeer
        )
        let mutatedInput: ProviderFixtureSemanticOperation.Input = .synchronizeIncremental(
            mutatedCommon,
            mailbox: mailbox,
            pageSize: pageSize,
            cursor: cursor
        )
        let mutated = ProviderFixtureSemanticOperation(
            id: operation.id,
            input: mutatedInput,
            expected: operation.expected
        )
        do {
            try await ProviderFixtureSemanticHarness.assertOperation(mutated)
            XCTFail("peer message output mutation was accepted by the fixed expected result")
        } catch let ProviderFixtureTransportHarness.FixtureHarnessError.transcript(message) {
            // The real SELECT response carries the changed UIDVALIDITY while
            // the independently fixed normalized cursor remains unchanged.
            XCTAssertTrue(message.contains("observedUIDValidity"), message)
        }
    }

    func testIMAPSemanticPeerMailboxMutationFailsAgainstFixedExpectedResult() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("imap-transcripts.json")
        let operation = try XCTUnwrap(ProviderFixtureDocumentDecoder.imapOperations(document).first(where: {
            $0.id == "gmail-oauth-refresh-rotation-symbolic"
        }))
        guard case let .discover(common) = operation.input else {
            throw FixtureError.invalid
        }
        let peer = common.peer
        let mutatedPeer = ProviderFixtureSemanticOperation.Peer(
            capabilities: peer.capabilities,
            mailboxes: peer.mailboxes.enumerated().map { index, mailbox in
                .init(
                    id: mailbox.id,
                    displayName: mailbox.displayName,
                    selectable: index == 0 ? false : mailbox.selectable,
                    specialUse: mailbox.specialUse
                )
            },
            uidValidity: peer.uidValidity,
            idleBehavior: peer.idleBehavior,
            appendResponses: peer.appendResponses,
            disconnect: peer.disconnect,
            catalogBehavior: peer.catalogBehavior,
            metadataBehavior: peer.metadataBehavior,
            security: peer.security,
            oauthBehavior: peer.oauthBehavior
        )
        let mutatedCommon = ProviderFixtureSemanticOperation.Common(
            provider: common.provider,
            transport: common.transport,
            authentication: common.authentication,
            peer: mutatedPeer
        )
        let mutatedInput: ProviderFixtureSemanticOperation.Input = .discover(mutatedCommon)
        let mutated = ProviderFixtureSemanticOperation(
            id: operation.id,
            input: mutatedInput,
            expected: operation.expected
        )
        do {
            try await ProviderFixtureSemanticHarness.assertOperation(mutated)
            XCTFail("peer mailbox response mutation was accepted by the fixed expected result")
        } catch let ProviderFixtureTransportHarness.FixtureHarnessError.transcript(message) {
            // LIST's \Noselect bit is not available in the public Mailbox
            // model, so the harness must observe a real SELECT failure rather
            // than copy the typed input's selectability into its output.
            XCTAssertTrue(message.contains("selectable: false"), message)
            XCTAssertTrue(message.contains("selectable: true"), message)
        }
    }

    func testSMTPTranscriptRejectsMutatedClientWire() async throws {
        guard var fixture = try Self.rawCases(Self.root("smtp-transcripts.json")).first,
              var script = fixture["script"] as? [[String: Any]],
              let index = script.firstIndex(where: {
                  $0["kind"] as? String == "wire" && $0["direction"] as? String == "client"
              })
        else { throw FixtureError.invalid }
        script[index]["bytesBase64"] = Data("EHLO altered.invalid\r\n".utf8).base64EncodedString()
        fixture["script"] = script
        do {
            _ = try await ProviderFixtureTransportHarness.replaySMTP(script: script)
            XCTFail("mutated SMTP client wire was accepted by transcript replay")
        } catch let ProviderFixtureTransportHarness.FixtureHarnessError.transcript(message) {
            XCTAssertTrue(message.contains("client wire mismatch"), message)
        } catch {
            XCTFail("mutated SMTP client wire failed for an unrelated reason: \(error)")
        }
    }

    func testSMTPSemanticOperationIgnoresMutatedTranscriptFinalClientWire() async throws {
        var root = try Self.root("smtp-transcripts.json")
        var cases = try Self.rawCases(root)
        guard let fixtureIndex = cases.firstIndex(where: {
            $0["id"] as? String == "final-250-then-quit-drop-is-applied"
        }) else { throw FixtureError.invalid }
        var fixture = cases[fixtureIndex]
        guard var script = fixture["script"] as? [[String: Any]],
              let index = script.lastIndex(where: {
                  $0["kind"] as? String == "wire" && $0["direction"] as? String == "client"
              })
        else { throw FixtureError.invalid }
        script[index]["bytesBase64"] = Data("QUIT MUTATED\r\n".utf8).base64EncodedString()
        fixture["script"] = script
        cases[fixtureIndex] = fixture
        root["cases"] = cases
        let document = try Self.document(root, named: "smtp-transcripts.json")
        guard let operation = try ProviderFixtureDocumentDecoder.smtpOperations(document).first(where: {
            $0.id == "final-250-then-quit-drop-is-applied"
        }) else { throw FixtureError.invalid }
        try await ProviderFixtureSMTPSemanticHarness.assertOperation(operation)
    }

    func testSMTPSemanticExpectedOutcomeMutationFailsWithoutChangingPeerInput() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("smtp-transcripts.json")
        let operation = try XCTUnwrap(ProviderFixtureDocumentDecoder.smtpOperations(document).first(where: {
            $0.id == "final-250-then-quit-drop-is-applied"
        }))
        let mutated = ProviderFixtureSMTPSemanticOperation(
            id: operation.id,
            input: operation.input,
            expected: .init(result: .outcome(.init(
                    state: "rejected",
                    code: "provider_rejected",
                    providerReference: "",
                    sentCopy: "not_applicable",
                    destinationRawID: ""
                )))
        )
        do {
            try await ProviderFixtureSMTPSemanticHarness.assertOperation(mutated)
            XCTFail("expected-only SMTP outcome mutation was accepted")
        } catch ProviderFixtureTransportHarness.FixtureHarnessError.transcript {
            // The input-driven server still accepts the message; the altered
            // oracle cannot change that behavior and is rejected afterward.
        }
    }

    func testSMTPSemanticPeerCapabilitiesMutationFailsAgainstFixedExpectedResult() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("smtp-transcripts.json")
        let operation = try XCTUnwrap(ProviderFixtureDocumentDecoder.smtpOperations(document).first(where: {
            $0.id == "smtputf8-required-but-missing-rejects-before-data"
        }))
        let mutated = ProviderFixtureSMTPSemanticOperation(
            id: operation.id,
            input: .init(
                provider: operation.input.provider,
                transport: operation.input.transport,
                authentication: operation.input.authentication,
                envelopeFrom: operation.input.envelopeFrom,
                recipients: operation.input.recipients,
                messageID: operation.input.messageID,
                messageBase64: operation.input.messageBase64,
                scenario: operation.input.scenario,
                capabilities: ["STARTTLS", "SMTPUTF8", "AUTH PLAIN"],
                sentBehavior: operation.input.sentBehavior,
                cancellation: operation.input.cancellation,
                authRejections: operation.input.authRejections
            ),
            expected: operation.expected
        )
        do {
            try await ProviderFixtureSMTPSemanticHarness.assertOperation(mutated)
            XCTFail("peer capability mutation was accepted by fixed expected result")
        } catch ProviderFixtureTransportHarness.FixtureHarnessError.transcript {
            // The changed peer capability permits the real SMTPUTF8 envelope;
            // only the unchanged oracle makes this deliberately fail.
        }
    }

    func testMIMENormalizedExpectations() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
        let literalFixtures = fixtures.filter { $0.input != nil }
        XCTAssertEqual(literalFixtures.count, 13)
        for fixture in literalFixtures {
            let input = try XCTUnwrap(fixture.input, fixture.id)
            let expectation = try XCTUnwrap(fixture.expectation, fixture.id)
            XCTAssertEqual(
                try ProviderFixtureDocumentDecoder.mimeProjection(from: input),
                expectation.projection,
                fixture.id
            )
            if expectation.attachments.contains(where: { $0.bytesError == "protocol" }) {
                XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: input), fixture.id) { error in
                    XCTAssertEqual(error as? MIMEAttachmentDecodingError, .malformedMessage, fixture.id)
                }
            } else {
                XCTAssertEqual(
                    try MIMEMessageDecoder.decodedAttachments(from: input),
                    try ProviderFixtureDocumentDecoder.hydratedAttachmentPayloads(for: expectation),
                    fixture.id
                )
            }
            try await Self.assertMIMESyncPath(
                input,
                expectation: expectation,
                fixtureID: fixture.id
            )
        }
    }

    func testMIMEHeaderBoundarySourcesCrossProductionSyncAndHydration() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let sources = try ProviderFixtureDocumentDecoder.mimeFixtures(document).flatMap(\.boundarySources)
        XCTAssertEqual(sources.count, 4)
        for source in sources {
            let accepted = try ProviderFixtureMIMEFixtures.headerBoundary(source, amount: source.accepted)
            try await Self.assertMIMEHeaderBoundarySyncPath(
                accepted,
                source: source,
                accepted: true
            )

            let rejected = try ProviderFixtureMIMEFixtures.headerBoundary(source, amount: source.rejected)
            do {
                try await Self.assertMIMEHeaderBoundarySyncPath(
                    rejected,
                    source: source,
                    accepted: false
                )
                XCTFail("\(source.name) accepted its +1 boundary")
            } catch let error as MIMEAttachmentDecodingError {
                XCTAssertEqual(error, .headerLimitExceeded, source.name)
            }
        }
    }

    func testGeneratedLimitCasesMatchGoConstants() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
        let generated = fixtures.filter { $0.generator != nil }
        XCTAssertEqual(generated.count, 7)
        for fixture in generated {
            for generator in fixture.generator?.boundaryCases ?? [] {
                let (next, overflow) = generator.accepted.addingReportingOverflow(1)
                XCTAssertFalse(overflow)
                XCTAssertEqual(generator.rejected, next)

                let acceptedData = try ProviderFixtureMIMEFixtures.generated(generator, amount: generator.accepted)
                let acceptedProjection = try ProviderFixtureDocumentDecoder.mimeProjection(from: acceptedData)
                if generator.dimension == "body_bytes" {
                    XCTAssertEqual(acceptedProjection.textBody, .complete(String(repeating: "b", count: generator.accepted)))
                }
                if ["attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes"].contains(generator.dimension) {
                    _ = try MIMEMessageDecoder.decodedAttachments(from: acceptedData)
                }

                let rejectedData = try ProviderFixtureMIMEFixtures.generated(generator, amount: generator.rejected)
                switch generator.dimension {
                case "body_bytes":
                    XCTAssertEqual(try ProviderFixtureDocumentDecoder.mimeProjection(from: rejectedData).textBody, .omittedOversized)
                case "attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes":
                    XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: rejectedData))
                default:
                    XCTAssertThrowsError(try ProviderFixtureDocumentDecoder.mimeProjection(from: rejectedData))
                }

                try await Self.assertGeneratedMIMESyncAndHydration(
                    generator: generator,
                    accepted: acceptedData,
                    rejected: rejectedData
                )
            }
        }
    }

    func testBase64AttachmentBoundaryCrossesProductionSyncAndHydration() async throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixture = try XCTUnwrap(
            try ProviderFixtureDocumentDecoder.mimeFixtures(document).first {
                $0.id == "attachment-50mib-accepted-plus-one-rejected"
            }
        )
        let generator = try XCTUnwrap(fixture.generator?.boundaryCases.first {
            $0.dimension == "attachment_bytes"
        })
        let accepted = try ProviderFixtureMIMEFixtures.generated(
            generator,
            amount: generator.accepted
        )
        let rejected = try ProviderFixtureMIMEFixtures.generated(
            generator,
            amount: generator.rejected
        )
        try await Self.assertGeneratedMIMESyncAndHydration(
            generator: generator,
            accepted: accepted,
            rejected: rejected
        )
    }

    func testFixtureDocumentsContainNoCredentialValues() throws {
        let prohibited = ["accesstoken", "refreshtoken", "\\\"password\\\"", "authorization", "imap.gmail.com", "smtp.gmail.com"]
        for name in Self.documents {
            let content = try String(contentsOf: Self.url(name), encoding: .utf8).lowercased()
            for value in prohibited { XCTAssertFalse(content.contains(value), "\(name) contains forbidden fixture material") }
        }
    }

    private static let documents = ["imap-transcripts.json", "smtp-transcripts.json", "mime-corpus.json"]
    private enum FixtureError: Error { case invalid }
    private static func url(_ name: String) -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Protocol/provider-fixtures/\(name)") }
    private static func root(_ name: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url(name))) as? [String: Any] else { throw FixtureError.invalid }
        return value
    }
    private static func document(
        _ root: [String: Any],
        named name: String
    ) throws -> ProviderFixtureDocumentDecoder.Document {
        guard JSONSerialization.isValidJSONObject(root) else { throw FixtureError.invalid }
        return try ProviderFixtureDocumentDecoder.decode(
            JSONSerialization.data(withJSONObject: root),
            named: name
        )
    }

    // Mutation tests need a raw document solely to alter byte transcripts;
    // their semantic shape is subsequently revalidated by the shared decoder.
    private static func rawCases(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let cases = root["cases"] as? [[String: Any]], !cases.isEmpty else { throw FixtureError.invalid }
        return cases
    }

    private static func rawOperations(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let operations = root["operations"] as? [[String: Any]], !operations.isEmpty else { throw FixtureError.invalid }
        return operations
    }

    /// The corpus oracle remains a complete RFC 5322 projection, while this
    /// assertion proves the shipping inbox sync path independently consumes the
    /// same source. Metadata-only commits must not decode transfer payloads;
    /// attachment-capable commits hydrate those exact payloads at commit time.
    private static func assertMIMESyncPath(
        _ input: Data,
        expectation: ProviderFixtureDocumentDecoder.MIMEExpectation,
        fixtureID: String
    ) async throws {
        let header = try fixtureHeader(from: input)
        let metadataCache = FixtureMIMEMetadataCache()
        let metadataService = IMAPSyncService(
            client: FixtureMIMEIMAPClient(header: header, body: input),
            cache: metadataCache
        )
        let credentials = IMAPAccountCredentials(
            accountID: AccountID("acc_fixture_mime"),
            email: EmailAddress("fixture@example.invalid"),
            username: "fixture-user",
            password: "fixture-secret"
        )

        let metadataResult = try await metadataService.syncInbox(credentials: credentials)
        XCTAssertEqual(metadataResult.syncedMessageCount, 1, fixtureID)
        XCTAssertEqual(metadataCache.messages.count, 1, fixtureID)
        XCTAssertEqual(metadataCache.metadata.count, 1, fixtureID)
        let metadataMessage = try XCTUnwrap(metadataCache.messages.first, fixtureID)
        let metadata = try XCTUnwrap(metadataCache.metadata.first, fixtureID)
        assertSyncProjection(
            message: metadataMessage,
            metadata: metadata,
            expected: expectation.projection,
            fixtureID: fixtureID
        )

        let attachmentCache = FixtureMIMEAttachmentCache()
        let attachmentService = IMAPSyncService(
            client: FixtureMIMEIMAPClient(header: header, body: input),
            cache: attachmentCache
        )
        if expectation.attachments.contains(where: { $0.bytesError == "protocol" }) {
            do {
                _ = try await attachmentService.syncInbox(credentials: credentials)
                XCTFail("\(fixtureID) hydrated malformed attachment bytes")
            } catch let error as MIMEAttachmentDecodingError {
                XCTAssertEqual(error, .malformedMessage, fixtureID)
            }
            return
        }

        let attachmentResult = try await attachmentService.syncInbox(credentials: credentials)
        XCTAssertEqual(attachmentResult.syncedMessageCount, 1, fixtureID)
        XCTAssertEqual(attachmentCache.messages.count, 1, fixtureID)
        XCTAssertEqual(attachmentCache.metadata.count, 1, fixtureID)
        XCTAssertEqual(
            attachmentCache.attachments,
            try ProviderFixtureDocumentDecoder.hydratedAttachmentPayloads(for: expectation),
            fixtureID
        )
    }

    private static func assertMIMEHeaderBoundarySyncPath(
        _ input: Data,
        source: ProviderFixtureDocumentDecoder.HeaderBoundarySource,
        accepted: Bool
    ) async throws {
        let header = try fixtureHeader(from: input)
        let cache = FixtureMIMEAttachmentCache()
        let service = IMAPSyncService(
            client: FixtureMIMEIMAPClient(header: header, body: input),
            cache: cache
        )
        let credentials = IMAPAccountCredentials(
            accountID: AccountID("acc_fixture_mime"),
            email: EmailAddress("fixture@example.invalid"),
            username: "fixture-user",
            password: "fixture-secret"
        )
        let result = try await service.syncInbox(credentials: credentials)
        guard accepted else { return }
        XCTAssertEqual(result.syncedMessageCount, 1, source.name)
        let message = try XCTUnwrap(cache.messages.first, source.name)
        let metadata = try XCTUnwrap(cache.metadata.first, source.name)
        XCTAssertTrue(cache.attachments.isEmpty, source.name)
        let expectedCount = source.dimension == "count" ? source.accepted : 256
        switch source.header {
        case "references":
            XCTAssertEqual(message.references.count, expectedCount, source.name)
            if source.dimension == "aggregate_bytes" {
                XCTAssertEqual(message.references.reduce(0) { $0 + $1.utf8.count }, source.accepted, source.name)
            }
        case "in_reply_to":
            XCTAssertEqual(
                message.inReplyTo,
                ProviderFixtureMIMEFixtures.headerBoundaryValue(
                    source,
                    bytes: source.dimension == "count" ? 16 : source.accepted / 256,
                    index: 0
                ),
                source.name
            )
            XCTAssertEqual(metadata.messageIdentifiers.count, 1, source.name)
        case "to":
            XCTAssertEqual(message.to.count, expectedCount, source.name)
            XCTAssertEqual(metadata.to.count, expectedCount, source.name)
        case "cc":
            XCTAssertEqual(message.cc.count, expectedCount, source.name)
            XCTAssertEqual(metadata.cc.count, expectedCount, source.name)
        default:
            throw FixtureError.invalid
        }
    }

    private static func assertGeneratedMIMESyncAndHydration(
        generator: ProviderFixtureDocumentDecoder.GeneratorBoundary,
        accepted: Data,
        rejected: Data
    ) async throws {
        let dimension = generator.dimension
        let acceptedCache = try await synchronizeGeneratedMIME(accepted)
        XCTAssertEqual(acceptedCache.messages.count, 1, "accepted \(dimension)")
        XCTAssertEqual(acceptedCache.metadata.count, 1, "accepted \(dimension)")

        if dimension == "body_bytes" {
            let cache = try await synchronizeGeneratedMIME(rejected)
            XCTAssertEqual(cache.messages.count, 1, "rejected \(dimension)")
            XCTAssertEqual(cache.messages.first?.body, "", "rejected \(dimension)")
            XCTAssertNil(cache.messages.first?.bodyHTML, "rejected \(dimension)")
            return
        }

        do {
            _ = try await synchronizeGeneratedMIME(rejected)
            XCTFail("rejected \(dimension) committed through sync/hydration")
        } catch let error as MIMEAttachmentDecodingError {
            XCTAssertEqual(error, generatedMIMEError(for: dimension), "rejected \(dimension)")
        }
    }

    private static func synchronizeGeneratedMIME(_ input: Data) async throws -> FixtureMIMEAttachmentCache {
        let header = try fixtureHeader(from: input)
        let cache = FixtureMIMEAttachmentCache()
        let service = IMAPSyncService(
            client: FixtureMIMEIMAPClient(header: header, body: input),
            cache: cache
        )
        let credentials = IMAPAccountCredentials(
            accountID: AccountID("acc_fixture_mime"),
            email: EmailAddress("fixture@example.invalid"),
            username: "fixture-user",
            password: "fixture-secret"
        )
        _ = try await service.syncInbox(credentials: credentials)
        return cache
    }

    private static func generatedMIMEError(for dimension: String) -> MIMEAttachmentDecodingError {
        switch dimension {
        case "depth": return .nestingDepthLimitExceeded
        case "part_count": return .partCountLimitExceeded
        case "header_bytes": return .headerLimitExceeded
        case "attachment_count": return .attachmentCountLimitExceeded
        case "attachment_metadata_bytes": return .attachmentMetadataLimitExceeded
        case "attachment_bytes", "aggregate_attachment_bytes": return .decodedSizeLimitExceeded
        default: return .malformedMessage
        }
    }

    private static func fixtureHeader(from input: Data) throws -> String {
        let text = String(decoding: input, as: UTF8.self)
        if let separator = text.range(of: "\r\n\r\n") {
            return String(text[..<separator.lowerBound])
        }
        if let separator = text.range(of: "\n\n") {
            return String(text[..<separator.lowerBound])
        }
        throw FixtureError.invalid
    }

    private static func assertSyncProjection(
        message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        expected: MIMEProviderProjection,
        fixtureID: String
    ) {
        XCTAssertEqual(message.subject, expected.subject, fixtureID)
        XCTAssertEqual(message.rfcMessageID ?? "", expected.rfcMessageID, fixtureID)
        if let first = expected.from.first {
            XCTAssertEqual(message.from.rawValue, first.mailbox, fixtureID)
            XCTAssertEqual(message.fromDisplayName ?? "", first.displayName, fixtureID)
        } else {
            XCTAssertEqual(message.from.rawValue, "unknown@example.invalid", fixtureID)
            XCTAssertNil(message.fromDisplayName, fixtureID)
        }
        XCTAssertEqual(message.replyTo?.rawValue, expected.replyTo.first?.mailbox, fixtureID)
        XCTAssertEqual(message.to.map(\.rawValue), expected.to.map(\.mailbox), fixtureID)
        XCTAssertEqual(message.cc.map(\.rawValue), expected.cc.map(\.mailbox), fixtureID)
        XCTAssertEqual(metadata.bcc.map(\.rawValue), expected.bcc.map(\.mailbox), fixtureID)
        XCTAssertEqual(message.inReplyTo, expected.inReplyTo.first, fixtureID)
        XCTAssertEqual(message.references, expected.references, fixtureID)
        XCTAssertEqual(
            metadata.messageIdentifiers,
            [message.rfcMessageID, message.inReplyTo].compactMap { $0 } + expected.references,
            fixtureID
        )

        switch expected.textBody {
        case let .complete(value):
            XCTAssertEqual(message.body, value, fixtureID)
        case .absent, .malformed, .omittedOversized:
            XCTAssertEqual(message.body, "", fixtureID)
        }
        switch expected.htmlBody {
        case let .complete(value):
            XCTAssertEqual(message.bodyHTML, value, fixtureID)
        case .absent, .malformed, .omittedOversized:
            XCTAssertNil(message.bodyHTML, fixtureID)
        }

        XCTAssertEqual(
            metadata.attachments,
            expected.parts.map {
                IncomingMessageAttachmentMetadata(
                    filename: $0.filename,
                    mimeType: $0.mediaType
                )
            },
            fixtureID
        )
    }

    private static func assertSMTPTranscript(_ name: String) async throws {
        for fixture in try rawCases(try root(name)) {
            guard let expected = fixture["expected"] as? [String: Any],
                  let normalized = expected["normalized"] as? [String: Any],
                  let script = fixture["script"] as? [[String: Any]] else { throw FixtureError.invalid }
            let id = fixture["id"] as? String ?? ""
            do {
                let actual = try await ProviderFixtureTransportHarness.replaySMTP(script: script)
                XCTAssertEqual(actual as NSDictionary, normalized as NSDictionary, id)
            } catch {
                XCTFail("\(name) fixture \(id): \(error)")
            }
        }
    }
}

private final class FixtureMIMEIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let header: String
    private let body: Data

    init(header: String, body: Data) {
        self.header = header
        self.body = body
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(
            id: MailboxID("mbx_fixture_mime"),
            accountID: AccountID("acc_fixture_mime"),
            name: "INBOX",
            path: "INBOX",
            specialUse: "\\Inbox"
        )]
    }

    func selectMailbox(_ path: String) async throws -> String {
        "* 1 EXISTS\r\n* OK [UIDVALIDITY 1] fixture"
    }

    func allMessageUIDs() async throws -> [Int] { [1] }

    func fetchHeader(uid: Int) async throws -> String { header }

    func fetchBody(uid: Int) async throws -> String {
        String(decoding: body, as: UTF8.self)
    }

    func fetchBodyData(uid: Int) async throws -> Data { body }

    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private final class FixtureMIMEMetadataCache: MailCache, AtomicIncomingMessageCache {
    private(set) var messages: [MessageSummary] = []
    private(set) var metadata: [IncomingMessageSearchMetadata] = []

    func cacheMailboxes(_ mailboxes: [Mailbox]) throws {}
    func cacheMessage(_ message: MessageSummary) throws { XCTFail("sync must commit metadata atomically") }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        messages.append(message)
        self.metadata.append(metadata)
        return IncomingMessageCommitResult(messageID: message.id, insertedMembership: true)
    }
}

private final class FixtureMIMEAttachmentCache: MailCache, AtomicIncomingAttachmentCache {
    private(set) var messages: [MessageSummary] = []
    private(set) var metadata: [IncomingMessageSearchMetadata] = []
    private(set) var attachments: [IncomingMessageAttachmentPayload] = []

    func cacheMailboxes(_ mailboxes: [Mailbox]) throws {}
    func cacheMessage(_ message: MessageSummary) throws { XCTFail("sync must commit attachments atomically") }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        messages.append(message)
        self.metadata.append(metadata)
        self.attachments.append(contentsOf: attachments)
        return IncomingMessageCommitResult(messageID: message.id, insertedMembership: true)
    }
}
