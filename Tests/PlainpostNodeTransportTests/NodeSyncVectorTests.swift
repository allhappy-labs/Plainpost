import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostNodeTransport

final class NodeSyncVectorTests: XCTestCase {
    func testCanonicalMailSourceMatchesPythonFixtureDefinition() {
        let source = Data("From: sender@example.test\r\nSubject: x\n\nbody".utf8)
        XCTAssertEqual(CanonicalMailSource.normalize(source), Data("From: sender@example.test\r\nSubject: x\r\n\r\nbody\r\n".utf8))
        XCTAssertEqual(CanonicalMailSource.digestHex(source), "8997d3ce8252a94297477dd6d47cb521951ce6665088bada83674d6ee01e8b34")
    }

    func testStatusResultDecodesLegacyV1ShapeWithSafeDefaults() throws {
        let legacy = Data("{\"kind\":\"node-sync.status-result.v1\",\"revision\":\"2\",\"state\":\"ready\"}".utf8)
        let status = try NodeSyncCodec.decodeStatusResult(legacy)
        XCTAssertEqual(status.revision, "2")
        XCTAssertEqual(status.state, "ready")
        XCTAssertEqual(status.syncLag, "unknown")
        XCTAssertEqual(status.assignments, [])
        XCTAssertEqual(status.reachability, "unknown")
        XCTAssertEqual(status.endpoint, "unknown")
    }

    func testStatusResultRejectsPartialRichShape() {
        let partial = Data("{\"assignments\":[],\"kind\":\"node-sync.status-result.v1\",\"revision\":\"2\",\"state\":\"ready\",\"version\":\"node-sync-v1\"}".utf8)
        XCTAssertThrowsError(try NodeSyncCodec.decodeStatusResult(partial))
    }

    func testStatusVectorValidatesNestedAuthorityEpochCanonicalBytes() throws {
        let vector = try ProtocolVectors.load()
        let wire = try XCTUnwrap(vector["statusResult"])
        let status = try NodeSyncCodec.decodeStatusResult(wire)
        let assignment = try XCTUnwrap(status.assignments.first)
        XCTAssertEqual(assignment.authorityEpoch, "12")
        XCTAssertEqual(assignment.role, "inbox")
        XCTAssertEqual(try NodeSyncCodec.encodeStatusResult(status), wire)
    }

    // This catches a changed field, nullability rule, collection ordering rule,
    // or canonical JSON representation before a page crosses node-session-v1.
    func testSnapshotVectorRoundTripsExactly() throws {
        let vector = try SnapshotVector.load()
        let request = try NodeSyncCodec.decodeSnapshotRequest(vector.request)
        XCTAssertEqual(request.after, "")
        XCTAssertEqual(request.limit, 2)
        XCTAssertEqual(try NodeSyncCodec.encodeSnapshotRequest(request), vector.request)

        let page = try NodeSyncCodec.decodeSnapshotPage(vector.page)
        XCTAssertEqual(page.revision, "7")
        XCTAssertEqual(page.nextCursor, "cursor-002")
        XCTAssertEqual(page.messages.count, 1)
        let message = try XCTUnwrap(page.messages.first)
        XCTAssertEqual(message.htmlBody.state, .absent)
        XCTAssertNil(message.htmlBody.value)
        XCTAssertEqual(message.textBody.state, .complete)
        XCTAssertEqual(message.textBody.value, "Done")
        XCTAssertNil(message.sentAt)
        XCTAssertNil(try XCTUnwrap(message.attachments.first).contentID)
        XCTAssertEqual(try NodeSyncCodec.encodeSnapshotPage(page), vector.page)
    }

    // This catches a mutation codec that modifies opaque signed operation bytes
    // or accepts a body-size declaration that does not match decoded bytes.
    func testMutationVectorRetainsCanonicalOperationBytes() throws {
        let vector = try MutationVector.load()
        let request = try NodeSyncCodec.decodeMutationRequest(vector.request)
        XCTAssertEqual(request.canonicalOperation, vector.canonicalOperation)
        XCTAssertTrue(String(decoding: request.canonicalOperation, as: UTF8.self).contains("\"idempotencyKey\":\"mutation-0006\""))
        XCTAssertEqual(try NodeSyncCodec.encodeMutationRequest(request), vector.request)
        XCTAssertEqual(try NodeSyncCodec.operationTranscript(try NodeSyncCodec.decodeOperation(vector.canonicalOperation).unsigned), vector.transcript)
    }

    // The signature is attached only after the canonical unsigned preimage is
    // frozen; it must not be represented by a placeholder signature.
    func testUnsignedOperationPreimageUsesLogicalMailboxIdentity() throws {
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111",
            authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222",
            idempotencyKey: "mutation-unsigned",
            issuedAt: "2026-08-20T12:34:56Z",
            logicalMailboxID: logicalMailboxID,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .archive(messageIDs: ["message-001"]),
            trustEpoch: "1"
        )
        let preimage = try NodeSyncCodec.canonicalUnsignedOperation(unsigned)
        let signed = try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64))
        XCTAssertEqual(try NodeSyncCodec.canonicalUnsignedOperation(signed.unsigned), preimage)
        XCTAssertThrowsError(try NodeSyncCodec.decodeLogicalMailboxID("mailbox-001"))
        XCTAssertThrowsError(try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg"))
        XCTAssertThrowsError(try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="))
        XCTAssertThrowsError(try NodeSyncCodec.decodeLogicalMailboxID("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    }

    func testAllSignedOperationVariantPeerVectors() throws {
        let vector = try MutationVector.load()
        XCTAssertEqual(vector.operations.count, 9)
        for expected in vector.operations {
            let operation = try NodeSyncCodec.decodeOperation(expected.canonicalOperation)
            XCTAssertEqual(try NodeSyncCodec.encodeOperation(operation), expected.canonicalOperation, expected.name)
            XCTAssertEqual(try NodeSyncCodec.operationTranscript(operation.unsigned), expected.transcript, expected.name)
        }
    }

    func testOperationVariantVectorsAndContractBreaks() throws {
        let signature = Data(repeating: 0x42, count: 64)
        let variants: [NodeSyncOperationVariant] = [
            .saveDraft(draftID: "draft-001", expectedRevision: "0", rfc5322: Data("From: sender@example.test\r\nTo: recipient@example.test\r\n\r\nbody".utf8)),
            .deleteDraft(draftID: "draft-001", expectedRevision: "1"),
            .send(draftID: "draft-001", expectedRevision: "1"),
            .setLabels(messageIDs: ["message-001"], addLabelIDs: ["label-001"], removeLabelIDs: ["label-002"]),
            .setRead(messageIDs: ["message-001"], read: true),
            .archive(messageIDs: ["message-001"]),
            .delete(messageIDs: ["message-001"]),
            .setFlagged(messageIDs: ["message-001"], flagged: false),
            .move(messageIDs: ["message-001"], destinationMailboxPath: "[Gmail]/Receipts")
        ]
        XCTAssertThrowsError(try operation(.move(messageIDs: ["message-001"], destinationMailboxPath: ""), signature: signature),
                             "a move names a folder")
        for variant in variants {
            let operation = try operation(variant, signature: signature)
            let wire = try NodeSyncCodec.encodeOperation(operation)
            XCTAssertEqual(try NodeSyncCodec.encodeOperation(NodeSyncCodec.decodeOperation(wire)), wire)
        }

        let vector = try MutationVector.load()
        let cases: [(String, Data)] = [
            ("missing signed field", replacing(vector.canonicalOperation, ",\"trustEpoch\":\"1\"", "")),
            ("signature tamper", replacing(vector.canonicalOperation, "\"signature\":\"", "\"signature\":\"=")),
            ("noncanonical signature tail", replacing(vector.canonicalOperation, "A\",\"trustEpoch", "E\",\"trustEpoch")),
            ("non-RFC UUID variant", replacing(vector.canonicalOperation, "-8111-111111111111", "-7111-111111111111")),
            ("missing variant required field", replacing(vector.canonicalOperation, "\"kind\":\"archive\"", "\"kind\":\"set_labels\"")),
            ("unsorted message IDs", replacing(vector.canonicalOperation, "[\"message-001\"]", "[\"message-002\",\"message-001\"]"))
        ]
        for (name, wire) in cases {
            XCTAssertThrowsError(try NodeSyncCodec.decodeOperation(wire), name)
        }
        XCTAssertThrowsError(try operation(.setLabels(messageIDs: ["message-001"], addLabelIDs: ["label-001"], removeLabelIDs: ["label-001"]), signature: signature))
        XCTAssertThrowsError(try operation(.deleteDraft(draftID: "draft-001", expectedRevision: "0"), signature: signature))
        XCTAssertThrowsError(try operation(.saveDraft(draftID: "draft-001", expectedRevision: "0", rfc5322: Data(repeating: 0x78, count: NodeSyncLimits.maximumRFC5322Bytes + 1)), signature: signature))
    }

    func testBccVectorsDefineCrossLanguageEnvelopeContract() throws {
        let root = try vectorRoot("bcc-v1.json")
        let accepted = try XCTUnwrap(root["accepted"] as? [[String: Any]])
        let rejected = try XCTUnwrap(root["rejected"] as? [[String: Any]])
        XCTAssertEqual(accepted.count, 4)
        XCTAssertEqual(rejected.count, 5)
        let limits = try XCTUnwrap(root["limits"] as? [String: Int])
        XCTAssertEqual(limits["maxEnvelopeRecipients"], 256)
        XCTAssertEqual(limits["maxAddressBytes"], 320)

        for vector in accepted {
            let name = try XCTUnwrap(vector["name"] as? String)
            let source = Data(try XCTUnwrap(vector["rfc5322"] as? String).utf8)
            let bcc = try XCTUnwrap(vector["bcc"] as? [String])
            let expectedEnvelope = try XCTUnwrap(vector["envelopeRecipients"] as? [String])
            let visible = String(decoding: source, as: UTF8.self).components(separatedBy: "\r\n").filter { $0.hasPrefix("To: ") || $0.hasPrefix("Cc: ") }.flatMap { field in
                field.dropFirst(4).split(separator: ",").map { raw in
                    let value = raw.trimmingCharacters(in: .whitespaces)
                    let mailbox: String
                    if let start = value.firstIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end {
                        mailbox = String(value[value.index(after: start)..<end])
                    } else {
                        mailbox = value
                    }
                    let parts = mailbox.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                    return parts.count == 2 ? "\(parts[0])@\(parts[1].lowercased())" : mailbox
                }
            }
            XCTAssertEqual(visible + bcc, expectedEnvelope, name)
            XCTAssertNoThrow(try operation(.saveDraft(draftID: name, expectedRevision: "0", rfc5322: source, bcc: bcc), signature: Data(repeating: 0x42, count: 64)), name)
        }

        for vector in rejected {
            let name = try XCTUnwrap(vector["name"] as? String)
            let source = Data(try XCTUnwrap(vector["rfc5322"] as? String).utf8)
            let bcc = try XCTUnwrap(vector["bcc"] as? [String])
            XCTAssertThrowsError(try operation(.saveDraft(draftID: name, expectedRevision: "0", rfc5322: source, bcc: bcc), signature: Data(repeating: 0x42, count: 64)), name)
        }

        let source = Data("Message-ID: <explicit-empty@example.test>\r\nFrom: sender@example.test\r\nTo: recipient@example.test\r\nSubject: compatibility\r\n\r\nbody\r\n".utf8)
        let withBcc = try operation(.saveDraft(draftID: "explicit-empty", expectedRevision: "0", rfc5322: source, bcc: ["blind@example.test"]), signature: Data(repeating: 0x42, count: 64))
        let explicitEmpty = replacing(try NodeSyncCodec.encodeOperation(withBcc), "\"bcc\":[\"blind@example.test\"]", "\"bcc\":[]")
        XCTAssertThrowsError(try NodeSyncCodec.decodeOperation(explicitEmpty), "explicit empty bcc must not be serialized")

        let oversized = String(repeating: "a", count: 308) + "@example.test"
        XCTAssertEqual(oversized.utf8.count, 321)
        XCTAssertThrowsError(try operation(.saveDraft(draftID: "oversized", expectedRevision: "0", rfc5322: Data("Message-ID: <oversized@example.test>\r\nFrom: sender@example.test\r\nSubject: oversized\r\n\r\nbody\r\n".utf8), bcc: [oversized]), signature: Data(repeating: 0x42, count: 64)))

        let visible = (0..<256).map { "recipient\($0)@example.test" }.joined(separator: ", ")
        let aggregateSource = Data("Message-ID: <aggregate@example.test>\r\nFrom: sender@example.test\r\nTo: \(visible)\r\nSubject: aggregate\r\n\r\nbody\r\n".utf8)
        XCTAssertThrowsError(try operation(.saveDraft(draftID: "aggregate-over-limit", expectedRevision: "0", rfc5322: aggregateSource, bcc: ["blind@example.test"]), signature: Data(repeating: 0x42, count: 64)))
    }

    func testCanonicalUnicodeAndTimestampBounds() throws {
        let vectors = try ProtocolVectors.load()
        let message = try XCTUnwrap(vectors["messageResult"])
        for (name, wire) in [
            ("raw U+2028", replacing(message, "\\u2028", " ")),
            ("raw U+2029", replacing(message, "\\u2029", " ")),
            ("year zero", replacing(message, "0001-01-01T00:00:00Z", "0000-01-01T00:00:00Z"))
        ] {
            XCTAssertThrowsError(try NodeSyncCodec.decodeMessageResult(wire), name)
        }
        let search = try NodeSyncCodec.decodeSearchRequest(try XCTUnwrap(vectors["searchRequest"]))
        XCTAssertEqual(search.logicalMailboxIDs.count, 2)
        XCTAssertTrue(search.logicalMailboxIDs[0].rawValue.lexicographicallyPrecedes(search.logicalMailboxIDs[1].rawValue))
        XCTAssertNotEqual(search.logicalMailboxIDs[0].rawValue, search.logicalMailboxIDs[1].rawValue)
        XCTAssertThrowsError(try NodeSyncCodec.decodeSearchRequest(replacing(try XCTUnwrap(vectors["searchRequest"]), "[\"aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"]", "[\"0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"]")))
        XCTAssertThrowsError(try NodeSyncMessageRequest(messageID: String(repeating: "é", count: 257)))
    }

    func testDeltaShapesAndGoogleBounds() throws {
        let vectors = try ProtocolVectors.load()
        let deltaRequest = try NodeSyncCodec.decodeDeltaRequest(try XCTUnwrap(vectors["deltaRequest"]))
        XCTAssertEqual(deltaRequest.after, "opaque-delta-tail-001")
        XCTAssertEqual(deltaRequest.limit, 1)
        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let changes = [
            try NodeSyncChange(kind: "upsert", logicalMailboxID: logicalMailboxID, messageID: "message-001", threadID: "thread-001"),
            try NodeSyncChange(kind: "membership_removed", logicalMailboxID: logicalMailboxID, messageID: nil, threadID: nil),
            try NodeSyncChange(kind: "tombstoned", logicalMailboxID: logicalMailboxID, messageID: "message-002", threadID: nil),
            try NodeSyncChange(kind: "epoch_reset", logicalMailboxID: logicalMailboxID, messageID: nil, threadID: nil),
            try NodeSyncChange(kind: "baseline_complete", logicalMailboxID: logicalMailboxID, messageID: nil, threadID: nil)
        ]
        XCTAssertEqual(try NodeSyncCodec.encodeDeltaPage(NodeSyncDeltaPage(changes: changes, nextCursor: "opaque-delta-tail-002", revision: "2")), try XCTUnwrap(vectors["deltaPage"]))
        XCTAssertThrowsError(try NodeSyncChange(kind: "membership_removed", logicalMailboxID: logicalMailboxID, messageID: "message-003", threadID: nil))
        XCTAssertThrowsError(try NodeSyncChange(kind: "tombstoned", logicalMailboxID: logicalMailboxID, messageID: "message-002", threadID: "thread-002"))

        let verifier = String(repeating: "a", count: 43)
        let maximumRedirectURI = "https://node.example.test/" + String(repeating: "u", count: 2_048 - "https://node.example.test/".utf8.count)
        XCTAssertNoThrow(try NodeSyncGoogleProvisionRequest(authorizationCode: String(repeating: "a", count: 4_096), clientID: "client-001", codeVerifier: verifier, redirectURI: maximumRedirectURI))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "", clientID: "client-001", codeVerifier: verifier, redirectURI: "u"))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: String(repeating: "a", count: 4_097), clientID: "client-001", codeVerifier: verifier, redirectURI: "u"))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "a", clientID: "client-001", codeVerifier: String(repeating: "a", count: 42), redirectURI: "u"))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "a", clientID: "client-001", codeVerifier: String(repeating: "a", count: 129), redirectURI: "u"))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "a", clientID: "client-001", codeVerifier: verifier + "!", redirectURI: "u"))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "a", clientID: "client-001", codeVerifier: verifier, redirectURI: ""))
        XCTAssertThrowsError(try NodeSyncGoogleProvisionRequest(authorizationCode: "a", clientID: "client-001", codeVerifier: verifier, redirectURI: String(repeating: "u", count: 2_049)))
    }

    func testOperationCeilingsAndRequiredMessageIDs() throws {
        let signature = Data(repeating: 0x42, count: 64)
        XCTAssertThrowsError(try operation(.setLabels(messageIDs: [], addLabelIDs: ["label-001"], removeLabelIDs: []), signature: signature))
        XCTAssertThrowsError(try operation(.setRead(messageIDs: [], read: true), signature: signature))
        XCTAssertThrowsError(try operation(.archive(messageIDs: []), signature: signature))
        XCTAssertThrowsError(try operation(.delete(messageIDs: []), signature: signature))

        let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let escaped = String(repeating: "\u{0001}", count: NodeSyncLimits.maximumIdentifierBytes)
        let rfcPrefix = "Message-ID: <maximum@example.test>\r\nFrom: sender@example.test\r\nTo: recipient@example.test\r\n\r\n"
        let maximumRFC = Data((rfcPrefix + String(repeating: "x", count: NodeSyncLimits.maximumRFC5322Bytes - rfcPrefix.utf8.count)).utf8)
        XCTAssertEqual(maximumRFC.count, NodeSyncLimits.maximumRFC5322Bytes)
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111",
            authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222",
            idempotencyKey: escaped,
            issuedAt: "2026-08-20T12:34:56Z",
            logicalMailboxID: logicalMailboxID,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .saveDraft(draftID: escaped, expectedRevision: "0", rfc5322: maximumRFC),
            trustEpoch: "1"
        )
        let signed = try NodeSyncOperation(unsigned: unsigned, signature: signature)
        XCTAssertLessThanOrEqual(try NodeSyncCodec.encodeOperation(signed).count, NodeSyncLimits.maximumCanonicalOperationBytes)
        XCTAssertThrowsError(try operation(.saveDraft(draftID: "draft-001", expectedRevision: "0", rfc5322: maximumRFC + Data([0x78])), signature: signature))
    }

    func testSearchReferenceAndRouteBounds() throws {
        let bounds = try ProtocolBounds.load()
        let valid = try NodeSyncSearchRequest(
            after: String(repeating: "c", count: bounds.cursor.acceptedBytes),
            limit: UInt16(bounds.pageLimit.accepted),
            logicalMailboxIDs: [],
            query: String(repeating: "q", count: bounds.searchQuery.acceptedBytes)
        )
        XCTAssertEqual(valid.limit, 200)
        XCTAssertThrowsError(try NodeSyncSearchRequest(after: valid.after, limit: valid.limit, logicalMailboxIDs: [], query: ""))
        XCTAssertThrowsError(try NodeSyncSearchRequest(after: valid.after, limit: valid.limit, logicalMailboxIDs: [], query: "query\u{0001}control"))
        XCTAssertThrowsError(try NodeSyncSearchRequest(after: valid.after, limit: valid.limit, logicalMailboxIDs: [], query: String(repeating: "q", count: bounds.searchQuery.rejectedBytes)))
        XCTAssertThrowsError(try NodeSyncSearchRequest(after: String(repeating: "c", count: bounds.cursor.rejectedBytes), limit: valid.limit, logicalMailboxIDs: [], query: valid.query))
        XCTAssertThrowsError(try NodeSyncSearchRequest(after: valid.after, limit: UInt16(bounds.pageLimit.rejected), logicalMailboxIDs: [], query: valid.query))

        let page = try NodeSyncCodec.decodeSnapshotPage(try SnapshotVector.load().page)
        let source = try XCTUnwrap(page.messages.first)
        let accepted = message(source, inReplyTo: [String(repeating: "i", count: bounds.messageReference.acceptedBytes)], references: [String(repeating: "r", count: bounds.messageReference.acceptedBytes)])
        XCTAssertNoThrow(try NodeSyncSnapshotPage(messages: [accepted], nextCursor: page.nextCursor, revision: page.revision))
        let longInReplyTo = message(source, inReplyTo: [String(repeating: "i", count: bounds.messageReference.rejectedBytes)], references: accepted.references)
        XCTAssertThrowsError(try NodeSyncSnapshotPage(messages: [longInReplyTo], nextCursor: page.nextCursor, revision: page.revision))
        let longReference = message(source, inReplyTo: accepted.inReplyTo, references: [String(repeating: "r", count: bounds.messageReference.rejectedBytes)])
        XCTAssertThrowsError(try NodeSyncSnapshotPage(messages: [longReference], nextCursor: page.nextCursor, revision: page.revision))
    }

    func testMutationIdentifierArrayBounds() throws {
        let bounds = try ProtocolBounds.load()
        let acceptedMessages = identifiers("message", count: bounds.mutationIdentifierArray.acceptedItems)
        XCTAssertNoThrow(try operation(.setLabels(messageIDs: acceptedMessages, addLabelIDs: ["label-000"], removeLabelIDs: []), signature: Data(repeating: 0x42, count: 64)))
        let rejectedMessages = identifiers("message", count: bounds.mutationIdentifierArray.rejectedItems)
        let rejectedLabels = identifiers("label", count: bounds.mutationIdentifierArray.rejectedItems)
        let variants: [NodeSyncOperationVariant] = [
            .setLabels(messageIDs: rejectedMessages, addLabelIDs: ["label-000"], removeLabelIDs: []),
            .setLabels(messageIDs: ["message-000"], addLabelIDs: rejectedLabels, removeLabelIDs: []),
            .setLabels(messageIDs: ["message-000"], addLabelIDs: [], removeLabelIDs: rejectedLabels),
            .setRead(messageIDs: rejectedMessages, read: true),
            .archive(messageIDs: rejectedMessages),
            .delete(messageIDs: rejectedMessages)
        ]
        for variant in variants {
            XCTAssertThrowsError(try operation(variant, signature: Data(repeating: 0x42, count: 64)))
        }
    }

    func testCanonicalFamilyEnvelopeBounds() throws {
        let bounds = try ProtocolBounds.load()
        let vectors = try ProtocolVectors.load()
        let atLimit = try resizedCanonicalFamily(try XCTUnwrap(vectors["messageResult"]), count: bounds.canonicalFamily.acceptedBytes)
        let result = try NodeSyncCodec.decodeMessageResult(atLimit)
        XCTAssertEqual(try NodeSyncCodec.encodeMessageResult(result), atLimit)
        let overLimit = try resizedCanonicalFamily(try XCTUnwrap(vectors["messageResult"]), count: bounds.canonicalFamily.rejectedBytes)
        XCTAssertThrowsError(try NodeSyncCodec.decodeMessageResult(overLimit))
        let body = try XCTUnwrap(result.message.textBody.value) + "x"
        let tooLarge = try NodeSyncMessageResult(message: message(result.message, textBody: NodeSyncBody(state: .complete, value: body)))
        XCTAssertThrowsError(try NodeSyncCodec.encodeMessageResult(tooLarge))
        let oversizedPage = try resizedCanonicalFamily(try SnapshotVector.load().page, count: bounds.canonicalFamily.rejectedBytes)
        XCTAssertThrowsError(try NodeSyncCodec.decodeSnapshotPage(oversizedPage))
    }

    // These are protocol breaks rather than normalization opportunities.
    func testVectorRejectsNonCanonicalWire() throws {
        let snapshot = try SnapshotVector.load()
        let mutation = try MutationVector.load()
        let oversizedAfter = "\"after\":\"" + String(repeating: "c", count: 4_097) + "\""
        let cases: [(String, () throws -> Void)] = [
            ("unknown field", { _ = try NodeSyncCodec.decodeSnapshotRequest(Data(#"{\"after\":\"\",\"extra\":true,\"kind\":\"node-sync.snapshot-request.v1\",\"limit\":2}"#.utf8)) }),
            ("duplicate field", { _ = try NodeSyncCodec.decodeSnapshotRequest(Data(#"{\"after\":\"\",\"after\":\"\",\"kind\":\"node-sync.snapshot-request.v1\",\"limit\":2}"#.utf8)) }),
            ("noncanonical whitespace", { _ = try NodeSyncCodec.decodeSnapshotRequest(snapshot.request + Data([0x0A])) }),
            ("NUL identifier", { _ = try NodeSyncCodec.decodeSnapshotPage(replacing(snapshot.page, "\"id\":\"message-001\"", "\"id\":\"message\\u0000-001\"")) }),
            ("fractional timestamp", { _ = try NodeSyncCodec.decodeSnapshotPage(replacing(snapshot.page, "2026-08-20T12:34:56Z", "2026-08-20T12:34:56.1Z")) }),
            ("unsorted flags", { _ = try NodeSyncCodec.decodeSnapshotPage(replacing(snapshot.page, "\"flags\":[\"answered\",\"seen\"]", "\"flags\":[\"seen\",\"answered\"]")) }),
            ("oversized cursor", { _ = try NodeSyncCodec.decodeSnapshotRequest(replacing(snapshot.request, "\"after\":\"\"", oversizedAfter)) }),
            ("padded base64url", { _ = try NodeSyncCodec.decodeMutationRequest(replacing(mutation.request, "\"canonicalOperation\":\"", "\"canonicalOperation\":\"=")) }),
            ("body-size mismatch", { _ = try NodeSyncCodec.decodeMutationRequest(replacing(mutation.request, "\"canonicalOperationBytes\":\(mutation.canonicalOperation.count)", "\"canonicalOperationBytes\":\(mutation.canonicalOperation.count - 1)")) }),
        ]
        for (name, operation) in cases {
            XCTAssertThrowsError(try operation(), name)
        }
    }

    func testAllFamilyVectorsRoundTripExactly() throws {
        let vectors = try ProtocolVectors.load()
        try roundTrip(vectors["snapshotRequest"], NodeSyncCodec.decodeSnapshotRequest, NodeSyncCodec.encodeSnapshotRequest)
        try roundTrip(vectors["deltaRequest"], NodeSyncCodec.decodeDeltaRequest, NodeSyncCodec.encodeDeltaRequest)
        try roundTrip(vectors["searchRequest"], NodeSyncCodec.decodeSearchRequest, NodeSyncCodec.encodeSearchRequest)
        try roundTrip(vectors["messageRequest"], NodeSyncCodec.decodeMessageRequest, NodeSyncCodec.encodeMessageRequest)
        try roundTrip(vectors["attachmentRequest"], NodeSyncCodec.decodeAttachmentRequest, NodeSyncCodec.encodeAttachmentRequest)
        try roundTrip(vectors["googleProvisionRequest"], NodeSyncCodec.decodeGoogleProvisionRequest, NodeSyncCodec.encodeGoogleProvisionRequest)
        try roundTrip(vectors["mailboxAssignmentsRequest"], NodeSyncCodec.decodeMailboxAssignmentsRequest, NodeSyncCodec.encodeMailboxAssignmentsRequest)
        try roundTrip(vectors["statusRequest"], NodeSyncCodec.decodeStatusRequest, NodeSyncCodec.encodeStatusRequest)
        try roundTrip(vectors["snapshotPage"], NodeSyncCodec.decodeSnapshotPage, NodeSyncCodec.encodeSnapshotPage)
        try roundTrip(vectors["deltaPage"], NodeSyncCodec.decodeDeltaPage, NodeSyncCodec.encodeDeltaPage)
        try roundTrip(vectors["searchPage"], NodeSyncCodec.decodeSearchPage, NodeSyncCodec.encodeSearchPage)
        try roundTrip(vectors["messageResult"], NodeSyncCodec.decodeMessageResult, NodeSyncCodec.encodeMessageResult)
        try roundTrip(vectors["attachmentResult"], NodeSyncCodec.decodeAttachmentResult, NodeSyncCodec.encodeAttachmentResult)
        try roundTrip(vectors["mutationResult"], NodeSyncCodec.decodeMutationResult, NodeSyncCodec.encodeMutationResult)
        try roundTrip(vectors["googleProvisionResult"], NodeSyncCodec.decodeGoogleProvisionResult, NodeSyncCodec.encodeGoogleProvisionResult)
        try roundTrip(vectors["mailboxAssignmentsResult"], NodeSyncCodec.decodeMailboxAssignmentsResult, NodeSyncCodec.encodeMailboxAssignmentsResult)
        try roundTrip(vectors["statusResult"], NodeSyncCodec.decodeStatusResult, NodeSyncCodec.encodeStatusResult)
        try roundTrip(vectors["problem"], NodeSyncCodec.decodeProblem, NodeSyncCodec.encodeProblem)
        for wire in try ProtocolVectors.problemVectors() { try roundTrip(wire, NodeSyncCodec.decodeProblem, NodeSyncCodec.encodeProblem) }
    }
}

private func roundTrip<Value>(_ wire: Data?, _ decode: (Data) throws -> Value, _ encode: (Value) throws -> Data) throws {
    let expected = try XCTUnwrap(wire)
    XCTAssertEqual(try encode(try decode(expected)), expected, "\(Value.self)")
}

private func replacing(_ data: Data, _ target: String, _ replacement: String) -> Data {
    Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: target, with: replacement).utf8)
}

private func operation(_ variant: NodeSyncOperationVariant, signature: Data) throws -> NodeSyncOperation {
    let logicalMailboxID = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    let unsigned = try NodeSyncUnsignedOperation(accountID: "11111111-1111-4111-8111-111111111111", authorityEpoch: "2", clientID: "22222222-2222-4222-8222-222222222222", idempotencyKey: "mutation-variant", issuedAt: "2026-08-20T12:34:56Z", logicalMailboxID: logicalMailboxID, nodeID: "33333333-3333-4333-8333-333333333333", operation: variant, trustEpoch: "1")
    return try NodeSyncOperation(unsigned: unsigned, signature: signature)
}

private func message(_ source: NodeSyncMessage, inReplyTo: [String], references: [String]) -> NodeSyncMessage {
    NodeSyncMessage(attachments: source.attachments, bcc: source.bcc, cc: source.cc, flags: source.flags, from: source.from, htmlBody: source.htmlBody, id: source.id, inReplyTo: inReplyTo, labels: source.labels, receivedAt: source.receivedAt, references: references, replyTo: source.replyTo, sentAt: source.sentAt, subject: source.subject, textBody: source.textBody, threadID: source.threadID, to: source.to)
}

private func message(_ source: NodeSyncMessage, textBody: NodeSyncBody) -> NodeSyncMessage {
    NodeSyncMessage(attachments: source.attachments, bcc: source.bcc, cc: source.cc, flags: source.flags, from: source.from, htmlBody: source.htmlBody, id: source.id, inReplyTo: source.inReplyTo, labels: source.labels, receivedAt: source.receivedAt, references: source.references, replyTo: source.replyTo, sentAt: source.sentAt, subject: source.subject, textBody: textBody, threadID: source.threadID, to: source.to)
}

private func identifiers(_ prefix: String, count: Int) -> [String] {
    (0..<count).map { String(format: "%@-%03d", prefix, $0) }
}

private func resizedCanonicalFamily(_ raw: Data, count: Int) throws -> Data {
    let text = String(decoding: raw, as: UTF8.self)
    let emptyBody = text.replacingOccurrences(of: "\"value\":\"Done\"", with: "\"value\":\"\"")
    let replacementCount = count - Data(emptyBody.utf8).count
    guard replacementCount >= 0 else { throw VectorError.invalid }
    let result = Data(emptyBody.replacingOccurrences(of: "\"value\":\"\"", with: "\"value\":\"" + String(repeating: "x", count: replacementCount) + "\"", options: [], range: nil).utf8)
    guard result.count == count else { throw VectorError.invalid }
    return result
}

private struct SnapshotVector {
    let request, page: Data

    static func load() throws -> Self {
        let root = try vectorRoot("snapshot-v1.json")
        guard root["kind"] as? String == "node-sync-v1.snapshot-vector", root["schemaVersion"] as? Int == 1,
              let request = root["snapshotRequest"] as? String, let page = root["snapshotPage"] as? String else {
            throw VectorError.invalid
        }
        return try Self(request: base64URL(request), page: base64URL(page))
    }
}

private struct MutationVector {
    let canonicalOperation, request, transcript: Data
    let operations: [Operation]

    struct Operation {
        let name: String
        let canonicalOperation: Data
        let transcript: Data
    }

    static func load() throws -> Self {
        let root = try vectorRoot("mutation-v1.json")
        guard root["kind"] as? String == "node-sync-v1.mutation-vector", root["schemaVersion"] as? Int == 1,
              let operation = root["canonicalOperation"] as? String, let template = root["mutationRequestTemplate"] as? String, let transcript = root["transcript"] as? String else {
            throw VectorError.invalid
        }
        let canonicalOperation = try base64URL(operation)
        let request = Data(template.replacingOccurrences(of: "$canonicalOperation", with: operation).utf8)
        guard try NodeSyncCodec.encodeMutationRequest(NodeSyncMutationRequest(canonicalOperation: canonicalOperation)) == request else { throw VectorError.invalid }
        guard let rawOperations = root["operations"] as? [[String: String]], rawOperations.count == 9 else { throw VectorError.invalid }
        let operations = try rawOperations.map { value in
            guard let name = value["name"], let operation = value["canonicalOperation"], let transcript = value["transcript"] else { throw VectorError.invalid }
            return Operation(name: name, canonicalOperation: try base64URL(operation), transcript: try base64URL(transcript))
        }
        return Self(canonicalOperation: canonicalOperation, request: request, transcript: try base64URL(transcript), operations: operations)
    }
}

private struct ProtocolVectors {
    let families: [String: Data]

    subscript(_ name: String) -> Data? { families[name] }

    static func load() throws -> Self {
        let root = try vectorRoot("protocol-v1.json")
        guard root["kind"] as? String == "node-sync-v1.protocol-vectors", root["schemaVersion"] as? Int == 1,
              let rawFamilies = root["families"] as? [String: String], rawFamilies.count == 18 else {
            throw VectorError.invalid
        }
        return Self(families: rawFamilies.mapValues { Data($0.utf8) })
    }

    static func problemVectors() throws -> [Data] {
        let root = try vectorRoot("protocol-v1.json")
        guard let problems = root["problems"] as? [String], problems.count == 5 else { throw VectorError.invalid }
        return problems.map { Data($0.utf8) }
    }
}

private struct ProtocolBounds {
    struct Bytes { let acceptedBytes: Int; let rejectedBytes: Int }
    struct Items { let acceptedItems: Int; let rejectedItems: Int }
    struct Limit { let accepted: Int; let rejected: Int }

    let cursor: Bytes
    let canonicalFamily: Bytes
    let messageReference: Bytes
    let mutationIdentifierArray: Items
    let pageLimit: Limit
    let searchQuery: Bytes

    static func load() throws -> Self {
        let root = try vectorRoot("protocol-v1.json")
        guard let bounds = root["bounds"] as? [String: [String: Int]],
              let canonicalFamily = bounds["canonicalFamily"], let cursor = bounds["cursor"], let messageReference = bounds["messageReference"],
              let mutationIdentifierArray = bounds["mutationIdentifierArray"], let pageLimit = bounds["pageLimit"], let searchQuery = bounds["searchQuery"],
              let canonicalAccepted = canonicalFamily["acceptedBytes"], let canonicalRejected = canonicalFamily["rejectedBytes"],
              let cursorAccepted = cursor["acceptedBytes"], let cursorRejected = cursor["rejectedBytes"],
              let referenceAccepted = messageReference["acceptedBytes"], let referenceRejected = messageReference["rejectedBytes"],
              let itemsAccepted = mutationIdentifierArray["acceptedItems"], let itemsRejected = mutationIdentifierArray["rejectedItems"],
              let limitAccepted = pageLimit["accepted"], let limitRejected = pageLimit["rejected"],
              let queryAccepted = searchQuery["acceptedBytes"], let queryRejected = searchQuery["rejectedBytes"],
              canonicalAccepted == 1_048_576, canonicalRejected == 1_048_577,
              cursorAccepted == 4_096, cursorRejected == 4_097, referenceAccepted == 998, referenceRejected == 999,
              itemsAccepted == 200, itemsRejected == 201, limitAccepted == 200, limitRejected == 201,
              queryAccepted == 4_096, queryRejected == 4_097 else {
            throw VectorError.invalid
        }
        return Self(cursor: Bytes(acceptedBytes: cursorAccepted, rejectedBytes: cursorRejected), canonicalFamily: Bytes(acceptedBytes: canonicalAccepted, rejectedBytes: canonicalRejected), messageReference: Bytes(acceptedBytes: referenceAccepted, rejectedBytes: referenceRejected), mutationIdentifierArray: Items(acceptedItems: itemsAccepted, rejectedItems: itemsRejected), pageLimit: Limit(accepted: limitAccepted, rejected: limitRejected), searchQuery: Bytes(acceptedBytes: queryAccepted, rejectedBytes: queryRejected))
    }
}

private func vectorRoot(_ name: String) throws -> [String: Any] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-sync-v1/fixtures/").appendingPathComponent(name)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
}

private func base64URL(_ value: String) throws -> Data {
    guard !value.contains("=") else { throw VectorError.invalid }
    let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let result = Data(base64Encoded: padded), result.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value else {
        throw VectorError.invalid
    }
    return result
}

private enum VectorError: Error {
    case invalid
}
