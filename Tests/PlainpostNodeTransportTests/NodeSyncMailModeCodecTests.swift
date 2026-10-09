import XCTest
import PlainpostAccountProtocol
@testable import PlainpostNodeTransport

final class NodeSyncMailModeCodecTests: XCTestCase {
    func testGoogleTokenImportRequestIsCanonicalAndRedacted() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let request = try NodeSyncGoogleTokenImportRequest(
            expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical, refreshToken: "1//refresh-secret")
        let wire = try NodeSyncMailModeCodec.encodeGoogleTokenImportRequest(request)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self),
            #"{"expectedProviderIdentity":"ada@example.test","kind":"node-sync.google-token-import-request.v1","logicalMailboxID":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","refreshToken":"1//refresh-secret"}"#)
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeGoogleTokenImportRequest(wire), request)
        XCTAssertFalse(String(describing: request).contains("refresh-secret"))
        XCTAssertFalse(String(reflecting: request).contains("refresh-secret"))
    }

    func testAccountSnapshotUsesAccountRouteAndExistingPageFamily() async throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let page = try NodeSyncCodec.encodeSnapshotPage(NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "3"))
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail/snapshot"))
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: page)])
        let result = try await NodeSyncClient(sender: sender).mailSnapshot(
            try NodeSyncAccountSnapshotRequest(after: "", limit: 50, logicalMailboxID: logical))
        XCTAssertEqual(result.revision, "3")
        let requests = await sender.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/mail/snapshot"])
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests.first).body, as: UTF8.self)
            .contains(#""kind":"node-sync.account-snapshot-request.v1""#))
    }

    func testMirrorCoordinatesRejectUnknownFieldsAndZeroUID() {
        let unknown = Data(#"{"extra":1,"kind":"node-sync.mirror-coordinates-result.v1","records":[]}"#.utf8)
        XCTAssertThrowsError(try NodeSyncMailModeCodec.decodeMirrorCoordinatesResult(unknown))
        let zero = Data(#"{"kind":"node-sync.mirror-coordinates-result.v1","records":[{"memberships":[{"flags":[],"logicalMailboxID":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","mailboxPath":"INBOX","uid":"0","uidValidity":"7"}],"messageID":"m1","rfcMessageID":null}]}"#.utf8)
        XCTAssertThrowsError(try NodeSyncMailModeCodec.decodeMirrorCoordinatesResult(zero))
    }

    func testIMAPProviderImportRequestIsCanonicalAndRedacted() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let request = try NodeSyncIMAPProviderImportRequest(
            expectedProviderIdentity: "grace@example.test",
            imap: NodeSyncMailEndpoint(host: "imap.example.test", port: 993, security: "implicit_tls"),
            logicalMailboxID: logical,
            password: "app-password-secret",
            roles: NodeSyncMailboxRolePaths(archive: nil, drafts: "Drafts", inbox: "INBOX", sent: "Sent", trash: "Trash"),
            smtp: NodeSyncMailEndpoint(host: "smtp.example.test", port: 587, security: "starttls"),
            username: "grace-login")
        let wire = try NodeSyncMailModeCodec.encodeIMAPProviderImportRequest(request)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self),
            #"{"expectedProviderIdentity":"grace@example.test","imap":{"host":"imap.example.test","port":"993","security":"implicit_tls"},"kind":"node-sync.imap-provider-import-request.v1","logicalMailboxID":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","password":"app-password-secret","roles":{"drafts":"Drafts","inbox":"INBOX","sent":"Sent","trash":"Trash"},"smtp":{"host":"smtp.example.test","port":"587","security":"starttls"},"username":"grace-login"}"#)
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeIMAPProviderImportRequest(wire), request)
        for text in [String(describing: request), String(reflecting: request), "\(request)", String(describing: Mirror(reflecting: request).children.map(\.value))] {
            XCTAssertFalse(text.contains("app-password-secret"), text)
        }
        XCTAssertTrue(Mirror(reflecting: request).children.isEmpty)
        let google = try NodeSyncGoogleTokenImportRequest(expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical, refreshToken: "1//refresh-secret")
        XCTAssertTrue(Mirror(reflecting: google).children.isEmpty)
    }

    func testCredentialAndIdentityValidation() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        for token in ["", "a\rb", "a\nb", "a\u{0}b", String(repeating: "x", count: 16_385)] {
            XCTAssertThrowsError(try NodeSyncGoogleTokenImportRequest(expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical, refreshToken: token))
        }
        XCTAssertNoThrow(try NodeSyncGoogleTokenImportRequest(expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical, refreshToken: String(repeating: "x", count: 16_384)))
        for identity in ["Ada@example.test", "ada", "ada@", "@example.test", "a@b@c", "ada @example.test", String(repeating: "a", count: 309) + "@example.test"] {
            XCTAssertThrowsError(try NodeSyncProviderRemoveRequest(expectedProviderIdentity: identity, logicalMailboxID: logical), identity)
        }
        XCTAssertNoThrow(try NodeSyncProviderRemoveRequest(expectedProviderIdentity: String(repeating: "a", count: 307) + "@example.test", logicalMailboxID: logical))
        XCTAssertThrowsError(try NodeSyncMailEndpoint(host: "imap.example.test", port: 0, security: "implicit_tls"))
        XCTAssertThrowsError(try NodeSyncMailEndpoint(host: "imap.example.test", port: 993, security: "tls"))
        XCTAssertThrowsError(try NodeSyncMailboxRolePaths(archive: "INBOX", drafts: "Drafts", inbox: "INBOX", sent: "Sent", trash: "Trash"))
    }

    func testMailCapabilitiesRequireVersionOne() throws {
        let capabilities = NodeSyncMailCapabilities(googleImport: true, imapImport: true, mirrorCoordinates: true, multiAccount: true)
        let wire = try NodeSyncMailModeCodec.encodeMailCapabilities(capabilities)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self), #"{"googleImport":true,"imapImport":true,"kind":"node-sync.mail-capabilities.v1","mirrorCoordinates":true,"multiAccount":true,"version":"1"}"#)
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeMailCapabilities(wire), capabilities)
        let future = Data(String(decoding: wire, as: UTF8.self).replacingOccurrences(of: #""version":"1""#, with: #""version":"2""#).utf8)
        XCTAssertThrowsError(try NodeSyncMailModeCodec.decodeMailCapabilities(future))
    }

    func testMailAccountsRequireExactlyOnePrimaryAndOwnAssignments() throws {
        let ada = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let grace = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 8, count: 32)))
        let inbox = try NodeSyncDiscoveredMailbox(displayName: "Inbox", logicalMailboxID: grace, mailboxHandle: "handle-1", role: "inbox", authorityEpoch: "2")
        let first = try NodeSyncMailAccount(assignments: [], logicalMailboxID: ada, primary: true, providerIdentity: "ada@example.test", providerKind: "gmail", state: .ready)
        let second = try NodeSyncMailAccount(assignments: [inbox], logicalMailboxID: grace, primary: false, providerIdentity: "grace@example.test", providerKind: "generic", state: .authenticationRequired)
        let result = try NodeSyncMailAccountsResult(accounts: [first, second], primaryState: .available)
        XCTAssertEqual(result.primaryAccount, first)
        let wire = try NodeSyncMailModeCodec.encodeMailAccountsResult(result)
        XCTAssertTrue(String(decoding: wire, as: UTF8.self).contains(#""state":"authentication_required""#))
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeMailAccountsResult(wire), result)
        XCTAssertNoThrow(try NodeSyncMailAccountsResult(accounts: [], primaryState: .none))
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [], primaryState: .available))
        let notPrimary = try NodeSyncMailAccount(assignments: [], logicalMailboxID: ada, primary: false, providerIdentity: "ada@example.test", providerKind: "gmail", state: .ready)
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [notPrimary, second], primaryState: .available))
        let unavailable = try NodeSyncMailAccountsResult(accounts: [second], primaryState: .unavailable)
        XCTAssertNil(unavailable.primaryAccount)
        XCTAssertTrue(String(decoding: try NodeSyncMailModeCodec.encodeMailAccountsResult(unavailable), as: UTF8.self).contains(#""primaryState":"unavailable""#))
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [first], primaryState: .unavailable))
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [second], primaryState: .none))
        let otherPrimary = try NodeSyncMailAccount(assignments: [inbox], logicalMailboxID: grace, primary: true, providerIdentity: "grace@example.test", providerKind: "generic", state: .ready)
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [first, otherPrimary], primaryState: .available))
        XCTAssertThrowsError(try NodeSyncMailAccountsResult(accounts: [first, first], primaryState: .available))
        XCTAssertThrowsError(try NodeSyncMailAccount(assignments: [inbox], logicalMailboxID: ada, primary: true, providerIdentity: "ada@example.test", providerKind: "gmail", state: .ready))
        XCTAssertThrowsError(try NodeSyncMailAccount(assignments: [], logicalMailboxID: ada, primary: true, providerIdentity: "ada@example.test", providerKind: "exchange", state: .ready))
    }

    func testMirrorCoordinatesRequestBoundsAndOrdering() throws {
        XCTAssertThrowsError(try NodeSyncMirrorCoordinatesRequest(messageIDs: []))
        XCTAssertThrowsError(try NodeSyncMirrorCoordinatesRequest(messageIDs: ["m2", "m1"]))
        XCTAssertThrowsError(try NodeSyncMirrorCoordinatesRequest(messageIDs: ["m1", "m1"]))
        let twoHundred = (0..<200).map { String(format: "m%03d", $0) }
        XCTAssertNoThrow(try NodeSyncMirrorCoordinatesRequest(messageIDs: twoHundred))
        XCTAssertThrowsError(try NodeSyncMirrorCoordinatesRequest(messageIDs: (0..<201).map { String(format: "m%03d", $0) }))
        let request = try NodeSyncMirrorCoordinatesRequest(messageIDs: ["m1", "m2"])
        XCTAssertEqual(String(decoding: try NodeSyncMailModeCodec.encodeMirrorCoordinatesRequest(request), as: UTF8.self), #"{"kind":"node-sync.mirror-coordinates-request.v1","messageIDs":["m1","m2"]}"#)
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let membership = try NodeSyncMirrorMembership(flags: ["flagged", "seen"], logicalMailboxID: logical, mailboxPath: "INBOX", uid: UInt32.max, uidValidity: 7)
        let coordinate = try NodeSyncMirrorCoordinate(memberships: [membership], messageID: "m1", rfcMessageID: "<m1@example.test>")
        let result = try NodeSyncMirrorCoordinatesResult(records: [coordinate])
        let wire = try NodeSyncMailModeCodec.encodeMirrorCoordinatesResult(result)
        XCTAssertTrue(String(decoding: wire, as: UTF8.self).contains(#""uid":"4294967295","uidValidity":"7""#))
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeMirrorCoordinatesResult(wire), result)
        XCTAssertThrowsError(try NodeSyncMirrorMembership(flags: ["seen", "flagged"], logicalMailboxID: logical, mailboxPath: "INBOX", uid: 1, uidValidity: 7))
        XCTAssertThrowsError(try NodeSyncMirrorMembership(flags: [], logicalMailboxID: logical, mailboxPath: "INBOX", uid: 1, uidValidity: 0))
    }

    func testCredentialRoutesAreSingleDispatchAndReadRoutesRetry() async throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail"))
        let unavailable = NodeHTTPResponse(statusCode: 503, url: url, headers: [:], body: Data())
        let imported = try NodeSyncMailModeCodec.encodeProviderImportResult(NodeSyncProviderImportResult(assignments: [], logicalMailboxID: logical, providerIdentity: "ada@example.test", state: .created))

        let google = RecordingNodeSessionSender(responses: [unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: imported)])
        do {
            _ = try await NodeSyncClient(sender: google).importGoogleToken(NodeSyncGoogleTokenImportRequest(expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical, refreshToken: "1//refresh-secret"))
            XCTFail("unavailable credential import succeeded")
        } catch {
            XCTAssertEqual(error as? NodeSyncClientError, .problem(.unavailable))
        }
        let googleRequests = await google.requests()
        XCTAssertEqual(googleRequests.map(\.path), ["/v1/mail/providers/google/import"])
        XCTAssertEqual(googleRequests.map(\.method), ["POST"])

        let imap = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: imported)])
        let imapRequest = try NodeSyncIMAPProviderImportRequest(
            expectedProviderIdentity: "ada@example.test", imap: NodeSyncMailEndpoint(host: "imap.example.test", port: 993, security: "implicit_tls"),
            logicalMailboxID: logical, password: "secret", roles: NodeSyncMailboxRolePaths(archive: "Archive", drafts: "Drafts", inbox: "INBOX", sent: "Sent", trash: "Trash"),
            smtp: NodeSyncMailEndpoint(host: "smtp.example.test", port: 465, security: "implicit_tls"), username: "ada@example.test")
        let importResult = try await NodeSyncClient(sender: imap).importIMAPProvider(imapRequest)
        XCTAssertEqual(importResult.state, .created)
        let imapRequests = await imap.requests()
        XCTAssertEqual(imapRequests.map(\.path), ["/v1/mail/providers/imap/import"])
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeIMAPProviderImportRequest(try XCTUnwrap(imapRequests.first).body), imapRequest)

        let removed = try NodeSyncMailModeCodec.encodeProviderRemoveResult(NodeSyncProviderRemoveResult(logicalMailboxID: logical, state: "absent"))
        let remove = RecordingNodeSessionSender(responses: [unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: removed)])
        do {
            _ = try await NodeSyncClient(sender: remove).removeProvider(NodeSyncProviderRemoveRequest(expectedProviderIdentity: "ada@example.test", logicalMailboxID: logical))
            XCTFail("unavailable removal succeeded")
        } catch {
            XCTAssertEqual(error as? NodeSyncClientError, .problem(.unavailable))
        }
        let removeRequests = await remove.requests()
        XCTAssertEqual(removeRequests.map(\.path), ["/v1/mail/providers/remove"])

        let capabilities = try NodeSyncMailModeCodec.encodeMailCapabilities(NodeSyncMailCapabilities(googleImport: true, imapImport: false, mirrorCoordinates: true, multiAccount: true))
        let accounts = try NodeSyncMailModeCodec.encodeMailAccountsResult(NodeSyncMailAccountsResult(accounts: [], primaryState: .none))
        let coordinates = try NodeSyncMailModeCodec.encodeMirrorCoordinatesResult(NodeSyncMirrorCoordinatesResult(records: []))
        let deltas = try NodeSyncMailModeCodec.encodeMailDeltaPage(NodeSyncMailDeltaPage(changes: [], nextCursor: "next", revision: "4", waitingAccounts: [logical]))
        let reads = RecordingNodeSessionSender(responses: [
            unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: capabilities),
            unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: accounts),
            unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: coordinates),
            unavailable, NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: deltas),
        ])
        let client = NodeSyncClient(sender: reads)
        let decodedCapabilities = try await client.mailCapabilities()
        XCTAssertFalse(decodedCapabilities.imapImport)
        let decodedAccounts = try await client.mailAccounts()
        XCTAssertEqual(decodedAccounts.accounts, [])
        let decodedCoordinates = try await client.mirrorCoordinates(messageIDs: ["m1"])
        XCTAssertEqual(decodedCoordinates.records, [])
        let decodedDeltas = try await client.mailDeltas(after: "cursor", limit: 25)
        XCTAssertEqual(decodedDeltas.revision, "4")
        XCTAssertEqual(decodedDeltas.waitingAccounts, [logical])
        let readRequests = await reads.requests()
        XCTAssertEqual(readRequests.map(\.path), [
            "/v1/mail/capabilities", "/v1/mail/capabilities", "/v1/mail/accounts", "/v1/mail/accounts",
            "/v1/mail/mirror/coordinates", "/v1/mail/mirror/coordinates", "/v1/mail/deltas", "/v1/mail/deltas",
        ])
        XCTAssertEqual(readRequests.map(\.method), ["GET", "GET", "GET", "GET", "POST", "POST", "POST", "POST"])
        XCTAssertEqual(readRequests[0].body, Data())
        XCTAssertEqual(try NodeSyncCodec.decodeDeltaRequest(readRequests[7].body), try NodeSyncDeltaRequest(after: "cursor", limit: 25))
    }

    func testMailDeltaPageReportsWaitingAccountsWithoutTheirChanges() throws {
        let ada = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let grace = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 8, count: 32)))
        let change = try NodeSyncChange(kind: "upsert", logicalMailboxID: ada, messageID: "m1", threadID: "t1")
        let page = try NodeSyncMailDeltaPage(changes: [change], nextCursor: "tail", revision: "5", waitingAccounts: [grace])
        let wire = try NodeSyncMailModeCodec.encodeMailDeltaPage(page)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self), #"{"changes":[{"kind":"upsert","logicalMailboxID":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc","messageID":"m1","threadID":"t1"}],"kind":"node-sync.mail-delta-page.v1","nextCursor":"tail","revision":"5","waitingAccounts":["CAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg"]}"#)
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeMailDeltaPage(wire), page)
        XCTAssertThrowsError(try NodeSyncMailDeltaPage(changes: [change], nextCursor: "tail", revision: "5", waitingAccounts: [ada]))
        XCTAssertThrowsError(try NodeSyncMailDeltaPage(changes: [], nextCursor: "tail", revision: "5", waitingAccounts: [grace, ada]))
        XCTAssertThrowsError(try NodeSyncCodec.decodeDeltaPage(wire))
    }

    func testSharedContractVectors() throws {
        let fixture = try MailModeContractFixture.load()
        XCTAssertEqual(fixture.kind, "node-sync-v1.mail-mode-vectors")
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(fixture.vectors.isEmpty)
        var families = Set<String>()
        for vector in fixture.vectors {
            let wire = try XCTUnwrap(mailModeVectorBase64URL(vector.wire), vector.name)
            families.insert(vector.family)
            let result = Result { try roundTripMailModeFamily(vector.family, wire) }
            switch vector.expect {
            case "accept":
                switch result {
                case let .success(canonical): XCTAssertEqual(canonical, wire, "\(vector.name): canonical bytes differ")
                case let .failure(error): XCTFail("\(vector.name): accept failed: \(error)")
                }
            case "reject":
                if case .success = result { XCTFail("\(vector.name): rejected vector decoded") }
            default:
                XCTFail("\(vector.name): unknown expectation \(vector.expect)")
            }
        }
        XCTAssertEqual(families, Set(MailModeFamily.allCases.map(\.rawValue)))
    }
}

private enum MailModeFamily: String, CaseIterable {
    case mailCapabilities, mailAccountsResult, googleTokenImportRequest, imapProviderImportRequest, providerImportResult
    case providerRemoveRequest, providerRemoveResult, accountSnapshotRequest, mirrorCoordinatesRequest, mirrorCoordinatesResult
    case mailDeltaPage
}

private enum MailModeVectorError: Error { case unknownFamily(String) }

private func roundTripMailModeFamily(_ family: String, _ wire: Data) throws -> Data {
    guard let family = MailModeFamily(rawValue: family) else { throw MailModeVectorError.unknownFamily(family) }
    switch family {
    case .mailCapabilities: return try NodeSyncMailModeCodec.encodeMailCapabilities(NodeSyncMailModeCodec.decodeMailCapabilities(wire))
    case .mailAccountsResult: return try NodeSyncMailModeCodec.encodeMailAccountsResult(NodeSyncMailModeCodec.decodeMailAccountsResult(wire))
    case .googleTokenImportRequest: return try NodeSyncMailModeCodec.encodeGoogleTokenImportRequest(NodeSyncMailModeCodec.decodeGoogleTokenImportRequest(wire))
    case .imapProviderImportRequest: return try NodeSyncMailModeCodec.encodeIMAPProviderImportRequest(NodeSyncMailModeCodec.decodeIMAPProviderImportRequest(wire))
    case .providerImportResult: return try NodeSyncMailModeCodec.encodeProviderImportResult(NodeSyncMailModeCodec.decodeProviderImportResult(wire))
    case .providerRemoveRequest: return try NodeSyncMailModeCodec.encodeProviderRemoveRequest(NodeSyncMailModeCodec.decodeProviderRemoveRequest(wire))
    case .providerRemoveResult: return try NodeSyncMailModeCodec.encodeProviderRemoveResult(NodeSyncMailModeCodec.decodeProviderRemoveResult(wire))
    case .accountSnapshotRequest: return try NodeSyncMailModeCodec.encodeAccountSnapshotRequest(NodeSyncMailModeCodec.decodeAccountSnapshotRequest(wire))
    case .mirrorCoordinatesRequest: return try NodeSyncMailModeCodec.encodeMirrorCoordinatesRequest(NodeSyncMailModeCodec.decodeMirrorCoordinatesRequest(wire))
    case .mirrorCoordinatesResult: return try NodeSyncMailModeCodec.encodeMirrorCoordinatesResult(NodeSyncMailModeCodec.decodeMirrorCoordinatesResult(wire))
    case .mailDeltaPage: return try NodeSyncMailModeCodec.encodeMailDeltaPage(NodeSyncMailModeCodec.decodeMailDeltaPage(wire))
    }
}

private struct MailModeContractFixture: Decodable {
    struct Vector: Decodable { let name, family, wire, expect: String }
    let kind: String
    let schemaVersion: Int
    let vectors: [Vector]

    static func load() throws -> Self {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Protocol/node-sync-v1/fixtures/mail-mode-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }
}

private func mailModeVectorBase64URL(_ value: String) -> Data? {
    guard !value.contains("=") else { return nil }
    let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: padded)
}
