import Foundation
import XCTest
import CryptoKit
import Observation
import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
import PlainpostCore
import PlainpostNodeTransport
@testable import PlainpostNotificationRuntime

final class NotificationRuntimeTests: XCTestCase {
    func testDirectPolicyClientReadsVersionZeroRichDefaultAndOpaqueMailboxSnapshot() async throws {
        let mailbox = Data(repeating: 0x2A, count: 32)
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "rich", "version": "0", "scopeVersion": "0", "override": false],
            "mailboxes": [[
                "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox),
                "policy": "generic", "version": "3", "scopeVersion": "3", "override": true
            ]]
        ])
        let transport = DirectPolicyTransport(response: response)
        let client = try makeDirectPolicyClient(transport: transport)

        let snapshot = try await client.snapshot()

        XCTAssertEqual(snapshot.defaultPolicy.mode, .richPreview)
        XCTAssertEqual(snapshot.defaultPolicy.version, "0")
        XCTAssertEqual(snapshot.defaultPolicy.scopeVersion, "0")
        XCTAssertEqual(snapshot.mailboxPolicies.count, 1)
        XCTAssertEqual(snapshot.mailboxPolicies[0].logicalMailboxID?.rawValue, mailbox)
        XCTAssertEqual(snapshot.mailboxPolicies[0].mode, .generic)
        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path, "/v1/notifications/direct-policies")
        XCTAssertNil(request?.httpBody)
    }

    func testDirectPolicyClientReadsPersistedPositiveDefaultWithNoMailboxScope() async throws {
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "generic", "version": "7", "scopeVersion": "0", "override": false],
            "mailboxes": []
        ])
        let client = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: response))

        let snapshot = try await client.snapshot()

        XCTAssertEqual(snapshot.defaultPolicy.mode, .generic)
        XCTAssertEqual(snapshot.defaultPolicy.version, "7")
        XCTAssertEqual(snapshot.defaultPolicy.scopeVersion, "0")
    }

    func testDirectMailboxReadPreservesAbsentTombstoneAndActiveScopePredecessors() async throws {
        let absent = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x30, count: 32)))
        let tombstone = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x31, count: 32)))
        let active = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x32, count: 32)))
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "generic", "version": "7", "scopeVersion": "0", "override": false],
            "mailboxes": [
                ["logicalMailboxID": AccountWireCodec.encodeBase64URL(tombstone.rawValue), "policy": "generic", "version": "7", "scopeVersion": "4", "override": false],
                ["logicalMailboxID": AccountWireCodec.encodeBase64URL(active.rawValue), "policy": "rich", "version": "9", "scopeVersion": "9", "override": true]
            ]
        ])
        let client = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: response))

        let absentState = try await client.directPolicy(for: absent)
        let tombstoneState = try await client.directPolicy(for: tombstone)
        let activeState = try await client.directPolicy(for: active)

        XCTAssertEqual(absentState, try DirectNotificationPolicyState(logicalMailboxID: absent, mode: .generic, version: "7", scopeVersion: "0", override: false))
        XCTAssertEqual(tombstoneState, try DirectNotificationPolicyState(logicalMailboxID: tombstone, mode: .generic, version: "7", scopeVersion: "4", override: false))
        XCTAssertEqual(activeState, try DirectNotificationPolicyState(logicalMailboxID: active, mode: .richPreview, version: "9", scopeVersion: "9", override: true))
    }

    func testDirectStateConstructorRejectsNonRichZeroAndIncoherentMailboxStates() throws {
        XCTAssertThrowsError(try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .generic, version: "0", scopeVersion: "0", override: false))
        XCTAssertThrowsError(try DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "0", scopeVersion: "1", override: false))
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x33, count: 32)))
        XCTAssertThrowsError(try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: .generic, version: "0", scopeVersion: "3", override: true))
        XCTAssertThrowsError(try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: .generic, version: "4", scopeVersion: "3", override: true))
        XCTAssertThrowsError(try DirectNotificationPolicyMailboxState(logicalMailboxID: mailbox, mode: .generic, version: "0", scopeVersion: "3", override: true))
    }

    func testDirectMutationRejectsSubstitutedModeAndNextVersion() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x34, count: 32)))
        let wrongMode = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "sender_subject", "version": "2", "scopeVersion": "2", "override": true
        ])
        let wrongModeClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: wrongMode))
        let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "1", idempotencyKey: "wrong-mode")
        do {
            _ = try await wrongModeClient.updateDirectNotificationPolicy(request)
            XCTFail("Central substituted mailbox mode was accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }

        let wrongVersion = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "3", "scopeVersion": "3", "override": true
        ])
        let wrongVersionClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: wrongVersion))
        do {
            _ = try await wrongVersionClient.updateDirectNotificationPolicy(request)
            XCTFail("Central substituted mailbox version was accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testDirectMutationRejectsOverflowBeforeSendingWireRequest() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x35, count: 32)))
        let transport = DirectPolicyTransport(response: try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "65535", "scopeVersion": "65535", "override": true
        ]))
        let client = try makeDirectPolicyClient(transport: transport)
        let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "65535", idempotencyKey: "overflow-send")
        do {
            _ = try await client.updateDirectNotificationPolicy(request)
            XCTFail("overflowing Direct CAS was sent")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
        let requests = await transport.requestsSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDirectPolicyDecoderAcceptsMaximumVersionAndRejectsOverflow() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2F, count: 32)))
        XCTAssertNoThrow(try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "65535", idempotencyKey: "max-version"))
        XCTAssertThrowsError(try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "65536", idempotencyKey: "overflow-version"))
        let valid = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "generic", "version": "65535", "scopeVersion": "0", "override": false],
            "mailboxes": []
        ])
        let validClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: valid))
        let validSnapshot = try await validClient.snapshot()
        XCTAssertEqual(validSnapshot.defaultPolicy.version, "65535")

        let invalid = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "generic", "version": "65536", "scopeVersion": "0", "override": false],
            "mailboxes": []
        ])
        let invalidClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: invalid))
        do {
            _ = try await invalidClient.snapshot()
            XCTFail("Central version overflow was accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testDirectPolicyClientSendsStableDigestWithoutAccountOrCredentialFields() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2B, count: 32)))
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "1", "scopeVersion": "1", "override": true
        ])
        let transport = DirectPolicyTransport(response: response)
        let client = try makeDirectPolicyClient(transport: transport)
        let request = try DirectNotificationPolicyUpdateRequest(
            logicalMailboxID: mailbox, mode: .generic, expectedVersion: "0", idempotencyKey: "stable-key"
        )

        _ = try await client.updateDirectNotificationPolicy(request)
        _ = try await client.updateDirectNotificationPolicy(request)

        let requests = await transport.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/v1/notifications/direct-policies/mailboxes/" + AccountWireCodec.encodeBase64URL(mailbox.rawValue))
        let body = try XCTUnwrap(requests[0].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["kind", "expectedVersion", "policy", "requestNonce", "requestDigest"]))
        XCTAssertNil(object["accountID"])
        XCTAssertNil(object["accessToken"])
        XCTAssertEqual(object["kind"] as? String, "notification.direct-policy-update.v1")
        XCTAssertEqual(object["expectedVersion"] as? String, "0")
        XCTAssertEqual(object["policy"] as? String, "generic")
        let nonce = try XCTUnwrap(object["requestNonce"] as? String)
        let digest = try XCTUnwrap(object["requestDigest"] as? String)
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(nonce, exactBytes: 32).count, 32)
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(digest, exactBytes: 32).count, 32)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testDirectPolicyClientMapsCentralStatusClassesAndUsesDeleteForClear() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2C, count: 32)))
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "rich", "version": "3", "scopeVersion": "3", "override": false
        ])
        let transport = DirectPolicyTransport(response: response)
        let client = try makeDirectPolicyClient(transport: transport)
        let request = try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: mailbox, clear: true, expectedVersion: "2", idempotencyKey: "clear-key"
        )

        _ = try await client.updateNotificationPolicy(request)

        let sent = await transport.lastRequest()
        XCTAssertEqual(sent?.httpMethod, "DELETE")
        XCTAssertEqual(sent?.url?.path, "/v1/notifications/direct-policies/mailboxes/" + AccountWireCodec.encodeBase64URL(mailbox.rawValue))
    }

    func testDirectPolicyClientAcceptsMailboxClearWithAbsentDefaultTombstone() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x2D, count: 32)))
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "rich", "version": "0", "scopeVersion": "4", "override": false
        ])
        let client = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: response))
        let request = try DirectNotificationPolicyUpdateRequest(
            logicalMailboxID: mailbox, mode: .richPreview, clear: true,
            expectedVersion: "3", idempotencyKey: "clear-absent-default"
        )

        _ = try await client.updateDirectNotificationPolicy(request)
    }

    func testDirectPolicyClientClassifiesUnauthorizedConflictAndUnavailableStatusOnly() async throws {
        for (status, expected) in [(401, NotificationPolicyRemoteError.unauthorized), (409, NotificationPolicyRemoteError.conflict), (503, NotificationPolicyRemoteError.unavailable)] {
            let transport = DirectPolicyTransport(response: AccountHTTPResponse(statusCode: status, headers: [:], body: Data()))
            let client = try makeDirectPolicyClient(transport: transport)
            do {
                _ = try await client.snapshot()
                XCTFail("Expected status \(status) to fail")
            } catch let error as NotificationPolicyRemoteError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testDirectPolicyClientRejectsMalformedStatesDuplicateKeysAndNumericBooleans() async throws {
        let malformed = [
            #"{"kind":"notification.direct-policy-snapshot.v0","default":{"policy":"rich","version":"0","scopeVersion":"0","override":false},"mailboxes":[]}"#,
            #"{"kind":"notification.direct-policy-snapshot.v1","default":{"policy":"off","version":"0","scopeVersion":"0","override":false},"mailboxes":[]}"#,
            #"{"kind":"notification.direct-policy-snapshot.v1","default":{"policy":"rich","version":"0","scopeVersion":"1","override":false},"mailboxes":[]}"#,
            #"{"kind":"notification.direct-policy-snapshot.v1","default":{"policy":"rich","version":"0","scopeVersion":"0","override":1},"mailboxes":[]}"#,
            #"{"kind":"notification.direct-policy-snapshot.v1","default":{"policy":"rich","version":"0","scopeVersion":"0","override":false},"mailboxes":[],"mailboxes":[]}"#
        ]
        for json in malformed {
            let client = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(json)))
            do {
                _ = try await client.snapshot()
                XCTFail("malformed Central snapshot was accepted: \(json)")
            } catch let error as NotificationPolicyRemoteError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }

        let mailbox = AccountWireCodec.encodeBase64URL(Data(repeating: 0x38, count: 32))
        let row = "{\"logicalMailboxID\":\"\(mailbox)\",\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false}"
        let inherited = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[\(row)]}"
        let inheritedClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(inherited)))
        let inheritedSnapshot = try await inheritedClient.snapshot()
        XCTAssertTrue(inheritedSnapshot.mailboxPolicies.isEmpty)
        XCTAssertEqual(inheritedSnapshot.mailboxStates.count, 1)
        XCTAssertEqual(inheritedSnapshot.mailboxStates[0].version, "0")
        XCTAssertEqual(inheritedSnapshot.mailboxStates[0].scopeVersion, "0")

        let tombstoneMailbox = AccountWireCodec.encodeBase64URL(Data(repeating: 0x3A, count: 32))
        let tombstone = "{\"logicalMailboxID\":\"\(tombstoneMailbox)\",\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"4\",\"override\":false}"
        let noDefaultTombstone = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[\(tombstone)]}"
        let tombstoneClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(noDefaultTombstone)))
        let tombstoneSnapshot = try await tombstoneClient.snapshot()
        XCTAssertTrue(tombstoneSnapshot.mailboxPolicies.isEmpty)
        XCTAssertEqual(tombstoneSnapshot.mailboxStates[0].scopeVersion, "4")

        let persistedMailbox = AccountWireCodec.encodeBase64URL(Data(repeating: 0x3B, count: 32))
        let persisted = "{\"logicalMailboxID\":\"\(persistedMailbox)\",\"policy\":\"generic\",\"version\":\"7\",\"scopeVersion\":\"9\",\"override\":false}"
        let persistedDefault = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"generic\",\"version\":\"7\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[\(persisted)]}"
        let persistedClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(persistedDefault)))
        let persistedSnapshot = try await persistedClient.snapshot()
        XCTAssertTrue(persistedSnapshot.mailboxPolicies.isEmpty)
        XCTAssertEqual(persistedSnapshot.mailboxStates[0].version, "7")
        XCTAssertEqual(persistedSnapshot.mailboxStates[0].scopeVersion, "9")

        let hundredRows = (0..<100).map { index in
            let mailbox = AccountWireCodec.encodeBase64URL(Data(repeating: UInt8(index + 1), count: 32))
            return "{\"logicalMailboxID\":\"\(mailbox)\",\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false}"
        }.joined(separator: ",")
        let exactlyHundred = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[\(hundredRows)]}"
        let hundredClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(exactlyHundred)))
        let hundredSnapshot = try await hundredClient.snapshot()
        XCTAssertEqual(hundredSnapshot.mailboxStates.count, 100)

        let invalidMailbox = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[{\"logicalMailboxID\":\"%%%\",\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false}]}"
        let invalidMailboxClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(invalidMailbox)))
        do {
            _ = try await invalidMailboxClient.snapshot()
            XCTFail("invalid mailbox encoding was accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .invalidResponse)
        }

        for mailboxString in [
            AccountWireCodec.encodeBase64URL(Data(repeating: 0x41, count: 31)),
            AccountWireCodec.encodeBase64URL(Data(repeating: 0x42, count: 33)),
            AccountWireCodec.encodeBase64URL(Data(repeating: 0x43, count: 32)) + "="
        ] {
            let malformedLength = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[{\"logicalMailboxID\":\"\(mailboxString)\",\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false}]}"
            let client = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(malformedLength)))
            do {
                _ = try await client.snapshot()
                XCTFail("invalid mailbox length/padding was accepted")
            } catch let error as NotificationPolicyRemoteError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }

        let rows = String(repeating: row + ",", count: 100) + row
        let tooMany = "{\"kind\":\"notification.direct-policy-snapshot.v1\",\"default\":{\"policy\":\"rich\",\"version\":\"0\",\"scopeVersion\":\"0\",\"override\":false},\"mailboxes\":[\(rows)]}"
        let tooManyClient = try makeDirectPolicyClient(transport: DirectPolicyTransport(response: directPolicyRawResponse(tooMany)))
        do {
            _ = try await tooManyClient.snapshot()
            XCTFail("101 mailbox rows were accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testDirectPolicyDigestMatchesFixedVectorAndBindsEveryField() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x39, count: 32)))
        let result = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "1", "scopeVersion": "1", "override": true
        ])
        let transport = DirectPolicyTransport(response: result)
        let client = try makeDirectPolicyClient(transport: transport)
        let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "0", idempotencyKey: "digest-vector")
        _ = try await client.updateDirectNotificationPolicy(request)
        let sent = await transport.lastRequest()
        let body = try XCTUnwrap(sent?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let nonce = Data(SHA256.hash(data: Data("digest-vector".utf8)))
        let expected = directPolicyDigestOracle(account: "00112233-4455-6677-8899-aabbccddeeff", actor: "11111111-2222-3333-4444-555555555555", mailbox: mailbox.rawValue, operation: "set", policy: "generic", expectedVersion: 0, nonce: nonce)
        XCTAssertEqual(expected.map { String(format: "%02x", $0) }.joined(), "1342870b64aff5f71949eab1b53742ee41be291bd8ffde86298eeb7667df4c0c")
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(XCTUnwrap(object["requestNonce"] as? String), exactBytes: 32), nonce)
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(XCTUnwrap(object["requestDigest"] as? String), exactBytes: 32), expected)

        let cases: [(String, String, String, UInt16, Data)] = [
            ("00112233-4455-6677-8899-aabbccddeeff", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "generic", 0, nonce),
            ("00112233-4455-6677-8899-aabbccddeeff", "11111111-2222-3333-4444-555555555555", "generic", 1, nonce),
            ("00112233-4455-6677-8899-aabbccddeeff", "11111111-2222-3333-4444-555555555555", "off", 0, nonce),
            ("00112233-4455-6677-8899-aabbccddeeff", "11111111-2222-3333-4444-555555555555", "generic", 0, Data(repeating: 0xA1, count: 32))
        ]
        let digests = cases.map { account, actor, policy, version, changedNonce in
            directPolicyDigestOracle(account: account, actor: actor, mailbox: mailbox.rawValue, operation: "set", policy: policy, expectedVersion: version, nonce: changedNonce)
        }
        XCTAssertEqual(Set(digests).count, digests.count)
        XCTAssertTrue(digests.allSatisfy { $0 != expected })
    }

    func testDirectPolicyProductionDigestBindsScopeOperationVersionAndNonce() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x39, count: 32)))
        let setResponse = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "1", "scopeVersion": "1", "override": true
        ])
        let clearResponse = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox.rawValue),
            "policy": "generic", "version": "3", "scopeVersion": "3", "override": false
        ])
        let defaultResponse = try directPolicyResponse([
            "kind": "notification.direct-policy-result.v1",
            "policy": "generic", "version": "1", "scopeVersion": "0", "override": false
        ])
        let baseTransport = DirectPolicyTransport(response: setResponse)
        let defaultTransport = DirectPolicyTransport(response: defaultResponse)
        let clearTransport = DirectPolicyTransport(response: clearResponse)
        let otherTransport = DirectPolicyTransport(response: setResponse)
        let baseClient = try makeDirectPolicyClient(transport: baseTransport)
        let defaultClient = try makeDirectPolicyClient(transport: defaultTransport)
        let clearClient = try makeDirectPolicyClient(transport: clearTransport)
        let otherClient = try makeDirectPolicyClient(
            transport: otherTransport,
            account: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            device: "99999999-aaaa-4bbb-8ccc-dddddddddddd"
        )
        let base = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "0", idempotencyKey: "digest-vector")
        let defaultRequest = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: nil, mode: .generic, expectedVersion: "0", idempotencyKey: "digest-vector")
        let clear = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, clear: true, expectedVersion: "2", idempotencyKey: "digest-vector")
        let other = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "0", idempotencyKey: "different-nonce")
        _ = try await baseClient.updateDirectNotificationPolicy(base)
        _ = try await defaultClient.updateDirectNotificationPolicy(defaultRequest)
        _ = try await clearClient.updateDirectNotificationPolicy(clear)
        _ = try await otherClient.updateDirectNotificationPolicy(other)
        // The transports are intentionally queried independently so this
        // assertion exercises the production client's serialized request,
        // including the account/device bytes, rather than a Swift oracle.
        let baseDigest = try await requestDigest(from: baseTransport)
        let defaultDigest = try await requestDigest(from: defaultTransport)
        let clearDigest = try await requestDigest(from: clearTransport)
        let otherDigest = try await requestDigest(from: otherTransport)
        XCTAssertNotEqual(baseDigest, defaultDigest)
        XCTAssertNotEqual(baseDigest, clearDigest)
        XCTAssertNotEqual(baseDigest, otherDigest)
    }

    func testAssignmentPolicyRemoteRequiresExactMailboxAndRechecksBeforeMutation() async throws {
        let mailboxA = Data(repeating: 0x51, count: 32)
        let mailboxB = Data(repeating: 0x52, count: 32)
        let mac = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let node = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let macAssignment = NotificationProducerAssignment(logicalMailboxID: mailboxA, producerDeviceID: mac, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let nodeAssignment = NotificationProducerAssignment(logicalMailboxID: mailboxB, producerDeviceID: node, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let source = SequencedAssignmentSource([ [macAssignment, nodeAssignment], [macAssignment, nodeAssignment] ])
        let direct = AssignmentPolicySpy(mode: .richPreview)
        let nodeRemote = AssignmentPolicySpy(mode: .generic)
        let remote = NotificationAssignmentPolicyRemote(assignments: { await source.next() }, direct: direct, syncNode: nodeRemote)
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: mailboxA))
        let selectedPolicy = try await remote.notificationPolicy(for: mailbox)
        XCTAssertEqual(selectedPolicy.mode, .richPreview)
        let unknownMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x53, count: 32)))
        do {
            _ = try await remote.notificationPolicy(for: unknownMailbox)
            XCTFail("unassigned mailbox was accepted")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }

        let switchSource = SequencedAssignmentSource([[macAssignment], [nodeAssignment]])
        let switchingRemote = NotificationAssignmentPolicyRemote(assignments: { await switchSource.next() }, direct: direct, syncNode: nodeRemote)
        let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, expectedVersion: "1", idempotencyKey: "authority-recheck")
        do {
            _ = try await switchingRemote.updateNotificationPolicy(request)
            XCTFail("producer change crossed the mutation boundary")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
        let updateCount = await direct.updateCount()
        XCTAssertEqual(updateCount, 0)
    }

    func testAssignmentPolicyRemoteMaterializesMixedDefaultsInStableAuthorityOrder() async throws {
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let mac = NotificationProducerAssignment(logicalMailboxID: Data(repeating: 0x61, count: 32), producerDeviceID: macID, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let node = NotificationProducerAssignment(logicalMailboxID: Data(repeating: 0x62, count: 32), producerDeviceID: nodeID, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let source = SequencedAssignmentSource(Array(repeating: [node, mac], count: 8))
        let direct = AssignmentPolicySpy(mode: .richPreview)
        let nodeRemote = AssignmentPolicySpy(mode: .richPreview)
        let remote = NotificationAssignmentPolicyRemote(assignments: { await source.next() }, direct: direct, syncNode: nodeRemote)

        try await remote.persistDefaultPolicy(mode: .generic)

        let directUpdates = await direct.updateCount()
        let nodeUpdates = await nodeRemote.updateCount()
        XCTAssertEqual(directUpdates, 1)
        XCTAssertEqual(nodeUpdates, 1)
    }

    func testAssignmentPolicyRemoteDirectDefaultRequiresCurrentMacAuthority() async throws {
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let node = NotificationProducerAssignment(logicalMailboxID: Data(repeating: 0x63, count: 32), producerDeviceID: nodeID, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let remote = NotificationAssignmentPolicyRemote(
            assignments: { [node] }, direct: AssignmentPolicySpy(mode: .richPreview), syncNode: AssignmentPolicySpy(mode: .generic)
        )

        do {
            _ = try await remote.directDefaultPolicy()
            XCTFail("Direct default read used a stale/non-Mac authority")
        } catch let error as NotificationPolicyRemoteError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testAssignmentPolicyRemotePresentationSeamRoutesSyncNodeSetAndClear() async throws {
        let mailboxData = Data(repeating: 0x64, count: 32)
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let node = NotificationProducerAssignment(logicalMailboxID: mailboxData, producerDeviceID: nodeID, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let source = SequencedAssignmentSource(Array(repeating: [node], count: 12))
        let syncNode = AssignmentPolicySpy(mode: .generic)
        let remote = NotificationAssignmentPolicyRemote(
            assignments: { await source.next() }, direct: AssignmentPolicySpy(mode: .richPreview), syncNode: syncNode
        )
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: mailboxData))

        let initial = try await remote.notificationPolicyPresentation(for: mailbox)
        XCTAssertEqual(initial.mode, .generic)
        let set = try await remote.updateNotificationPolicyPresentation(for: mailbox, mode: .senderSubject, clear: false, idempotencyKey: "sync-set")
        XCTAssertEqual(set.mode, .senderSubject)
        let cleared = try await remote.updateNotificationPolicyPresentation(for: mailbox, mode: .senderSubject, clear: true, idempotencyKey: "sync-clear")
        XCTAssertFalse(cleared.override)
    }

    func testAssignmentPolicyRemotePresentationSeamRetainsDirectScopeAcrossClearAndRecreate() async throws {
        let mailboxData = Data(repeating: 0x65, count: 32)
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let mac = NotificationProducerAssignment(logicalMailboxID: mailboxData, producerDeviceID: macID, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let source = SequencedAssignmentSource(Array(repeating: [mac], count: 12))
        let direct = AssignmentDirectPolicySpy(mailboxID: try XCTUnwrap(LogicalMailboxID(rawValue: mailboxData)))
        let remote = NotificationAssignmentPolicyRemote(
            assignments: { await source.next() }, direct: direct, syncNode: AssignmentPolicySpy(mode: .generic)
        )
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: mailboxData))

        let fresh = try await remote.notificationPolicyPresentation(for: mailbox)
        XCTAssertEqual(fresh.scopeVersion, "0")
        XCTAssertFalse(fresh.override)
        let first = try await remote.updateNotificationPolicyPresentation(for: mailbox, mode: .generic, clear: false, idempotencyKey: "direct-set")
        XCTAssertEqual(first.scopeVersion, "1")
        XCTAssertTrue(first.override)
        let tombstone = try await remote.updateNotificationPolicyPresentation(for: mailbox, mode: .generic, clear: true, idempotencyKey: "direct-clear")
        XCTAssertEqual(tombstone.scopeVersion, "2")
        XCTAssertFalse(tombstone.override)
        let recreated = try await remote.updateNotificationPolicyPresentation(for: mailbox, mode: .senderSubject, clear: false, idempotencyKey: "direct-recreate")
        XCTAssertEqual(recreated.scopeVersion, "3")
        XCTAssertTrue(recreated.override)
    }

    func testAssignmentPolicyRemoteLegacyDirectFallbackSendsNodeClear() async throws {
        let mailboxData = Data(repeating: 0x66, count: 32)
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let mac = NotificationProducerAssignment(logicalMailboxID: mailboxData, producerDeviceID: macID, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        let source = SequencedAssignmentSource(Array(repeating: [mac], count: 4))
        let direct = AssignmentPolicySpy(mode: .generic)
        let remote = NotificationAssignmentPolicyRemote(assignments: { await source.next() }, direct: direct, syncNode: AssignmentPolicySpy(mode: .generic))
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: mailboxData))
        let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: .generic, clear: true, expectedVersion: "1", idempotencyKey: "fallback-clear")

        let result = try await remote.updateDirectNotificationPolicy(request)
        XCTAssertFalse(result.override)
        let lastClear = await direct.lastClear()
        XCTAssertTrue(lastClear)
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorRestoresRowsAndRetriesFailures() async throws {
        let directMailbox = Data(repeating: 0x67, count: 32)
        let syncMailbox = Data(repeating: 0x68, count: 32)
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let assignments = [
            NotificationProducerAssignment(logicalMailboxID: directMailbox, producerDeviceID: macID, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32)),
            NotificationProducerAssignment(logicalMailboxID: syncMailbox, producerDeviceID: nodeID, kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 2, count: 32))
        ]
        let directID = try XCTUnwrap(LogicalMailboxID(rawValue: directMailbox))
        let syncID = try XCTUnwrap(LogicalMailboxID(rawValue: syncMailbox))
        let coordinator = NotificationPolicyPresentationCoordinator()
        var shouldFail = true
        let initial = try await coordinator.refresh(
            assignments: { assignments },
            providerMailboxes: [NotificationPolicyProviderMailbox(logicalMailboxID: syncID, label: "Inbox")],
            policyProvider: { mailbox in
                if shouldFail && mailbox == directID { throw NotificationPolicyRemoteError.unavailable }
                return try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: mailbox == directID ? "0" : "1", override: false)
            }
        )
        XCTAssertEqual(initial.authority, .mixed)
        XCTAssertEqual(initial.rows.map(\.label), ["Mailbox 1", "Inbox"])
        XCTAssertTrue(initial.rows.first?.loadState == .error(.unavailable))
        shouldFail = false
        let retried = try await coordinator.retry(directID, policyProvider: { mailbox in
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: "0", override: false)
        })
        XCTAssertTrue(retried.rows.first?.loadState.isLoaded == true)
        let failedRefresh = try await coordinator.refreshAfterConflict(directID, policyProvider: { _ in
            throw NotificationPolicyRemoteError.conflict
        })
        XCTAssertTrue(failedRefresh.rows.first?.loadState == .error(.conflict))
        XCTAssertEqual(failedRefresh.message, NotificationPolicyPresentationLoadError.conflict.message)
        let successfulRefresh = try await coordinator.refreshAfterConflict(directID, policyProvider: { mailbox in
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .senderSubject, version: "2", scopeVersion: "0", override: false)
        })
        XCTAssertTrue(successfulRefresh.rows.first?.loadState.isLoaded == true)
        XCTAssertEqual(successfulRefresh.message, "Mailbox notification policy changed elsewhere; refreshed.")
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorDerivesEachAuthorityAndFiltersRows() async throws {
        let macMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x69, count: 32)))
        let syncMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6A, count: 32)))
        let strayMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6B, count: 32)))
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let nodeID = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        func assignment(_ mailbox: LogicalMailboxID, _ kind: NotificationProducerKind, _ device: AccountDeviceID) -> NotificationProducerAssignment {
            NotificationProducerAssignment(logicalMailboxID: mailbox.rawValue, producerDeviceID: device, kind: kind, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        let policy: (LogicalMailboxID) async throws -> NotificationPolicyPresentationState = { mailbox in
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: mailbox == macMailbox ? "0" : "1", override: false)
        }

        let mac = try await coordinator.refresh(assignments: { [assignment(macMailbox, .mac, macID)] }, providerMailboxes: [], policyProvider: policy)
        XCTAssertEqual(mac.authority, .mac)
        XCTAssertEqual(mac.rows.map(\.label), ["Mailbox 1"])
        let sync = try await coordinator.refresh(
            assignments: { [assignment(syncMailbox, .syncNode, nodeID)] },
            providerMailboxes: [NotificationPolicyProviderMailbox(logicalMailboxID: syncMailbox, label: "Inbox"), NotificationPolicyProviderMailbox(logicalMailboxID: strayMailbox, label: "Stray")],
            policyProvider: policy
        )
        XCTAssertEqual(sync.authority, .syncNode)
        XCTAssertEqual(sync.rows.map(\.label), ["Inbox"])
        let mixed = try await coordinator.refresh(
            assignments: { [assignment(macMailbox, .mac, macID), assignment(syncMailbox, .syncNode, nodeID)] },
            providerMailboxes: [NotificationPolicyProviderMailbox(logicalMailboxID: syncMailbox, label: "Inbox")],
            policyProvider: policy
        )
        XCTAssertEqual(mixed.authority, .mixed)
        XCTAssertEqual(mixed.rows.map(\.label), ["Mailbox 1", "Inbox"])
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorObservationTracksSnapshotChanges() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6C, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue,
            producerDeviceID: device,
            kind: .mac,
            generation: 1,
            trustEpoch: 1,
            trustRevision: 1,
            trustHead: Data(repeating: 1, count: 32)
        )
        let coordinator = NotificationPolicyPresentationCoordinator()
        _ = try await coordinator.refresh(
            assignments: { [assignment] },
            providerMailboxes: [],
            policyProvider: { mailbox in
                try NotificationPolicyPresentationState(
                    logicalMailboxID: mailbox,
                    mode: .generic,
                    version: "1",
                    scopeVersion: "0",
                    override: false
                )
            }
        )

        let changes = ObservationChangeCounter()
        withObservationTracking({
            _ = coordinator.current().rows
        }, onChange: {
            changes.value += 1
        })
        coordinator.setError(mailbox, error: .unavailable)

        XCTAssertEqual(changes.value, 1, "the production coordinator must invalidate SwiftUI observation when its snapshot changes")
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorPublishesLoadingErrorRetryAndLoadedStates() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6D, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue,
            producerDeviceID: device,
            kind: .mac,
            generation: 1,
            trustEpoch: 1,
            trustRevision: 1,
            trustHead: Data(repeating: 1, count: 32)
        )
        let coordinator = NotificationPolicyPresentationCoordinator()
        let gate = CoordinatorGate()
        let observations = ObservationChangeCounter()
        withObservationTracking({ _ = coordinator.current().rows }, onChange: { observations.value += 1 })

        let refreshTask = Task {
            try await coordinator.refresh(
                assignments: { [assignment] },
                providerMailboxes: [],
                policyProvider: { _ in
                    await gate.wait()
                    throw NotificationPolicyRemoteError.unavailable
                }
            )
        }
        await gate.waitUntilEntered()

        XCTAssertTrue(coordinator.current().rows.allSatisfy { $0.loadState == .loading })
        XCTAssertEqual(observations.value, 1, "the real coordinator must publish the loading state while its loader is suspended")
        await gate.release()
        let failed = try await refreshTask.value
        XCTAssertEqual(failed.rows.first?.loadState, .error(.unavailable))

        let retryGate = CoordinatorGate()
        let retryTask = Task {
            try await coordinator.retry(mailbox, policyProvider: { mailbox in
                await retryGate.wait()
                return try NotificationPolicyPresentationState(
                    logicalMailboxID: mailbox,
                    mode: .generic,
                    version: "1",
                    scopeVersion: "0",
                    override: false
                )
            })
        }
        await retryGate.waitUntilEntered()
        XCTAssertEqual(coordinator.current().rows.first?.loadState, .loading)
        await retryGate.release()
        let loaded = try await retryTask.value
        XCTAssertTrue(loaded.rows.first?.loadState.isLoaded == true)
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorCancellationRestoresPriorState() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6E, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let assignment = NotificationProducerAssignment(
            logicalMailboxID: mailbox.rawValue,
            producerDeviceID: device,
            kind: .mac,
            generation: 1,
            trustEpoch: 1,
            trustRevision: 1,
            trustHead: Data(repeating: 1, count: 32)
        )
        let coordinator = NotificationPolicyPresentationCoordinator()
        _ = try await coordinator.refresh(
            assignments: { [assignment] },
            providerMailboxes: [],
            policyProvider: { mailbox in
                try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: "0", override: false)
            }
        )
        let gate = CoordinatorGate()
        let retryTask = Task {
            try await coordinator.retry(mailbox, policyProvider: { mailbox in
                await gate.wait()
                return try NotificationPolicyPresentationState(
                    logicalMailboxID: mailbox,
                    mode: .generic,
                    version: "1",
                    scopeVersion: "0",
                    override: false
                )
            })
        }
        await gate.waitUntilEntered()
        retryTask.cancel()
        await gate.release()
        do {
            _ = try await retryTask.value
            XCTFail("cancellation must propagate from the production coordinator")
        } catch is CancellationError {
            // Expected: cancellation is not a policy-unavailable result.
        }
        XCTAssertTrue(coordinator.current().rows.first?.loadState.isLoaded == true)
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorPropagatesSupersededRetryCancellation() async throws {
        let firstMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x71, count: 32)))
        let secondMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x72, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        func assignment(_ mailbox: LogicalMailboxID) -> NotificationProducerAssignment {
            NotificationProducerAssignment(logicalMailboxID: mailbox.rawValue, producerDeviceID: device, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        }
        func state(_ mailbox: LogicalMailboxID) throws -> NotificationPolicyPresentationState {
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: "0", override: false)
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        _ = try await coordinator.refresh(assignments: { [assignment(firstMailbox)] }, providerMailboxes: [], policyProvider: { try state($0) })
        let retryGate = CoordinatorGate()
        let retryTask = Task {
            try await coordinator.retry(firstMailbox, policyProvider: { mailbox in
                await retryGate.wait()
                return try state(mailbox)
            })
        }
        await retryGate.waitUntilEntered()

        _ = try await coordinator.refresh(assignments: { [assignment(secondMailbox)] }, providerMailboxes: [], policyProvider: { try state($0) })
        retryTask.cancel()
        await retryGate.release()
        do {
            _ = try await retryTask.value
            XCTFail("a canceled superseded retry must still propagate CancellationError")
        } catch is CancellationError {
            // Expected: stale completion is ignored, but cancellation is not swallowed.
        }
        XCTAssertTrue(coordinator.current().rows.allSatisfy { $0.loadState.isLoaded })
        XCTAssertEqual(coordinator.current().rows.map(\.logicalMailboxID), [secondMailbox])
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorCanceledSupersededRefreshRestoresSettledSnapshot() async throws {
        let firstMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x73, count: 32)))
        let secondMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x74, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        func assignment(_ mailbox: LogicalMailboxID) -> NotificationProducerAssignment {
            NotificationProducerAssignment(logicalMailboxID: mailbox.rawValue, producerDeviceID: device, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        }
        func state(_ mailbox: LogicalMailboxID) throws -> NotificationPolicyPresentationState {
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: "0", override: false)
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        let firstGate = CoordinatorGate()
        let firstRefresh = Task {
            try await coordinator.refresh(assignments: { [assignment(firstMailbox)] }, providerMailboxes: [], policyProvider: { mailbox in
                await firstGate.wait()
                return try state(mailbox)
            })
        }
        await firstGate.waitUntilEntered()
        XCTAssertTrue(coordinator.current().rows.contains { $0.loadState == .loading })

        let secondGate = CoordinatorGate()
        let canceledRefresh = Task {
            try await coordinator.refresh(assignments: { [assignment(secondMailbox)] }, providerMailboxes: [], policyProvider: { mailbox in
                await secondGate.wait()
                return try state(mailbox)
            })
        }
        await secondGate.waitUntilEntered()
        canceledRefresh.cancel()
        await secondGate.release()
        do {
            _ = try await canceledRefresh.value
            XCTFail("a canceled refresh must propagate CancellationError even when superseded work exists")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(coordinator.current().rows.contains { $0.loadState == .loading })
        await firstGate.release()
        _ = try await firstRefresh.value
        XCTAssertFalse(coordinator.current().rows.contains { $0.loadState == .loading })
    }

    @MainActor
    func testCanceledRefreshRestoresOnlyOwnedRowsAndPreservesNewerMailboxUpdate() async throws {
        let firstMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x75, count: 32)))
        let secondMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x76, count: 32)))
        let device = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        func assignment(_ mailbox: LogicalMailboxID) -> NotificationProducerAssignment {
            NotificationProducerAssignment(logicalMailboxID: mailbox.rawValue, producerDeviceID: device, kind: .mac, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 1, count: 32))
        }
        func state(_ mailbox: LogicalMailboxID, version: String) throws -> NotificationPolicyPresentationState {
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: version, scopeVersion: "0", override: false)
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        _ = try await coordinator.refresh(
            assignments: { [assignment(firstMailbox), assignment(secondMailbox)] },
            providerMailboxes: [],
            policyProvider: { mailbox in try state(mailbox, version: "1") }
        )

        let secondGate = CoordinatorGate()
        let blockedRefresh = Task {
            try await coordinator.refresh(
                assignments: { [assignment(firstMailbox), assignment(secondMailbox)] },
                providerMailboxes: [],
                policyProvider: { mailbox in
                    if mailbox == secondMailbox { await secondGate.wait() }
                    return try state(mailbox, version: "2")
                }
            )
        }
        await secondGate.waitUntilEntered()

        _ = try await coordinator.retry(firstMailbox, policyProvider: { mailbox in
            try state(mailbox, version: "3")
        })
        blockedRefresh.cancel()
        await secondGate.release()
        do {
            _ = try await blockedRefresh.value
            XCTFail("canceled refresh must propagate CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        let rows = coordinator.current().rows
        XCTAssertFalse(rows.contains { $0.loadState == .loading })
        guard case let .loaded(firstState) = rows.first(where: { $0.logicalMailboxID == firstMailbox })?.loadState else {
            return XCTFail("newer mailbox update must remain loaded")
        }
        XCTAssertEqual(firstState.version, "3")
        guard case let .loaded(secondState) = rows.first(where: { $0.logicalMailboxID == secondMailbox })?.loadState else {
            return XCTFail("canceled mailbox load must restore its settled state")
        }
        XCTAssertEqual(secondState.version, "1")
    }

    @MainActor
    func testCanceledRefreshDoesNotRestorePriorStateAcrossAssignmentRotation() async throws {
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x77, count: 32)))
        let firstDevice = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let rotatedDevice = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        func assignment(device: AccountDeviceID, generation: UInt64) -> NotificationProducerAssignment {
            NotificationProducerAssignment(logicalMailboxID: mailbox.rawValue, producerDeviceID: device, kind: .mac, generation: generation, trustEpoch: generation, trustRevision: generation, trustHead: Data(repeating: UInt8(generation), count: 32))
        }
        func state(version: String) throws -> NotificationPolicyPresentationState {
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: version, scopeVersion: "0", override: false)
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        _ = try await coordinator.refresh(assignments: { [assignment(device: firstDevice, generation: 1)] }, providerMailboxes: [], policyProvider: { _ in try state(version: "1") })

        let gate = CoordinatorGate()
        let rotatedRefresh = Task {
            try await coordinator.refresh(assignments: { [assignment(device: rotatedDevice, generation: 2)] }, providerMailboxes: [], policyProvider: { _ in
                await gate.wait()
                return try state(version: "2")
            })
        }
        await gate.waitUntilEntered()
        rotatedRefresh.cancel()
        await gate.release()
        do {
            _ = try await rotatedRefresh.value
            XCTFail("canceled assignment-rotated refresh must propagate CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        guard let row = coordinator.current().rows.first else { return XCTFail("rotated mailbox row is missing") }
        XCTAssertFalse(row.loadState == .loading)
        XCTAssertEqual(row.loadState, .error(.unavailable), "a prior producer state must not be restored into a rotated assignment")
    }

    @MainActor
    func testProductionPolicyPresentationCoordinatorIgnoresStaleRefreshAndRetryRows() async throws {
        let firstMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x6F, count: 32)))
        let secondMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x70, count: 32)))
        let macID = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        func assignment(_ mailbox: LogicalMailboxID) -> NotificationProducerAssignment {
            NotificationProducerAssignment(
                logicalMailboxID: mailbox.rawValue,
                producerDeviceID: macID,
                kind: .mac,
                generation: 1,
                trustEpoch: 1,
                trustRevision: 1,
                trustHead: Data(repeating: 1, count: 32)
            )
        }
        func state(_ mailbox: LogicalMailboxID) throws -> NotificationPolicyPresentationState {
            try NotificationPolicyPresentationState(logicalMailboxID: mailbox, mode: .generic, version: "1", scopeVersion: "0", override: false)
        }
        let coordinator = NotificationPolicyPresentationCoordinator()
        let refreshGate = CoordinatorGate()
        let staleRefresh = Task {
            try await coordinator.refresh(
                assignments: { [assignment(firstMailbox), assignment(secondMailbox)] },
                providerMailboxes: [],
                policyProvider: { mailbox in
                    if mailbox == firstMailbox { await refreshGate.wait() }
                    return try state(mailbox)
                }
            )
        }
        await refreshGate.waitUntilEntered()

        let currentRefresh = Task {
            try await coordinator.refresh(
                assignments: { [assignment(secondMailbox)] },
                providerMailboxes: [],
                policyProvider: { mailbox in try state(mailbox) }
            )
        }
        _ = try await currentRefresh.value
        await refreshGate.release()
        _ = try await staleRefresh.value
        XCTAssertEqual(coordinator.current().rows.map(\.logicalMailboxID), [secondMailbox])
        guard case let .loaded(refreshState) = coordinator.current().rows.first?.loadState else {
            return XCTFail("the current mailbox row must remain loaded")
        }
        XCTAssertEqual(refreshState.logicalMailboxID, secondMailbox)

        _ = try await coordinator.refresh(
            assignments: { [assignment(firstMailbox), assignment(secondMailbox)] },
            providerMailboxes: [],
            policyProvider: { mailbox in try state(mailbox) }
        )
        let retryGate = CoordinatorGate()
        let staleRetry = Task {
            try await coordinator.retry(firstMailbox, policyProvider: { mailbox in
                await retryGate.wait()
                return try state(mailbox)
            })
        }
        await retryGate.waitUntilEntered()
        _ = try await coordinator.refresh(
            assignments: { [assignment(secondMailbox)] },
            providerMailboxes: [],
            policyProvider: { mailbox in try state(mailbox) }
        )
        await retryGate.release()
        _ = try await staleRetry.value
        XCTAssertEqual(coordinator.current().rows.map(\.logicalMailboxID), [secondMailbox])
        guard case let .loaded(retryState) = coordinator.current().rows.first?.loadState else {
            return XCTFail("the current mailbox row must remain loaded after stale retry completion")
        }
        XCTAssertEqual(retryState.logicalMailboxID, secondMailbox)
    }

    func testProducerTargetKindUsesTrustedPlatformAndDoesNotUseActorAsTarget() throws {
        let actor = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let mac = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        XCTAssertNotEqual(actor, mac)
        XCTAssertEqual(NotificationProducerKind.mac.platform, .macos)
        XCTAssertEqual(NotificationProducerKind.syncNode.platform, .syncNode)
    }

    func testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload() async throws {
        let mailbox = Data(repeating: 0xA7, count: 32)
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let mac = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let node = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let (commit, material) = try productionSelectorCommit(account: account, mac: mac, node: node)
        let secrets = InMemoryAccountSecretStore()
        let trustStore = AccountTrustStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.ProducerSwitch")
        let entry = try AccountTrustHistoryEntryV1(commit: commit, evidence: nil)
        _ = try trustStore.installVerifiedCommit(commit, openedMaterial: material, verifiedEntries: [entry], expected: nil)
        let credentials = AccountCredentialStore(
            secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.ProducerSwitch",
            accessGroup: nil, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore
        )
        try credentials.saveSession(AccountSession(credentials: AccountSessionCredentials(
            accountID: account, deviceID: mac, accessToken: "access-token",
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshCredential: Data(repeating: 0x11, count: 32), offlineLease: "lease"
        )))
        _ = try credentials.loadOrCreateDeviceIdentity()
        let transport = AuthenticatedProducerModeSwitchTransport(
            account: account, mailbox: mailbox, mac: mac, node: node,
            trustHead: AccountTranscript.trustCommitDigest(commit)
        )
        let api = try AccountAPIClient(
            transport: transport, credentialStore: credentials,
            manifestStore: BootstrapKeyManifestStore(secretStore: secrets),
            baseURL: URL(string: "https://central.example")!
        )
        let selector = AuthenticatedNotificationProducerSelector(
            api: api, credentialStore: credentials,
            random: { Data(repeating: UInt8($0), count: $0) }
        )
        let direct = AssignmentDirectPolicySpy(mailboxID: try XCTUnwrap(LogicalMailboxID(rawValue: mailbox)))
        let nodePolicy = AssignmentPolicySpy(mode: .generic)
        let mailboxID = try XCTUnwrap(LogicalMailboxID(rawValue: mailbox))
        let policyRemote = NotificationAssignmentPolicyRemote(
            assignments: { try await selector.currentProducerAssignments() },
            direct: direct, syncNode: nodePolicy
        )
        let macTarget = NotificationProducerTarget(deviceID: mac, kind: .mac)
        let nodeTarget = NotificationProducerTarget(deviceID: node, kind: .syncNode, expectedGeneration: 1)
        let restoredMacTarget = NotificationProducerTarget(deviceID: mac, kind: .mac, expectedGeneration: 2)
        let first = await selector.selectProducer(target: macTarget, logicalMailboxID: mailbox, expectedGeneration: 0, identityToken: "identity-token", appleNonce: Data(repeating: 1, count: 32))
        guard case .selected(let firstGeneration) = first else { return XCTFail("Mac CAS did not select") }
        XCTAssertEqual(firstGeneration, 1)
        let firstAssignments = try await selector.currentProducerAssignments()
        let firstAssignment = try XCTUnwrap(firstAssignments.first)
        XCTAssertEqual(firstAssignment.producerDeviceID, mac)
        let firstPolicy = try await policyRemote.notificationPolicyPresentation(for: mailboxID)
        XCTAssertEqual(firstPolicy.mode, .richPreview)

        let second = await selector.selectProducer(target: nodeTarget, logicalMailboxID: mailbox, expectedGeneration: firstGeneration, identityToken: "identity-token", appleNonce: Data(repeating: 2, count: 32))
        guard case .selected(let secondGeneration) = second else { return XCTFail("Sync Node CAS did not select") }
        XCTAssertEqual(secondGeneration, 2)
        let secondAssignments = try await selector.currentProducerAssignments()
        let secondAssignment = try XCTUnwrap(secondAssignments.first)
        XCTAssertEqual(secondAssignment.producerDeviceID, node)
        let secondPolicy = try await policyRemote.notificationPolicyPresentation(for: mailboxID)
        XCTAssertEqual(secondPolicy.mode, .generic)

        let restored = await selector.selectProducer(target: restoredMacTarget, logicalMailboxID: mailbox, expectedGeneration: secondGeneration, identityToken: "identity-token", appleNonce: Data(repeating: 3, count: 32))
        guard case .selected(let restoredGeneration) = restored else { return XCTFail("Mac restore CAS did not select") }
        XCTAssertEqual(restoredGeneration, 3)
        let finalAssignments = try await selector.currentProducerAssignments()
        let finalAssignment = try XCTUnwrap(finalAssignments.first)
        XCTAssertEqual(finalAssignment.producerDeviceID, mac)
        XCTAssertEqual(finalAssignment.generation, 3)
        let finalPolicy = try await policyRemote.notificationPolicyPresentation(for: mailboxID)
        XCTAssertEqual(finalPolicy.mode, .richPreview)
        let staleCAS = await selector.selectProducer(target: restoredMacTarget, logicalMailboxID: mailbox, expectedGeneration: 2, identityToken: "identity-token", appleNonce: Data(repeating: 4, count: 32))
        XCTAssertEqual(staleCAS, .conflict)
        let requests = await transport.requestsSnapshot()
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "POST /v1/notifications/producers/owner-query", "POST /v1/notifications/producers/step-up", "PUT /v1/notifications/producers", "POST /v1/notifications/assignments/query", "POST /v1/notifications/assignments/query",
            "POST /v1/notifications/producers/owner-query", "POST /v1/notifications/producers/step-up", "PUT /v1/notifications/producers", "POST /v1/notifications/assignments/query", "POST /v1/notifications/assignments/query",
            "POST /v1/notifications/producers/owner-query", "POST /v1/notifications/producers/step-up", "PUT /v1/notifications/producers", "POST /v1/notifications/assignments/query", "POST /v1/notifications/assignments/query",
            "POST /v1/notifications/producers/owner-query"
        ])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" &&
            $0.value(forHTTPHeaderField: "DPoP")?.isEmpty == false
        })
        let policyWriteCount = await transport.policyWriteCount()
        XCTAssertEqual(policyWriteCount, 0)
    }

    func testProducerSelectorResamplesTimeAfterRefreshFenceForOwnerStepUpAndPut() async throws {
        let staleNow = Date(timeIntervalSince1970: 1_900_000_000)
        let postFenceNow = staleNow.addingTimeInterval(300)
        let mailbox = Data(repeating: 0xA7, count: 32)
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let mac = try AccountDeviceID("22222222-3333-4444-5555-666666666666")
        let node = try AccountDeviceID("77777777-8888-4999-aaaa-bbbbbbbbbbbb")
        let (commit, material) = try productionSelectorCommit(account: account, mac: mac, node: node)
        let secrets = InMemoryAccountSecretStore()
        let trustStore = AccountTrustStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.ProducerFenceClock")
        let entry = try AccountTrustHistoryEntryV1(commit: commit, evidence: nil)
        _ = try trustStore.installVerifiedCommit(commit, openedMaterial: material, verifiedEntries: [entry], expected: nil)
        let credentials = AccountCredentialStore(
            secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.ProducerFenceClock",
            accessGroup: nil, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil,
            secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: trustStore
        )
        try credentials.saveSession(AccountSession(credentials: AccountSessionCredentials(
            accountID: account, deviceID: mac, accessToken: "expired",
            accessExpiresAt: staleNow.addingTimeInterval(-1),
            refreshCredential: Data(repeating: 0x11, count: 32), offlineLease: "lease"
        )))
        _ = try credentials.loadOrCreateDeviceIdentity()
        let clock = LockedDateBox(staleNow)
        let holderTransport = BlockingRefreshTransport()
        let holderAPI = try AccountAPIClient(transport: holderTransport, credentialStore: credentials, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-refresh-selector-clock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let holder = NotificationAccountSession(api: holderAPI, store: credentials, refreshLockURL: lockURL, clock: { staleNow })
        let transport = SelectorTimestampTransport(account: account, mailbox: mailbox, mac: mac, node: node, trustHead: AccountTranscript.trustCommitDigest(commit))
        let api = try AccountAPIClient(
            transport: transport, credentialStore: credentials,
            manifestStore: BootstrapKeyManifestStore(secretStore: secrets),
            baseURL: URL(string: "https://central.example")!
        )
        let selector = AuthenticatedNotificationProducerSelector(
            api: api, credentialStore: credentials, refreshLockURL: lockURL,
            random: { Data(repeating: UInt8($0), count: $0) }, clock: { clock.value }
        )
        let acquisitionProbe = AcquisitionStartProbe()
#if DEBUG
        NotificationRefreshLockTestHooks.setAcquireStart { acquisitionProbe.record() }
        defer { NotificationRefreshLockTestHooks.setAcquireStart(nil) }
#endif
        let holderTask = Task { _ = try? await holder.current(now: staleNow) }
        var selectionTask: Task<NotificationProducerSelectionState, Never>?
        do {
            await holderTransport.waitUntilStarted()
            selectionTask = Task {
                await selector.selectProducer(
                    target: NotificationProducerTarget(deviceID: mac, kind: .mac), logicalMailboxID: mailbox,
                    expectedGeneration: 0, identityToken: "identity-token", appleNonce: Data(repeating: 1, count: 32), now: staleNow
                )
            }
#if DEBUG
            let contenderDeadline = Date().addingTimeInterval(2)
            while acquisitionProbe.count < 2, Date() < contenderDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(acquisitionProbe.count, 2, "selector must reach the refresh fence before time advances")
#else
            try await Task.sleep(for: .milliseconds(100))
#endif
            clock.value = postFenceNow
            await holderTransport.release()
            let result = await selectionTask?.value
            let requestSummary = await transport.requestSummary()
            XCTAssertEqual(result, .selected(generation: 1), "selector requests: \(requestSummary)")
            let timestamps = await transport.timestampsSnapshot()
            for path in [
                "/v1/notifications/producers/owner-query",
                "/v1/notifications/producers/step-up",
                "/v1/notifications/producers"
            ] {
                let timestamp = try XCTUnwrap(timestamps[path], "missing timestamp for \(path)")
                XCTAssertGreaterThan(timestamp.timeIntervalSince(staleNow), 60, "\(path) must use time sampled after refresh-fence ownership")
            }
            _ = await holderTask.value
        } catch {
            await holderTransport.release()
            _ = await holderTask.value
            selectionTask?.cancel()
            _ = await selectionTask?.value
            throw error
        }
    }

    func testProducerSelectionMapsStatusOnlyCASConflictToConflict() {
        XCTAssertEqual(
            AuthenticatedNotificationProducerSelector.selectionState(for: .httpFailure(statusCode: 409)),
            .conflict
        )
        XCTAssertEqual(
            AuthenticatedNotificationProducerSelector.selectionState(for: .httpFailure(statusCode: 401)),
            .unavailable
        )
    }

    func testOwnerQueryKeepsPredecessorGenerationAcrossTrustRotation() throws {
        let mailbox = Data(repeating: 0x31, count: 32)
        let response = try JSONSerialization.data(withJSONObject: [
            "kind": "notification.producer-selection-state.v2",
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox),
            "producerDeviceID": "11111111-2222-3333-8444-555555555555",
            "producerKind": "mac",
            "generation": 7,
            // These coordinates are deliberately from the predecessor trust
            // commit. They must not be compared with the caller's new commit.
            "trustEpoch": 2,
            "trustRevision": 3,
            "trustHead": AccountWireCodec.encodeBase64URL(Data(repeating: 0xA1, count: 32))
        ], options: [.sortedKeys, .withoutEscapingSlashes])

        XCTAssertEqual(
            try AuthenticatedNotificationProducerSelector.ownerQueryGeneration(
                response: response, logicalMailboxID: mailbox
            ),
            7
        )
    }

    func testInactiveOwnerQueryUsesZeroCASPredecessor() throws {
        let mailbox = Data(repeating: 0x31, count: 32)
        XCTAssertEqual(
            try AuthenticatedNotificationProducerSelector.ownerQueryPredecessor(
                result: .httpFailure(statusCode: 409), logicalMailboxID: mailbox
            ),
            0
        )
    }

    func testRelayHTTPFailuresKeepPermanentStatusesTerminal() {
        let retryAt = Date(timeIntervalSince1970: 123)
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 401, retryAt: retryAt), NotificationRelayResult(outcome: .revoked))
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 404, retryAt: retryAt), NotificationRelayResult(outcome: .revoked))
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 409, retryAt: retryAt), NotificationRelayResult(outcome: .rejected))
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 422, retryAt: retryAt), NotificationRelayResult(outcome: .malformed))
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 429, retryAt: retryAt), NotificationRelayResult(outcome: .retryable, nextAttemptAt: retryAt))
        XCTAssertEqual(AuthenticatedNotificationRelayClient.classifyHTTPFailure(statusCode: 503, retryAt: retryAt), NotificationRelayResult(outcome: .retryable, nextAttemptAt: retryAt))
    }

    func testConcurrentSessionsRefreshOnceAcrossSharedFenceAndUseWinner() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secrets = InMemoryAccountSecretStore()
        let firstStore = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.RefreshRace")
        let credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "expired", accessExpiresAt: now.addingTimeInterval(-1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        try firstStore.saveSession(AccountSession(credentials: credentials))
        _ = try firstStore.loadOrCreateDeviceIdentity()
        let secondStore = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.RefreshRace")
        let transport = RefreshCountingTransport(accountID: accountID)
        let firstAPI = try AccountAPIClient(transport: transport, credentialStore: firstStore, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let secondAPI = try AccountAPIClient(transport: transport, credentialStore: secondStore, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-refresh-race-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let first = NotificationAccountSession(api: firstAPI, store: firstStore, refreshLockURL: lockURL, clock: { now })
        let second = NotificationAccountSession(api: secondAPI, store: secondStore, refreshLockURL: lockURL, clock: { now })
        async let firstContext = first.current(now: now)
        async let secondContext = second.current(now: now)
        let (winner, follower) = try await (firstContext, secondContext)
        XCTAssertEqual(winner.credentials, follower.credentials)
        let refreshCount = await transport.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(winner.credentials.accessToken, "rotated-access")
    }

    func testCancelledSessionWaitingForRefreshFenceExitsPromptly() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secrets = InMemoryAccountSecretStore()
        let firstStore = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.FenceCancellation")
        let secondStore = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.FenceCancellation")
        let credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "expired", accessExpiresAt: now.addingTimeInterval(-1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        try firstStore.saveSession(AccountSession(credentials: credentials))
        _ = try firstStore.loadOrCreateDeviceIdentity()
        _ = try secondStore.loadOrCreateDeviceIdentity()
        let firstTransport = BlockingRefreshTransport()
        let firstAPI = try AccountAPIClient(transport: firstTransport, credentialStore: firstStore, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let secondAPI = try AccountAPIClient(transport: CancellationTransport(), credentialStore: secondStore, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-refresh-cancel-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let first = NotificationAccountSession(api: firstAPI, store: firstStore, refreshLockURL: lockURL, clock: { now })
        let second = NotificationAccountSession(api: secondAPI, store: secondStore, refreshLockURL: lockURL, clock: { now })
        let resultProbe = FenceResultProbe()

        let holder = Task {
            try await first.current(now: now)
        }
        var contender: Task<Void, Never>?
        do {
            await firstTransport.waitUntilStarted()
            contender = Task {
                do {
                    _ = try await second.current(now: now)
                    await resultProbe.record("completed")
                } catch is CancellationError {
                    await resultProbe.record("cancelled")
                } catch {
                    await resultProbe.record("error")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            contender?.cancel()
            try await Task.sleep(for: .milliseconds(200))
            let contenderResult = await resultProbe.value()
            XCTAssertEqual(contenderResult, "cancelled", "cancelled fence contenders must not remain blocked")
            await firstTransport.release()
            _ = try? await holder.value
            _ = await contender?.value
        } catch {
            await firstTransport.release()
            _ = try? await holder.value
            contender?.cancel()
            _ = await contender?.value
            throw error
        }
    }

#if DEBUG
    func testCancelledLocalFenceContenderCannotReleaseCrossProcessLock() async throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        guard let python else {
            throw XCTSkip("python3 is unavailable for the cross-process fcntl interoperability check")
        }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.CrossProcessFence")
        let credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "expired", accessExpiresAt: now.addingTimeInterval(-1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        try store.saveSession(AccountSession(credentials: credentials))
        _ = try store.loadOrCreateDeviceIdentity()
        let holderTransport = BlockingRefreshTransport()
        let holderAPI = try AccountAPIClient(transport: holderTransport, credentialStore: store, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let contenderAPI = try AccountAPIClient(transport: CancellationTransport(), credentialStore: store, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-refresh-cross-process-\(UUID().uuidString)", isDirectory: true)
        let lockURL = root.appendingPathComponent("refresh.lock")
        let readyURL = root.appendingPathComponent("child-ready")
        let enteredURL = root.appendingPathComponent("child-entered")
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = NotificationAccountSession(api: holderAPI, store: store, refreshLockURL: lockURL, clock: { now })
        let contenderSession = NotificationAccountSession(api: contenderAPI, store: store, refreshLockURL: lockURL, clock: { now })
        let acquisitionProbe = AcquisitionStartProbe()
        NotificationRefreshLockTestHooks.setAcquireStart { acquisitionProbe.record() }
        defer { NotificationRefreshLockTestHooks.setAcquireStart(nil) }
        let holderTask = Task { _ = try? await holder.current(now: now) }
        var child: Process?
        do {
            await holderTransport.waitUntilStarted()
            XCTAssertGreaterThanOrEqual(acquisitionProbe.count, 1)
            let process = Process()
            process.executableURL = python
            process.arguments = [
                "-c",
                "import fcntl, os, sys; fd=os.open(sys.argv[1], os.O_RDWR); open(sys.argv[2], 'wb').close(); fcntl.lockf(fd, fcntl.LOCK_EX); open(sys.argv[3], 'wb').close(); os.close(fd)",
                lockURL.path, readyURL.path, enteredURL.path
            ]
            try process.run()
            child = process
            let readyDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

            let contender = Task { () -> String in
                do {
                    _ = try await contenderSession.current(now: now)
                    return "completed"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "error"
                }
            }
            let contenderStartDeadline = Date().addingTimeInterval(2)
            while acquisitionProbe.count < 2, Date() < contenderStartDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(acquisitionProbe.count, 2, "cancellation must exercise a contender that reached fence acquisition")
            contender.cancel()
            let contenderResult = await contender.value
            XCTAssertEqual(contenderResult, "cancelled")
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(FileManager.default.fileExists(atPath: enteredURL.path), "a cancelled local contender must not release another process's fence")

            await holderTransport.release()
            _ = await holderTask.value
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: enteredURL.path))
        } catch {
            await holderTransport.release()
            _ = await holderTask.value
            if let child, child.isRunning {
                child.terminate()
            }
            child?.waitUntilExit()
            throw error
        }
    }
#endif

    func testRefreshFenceResamplesTimeAfterWaitingForOwnership() async throws {
        let staleNow = Date().addingTimeInterval(-120)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secrets = InMemoryAccountSecretStore()
        let store = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.FenceClock")
        let credentials = try AccountSessionCredentials(accountID: accountID, deviceID: deviceID, accessToken: "expired", accessExpiresAt: staleNow.addingTimeInterval(-1), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        try store.saveSession(AccountSession(credentials: credentials))
        _ = try store.loadOrCreateDeviceIdentity()
        let clock = LockedDateBox(staleNow)
        let holderTransport = BlockingRefreshTransport()
        let contenderTransport = TimestampRecordingRefreshTransport(accountID: accountID)
        let holderAPI = try AccountAPIClient(transport: holderTransport, credentialStore: store, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let contenderAPI = try AccountAPIClient(transport: contenderTransport, credentialStore: store, manifestStore: BootstrapKeyManifestStore(secretStore: secrets))
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-refresh-clock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let holder = NotificationAccountSession(api: holderAPI, store: store, refreshLockURL: lockURL, clock: { clock.value })
        let contender = NotificationAccountSession(api: contenderAPI, store: store, refreshLockURL: lockURL, clock: { clock.contenderValue })

        let holderTask = Task { try? await holder.current() }
        var contenderTask: Task<Void, Never>?
        do {
            await holderTransport.waitUntilStarted()
            contenderTask = Task { _ = try? await contender.current() }
            let staleReadDeadline = Date().addingTimeInterval(2)
            while clock.contenderReadCount < 1, Date() < staleReadDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(clock.contenderReadCount, 1, "contender must capture the pre-advance clock before waiting for ownership")
            clock.value = Date()
            await holderTransport.release()
            _ = await holderTask.value
            _ = await contenderTask?.value

            let recordedTimestamp = await contenderTransport.lastTimestamp()
            let timestamp = try XCTUnwrap(recordedTimestamp)
            XCTAssertGreaterThan(timestamp.timeIntervalSince(staleNow), 60, "refresh proof must use time sampled after fence ownership")
        } catch {
            await holderTransport.release()
            _ = await holderTask.value
            contenderTask?.cancel()
            _ = await contenderTask?.value
            throw error
        }
    }

    func testDirectClientPropagatesSessionRefreshCancellation() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let device = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.Cancellation")
        let expired = try AccountSessionCredentials(accountID: account, deviceID: device, accessToken: "expired", accessExpiresAt: Date(timeIntervalSinceNow: -60), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "lease")
        try credentials.saveSession(AccountSession(credentials: expired))
        _ = try credentials.loadOrCreateDeviceIdentity()
        let api = try AccountAPIClient(transport: CancellationTransport(), credentialStore: credentials, manifestStore: BootstrapKeyManifestStore(secretStore: secrets), baseURL: URL(string: "https://central.example")!)
        let client = AuthenticatedDirectNotificationPolicyClient(api: api, credentialStore: credentials)

        do {
            _ = try await client.snapshot()
            XCTFail("session cancellation was swallowed")
        } catch is CancellationError {
            // The superseded operation must exit its cancellation branch.
        } catch {
            XCTFail("unexpected mapped session error: \(error)")
        }
    }

    func testDirectClientRefreshesRotatedSessionCredentialsOnSuccessiveOperations() async throws {
        let account = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let firstDevice = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let secondDevice = try AccountDeviceID("99999999-aaaa-4bbb-8ccc-dddddddddddd")
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.Rotation")
        let response = try directPolicyResponse([
            "kind": "notification.direct-policy-snapshot.v1",
            "default": ["policy": "generic", "version": "1", "scopeVersion": "0", "override": false],
            "mailboxes": []
        ])
        let transport = DirectPolicyTransport(response: response)
        let first = try AccountSessionCredentials(accountID: account, deviceID: firstDevice, accessToken: "first-token", accessExpiresAt: Date(timeIntervalSinceNow: 600), refreshCredential: Data(repeating: 1, count: 32), offlineLease: "first-lease")
        try credentials.saveSession(AccountSession(credentials: first))
        _ = try credentials.loadOrCreateDeviceIdentity()
        let api = try AccountAPIClient(transport: transport, credentialStore: credentials, manifestStore: BootstrapKeyManifestStore(secretStore: secrets), baseURL: URL(string: "https://central.example")!)
        let client = AuthenticatedDirectNotificationPolicyClient(api: api, credentialStore: credentials)

        _ = try await client.snapshot()
        let second = try AccountSessionCredentials(accountID: account, deviceID: secondDevice, accessToken: "second-token", accessExpiresAt: Date(timeIntervalSinceNow: 600), refreshCredential: Data(repeating: 2, count: 32), offlineLease: "second-lease")
        try credentials.saveSession(AccountSession(credentials: second))
        _ = try await client.snapshot()

        let requests = await transport.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer first-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer second-token")
        XCTAssertNotEqual(requests[0].value(forHTTPHeaderField: "DPoP"), requests[1].value(forHTTPHeaderField: "DPoP"))
    }

    func testProducerRejectsAssignmentGenerationChangeBeforeBuildingEnvelope() async throws {
        let source = source()
        let claim = claim(source: source)
        let coordination = FixedCoordinationClient(assignment: NotificationRecipientAssignment(
            recipients: [], signedBytes: Data([1]), signature: Data([2]), signerDeviceID: "producer",
            configVersion: "wrong", producerGeneration: 8, policyVersion: 1
        ))
        let builder = RecordingPreviewBuilder()
        let producer = NotificationProducer(
            coordination: coordination,
            verifier: NoOpAssignmentVerifier(),
            previewBuilder: builder
        )

        do {
            _ = try await producer.prepare(claim: claim, source: source)
            XCTFail("Expected stale assignment")
        } catch NotificationRuntimeError.staleAssignment {
            XCTAssertTrue(builder.envelopes.isEmpty)
        }
    }

    func testDrainFreezesAndRelaysTheExactPersistedEnvelopeBytes() async throws {
        let source = source()
        let claim = claim(source: source)
        let recipient = NotificationRecipientSnapshot(
            recipientID: "ios", routingHandle: Data(repeating: 1, count: 32),
            agreementPublicKey: Data(repeating: 2, count: 65)
        )
        let assignment = NotificationRecipientAssignment(
            recipients: [recipient], signedBytes: Data([3]), signature: Data([4]), signerDeviceID: "producer",
            configVersion: "cfg", producerGeneration: 7, policyVersion: 1
        )
        let store = RecordingPublicationStore(claim: claim, source: source, recipient: recipient)
        let producer = NotificationProducer(
            coordination: FixedCoordinationClient(assignment: assignment),
            verifier: NoOpAssignmentVerifier(),
            previewBuilder: FixedPreviewBuilder(bytes: Data([0xAA, 0xBB]))
        )
        let relay = RecordingRelayClient()
        let drain = NotificationDrain(
            store: store, producer: producer, relay: relay,
            dateProvider: { Date(timeIntervalSince1970: 100) }
        )

        let result = try await drain.drain()

        XCTAssertEqual(result.claimedCount, 1)
        XCTAssertEqual(result.frozenCount, 1)
        XCTAssertEqual(result.deliveredCount, 1)
        XCTAssertEqual(store.frozenEnvelopeBytes, [Data([0xAA, 0xBB])])
        XCTAssertEqual(relay.bytes, [Data([0xAA, 0xBB])])
        XCTAssertEqual(store.outcomes, [.accepted])
    }

    func testPPN2PreviewBuilderProducesDecryptableClaimAwareEnvelope() throws {
        let source = NotificationPublicationSource(
            publicationID: "publication", accountID: AccountID("account"), messageID: MessageID("message"),
            mailboxPath: "INBOX", uidValidity: 1, uid: 2, providerArrivalAt: Date(),
            plainpostAccountID: AccountID("plainpost"), logicalMailboxID: "logical",
            logicalMailboxIDBytes: Data(repeating: 3, count: 32), configVersion: "cfg", producerGeneration: 7
        )
        let claim = NotificationPublicationClaim(
            publicationID: source.publicationID, accountID: source.accountID, messageID: source.messageID,
            leaseToken: "lease", configVersion: "cfg", producerGeneration: 7,
            logicalMailboxID: source.logicalMailboxID, producerDeviceID: "00000000-0000-4000-8000-000000000001", producerKind: "mac",
            policyMode: "rich_preview", policyVersion: 1, configRevision: 1,
            logicalMailboxIDBytes: source.logicalMailboxIDBytes
        )
        let producerID = try AccountDeviceID("00000000-0000-4000-8000-000000000001")
        let recipientID = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        let trust = try NotificationTrustCoordinates(epoch: 1, revision: 1, head: Data(repeating: 9, count: 32))
        let snapshot = NotificationMessageSnapshot(
            mailboxToken: "mailbox", threadToken: "thread", messageToken: "message",
            sender: "sender@example.com", subject: "Subject", preview: "Preview", badge: 2,
            messageDigest: Data(repeating: 4, count: 32), replayID: Data(repeating: 5, count: 32), collapseDigest: Data(repeating: 6, count: 32)
        )
        let builder = PPN2NotificationPreviewBuilder(
            producerDeviceID: producerID, producerSigningPublicKey: signing.publicKey.x963Representation,
            sign: { try signing.signature(for: $0).rawRepresentation },
            snapshot: { _, _ in snapshot }, trust: { _, _ in trust }, now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let recipient = NotificationRecipientSnapshot(
            recipientID: recipientID.rawValue, routingHandle: Data(repeating: 7, count: 32),
            agreementPublicKey: agreement.publicKey.x963Representation
        )
        let envelope = try builder.envelope(for: source, claim: claim, recipient: recipient)
        let opened = try RichNotificationEnvelope.open(
            envelope, recipientAgreementPrivateKey: agreement.rawRepresentation,
            authority: try RichNotificationEnvelope.Authority(
                recipientDeviceID: recipientID, producerDeviceID: producerID,
                producerSigningPublicKey: signing.publicKey.x963Representation
            ), now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        XCTAssertEqual(opened.content.subject, "Subject")
        XCTAssertEqual(opened.header.producerAssignmentGeneration, 7)
    }

    func testPPN2PreviewBuilderUsesCanonicalGenericContent() throws {
        let source = NotificationPublicationSource(
            publicationID: "publication", accountID: AccountID("account"), messageID: MessageID("message"),
            mailboxPath: "INBOX", uidValidity: 1, uid: 2, providerArrivalAt: Date(),
            plainpostAccountID: AccountID("plainpost"), logicalMailboxID: "logical",
            logicalMailboxIDBytes: Data(repeating: 3, count: 32), configVersion: "cfg", producerGeneration: 7
        )
        let claim = NotificationPublicationClaim(
            publicationID: source.publicationID, accountID: source.accountID, messageID: source.messageID,
            leaseToken: "lease", configVersion: "cfg", producerGeneration: 7,
            logicalMailboxID: source.logicalMailboxID, producerDeviceID: "00000000-0000-4000-8000-000000000001", producerKind: "mac",
            policyMode: "generic", policyVersion: 1, configRevision: 1,
            logicalMailboxIDBytes: source.logicalMailboxIDBytes
        )
        let producerID = try AccountDeviceID("00000000-0000-4000-8000-000000000001")
        let recipientID = try AccountDeviceID("00000000-0000-4000-8000-000000000002")
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        let builder = PPN2NotificationPreviewBuilder(
            producerDeviceID: producerID, producerSigningPublicKey: signing.publicKey.x963Representation,
            sign: { try signing.signature(for: $0).rawRepresentation },
            snapshot: { _, _ in NotificationMessageSnapshot(
                mailboxToken: "mailbox", threadToken: "thread", messageToken: "message",
                sender: "hidden@example.com", subject: "hidden", preview: "hidden", badge: 1,
                messageDigest: Data(repeating: 4, count: 32), replayID: Data(repeating: 5, count: 32), collapseDigest: Data(repeating: 6, count: 32)
            ) },
            trust: { _, _ in try NotificationTrustCoordinates(epoch: 1, revision: 1, head: Data(repeating: 9, count: 32)) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let recipient = NotificationRecipientSnapshot(
            recipientID: recipientID.rawValue, routingHandle: Data(repeating: 7, count: 32),
            agreementPublicKey: agreement.publicKey.x963Representation
        )
        let envelope = try builder.envelope(for: source, claim: claim, recipient: recipient)
        let opened = try RichNotificationEnvelope.open(
            envelope, recipientAgreementPrivateKey: agreement.rawRepresentation,
            authority: try RichNotificationEnvelope.Authority(
                recipientDeviceID: recipientID, producerDeviceID: producerID,
                producerSigningPublicKey: signing.publicKey.x963Representation
            ), now: Date(timeIntervalSince1970: 1_800_000_001)
        )
        XCTAssertEqual(opened.content.sender, "Plainpost")
        XCTAssertEqual(opened.content.subject, "New mail is available.")
        XCTAssertEqual(opened.content.preview, "")
    }

    func testFrozenRetryDoesNotReprepareAfterAssignmentChanges() async throws {
        let source = source()
        let claim = NotificationPublicationClaim(
            publicationID: source.publicationID, accountID: source.accountID, messageID: source.messageID,
            leaseToken: "lease", configVersion: source.configVersion, producerGeneration: source.producerGeneration,
            logicalMailboxID: source.logicalMailboxID, producerDeviceID: "producer", producerKind: "mac",
            policyMode: "enabled", policyVersion: 1, configRevision: 1,
            logicalMailboxIDBytes: source.logicalMailboxIDBytes, resumesFrozenPublication: true
        )
        let recipient = NotificationRecipientSnapshot(recipientID: "ios", routingHandle: Data(repeating: 1, count: 32), agreementPublicKey: Data(repeating: 2, count: 65))
        let store = RecordingPublicationStore(claim: claim, source: source, recipient: recipient)
        let builder = RecordingPreviewBuilder()
        let producer = NotificationProducer(coordination: UnavailableCoordinationForTest(), verifier: NoOpAssignmentVerifier(), previewBuilder: builder)
        let relay = RecordingRelayClient()
        let drain = NotificationDrain(store: store, producer: producer, relay: relay, dateProvider: { Date(timeIntervalSince1970: 100) })

        _ = try await drain.drain()

        XCTAssertTrue(builder.envelopes.isEmpty)
        XCTAssertEqual(relay.bytes, [Data([0xAA, 0xBB])])
    }

    private func source() -> NotificationPublicationSource {
        NotificationPublicationSource(
            publicationID: "publication", accountID: AccountID("account"), messageID: MessageID("message"),
            mailboxPath: "INBOX", uidValidity: 1, uid: 2, providerArrivalAt: Date(),
            plainpostAccountID: AccountID("plainpost"), logicalMailboxID: "logical",
            logicalMailboxIDBytes: Data(repeating: 3, count: 32), configVersion: "cfg", producerGeneration: 7
        )
    }

    private func claim(source: NotificationPublicationSource) -> NotificationPublicationClaim {
        NotificationPublicationClaim(
            publicationID: source.publicationID, accountID: source.accountID, messageID: source.messageID,
            leaseToken: "lease", configVersion: source.configVersion, producerGeneration: source.producerGeneration,
            logicalMailboxID: source.logicalMailboxID, producerDeviceID: "producer", producerKind: "mac",
            policyMode: "enabled", policyVersion: 1, configRevision: 1,
            logicalMailboxIDBytes: source.logicalMailboxIDBytes
        )
    }
}

private final class ObservationChangeCounter: @unchecked Sendable {
    var value = 0
}

private actor CoordinatorGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor DirectPolicyTransport: AccountHTTPTransport {
    private let response: AccountHTTPResponse
    private var requests: [URLRequest] = []

    init(response: AccountHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        requests.append(request)
        return response
    }

    func requestsSnapshot() -> [URLRequest] { requests }
    func lastRequest() -> URLRequest? { requests.last }
}

private actor SequencedAssignmentSource {
    private let values: [[NotificationProducerAssignment]]
    private var index = 0
    init(_ values: [[NotificationProducerAssignment]]) { self.values = values }
    func next() -> [NotificationProducerAssignment] {
        defer { index = min(index + 1, values.count - 1) }
        return values[index]
    }
}

private actor AssignmentPolicySpy: NotificationPolicyRemote {
    private var mode: NodeSyncNotificationPolicyMode
    private var mailboxOverride = false
    private var lastWasClear = false
    private var updates = 0
    init(mode: NodeSyncNotificationPolicyMode) { self.mode = mode }
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        try NodeSyncNotificationPolicy(logicalMailboxID: logicalMailboxID, mode: mode, version: "1", scopeVersion: "1", override: logicalMailboxID != nil && mailboxOverride)
    }
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        updates += 1
        lastWasClear = request.clear
        if request.clear {
            mailboxOverride = false
        } else {
            mode = request.mode
            mailboxOverride = request.logicalMailboxID != nil
        }
        return try await notificationPolicy(for: request.logicalMailboxID)
    }
    func updateCount() -> Int { updates }
    func lastClear() -> Bool { lastWasClear }
}

private actor AssignmentDirectPolicySpy: DirectNotificationPolicyAccess {
    private let mailboxID: LogicalMailboxID
    private var defaultState: DirectNotificationPolicyState
    private var mailboxState: DirectNotificationPolicyState

    init(mailboxID: LogicalMailboxID) {
        self.mailboxID = mailboxID
        defaultState = try! DirectNotificationPolicyState(logicalMailboxID: nil, mode: .richPreview, version: "0", scopeVersion: "0", override: false)
        mailboxState = try! DirectNotificationPolicyState(logicalMailboxID: mailboxID, mode: .richPreview, version: "0", scopeVersion: "0", override: false)
    }

    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        let state = logicalMailboxID == nil ? defaultState : mailboxState
        return try NodeSyncNotificationPolicy(logicalMailboxID: state.logicalMailboxID, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: state.override)
    }

    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        let directRequest = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: request.logicalMailboxID, mode: request.mode, clear: request.clear, expectedVersion: request.expectedVersion, idempotencyKey: request.idempotencyKey)
        return try NodeSyncNotificationPolicy(logicalMailboxID: (try await updateDirectNotificationPolicy(directRequest)).logicalMailboxID, mode: defaultState.mode, version: "1", scopeVersion: "1", override: true)
    }

    func directDefaultPolicy() async throws -> DirectNotificationPolicyState { defaultState }
    func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState { mailboxState }

    func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState {
        if request.logicalMailboxID == nil {
            guard request.expectedVersion == defaultState.version else { throw NotificationPolicyRemoteError.conflict }
            defaultState = try DirectNotificationPolicyState(logicalMailboxID: nil, mode: request.mode, version: "1", scopeVersion: "0", override: false)
            return defaultState
        }
        guard request.logicalMailboxID == mailboxID, request.expectedVersion == mailboxState.scopeVersion else { throw NotificationPolicyRemoteError.conflict }
        let nextScope = String((UInt64(request.expectedVersion) ?? 0) + 1)
        if request.clear {
            mailboxState = try DirectNotificationPolicyState(logicalMailboxID: mailboxID, mode: defaultState.mode, version: defaultState.version, scopeVersion: nextScope, override: false)
        } else {
            mailboxState = try DirectNotificationPolicyState(logicalMailboxID: mailboxID, mode: request.mode, version: nextScope, scopeVersion: nextScope, override: true)
        }
        return mailboxState
    }
}

private func directPolicyResponse(_ object: [String: Any]) throws -> AccountHTTPResponse {
    AccountHTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    )
}

private func productionSelectorCommit(
    account: PlainpostAccountID,
    mac: AccountDeviceID,
    node: AccountDeviceID
) throws -> (AccountTrustStateCommit, AccountTrustKeyMaterial) {
    let epoch = AccountTrustEpoch(rawValue: try PositiveUInt64(1))
    let revision = try PositiveUInt64(2)
    let keyGeneration = try PositiveUInt64(1)
    let material = try AccountTrustKeyMaterial(
        accountID: account, epoch: epoch, keyGeneration: keyGeneration,
        trustRevision: revision, mailboxMatchingKey: Data(repeating: 0x41, count: 32),
        metadataKey: Data(repeating: 0x42, count: 32)
    )
    func member(_ id: AccountDeviceID, platform: AccountPlatform) throws -> AccountDeviceTrustRecord {
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        let agreement = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        return try AccountDeviceTrustRecord(
            accountID: account, epoch: epoch, revision: try PositiveUInt64(id == mac ? 1 : 2),
            deviceID: id, platform: platform,
            publicBundle: try AccountPublicKeyBundle(signingKey: signing, agreementKey: agreement),
            signerDeviceID: mac, signature: Data(repeating: 0x43, count: 64)
        )
    }
    let members = try [member(mac, platform: .macos), member(node, platform: .syncNode)]
        .sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
    let transition = try AccountTrustTransition(
        kind: .revocation, targetDeviceIDs: [try AccountDeviceID("88888888-9999-4aaa-bbbb-cccccccccccc")],
        priorRecordDigests: [try AccountPriorRecordDigest(deviceID: try AccountDeviceID("88888888-9999-4aaa-bbbb-cccccccccccc"), recordDigest: Data(repeating: 0x44, count: 32))]
    )
    let state = try AccountTrustState(
        accountID: account, epoch: epoch, revision: revision,
        previousCommitDigest: Data(repeating: 0x45, count: 32), transition: transition,
        keyGeneration: keyGeneration, keyCommitment: material.commitment, members: members,
        signerDeviceID: mac, signature: Data(repeating: 0x46, count: 64)
    )
    let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
    let packages = try members.map { member in
        try AccountGroupKeyPackage(
            accountID: account, epoch: epoch, stateRevision: revision,
            keyGeneration: keyGeneration, stateDigest: stateDigest, keyCommitment: state.keyCommitment,
            recipientDeviceID: member.deviceID, senderDeviceID: mac,
            senderEphemeralPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
            nonce: Data(repeating: 0x47, count: 12), encryptedKeyMaterial: Data(repeating: 0x48, count: 80),
            signature: Data(repeating: 0x49, count: 64)
        )
    }
    return (try AccountTrustStateCommit(state: state, keyPackages: packages), material)
}

private actor AuthenticatedProducerModeSwitchTransport: AccountHTTPTransport {
    private let account: PlainpostAccountID
    private let mailbox: Data
    private let mac: AccountDeviceID
    private let node: AccountDeviceID
    private let trustHead: Data
    private var assignment: NotificationProducerAssignment?
    private var requests: [URLRequest] = []
    private var policyWrites = 0

    init(account: PlainpostAccountID, mailbox: Data, mac: AccountDeviceID, node: AccountDeviceID, trustHead: Data) {
        self.account = account; self.mailbox = mailbox; self.mac = mac; self.node = node; self.trustHead = trustHead
    }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        requests.append(request)
        let path = request.url?.path ?? ""
        if path.contains("/direct-policies") || path.contains("/node/policy") { policyWrites += 1 }
        switch (request.httpMethod, path) {
        case ("POST", "/v1/notifications/producers/owner-query"):
            guard let assignment else { return AccountHTTPResponse(statusCode: 409, headers: [:], body: Data()) }
            return try json(["kind": "notification.producer-selection-state.v2", "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox), "producerDeviceID": assignment.producerDeviceID.rawValue, "producerKind": assignment.kind.rawValue, "generation": assignment.generation, "trustEpoch": 1, "trustRevision": 2, "trustHead": AccountWireCodec.encodeBase64URL(trustHead)])
        case ("POST", "/v1/notifications/producers/step-up"):
            return try json(["kind": "notification.producer-step-up.v2", "authorization": AccountWireCodec.encodeBase64URL(Data(repeating: 0x51, count: 32)), "requestDigest": AccountWireCodec.encodeBase64URL(Data(repeating: 0x52, count: 32))])
        case ("PUT", "/v1/notifications/producers"):
            let object = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            let expected = try XCTUnwrap((object["expectedGeneration"] as? NSNumber)?.uint64Value)
            guard expected == assignment?.generation ?? 0,
                  let producerString = object["producerDeviceID"] as? String,
                  let producer = try? AccountDeviceID(producerString),
                  let kindString = object["producerKind"] as? String,
                  let kind = NotificationProducerKind(rawValue: kindString),
                  (kind == .mac ? producer == mac : producer == node) else {
                return AccountHTTPResponse(statusCode: 409, headers: [:], body: Data())
            }
            let next = expected + 1
            assignment = NotificationProducerAssignment(logicalMailboxID: mailbox, producerDeviceID: producer, kind: kind, generation: next, trustEpoch: 1, trustRevision: 2, trustHead: trustHead)
            return try json(["kind": "notification.producer-selection.v2", "generation": next])
        case ("POST", "/v1/notifications/assignments/query"):
            guard let assignment else { return try json(["kind": "notification.account-assignments.v2", "assignments": []]) }
            return try json(["kind": "notification.account-assignments.v2", "assignments": [["logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox), "producerDeviceID": assignment.producerDeviceID.rawValue, "producerKind": assignment.kind.rawValue, "generation": assignment.generation, "trustEpoch": 1, "trustRevision": 2, "trustHead": AccountWireCodec.encodeBase64URL(trustHead)] ]])
        default:
            return AccountHTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func json(_ object: [String: Any]) throws -> AccountHTTPResponse {
        AccountHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    func requestsSnapshot() -> [URLRequest] { requests }
    func policyWriteCount() -> Int { policyWrites }
}

private actor SelectorTimestampTransport: AccountHTTPTransport {
    private let account: PlainpostAccountID
    private let mailbox: Data
    private let mac: AccountDeviceID
    private let node: AccountDeviceID
    private let trustHead: Data
    private var assignment: NotificationProducerAssignment?
    private var timestamps: [String: Date] = [:]
    private var requestSummaryValues: [String] = []

    init(account: PlainpostAccountID, mailbox: Data, mac: AccountDeviceID, node: AccountDeviceID, trustHead: Data) {
        self.account = account
        self.mailbox = mailbox
        self.mac = mac
        self.node = node
        self.trustHead = trustHead
    }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        let path = request.url?.path ?? ""
        if path != "/v1/sessions/refresh",
           let encodedProof = request.value(forHTTPHeaderField: "DPoP"),
           let proofData = try? AccountWireCodec.decodeBase64URL(encodedProof),
           let proof = try? JSONSerialization.jsonObject(with: proofData) as? [String: String],
           let timestamp = proof["timestamp"].flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            timestamps[path] = timestamp
        }
        switch (request.httpMethod, path) {
        case ("POST", "/v1/sessions/refresh"):
            requestSummaryValues.append("refresh")
            let body = try JSONSerialization.data(withJSONObject: [
                "kind": "account.session-refresh.v1",
                "accessToken": "rotated-access",
                "accessExpiresAt": "2031-01-01T00:00:00Z",
                "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 2, count: 32)),
                "refreshCredentialID": account.rawValue,
                "refreshExpiresAt": "2031-02-01T00:00:00Z",
                "offlineLease": "rotated-lease",
                "offlineLeaseExpiresAt": "2031-02-01T00:00:00Z",
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body)
        case ("POST", "/v1/notifications/producers/owner-query"):
            guard let assignment else {
                requestSummaryValues.append("owner-query:409")
                return AccountHTTPResponse(statusCode: 409, headers: [:], body: Data())
            }
            requestSummaryValues.append("owner-query:200")
            return try json([
                "kind": "notification.producer-selection-state.v2",
                "logicalMailboxID": AccountWireCodec.encodeBase64URL(mailbox),
                "producerDeviceID": assignment.producerDeviceID.rawValue,
                "producerKind": assignment.kind.rawValue,
                "generation": assignment.generation,
                "trustEpoch": 1,
                "trustRevision": 2,
                "trustHead": AccountWireCodec.encodeBase64URL(trustHead),
            ])
        case ("POST", "/v1/notifications/producers/step-up"):
            requestSummaryValues.append("step-up:200")
            return try json([
                "kind": "notification.producer-step-up.v2",
                "authorization": AccountWireCodec.encodeBase64URL(Data(repeating: 0x51, count: 32)),
                "requestDigest": AccountWireCodec.encodeBase64URL(Data(repeating: 0x52, count: 32)),
            ])
        case ("PUT", "/v1/notifications/producers"):
            guard let body = request.httpBody,
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let producerString = object["producerDeviceID"] as? String,
                  let producer = try? AccountDeviceID(producerString),
                  let kindString = object["producerKind"] as? String,
                  let kind = NotificationProducerKind(rawValue: kindString),
                  let expected = (object["expectedGeneration"] as? NSNumber)?.uint64Value,
                  expected == (assignment?.generation ?? 0),
                  (kind == .mac ? producer == mac : producer == node) else {
                requestSummaryValues.append("put:409")
                return AccountHTTPResponse(statusCode: 409, headers: [:], body: Data())
            }
            requestSummaryValues.append("put:200")
            assignment = NotificationProducerAssignment(logicalMailboxID: mailbox, producerDeviceID: producer, kind: kind, generation: expected + 1, trustEpoch: 1, trustRevision: 2, trustHead: trustHead)
            return try json(["kind": "notification.producer-selection.v2", "generation": expected + 1])
        default:
            return AccountHTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    func timestampsSnapshot() -> [String: Date] { timestamps }
    func requestSummary() -> [String] { requestSummaryValues }

    private func json(_ object: [String: Any]) throws -> AccountHTTPResponse {
        AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}

private func directPolicyRawResponse(_ json: String) -> AccountHTTPResponse {
    AccountHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
}

private func directPolicyDigestOracle(account: String, actor: String, mailbox: Data?, operation: String, policy: String, expectedVersion: UInt16, nonce: Data) -> Data {
    var transcript = Data()
    func append(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        transcript.append(Data(bytes: &length, count: 4))
        transcript.append(data)
    }
    func uuid(_ value: String) -> Data { withUnsafeBytes(of: UUID(uuidString: value)!.uuid) { Data($0) } }
    append(Data("Plainpost.DirectNotificationPolicyRequest.v1".utf8))
    append(uuid(account)); append(uuid(actor))
    append(Data((mailbox == nil ? "default" : "mailbox").utf8)); append(mailbox ?? Data())
    append(Data(operation.utf8)); append(Data(policy.utf8))
    var version = expectedVersion.bigEndian
    append(Data(bytes: &version, count: 2)); append(nonce)
    return Data(SHA256.hash(data: transcript))
}

private func makeDirectPolicyClient(transport: DirectPolicyTransport, account: String = "00112233-4455-6677-8899-aabbccddeeff", device: String = "11111111-2222-3333-4444-555555555555") throws -> AuthenticatedDirectNotificationPolicyClient {
    let account = try PlainpostAccountID(account)
    let device = try AccountDeviceID(device)
    let secrets = InMemoryAccountSecretStore()
    let credentials = AccountCredentialStore(secretStore: secrets, service: "com.marynavdovenko.Plainpost.AccountTests.DirectPolicy")
    let session = try AccountSessionCredentials(
        accountID: account, deviceID: device, accessToken: "access-token",
        accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        refreshCredential: Data(repeating: 0x19, count: 32), offlineLease: "lease"
    )
    try credentials.saveSession(AccountSession(credentials: session))
    _ = try credentials.loadOrCreateDeviceIdentity()
    let api = try AccountAPIClient(
        transport: transport, credentialStore: credentials,
        manifestStore: BootstrapKeyManifestStore(secretStore: secrets),
        baseURL: URL(string: "https://central.example")!
    )
    return AuthenticatedDirectNotificationPolicyClient(api: api, credentialStore: credentials)
}

private func requestDigest(from transport: DirectPolicyTransport) async throws -> Data {
    let lastRequest = await transport.lastRequest()
    let request = try XCTUnwrap(lastRequest)
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try AccountWireCodec.decodeBase64URL(XCTUnwrap(object["requestDigest"] as? String), exactBytes: 32)
}

private actor RefreshCountingTransport: AccountHTTPTransport {
    private let accountID: PlainpostAccountID
    private var count = 0

    init(accountID: PlainpostAccountID) { self.accountID = accountID }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        guard request.url?.path == "/v1/sessions/refresh" else {
            return AccountHTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        count += 1
        await Task.yield()
        let body = try! JSONSerialization.data(withJSONObject: [
            "kind": "account.session-refresh.v1",
            "accessToken": "rotated-access",
            "accessExpiresAt": "2031-01-01T00:00:00Z",
            "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 2, count: 32)),
            "refreshCredentialID": accountID.rawValue,
            "refreshExpiresAt": "2031-02-01T00:00:00Z",
            "offlineLease": "rotated-lease",
            "offlineLeaseExpiresAt": "2031-02-01T00:00:00Z",
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
        return response
    }

    func refreshCount() -> Int { count }
}

private actor CancellationTransport: AccountHTTPTransport {
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        throw CancellationError()
    }
}

private actor BlockingRefreshTransport: AccountHTTPTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        guard request.url?.path == "/v1/sessions/refresh" else {
            return AccountHTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
        throw CancellationError()
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
        return response
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if started { continuation.resume() } else { startWaiters.append(continuation) }
        }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor FenceResultProbe {
    private var result: String?

    func record(_ result: String) { self.result = result }
    func value() -> String? { result }
}

private final class LockedDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var reads = 0
    private var contenderReads = 0

    init(_ date: Date) { self.date = date }

    var value: Date {
        get {
            lock.withLock {
                reads += 1
                return date
            }
        }
        set { lock.withLock { date = newValue } }
    }

    var readCount: Int { lock.withLock { reads } }

    var contenderValue: Date {
        lock.withLock {
            contenderReads += 1
            return date
        }
    }

    var contenderReadCount: Int { lock.withLock { contenderReads } }
}

private final class AcquisitionStartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    func record() { lock.withLock { starts += 1 } }
    var count: Int { lock.withLock { starts } }
}

private actor TimestampRecordingRefreshTransport: AccountHTTPTransport {
    private let accountID: PlainpostAccountID
    private var timestamp: Date?

    init(accountID: PlainpostAccountID) { self.accountID = accountID }

    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        guard request.url?.path == "/v1/sessions/refresh",
              let encodedProof = request.value(forHTTPHeaderField: "DPoP"),
              let proofData = try? AccountWireCodec.decodeBase64URL(encodedProof),
              let proof = try? JSONSerialization.jsonObject(with: proofData) as? [String: String],
              let proofTimestamp = proof["timestamp"],
              let parsed = ISO8601DateFormatter().date(from: proofTimestamp) else {
            throw AccountRuntimeError.transportFailure
        }
        timestamp = parsed
        let body = try JSONSerialization.data(withJSONObject: [
            "kind": "account.session-refresh.v1",
            "accessToken": "rotated-access",
            "accessExpiresAt": "2031-01-01T00:00:00Z",
            "refreshCredential": AccountWireCodec.encodeBase64URL(Data(repeating: 2, count: 32)),
            "refreshCredentialID": accountID.rawValue,
            "refreshExpiresAt": "2031-02-01T00:00:00Z",
            "offlineLease": "rotated-lease",
            "offlineLeaseExpiresAt": "2031-02-01T00:00:00Z",
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return AccountHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
        return response
    }

    func lastTimestamp() -> Date? { timestamp }
}

private struct FixedCoordinationClient: CoordinationClient {
    let assignment: NotificationRecipientAssignment
    func recipientAssignment(for source: NotificationPublicationSource, claim: NotificationPublicationClaim) async throws -> NotificationRecipientAssignment { assignment }
}

private struct NoOpAssignmentVerifier: RecipientAssignmentVerifying {
    func verify(assignment: NotificationRecipientAssignment, source: NotificationPublicationSource) throws {}
}

private struct UnavailableCoordinationForTest: CoordinationClient {
    func recipientAssignment(for source: NotificationPublicationSource, claim: NotificationPublicationClaim) async throws -> NotificationRecipientAssignment {
        throw NotificationRuntimeError.unavailable
    }
}

private final class RecordingPreviewBuilder: NotificationPreviewBuilder, @unchecked Sendable {
    private(set) var envelopes: [Data] = []
    func envelope(for source: NotificationPublicationSource, claim: NotificationPublicationClaim, recipient: NotificationRecipientSnapshot) throws -> Data {
        envelopes.append(Data([1]))
        return Data([1])
    }
}

private struct FixedPreviewBuilder: NotificationPreviewBuilder {
    let bytes: Data
    func envelope(for source: NotificationPublicationSource, claim: NotificationPublicationClaim, recipient: NotificationRecipientSnapshot) throws -> Data { bytes }
}

private final class RecordingRelayClient: RelayClient, @unchecked Sendable {
    private(set) var bytes: [Data] = []
    func deliver(_ delivery: NotificationDeliveryClaim) async throws -> NotificationRelayResult {
        bytes.append(delivery.envelopeBytes)
        return NotificationRelayResult(outcome: .accepted)
    }
}

private final class RecordingPublicationStore: NotificationPublicationStore, @unchecked Sendable {
    let claimValue: NotificationPublicationClaim
    let sourceValue: NotificationPublicationSource
    let recipient: NotificationRecipientSnapshot
    private(set) var frozenEnvelopeBytes: [Data] = []
    private(set) var outcomes: [NotificationDeliveryOutcome] = []

    init(claim: NotificationPublicationClaim, source: NotificationPublicationSource, recipient: NotificationRecipientSnapshot) {
        claimValue = claim
        sourceValue = source
        self.recipient = recipient
        if claim.resumesFrozenPublication { frozenEnvelopeBytes = [Data([0xAA, 0xBB])] }
    }

    func source(for publicationID: String) throws -> NotificationPublicationSource? { sourceValue }
    func claimDeliveries(publicationID: String, leaseToken: String, limit: Int, now: Date) throws -> [NotificationDeliveryClaim] {
        [NotificationDeliveryClaim(
            publicationID: claimValue.publicationID, recipientID: recipient.recipientID,
            routingHandle: recipient.routingHandle, agreementPublicKey: recipient.agreementPublicKey,
            envelopeBytes: frozenEnvelopeBytes[0], producerDeviceID: "producer",
            producerGeneration: 7, policyVersion: 1, leaseToken: leaseToken,
            leaseExpiresAt: now.addingTimeInterval(60)
        )]
    }
    func nextWorkDate(now: Date) throws -> Date? { nil }
    func claimNotificationPublication(now: Date, leaseToken: String, leaseDuration: TimeInterval) throws -> NotificationPublicationClaim? { claimValue }
    func claimNotificationPublications(now: Date, leaseToken: String, leaseDuration: TimeInterval, limit: Int) throws -> [NotificationPublicationClaim] { [claimValue] }
    func freezeNotificationPublication(publicationID: String, leaseToken: String, configVersion: String, producerGeneration: Int64, recipients: [NotificationRecipientSnapshot], envelopeBytes: [Data]) throws -> Bool {
        frozenEnvelopeBytes = envelopeBytes
        return true
    }
    func cancelNotificationPublication(publicationID: String, leaseToken: String, configVersion: String, producerGeneration: Int64) throws -> Bool { true }
    func recordNotificationDeliveryOutcome(publicationID: String, leaseToken: String, recipientID: String, outcome: NotificationDeliveryOutcome, nextAttemptAt: Date?) throws -> Bool {
        outcomes.append(outcome)
        return true
    }
    func cleanupNotificationPublications(olderThan cutoff: Date) throws -> Int { 0 }
}
