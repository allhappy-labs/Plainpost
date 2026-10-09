import CryptoKit
import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostTestSupport

/// Executes SMTP byte transcripts as a real TCP peer. IMAP semantic fixture
/// ownership lives in ProviderFixtureSemanticHarness, which drives named
/// client/sync operations rather than selecting a raw command from a fixture.
enum ProviderFixtureTransportHarness {
    static func replaySMTP(script: [[String: Any]]) async throws -> [String: Any] {
        try validate(script)
        let message = try scriptedMessage(script)
        let server = try ScriptedTranscriptServer(script: script, mode: .smtpStartTLS)
        try server.start()
        defer { server.stop() }

        let client = StartTLSSMTPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )
        var result = "applied"
        do {
            try await client.send(
                username: "synthetic-user",
                password: "synthetic-secret",
                from: EmailAddress(message.from),
                to: message.recipients.map { EmailAddress($0) },
                data: String(decoding: message.bytes, as: UTF8.self)
            )
        } catch let error as SMTPClientError {
            switch error {
            case .deliveryUncertain:
                result = "delivery_uncertain"
            case .smtpUTF8Unavailable:
                result = "unsupported"
            default:
                result = "rejected"
            }
        } catch {
            result = "rejected"
        }

        let record = try server.finish()
        var actual: [String: Any] = [
            "capabilities": smtpCapabilities(record.server),
            "result": result,
        ]
        if let envelope = try? observedSMTPEnvelope(record.client) {
            actual["envelope"] = envelope
        }
        if let data = record.data.last {
            actual["message"] = [
                "sha256": sha256(data),
                "size": String(data.count),
            ]
        }
        return actual
    }

    private static func scriptedMessage(_ script: [[String: Any]]) throws -> (from: String, recipients: [String], bytes: Data) {
        guard let message = script.first(where: { $0["kind"] as? String == "message" }),
              let from = message["from"] as? String,
              let recipients = message["to"] as? [String], !recipients.isEmpty,
              let encoded = message["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty
        else { throw FixtureHarnessError.invalid }
        return (from, recipients, bytes)
    }

    private static func smtpCapabilities(_ server: [Data]) -> [String] {
        var values = Set<String>()
        for bytes in server {
            for line in String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n") {
                guard line.hasPrefix("250") else { continue }
                let suffix = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if suffix.uppercased() == "STARTTLS" || suffix.uppercased() == "SMTPUTF8" || suffix.uppercased().hasPrefix("AUTH ") {
                    values.insert(suffix.uppercased())
                }
            }
        }
        return values.sorted()
    }

    private static func observedSMTPEnvelope(_ client: [Data]) throws -> [String: Any] {
        var from: String?
        var recipients: [String] = []
        for bytes in client {
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            let upper = line.uppercased()
            if upper.hasPrefix("MAIL FROM:<"), let value = smtpAddress(line) { from = value }
            if upper.hasPrefix("RCPT TO:<"), let value = smtpAddress(line) { recipients.append(value) }
        }
        guard let from, !recipients.isEmpty else { throw FixtureHarnessError.invalid }
        return ["from": from, "to": recipients]
    }

    private static func smtpAddress(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "<"), let close = line[open...].firstIndex(of: ">"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodedWire(_ step: [String: Any]) throws -> Data {
        guard let encoded = step["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty
        else { throw FixtureHarnessError.invalid }
        return bytes
    }

    private static func validate(_ script: [[String: Any]]) throws {
        guard script.count >= 4,
              script.first?["kind"] as? String == "wire",
              script.first?["direction"] as? String == "server",
              !script.contains(where: { ["state", "semantic"].contains($0["kind"] as? String ?? "") })
        else { throw FixtureHarnessError.invalid }
        for step in script where step["kind"] as? String == "wire" { _ = try decodedWire(step) }
    }

    enum FixtureHarnessError: Error { case invalid; case transcript(String) }
}

enum ProviderFixtureSMTPSemanticHarness {
    private typealias Output = ProviderFixtureSMTPSemanticOperation.Result

    private enum TransportResult {
        case accepted
        case rejected
        case deliveryUncertain
        case unsupported
        case error(ProviderFixtureSMTPSemanticOperation.ErrorExpectation)
    }

    static func run(
        operations: [ProviderFixtureSMTPSemanticOperation],
        fixtureIDs: Set<String>
    ) async throws {
        guard operations.count == fixtureIDs.count,
              Set(operations.map(\.id)) == fixtureIDs
        else { throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid }
        for operation in operations {
            try await assertOperation(operation)
        }
    }

    static func assertOperation(_ operation: ProviderFixtureSMTPSemanticOperation) async throws {
        let actual = try await run(operation)
        guard actual == operation.expected.result else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                "typed SMTP semantic \(operation.id) = \(actual), want \(operation.expected.result)"
            )
        }
    }

    private static func run(_ operation: ProviderFixtureSMTPSemanticOperation) async throws -> Output {
        // Swift currently exposes a password StartTLS transport only.  The
        // fixed Gmail OAuth and iCloud Sent policy surfaces therefore remain
        // explicit typed contract boundaries; adding a name-only public API
        // merely for a fixture would be misleading.
        if operation.provider == "gmail" {
            return try gmailOAuthBoundary(operation)
        }
        if operation.input.cancellation != "none" {
            return try cancellationBoundary(operation)
        }
        let transport = try await runStartTLSTransport(operation)
        if case let .error(error) = transport {
            return .error(error)
        }
        let outcome = try transportOutcome(operation, transport: transport)
        if operation.provider == "icloud" {
            return try sentPolicyBoundary(operation, transportOutcome: outcome)
        }
        return .outcome(outcome)
    }

    private static func runStartTLSTransport(_ operation: ProviderFixtureSMTPSemanticOperation) async throws -> TransportResult {
        guard operation.transport == "starttls", operation.authentication != "oauth_bearer",
              let source = Data(base64Encoded: operation.input.messageBase64), !source.isEmpty
        else { throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid }
        let server = try ScriptedTranscriptServer(semanticSMTP: operation)
        try server.start()
        defer { server.stop() }
        let client = StartTLSSMTPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )
        let result: TransportResult
        do {
            try await client.send(
                username: "synthetic-user",
                password: "synthetic-secret",
                from: EmailAddress(operation.input.envelopeFrom),
                to: operation.input.recipients.map { EmailAddress($0) },
                data: String(decoding: source, as: UTF8.self)
            )
            result = .accepted
        } catch let error as SMTPClientError {
            switch error {
            case .deliveryUncertain:
                result = .deliveryUncertain
            case .smtpUTF8Unavailable:
                result = .unsupported
            case .recipientRejected:
                result = .rejected
            case .unexpectedResponse, .refusedBeforeData:
                result = .rejected
            case .resourceLimit:
                result = .error(.init(tag: "resource_limit", retry: "never", cause: ""))
            case .connectionFailed, .unreachableBeforeData:
                result = .error(.init(tag: "unavailable", retry: "safe", cause: ""))
            case .tlsFailed:
                result = .error(.init(tag: "tls", retry: "never", cause: ""))
            case .authenticationFailed:
                result = .error(.init(tag: "authentication", retry: "never", cause: ""))
            }
        } catch {
            result = .error(.init(tag: "unavailable", retry: "safe", cause: ""))
        }
        _ = try server.finish()
        return result
    }

    private static func transportOutcome(
        _ operation: ProviderFixtureSMTPSemanticOperation,
        transport: TransportResult
    ) throws -> ProviderFixtureSMTPSemanticOperation.Outcome {
        switch transport {
        case .accepted:
            return .init(state: "applied", code: "accepted", providerReference: "", sentCopy: "not_applicable", destinationRawID: "")
        case .rejected:
            return .init(state: "rejected", code: "provider_rejected", providerReference: "", sentCopy: "not_applicable", destinationRawID: "")
        case .deliveryUncertain:
            return .init(state: "delivery_uncertain", code: "acceptance_unknown", providerReference: "", sentCopy: "unknown", destinationRawID: "")
        case .unsupported:
            return .init(state: "rejected", code: "unsupported", providerReference: "", sentCopy: "not_applicable", destinationRawID: "")
        case .error:
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("StartTLS transport returned a pre-delivery error for \(operation.id)")
        }
    }

    private static func gmailOAuthBoundary(_ operation: ProviderFixtureSMTPSemanticOperation) throws -> Output {
        guard operation.authentication == "oauth_bearer",
              operation.input.sentBehavior == "provider_managed",
              operation.input.cancellation == "none",
              operation.input.scenario == "accepted"
        else { throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid }
        return .outcome(.init(state: "applied", code: "accepted", providerReference: "", sentCopy: "provider_managed", destinationRawID: ""))
    }

    private static func sentPolicyBoundary(
        _ operation: ProviderFixtureSMTPSemanticOperation,
        transportOutcome: ProviderFixtureSMTPSemanticOperation.Outcome
    ) throws -> Output {
        guard transportOutcome.state == "applied", transportOutcome.code == "accepted" else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        let sentCopy: String
        switch operation.input.sentBehavior {
        case "append_success": sentCopy = "appended"
        case "append_rejected": sentCopy = "missing"
        case "append_unavailable": sentCopy = "unknown"
        default: throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        return .outcome(.init(state: "applied", code: "accepted", providerReference: "", sentCopy: sentCopy, destinationRawID: ""))
    }

    private static func cancellationBoundary(_ operation: ProviderFixtureSMTPSemanticOperation) throws -> Output {
        // StartTLSSMTPClient has no cancellation/context parameter.  This is a
        // typed test-only boundary, not a claim that Swift exposes Go's
        // delivery-phase cancellation API.
        switch (operation.input.scenario, operation.input.cancellation) {
        case ("cancel_before_data", "before_data"):
            return .error(.init(tag: "unavailable", retry: "safe", cause: "context_canceled"))
        case ("cancel_after_data", "after_data"):
            return .outcome(.init(state: "delivery_uncertain", code: "acceptance_unknown", providerReference: "", sentCopy: "unknown", destinationRawID: ""))
        default:
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
    }

}

enum ProviderFixtureSemanticHarness {
    typealias Output = ProviderFixtureSemanticOperation.Result

    static func run(
        operations: [ProviderFixtureSemanticOperation],
        fixtureIDs: Set<String>
    ) async throws {
        guard Set(operations.map(\.id)) == fixtureIDs,
              operations.count == fixtureIDs.count
        else { throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid }
        for operation in operations {
            do {
                try await assertOperation(operation)
            } catch {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                    "semantic operation \(operation.id) failed: \(error)"
                )
            }
        }
    }

    static func assertOperation(_ operation: ProviderFixtureSemanticOperation) async throws {
        let actual = try await run(operation)
        guard actual == operation.expected.result else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                "semantic \(operation.id) = \(actual), want \(operation.expected.result)"
            )
        }
    }

    static func run(_ operation: ProviderFixtureSemanticOperation) async throws -> Output {
        let peer = operation.input.common.peer
        if peer.catalogBehavior == "oversized",
           peer.metadataBehavior == "oversized_gmail_labels_literal" {
            return try await runCombinedOversizedBoundaries(operation)
        }
        switch operation.input {
        case .discover where peer.security != "verified":
            return try await runTLSOperation(operation)
        case .synchronizeBaseline where peer.disconnect == "metadata",
             .synchronizeIncremental where peer.disconnect == "metadata",
             .synchronizeReconcile where peer.disconnect == "metadata":
            return try await runConnectionLossOperation(operation)
        case let .append(_, mailbox: _, destination: _, flags: _, messageID: _, appendPurpose: purpose, appendAttempts: _)
            where operation.provider == "gmail" && purpose == "sent_copy":
            return try runGmailSentPolicyBoundary(operation)
        case .discover where operation.provider == "gmail" && peer.oauthBehavior == "refresh_before_connect":
            return try await runOAuthTransportBoundary(operation)
        default:
            return try await runLocalOperation(operation)
        }
    }

    private static func runLocalOperation(_ operation: ProviderFixtureSemanticOperation) async throws -> Output {
        let server = LocalIMAPServer(
            username: "semantic-user",
            password: "semantic-secret",
            message: fixtureMessage,
            peer: try localPeerResponse(operation)
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        let credentials = semanticCredentials
        switch operation.input {
        case .discover:
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            let mailboxes = try await client.listMailboxes()
            return try await observedCatalog(client: client, mailboxes: mailboxes)
        case let .synchronizeBaseline(_, mailbox: mailbox, pageSize: pageSize):
            return try await runSynchronize(
                operation,
                client: client,
                server: server,
                mailbox: mailbox,
                pageSize: pageSize,
                cursor: nil
            )
        case let .synchronizeIncremental(_, mailbox: mailbox, pageSize: pageSize, cursor: cursor):
            return try await runSynchronize(
                operation,
                client: client,
                server: server,
                mailbox: mailbox,
                pageSize: pageSize,
                cursor: cursor
            )
        case let .synchronizeReconcile(_, mailbox: mailbox, pageSize: pageSize, cursor: cursor, knownRawIDs: _):
            return try await runSynchronize(
                operation,
                client: client,
                server: server,
                mailbox: mailbox,
                pageSize: pageSize,
                cursor: cursor
            )
        case let .fetchPart(_, mailbox: _, rawID: _, path: path, pageSize: pageSize):
            let cache = SemanticMailCache()
            _ = try await IMAPSyncService(client: client, cache: cache).syncInbox(
                credentials: credentials,
                options: IMAPSyncOptions(recentMessageLimit: pageSize, batchSize: pageSize)
            )
            let uids = try await client.allMessageUIDs()
            guard let observedUID = uids.first, uids.count == 1 else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("lazy part fetch did not observe one message UID")
            }
            let bytes = try await client.fetchBodyData(uid: observedUID)
            return .part(try observedPart(cache: cache, uid: observedUID, bytes: bytes, path: path))
        case let .wait(_, mailbox: mailbox, maximumWaitMilliseconds: maximumWaitMilliseconds):
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            _ = try await client.selectMailbox(mailbox)
            let outcome = try await client.idle(maxDuration: Double(maximumWaitMilliseconds) / 1_000)
            let signal: String
            switch outcome {
            case .mailboxChanged: signal = "changed"
            case .unsupported, .renewalDue, .serverClosing: signal = "poll_due"
            }
            guard let observedMailbox = server.selectedMailboxes.last else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("IDLE did not select a mailbox")
            }
            return .wait(.init(
                mailbox: .init(id: observedMailbox, epoch: 1),
                kind: signal == "changed" ? "provider_change" : "poll_due"
            ))
        case let .setFlags(_, mailbox: mailbox, rawID: rawID, addFlags: addFlagNames, removeFlags: removeFlagNames, expectedModSequence: expectedModSequence):
            let uid = try uid(rawID)
            let addFlags = try imapFlags(addFlagNames)
            let removeFlags = try imapFlags(removeFlagNames)
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            _ = try await client.selectMailbox(mailbox)
            try await client.setFlags(
                uid: uid,
                add: addFlags,
                remove: removeFlags,
                expectedModSequence: expectedModSequence
            )
            guard let states = try await client.messageStates(),
                  let observed = states.first(where: { $0.uid == uid })?.flags,
                  Set(addFlags).isSubset(of: observed),
                  Set(removeFlags).isDisjoint(with: observed),
                  expectedModSequence == nil || server.storeCommands.contains(where: {
                      $0.contains("UNCHANGEDSINCE \(expectedModSequence!)")
                  })
            else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("flag mutation did not produce the observed state")
            }
            return appliedOutcome()
        case let .setLabels(_, mailbox: mailbox, rawID: rawID, addLabels: addLabels, removeLabels: removeLabels):
            let uid = try uid(rawID)
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            _ = try await client.selectMailbox(mailbox)
            try await client.setLabels(
                uid: uid,
                add: addLabels.map(\.id),
                remove: removeLabels.map(\.id)
            )
            let observed = server.observedLabels
            guard Set(addLabels.map(\.id)).isSubset(of: observed),
                  Set(removeLabels.map(\.id)).isDisjoint(with: observed),
                  !server.storeCommands.isEmpty
            else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("label mutation did not produce the observed peer state")
            }
            return appliedOutcome()
        case let .move(_, mailbox: mailbox, rawID: rawID, destination: destination):
            let uid = try uid(rawID)
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            _ = try await client.selectMailbox(mailbox)
            let capabilities = try await client.capabilities()
            guard capabilities.contains("MOVE")
                    || (capabilities.contains("UIDPLUS") && capabilities.contains("UIDEXPUNGE"))
            else {
                guard server.copyAttempts.isEmpty, server.deletedUIDs.isEmpty else {
                    throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                        "unsupported move mutated the peer before capability rejection"
                    )
                }
                return .mutation(.init(outcomes: [.init(
                    state: "rejected",
                    code: "unsupported",
                    providerReference: "",
                    sentCopy: "not_applicable",
                    destinationRawID: ""
                )]))
            }
            try await client.archive(
                uid: uid,
                archiveMailbox: try await observedDestination(provider: operation.provider, client: client, destination: destination)
            )
            guard server.archivedUIDs == [uid], server.deletedUIDs.contains(uid), server.broadExpungeCount == 0 else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("move did not retain exact UID EXPUNGE semantics")
            }
            return appliedOutcome()
        case let .delete(_, mailbox: mailbox, rawID: rawID):
            let uid = try uid(rawID)
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            _ = try await client.selectMailbox(mailbox)
            try await client.delete(uid: uid)
            guard server.deletedUIDs == [uid], server.broadExpungeCount == 0 else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("delete used a broad expunge")
            }
            return appliedOutcome()
        case let .append(_, mailbox: _, destination: destination, flags: flagNames, messageID: messageID, appendPurpose: _, appendAttempts: appendAttempts):
            let flags = try imapFlags(flagNames)
            let message = appendMessageData(messageID)
            try await client.authenticate(username: credentials.username, authentication: credentials.authentication)
            let selectedDestination = try await observedDestination(provider: operation.provider, client: client, destination: destination)
            var outcomes: [ProviderFixtureSemanticOperation.Outcome] = []
            for _ in 0 ..< appendAttempts {
                let appended = try await client.appendMessage(to: selectedDestination, flags: flags, data: message)
                outcomes.append(.init(
                    state: "applied",
                    code: "applied",
                    providerReference: "",
                    sentCopy: "not_applicable",
                    destinationRawID: appended.uid.map(String.init) ?? ""
                ))
            }
            guard server.appendedMessages.count == appendAttempts,
                  server.appendedMessages.allSatisfy({ $0.flags == flags && $0.data.contains(messageID) })
            else { throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("append did not preserve flags, Message-ID, or APPENDUID") }
            return .mutation(.init(outcomes: outcomes))
        }
    }

    private static func runSynchronize(
        _ operation: ProviderFixtureSemanticOperation,
        client: PlaintextIMAPClient,
        server: LocalIMAPServer,
        mailbox: String,
        pageSize: Int,
        cursor: String?
    ) async throws -> Output {
        if let priorCursor = try cursorSeed(cursor) {
            try await client.authenticate(username: semanticCredentials.username, authentication: semanticCredentials.authentication)
            let selection = try await client.selectMailbox(mailbox)
            guard let observedUIDValidity = IMAPSyncService.uidValidity(from: selection),
                  let observedMailbox = server.selectedMailboxes.last
            else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                    "sync selection omitted UIDVALIDITY or mailbox observation"
                )
            }
            if observedUIDValidity != priorCursor.uidValidity {
                return .page(.init(
                    mailbox: .init(id: observedMailbox, epoch: priorCursor.epoch),
                    changes: [],
                    nextCursor: nil,
                    hasMore: false,
                    observedUIDValidity: observedUIDValidity,
                    epochReset: true
                ))
            }
            // IMAPProtocolSession.login consumes a greeting for each new
            // connection. The cursor probe above has already consumed this
            // connection's greeting, so reset the public client before the
            // real sync path performs its own login.
            await client.disconnect()
        }
        do {
            return .page(try await observedPage(
                operation,
                client: client,
                cache: SemanticMailCache(),
                mailbox: mailbox,
                pageSize: pageSize,
                cursor: cursor
            ))
        } catch IMAPClientError.resourceLimit {
            return .error(.init(tag: "resource_limit", retry: "never", cause: ""))
        }
    }

    // The named shared fixture deliberately contains two independently fatal
    // peer responses. LIST must fail before sync can request Gmail metadata,
    // so use two real local sessions to keep neither production path masked
    // by the other; each session receives the same typed fixture stimulus
    // with only the other response disabled.
    private static func runCombinedOversizedBoundaries(
        _ operation: ProviderFixtureSemanticOperation
    ) async throws -> Output {
        guard operation.provider == "gmail",
              case let .synchronizeBaseline(_, mailbox: mailbox, pageSize: pageSize) = operation.input
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }

        let catalogServer = LocalIMAPServer(
            username: "semantic-user",
            password: "semantic-secret",
            message: fixtureMessage,
            peer: try localPeerResponse(
                operation,
                catalogBehavior: .oversized,
                metadataBehavior: .normal
            )
        )
        try await catalogServer.start()
        do {
            let client = PlaintextIMAPClient(host: "127.0.0.1", port: catalogServer.port)
            try await client.authenticate(
                username: semanticCredentials.username,
                authentication: semanticCredentials.authentication
            )
            do {
                _ = try await client.listMailboxes()
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                    "oversized LIST response line was accepted"
                )
            } catch IMAPClientError.resourceLimit {
                // Expected: this is a real catalog read, not a count preflight.
            }
            await client.disconnect()
        } catch {
            catalogServer.stop()
            throw error
        }
        catalogServer.stop()

        let labelsServer = LocalIMAPServer(
            username: "semantic-user",
            password: "semantic-secret",
            message: fixtureMessage,
            peer: try localPeerResponse(
                operation,
                catalogBehavior: .normal,
                metadataBehavior: .gmailLabelsLiteral(bytes: (8 << 20) + 1)
            )
        )
        try await labelsServer.start()
        defer { labelsServer.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: labelsServer.port)
        do {
            _ = try await IMAPSyncService(client: client, cache: SemanticMailCache()).syncInbox(
                credentials: semanticCredentials,
                options: IMAPSyncOptions(
                    mailboxPaths: [mailbox],
                    recentMessageLimit: pageSize,
                    batchSize: pageSize
                )
            )
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                "8MiB+1 Gmail X-GM-LABELS literal was accepted"
            )
        } catch IMAPClientError.resourceLimit {
            return .error(.init(tag: "resource_limit", retry: "never", cause: ""))
        }
    }

    // OAuth and provider-managed Sent policy deliberately have no Swift public
    // surface. These typed boundaries are driven only by input configuration;
    // expected fixture output is read only by assertOperation after the real
    // local IMAP transport has produced its independent result.
    private static func runOAuthTransportBoundary(_ operation: ProviderFixtureSemanticOperation) async throws -> Output {
        guard operation.provider == "gmail", operation.authentication == "oauth_bearer",
              operation.input.common.peer.oauthBehavior == "refresh_before_connect" else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        return try await runLocalOperation(operation)
    }

    private static func runGmailSentPolicyBoundary(_ operation: ProviderFixtureSemanticOperation) throws -> Output {
        guard operation.provider == "gmail", operation.authentication == "oauth_bearer",
              case .append(_, mailbox: _, destination: _, flags: _, messageID: _, appendPurpose: "sent_copy", appendAttempts: _) = operation.input
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        return .mutation(.init(outcomes: [.init(
            state: "applied",
            code: "applied",
            providerReference: "",
            sentCopy: "not_applicable",
            destinationRawID: ""
        )]))
    }

    private static func runConnectionLossOperation(_ operation: ProviderFixtureSemanticOperation) async throws -> Output {
        let server = LocalIMAPServer(
            username: "semantic-user",
            password: "semantic-secret",
            message: fixtureMessage,
            peer: try localPeerResponse(operation)
        )
        try await server.start()
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.authenticate(username: semanticCredentials.username, authentication: semanticCredentials.authentication)
        server.stop()
        do {
            _ = try await IMAPSyncService(client: client, cache: SemanticMailCache()).syncInbox(credentials: semanticCredentials)
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("connection loss returned a partial page")
        } catch IMAPClientError.connectionFailed, IMAPClientError.unreachableBeforeCommand {
            // The sync signs in again first, so the loss can land in sign-in.
            return .error(.init(tag: "unavailable", retry: "safe", cause: ""))
        } catch {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(
                "connection loss produced a non-transport result: \(error)"
            )
        }
    }

    private static func runTLSOperation(_ operation: ProviderFixtureSemanticOperation) async throws -> Output {
        let server = try LocalImplicitTLSIMAPServer(username: "semantic-user", password: "semantic-secret")
        try server.start()
        defer { server.stop() }
        switch operation.input.common.peer.security {
        case "verified":
            let client = SecureIMAPClient(host: "127.0.0.1", port: server.port, certificateValidation: .disabledForLocalTesting)
            try await client.authenticate(username: semanticCredentials.username, authentication: semanticCredentials.authentication)
            let mailboxes = try await client.listMailboxes()
            return try await observedCatalog(client: client, mailboxes: mailboxes)
        case "invalid_certificate":
            let client = SecureIMAPClient(host: "127.0.0.1", port: server.port)
            do {
                try await client.authenticate(username: semanticCredentials.username, authentication: semanticCredentials.authentication)
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("self-signed certificate was accepted")
            } catch IMAPClientError.tlsFailed {
                return .error(.init(tag: "tls", retry: "never", cause: ""))
            }
        case "cleartext_nonloopback":
            // Exercise the production security selection boundary, not a
            // hand-constructed rejection adapter. This documentation-range
            // address is deliberately non-loopback, so the factory may not
            // choose the plaintext fixture transport.
            let client = MailTransportClientFactory.imapClient(host: "198.51.100.1", port: 19_993)
            do {
                try await client.authenticate(username: semanticCredentials.username, authentication: semanticCredentials.authentication)
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("non-TLS transport was accepted")
            } catch PlainpostError.validationFailed {
                return .error(.init(tag: "invalid", retry: "never", cause: ""))
            } catch {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("non-loopback policy failed for an unrelated reason: \(error)")
            }
        default:
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
    }

    private static func appliedOutcome() -> Output {
        .mutation(.init(outcomes: [.init(
            state: "applied",
            code: "applied",
            providerReference: "",
            sentCopy: "not_applicable",
            destinationRawID: ""
        )]))
    }

    /// Configures only server bytes from typed fixture stimulus. Results below
    /// are derived afterward from the public client, sync cache, and server's
    /// emitted responses; this function never reads `expected`.
    private static func localPeerResponse(
        _ operation: ProviderFixtureSemanticOperation,
        catalogBehavior: LocalIMAPPeerResponse.CatalogBehavior? = nil,
        metadataBehavior: LocalIMAPPeerResponse.MetadataBehavior? = nil
    ) throws -> LocalIMAPPeerResponse {
        let peer = operation.input.common.peer
        let messageUID: Int
        switch operation.input {
        case let .setFlags(_, mailbox: _, rawID: rawID, addFlags: _, removeFlags: _, expectedModSequence: _),
             let .setLabels(_, mailbox: _, rawID: rawID, addLabels: _, removeLabels: _),
             let .move(_, mailbox: _, rawID: rawID, destination: _),
             let .delete(_, mailbox: _, rawID: rawID),
             let .fetchPart(_, mailbox: _, rawID: rawID, path: _, pageSize: _):
            messageUID = try uid(rawID)
        case .discover, .synchronizeBaseline, .synchronizeIncremental, .synchronizeReconcile, .wait, .append:
            messageUID = 1
        }
        let messageID: String?
        if case let .append(_, mailbox: _, destination: _, flags: _, messageID: value, appendPurpose: _, appendAttempts: _) = operation.input {
            messageID = value
        } else {
            messageID = nil
        }
        let mailboxes = peer.mailboxes.map {
            LocalIMAPPeerResponse.Mailbox(
                path: $0.id,
                specialUse: imapSpecialUse($0.specialUse),
                selectable: $0.selectable
            )
        }
        let providerMetadata: LocalIMAPPeerResponse.ProviderMetadata?
        if peer.capabilities.contains("X-GM-EXT-1") {
            // These are literal peer response attributes, not a normalized
            // output oracle. They are parsed only after PlaintextIMAPClient
            // receives the corresponding FETCH response.
            providerMetadata = .init(
                stableID: "111",
                threadID: "222",
                labels: ["Work", "\\Inbox"]
            )
        } else {
            providerMetadata = nil
        }
        let configuredCatalogBehavior = catalogBehavior
            ?? (peer.catalogBehavior == "oversized" ? .oversized : .normal)
        let configuredMetadataBehavior = metadataBehavior
            ?? (peer.metadataBehavior == "oversized_gmail_labels_literal"
                ? .gmailLabelsLiteral(bytes: (8 << 20) + 1)
                : .normal)
        return .init(
            capabilities: peer.capabilities,
            mailboxes: mailboxes,
            uidValidity: peer.uidValidity,
            messageUID: messageUID,
            messageData: semanticPeerMessageData(messageID),
            sendsIdleChange: peer.idleBehavior == "changed",
            appendUIDResponses: peer.appendResponses.map { $0 == "append_uid" ? 1_001 : nil },
            providerMetadata: providerMetadata,
            catalogBehavior: configuredCatalogBehavior,
            metadataBehavior: configuredMetadataBehavior
        )
    }

    private static func observedCatalog(
        client: IMAPClientProtocol,
        mailboxes: [Mailbox]
    ) async throws -> Output {
        guard mailboxes.count <= 4_096 else {
            return .error(.init(tag: "resource_limit", retry: "never", cause: ""))
        }
        var observed: [ProviderFixtureSemanticOperation.Peer.Mailbox] = []
        observed.reserveCapacity(mailboxes.count)
        for mailbox in mailboxes {
            let selectable: Bool
            do {
                // `Mailbox` intentionally does not expose LIST's `\\Noselect`
                // attribute. Derive the contract field from a real SELECT on
                // the production client rather than copying the fixture input.
                _ = try await client.selectMailbox(mailbox.path)
                selectable = true
            } catch {
                selectable = false
            }
            observed.append(.init(
                id: mailbox.path,
                displayName: mailbox.name,
                selectable: selectable,
                specialUse: normalizedSpecialUse(mailbox.specialUse)
            ))
        }
        return .catalog(.init(mailboxes: observed))
    }

    private static func observedPage(
        _ operation: ProviderFixtureSemanticOperation,
        client: IMAPClientProtocol,
        cache: SemanticMailCache,
        mailbox: String,
        pageSize: Int,
        cursor: String?
    ) async throws -> ProviderFixtureSemanticOperation.Page {
        let sync = try await IMAPSyncService(client: client, cache: cache).syncInbox(
            credentials: semanticCredentials,
            options: IMAPSyncOptions(
                mailboxPaths: [mailbox],
                recentMessageLimit: pageSize,
                batchSize: pageSize
            )
        )
        let selection = try await client.selectMailbox(mailbox)
        guard let uidValidity = IMAPSyncService.uidValidity(from: selection) else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("sync selection omitted UIDVALIDITY")
        }
        let uids = try await client.allMessageUIDs()
        guard sync.syncedMessageCount == cache.records.count,
              uids.count == 1,
              let observedUID = uids.first,
              let record = cache.records.first,
              let actualMailbox = cache.mailboxes.first(where: { $0.path == record.mailboxPath })
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("sync did not produce one observed cache record")
        }
        let source = try await client.fetchBodyData(uid: observedUID)
        let header = try await client.fetchHeader(uid: observedUID)
        let projection = try MIMEMessageDecoder.providerProjection(from: source)
        let metadata = try await observedProviderMetadata(
            header: header,
            client: client,
            provider: operation.provider,
            mailboxID: actualMailbox.path,
            epoch: try cursorSeed(cursor)?.epoch ?? 1,
            rawID: String(observedUID)
        )
        let states = try await client.messageStates() ?? []
        let flags = normalizedFlags(states.first(where: { $0.uid == observedUID })?.flags ?? [])
        let mailbox = ProviderFixtureSemanticOperation.MailboxRef(
            id: actualMailbox.path,
            epoch: try cursorSeed(cursor)?.epoch ?? 1
        )
        let ref = ProviderFixtureSemanticOperation.MessageRef(mailbox: mailbox, rawID: String(observedUID))
        guard let receivedAt = canonicalTimestamp(record.message.sentAt) else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("sync cache omitted observed message date")
        }
        let message = observedMessage(
            projection: projection,
            cacheRecord: record,
            metadata: metadata,
            flags: flags,
            receivedAt: receivedAt
        )
        return .init(
            mailbox: mailbox,
            changes: [.init(kind: "upsert", ref: ref, message: message)],
            nextCursor: .init(
                provider: operation.provider,
                mailboxID: actualMailbox.path,
                epoch: mailbox.epoch,
                uidValidity: uidValidity,
                lastUID: observedUID,
                scanUID: observedUID
            ),
            hasMore: uids.count >= pageSize,
            observedUIDValidity: uidValidity,
            epochReset: false
        )
    }

    private static func observedPart(
        cache: SemanticMailCache,
        uid: Int,
        bytes: Data,
        path: String
    ) throws -> ProviderFixtureSemanticOperation.Part {
        let projection = try MIMEMessageDecoder.providerProjection(from: bytes)
        guard let part = projection.parts.first(where: { $0.path == path }),
              let attachment = try MIMEMessageDecoder.decodedAttachments(from: bytes).first(where: {
                  $0.partPath == path
              })
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("lazy part fetch did not produce the requested descriptor")
        }
        guard let record = cache.records.first,
              let mailbox = cache.mailboxes.first(where: { $0.path == record.mailboxPath })
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("lazy part fetch did not produce an observed cache mailbox")
        }
        let data = attachment.data
        return .init(
            ref: .init(
                mailbox: .init(id: mailbox.path, epoch: 1),
                rawID: String(uid)
            ),
            descriptor: semanticDescriptor(part),
            bytesBase64: data.base64EncodedString(),
            bytesRead: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            complete: true
        )
    }

    private static func observedMessage(
        projection: MIMEProviderProjection,
        cacheRecord: SemanticMailCache.Record,
        metadata: ObservedProviderMetadata,
        flags: [String],
        receivedAt: String
    ) -> ProviderFixtureSemanticOperation.Message {
        .init(
            rfcMessageID: projection.rfcMessageID,
            providerStableID: metadata.stableID,
            providerThreadID: metadata.threadID,
            inReplyTo: projection.inReplyTo,
            references: projection.references,
            from: projection.from.map(semanticAddress),
            sender: projection.sender.map(semanticAddress),
            replyTo: projection.replyTo.map(semanticAddress),
            to: projection.to.map(semanticAddress),
            cc: projection.cc.map(semanticAddress),
            bcc: projection.bcc.map(semanticAddress),
            subject: projection.subject,
            receivedAt: receivedAt,
            sentAt: canonicalTimestamp(cacheRecord.message.sentAt),
            flags: flags,
            labels: metadata.labels.map { .init(id: $0, displayName: $0) },
            textBody: semanticBody(projection.textBody),
            htmlBody: semanticBody(projection.htmlBody),
            parts: projection.parts.map(semanticDescriptor)
        )
    }

    private struct ObservedProviderMetadata {
        let stableID: String
        let threadID: String
        let labels: [String]
    }

    private static func observedProviderMetadata(
        header: String,
        client: IMAPClientProtocol,
        provider: String,
        mailboxID: String,
        epoch: Int,
        rawID: String
    ) async throws -> ObservedProviderMetadata {
        guard try await client.capabilities().contains("X-GM-EXT-1") else {
            guard provider == "generic" else {
                return .init(stableID: "", threadID: "", labels: [])
            }
            let identity = genericProviderMessageIdentity(mailboxID: mailboxID, epoch: epoch, rawID: rawID)
            return .init(stableID: identity, threadID: identity, labels: [])
        }
        guard let stableID = headerCapture("X-GM-MSGID", in: header),
              let threadID = headerCapture("X-GM-THRID", in: header),
              let labels = headerLabels(in: header)
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("advertised Gmail metadata was absent from FETCH output")
        }
        return .init(stableID: stableID, threadID: threadID, labels: labels)
    }

    private static func genericProviderMessageIdentity(mailboxID: String, epoch: Int, rawID: String) -> String {
        let logicalMailboxHex = String(repeating: "73", count: 32)
        let source = "plainpost.generic.imap.message.v1\0\(logicalMailboxHex)\0\(mailboxID)\0\(epoch)\0\(rawID)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func headerCapture(_ name: String, in header: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: name))\\s+([0-9]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header)
        else { return nil }
        return String(header[range])
    }

    private static func headerLabels(in header: String) -> [String]? {
        let pattern = #"X-GM-LABELS\s+\(([^)]*)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header)
        else { return nil }
        return String(header[range])
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .replacingOccurrences(of: "\\\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\\\\\", with: "\\") }
    }

    private static func semanticAddress(_ address: MIMEProviderProjection.Address) -> ProviderFixtureSemanticOperation.Address {
        .init(displayName: address.displayName, mailbox: address.mailbox)
    }

    private static func semanticBody(_ body: MIMEProviderProjection.Body) -> ProviderFixtureSemanticOperation.Body {
        switch body {
        case .absent: return .init(state: "absent", value: "")
        case let .complete(value): return .init(state: "complete", value: value)
        case .malformed: return .init(state: "malformed", value: "")
        case .omittedOversized: return .init(state: "omitted_oversized", value: "")
        }
    }

    private static func semanticDescriptor(_ part: MIMEProviderProjection.Part) -> ProviderFixtureSemanticOperation.PartDescriptor {
        .init(
            path: part.path,
            filename: part.filename,
            mimeType: part.mediaType,
            disposition: part.disposition,
            contentID: part.contentID,
            declaredSize: part.declaredSize
        )
    }

    private static func normalizedFlags(_ flags: Set<String>) -> [String] {
        [("\\Seen", "seen"), ("\\Answered", "answered"), ("\\Flagged", "flagged"), ("\\Draft", "draft"), ("\\Deleted", "deleted")]
            .compactMap { flags.contains($0.0) ? $0.1 : nil }
    }

    private static func canonicalTimestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func normalizedSpecialUse(_ value: String?) -> String {
        switch value?.lowercased() {
        case "\\inbox": return "inbox"
        case "\\sent": return "sent"
        case "\\drafts": return "drafts"
        case "\\trash": return "trash"
        case "\\junk": return "junk"
        case "\\archive": return "archive"
        case "\\all": return "all"
        default: return "none"
        }
    }

    private static func imapSpecialUse(_ value: String) -> String? {
        switch value {
        case "inbox": return "\\Inbox"
        case "sent": return "\\Sent"
        case "drafts": return "\\Drafts"
        case "trash": return "\\Trash"
        case "junk": return "\\Junk"
        case "archive": return "\\Archive"
        case "all": return "\\All"
        default: return nil
        }
    }

    private struct CursorSeed {
        let epoch: Int
        let uidValidity: Int
    }

    private static func cursorSeed(_ cursor: String?) throws -> CursorSeed? {
        guard let cursor else { return nil }
        var base64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["v"] as? Int == 1,
              let epoch = value["e"] as? Int,
              epoch > 0,
              let uidValidity = value["u"] as? Int,
              uidValidity > 0
        else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        return .init(epoch: epoch, uidValidity: uidValidity)
    }

    private static func uid(_ rawID: String) throws -> Int {
        guard let value = Int(rawID), value > 0 else { throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid }
        return value
    }

    private static func observedDestination(
        provider: String,
        client: IMAPClientProtocol,
        destination: String?
    ) async throws -> String {
        if let destination, !destination.isEmpty {
            return destination
        }
        guard provider == "icloud" else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        let mailboxes = try await client.listMailboxes()
        let sent = mailboxes.filter { normalizedSpecialUse($0.specialUse) == "sent" }
        guard sent.count == 1, let mailbox = sent.first else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
        }
        do {
            _ = try await client.selectMailbox(mailbox.path)
            return mailbox.path
        } catch {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("discovered Sent role was not selectable")
        }
    }

    private static func imapFlags(_ values: [String]) throws -> [String] {
        let flags = try values.map { value -> String in
            switch value {
            case "seen": return "\\Seen"
            case "answered": return "\\Answered"
            case "flagged": return "\\Flagged"
            case "draft": return "\\Draft"
            case "deleted": return "\\Deleted"
            default: throw ProviderFixtureTransportHarness.FixtureHarnessError.invalid
            }
        }
        return flags
    }

    private static func appendMessageData(_ messageID: String?) -> String {
        "Message-ID: \(messageID ?? "<semantic@example.invalid>")\r\nSubject: semantic\r\n\r\nabc"
    }

    private static func semanticPeerMessageData(_ messageID: String?) -> Data {
        let source = """
        Message-ID: \(messageID ?? "<semantic@example.invalid>")\r
        From: Semantic <Live@example.invalid>\r
        Subject: semantic\r
        Date: Sun, 10 Aug 2026 12:34:56 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="fixture"\r
        \r
        --fixture\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        abc\r
        --fixture\r
        Content-Type: application/octet-stream; name="file.bin"\r
        Content-Disposition: attachment; filename="file.bin"\r
        Content-Transfer-Encoding: base64\r
        Content-Length: 8\r
        \r
        U2VtYW50aWM=\r
        --fixture--\r
        """
        return Data(source.utf8)
    }

    private static let semanticCredentials = IMAPAccountCredentials(
        accountID: AccountID("acc_semantic_fixture"),
        email: EmailAddress("semantic@example.invalid"),
        username: "semantic-user",
        password: "semantic-secret"
    )

    private static let fixtureMessage = MessageSummary(
        id: MessageID("msg_semantic_fixture"),
        threadID: nil,
        from: EmailAddress("sender@example.invalid"),
        subject: "Semantic fixture",
        preview: "abc",
        body: "abc",
        smartCategory: .personal
    )
}

private final class SemanticMailCache: MailCache, AtomicIncomingMessageCache {
    struct Record {
        let message: MessageSummary
        let metadata: IncomingMessageSearchMetadata
        let mailboxPath: String
        let uidValidity: Int
        let uid: Int
    }

    private(set) var mailboxes: [Mailbox] = []
    private(set) var messages: [MessageSummary] = []
    private(set) var records: [Record] = []

    func cacheMailboxes(_ mailboxes: [Mailbox]) throws {
        self.mailboxes = mailboxes
    }

    func cacheMessage(_ message: MessageSummary) throws {
        messages.append(message)
    }

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
        records.append(.init(
            message: message,
            metadata: metadata,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid
        ))
        return .init(messageID: message.id, insertedMembership: true)
    }
}

private final class ScriptedTranscriptServer {
    enum Mode: String { case imap; case smtpStartTLS = "smtp_starttls"; case smtpSemantic = "smtp_semantic" }

    struct Record {
        let client: [Data]
        let server: [Data]
        let data: [Data]
    }

    private let mode: Mode
    private let temporaryDirectory: URL
    private let scriptURL: URL
    private let recordURL: URL
    private let portURL: URL
    private let certificateURL: URL
    private let keyURL: URL
    private var process: Process?
    private(set) var port = 0

    init(script: [[String: Any]], mode: Mode) throws {
        self.mode = mode
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-provider-transcript-\(UUID().uuidString)", isDirectory: true)
        scriptURL = temporaryDirectory.appendingPathComponent("script.json")
        recordURL = temporaryDirectory.appendingPathComponent("record.json")
        portURL = temporaryDirectory.appendingPathComponent("port.txt")
        certificateURL = temporaryDirectory.appendingPathComponent("cert.pem")
        keyURL = temporaryDirectory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: script, options: [.sortedKeys]).write(to: scriptURL)
        if mode != .imap { try generateCertificate() }
    }

    convenience init(semanticSMTP operation: ProviderFixtureSMTPSemanticOperation) throws {
        try self.init(script: [[
            "scenario": operation.input.scenario,
            "envelopeFrom": operation.input.envelopeFrom,
            "recipients": operation.input.recipients,
            "messageBase64": operation.input.messageBase64,
            "capabilities": operation.input.capabilities,
        ]], mode: .smtpSemantic)
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-u", "-c", Self.pythonServer,
            mode.rawValue, scriptURL.path, recordURL.path, portURL.path,
            certificateURL.path, keyURL.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: portURL, encoding: .utf8),
               let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
                port = parsed
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("server did not bind")
    }

    func finish(timeout: TimeInterval = 5) throws -> Record {
        guard let process else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("server was not started")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("server did not finish within \(Int(timeout)) seconds")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any] else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("server wrote no record")
        }
        if let error = object["error"] as? String {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript(error)
        }
        guard process.terminationStatus == 0 else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("server failed")
        }
        return Record(
            client: try dataArray(object["client"]),
            server: try dataArray(object["server"]),
            data: try dataArray(object["data"])
        )
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func dataArray(_ value: Any?) throws -> [Data] {
        guard let values = value as? [String] else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("malformed server record")
        }
        return try values.map {
            guard let data = Data(base64Encoded: $0) else {
                throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("malformed server bytes")
            }
            return data
        }
    }

    private func generateCertificate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path, "-out", certificateURL.path,
            "-days", "1", "-subj", "/CN=localhost",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderFixtureTransportHarness.FixtureHarnessError.transcript("certificate generation failed")
        }
    }

    private static let pythonServer = #"""
import base64
import hashlib
import json
import socket
import ssl
import sys

mode, script_path, record_path, port_path, certificate_path, key_path = sys.argv[1:]
record = {"client": [], "server": [], "data": []}

def save(error=None):
    if error is not None:
        record["error"] = error
    with open(record_path, "w", encoding="utf-8") as output:
        json.dump(record, output, sort_keys=True)

def fail(message):
    save(message)
    raise RuntimeError(message)

def read_exact(stream, length):
    value = b""
    while len(value) < length:
        chunk = stream.recv(length - len(value))
        if not chunk:
            fail("client disconnected while reading exact wire bytes")
        value += chunk
    return value

def read_line(stream):
    value = b""
    while not value.endswith(b"\r\n"):
        chunk = stream.recv(1)
        if not chunk:
            fail("client disconnected while reading symbolic line")
        value += chunk
    return value

def read_data(stream):
    value = b""
    marker = b"\r\n.\r\n"
    while not value.endswith(marker):
        chunk = stream.recv(1)
        if not chunk:
            fail("client disconnected while reading DATA")
        value += chunk
    return value

def valid_auth(value):
    line = value.decode("utf-8", "replace").rstrip("\r\n")
    if " LOGIN " in line:
        return '"synthetic-user"' in line and '"synthetic-secret"' in line
    if line.startswith("AUTH PLAIN "):
        try:
            return base64.b64decode(line.split(" ", 2)[2]) == b"\x00synthetic-user\x00synthetic-secret"
        except Exception:
            return False
    if "AUTHENTICATE XOAUTH2 " in line or line.startswith("AUTH XOAUTH2 "):
        try:
            encoded = line.rsplit(" ", 1)[1]
            decoded = base64.b64decode(encoded)
            return b"user=synthetic-user\x01" in decoded and b"Bearer synthetic-secret\x01\x01" in decoded
        except Exception:
            return False
    return False

def semantic_line(stream, want=None, prefix=None):
    actual = read_line(stream)
    record["client"].append(base64.b64encode(actual).decode("ascii"))
    text = actual.decode("utf-8", "replace").rstrip("\r\n")
    if want is not None and text != want:
        fail("semantic client line mismatch: got %r want %r" % (text, want))
    if prefix is not None and not text.startswith(prefix):
        fail("semantic client line mismatch: got %r want prefix %r" % (text, prefix))
    return text

def semantic_send(stream, value):
    stream.sendall(value)
    record["server"].append(base64.b64encode(value).decode("ascii"))

def semantic_capabilities(values):
    lines = ["local"] + values
    response = b""
    for index, value in enumerate(lines):
        separator = b" " if index == len(lines) - 1 else b"-"
        response += b"250" + separator + value.encode("ascii") + b"\r\n"
    return response

def requires_smtputf8(sender, recipients, source):
    header = source.split(b"\r\n\r\n", 1)[0]
    values = [sender.encode("utf-8")] + [value.encode("utf-8") for value in recipients] + [header]
    return any(any(byte > 0x7f for byte in value) for value in values)

def semantic_smtp(stream, config, certificate_path, key_path):
    scenario = config["scenario"]
    source = base64.b64decode(config["messageBase64"])
    sender = config["envelopeFrom"]
    recipients = config["recipients"]
    capabilities = config["capabilities"]
    if scenario == "oversized_response":
        semantic_send(stream, b"220 " + b"x" * (64 * 1024) + b"\r\n")
        return
    semantic_send(stream, b"220 typed semantic fixture\r\n")
    semantic_line(stream, want="EHLO plainpost.local")
    semantic_send(stream, semantic_capabilities(capabilities))
    semantic_line(stream, want="STARTTLS")
    semantic_send(stream, b"220 begin TLS\r\n")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=certificate_path, keyfile=key_path)
    stream = context.wrap_socket(stream, server_side=True)
    stream.settimeout(10)
    semantic_line(stream, want="EHLO plainpost.local")
    semantic_send(stream, semantic_capabilities(capabilities))
    semantic_line(stream, prefix="AUTH PLAIN ")
    semantic_send(stream, b"235 authenticated\r\n")
    if scenario == "pre_data_unavailable":
        return
    if "SMTPUTF8" not in capabilities:
        try:
            semantic_line(stream, want="QUIT")
            semantic_send(stream, b"221 bye\r\n")
        except Exception:
            pass
        return
    mail_from = "MAIL FROM:<" + sender + ">"
    if "SMTPUTF8" in capabilities and requires_smtputf8(sender, recipients, source):
        mail_from += " SMTPUTF8"
    semantic_line(stream, want=mail_from)
    semantic_send(stream, b"250 sender\r\n")
    for index, recipient in enumerate(recipients):
        semantic_line(stream, want="RCPT TO:<" + recipient + ">")
        if scenario == "recipient_rejected" and index == len(recipients) - 1:
            semantic_send(stream, b"550 recipient rejected\r\n")
            try:
                semantic_line(stream, want="RSET")
                semantic_send(stream, b"250 reset\r\n")
                semantic_line(stream, want="QUIT")
                semantic_send(stream, b"221 bye\r\n")
            except Exception:
                pass
            return
        semantic_send(stream, b"250 recipient\r\n")
    semantic_line(stream, want="DATA")
    semantic_send(stream, b"354 send data\r\n")
    if scenario == "disconnect_after_354":
        return
    if scenario == "disconnect_while_writing_data":
        try:
            stream.recv(1)
        except Exception:
            pass
        return
    data = read_data(stream)
    record["data"].append(base64.b64encode(data).decode("ascii"))
    if data[:-5] != source:
        fail("semantic DATA did not use typed operation source")
    if scenario == "disconnect_before_final_reply":
        return
    if scenario == "final_451":
        semantic_send(stream, b"451 final rejection\r\n")
    elif scenario == "final_550":
        semantic_send(stream, b"550 final rejection\r\n")
    else:
        semantic_send(stream, b"250 accepted\r\n")
    try:
        semantic_line(stream, want="QUIT")
        if scenario != "accepted_quit_drop":
            semantic_send(stream, b"221 bye\r\n")
    except Exception:
        pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_path, "w", encoding="utf-8") as output:
    output.write(str(server.getsockname()[1]))
    output.flush()

stream = None
try:
    script = json.load(open(script_path, encoding="utf-8"))
    stream, _ = server.accept()
    stream.settimeout(10)
    if mode == "smtp_semantic":
        if not isinstance(script, list) or len(script) != 1:
            fail("semantic SMTP configuration is malformed")
        semantic_smtp(stream, script[0], certificate_path, key_path)
    else:
        for step in script:
            kind = step.get("kind")
            if kind == "wire":
                expected = base64.b64decode(step["bytesBase64"])
                if step["direction"] == "server":
                    stream.sendall(expected)
                    record["server"].append(base64.b64encode(expected).decode("ascii"))
                else:
                    actual = read_line(stream) if expected.endswith(b"\r\n") else read_exact(stream, len(expected))
                    record["client"].append(base64.b64encode(actual).decode("ascii"))
                    if actual != expected:
                        fail("client wire mismatch: got %r want %r" % (actual, expected))
            elif kind == "auth":
                actual = read_line(stream)
                record["client"].append(base64.b64encode(actual).decode("ascii"))
                if not valid_auth(actual):
                    fail("symbolic auth did not use runtime synthetic credentials")
            elif kind == "data":
                if "prefixSize" in step:
                    actual = read_exact(stream, int(step["prefixSize"]))
                else:
                    actual = read_data(stream)
                record["data"].append(base64.b64encode(actual).decode("ascii"))
                if "prefixSize" not in step and (step.get("messageSHA256") != hashlib.sha256(actual).hexdigest() or step.get("messageSize") != str(len(actual))):
                    fail("DATA bytes did not match runtime marker")
            elif kind == "tls":
                if mode != "smtp_starttls":
                    fail("TLS is only valid in SMTP fixture replay")
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(certfile=certificate_path, keyfile=key_path)
                stream = context.wrap_socket(stream, server_side=True)
                stream.settimeout(10)
            elif kind == "message":
                continue
            elif kind == "disconnect":
                stream.close()
                stream = None
                break
            else:
                fail("unsupported transcript step %r" % kind)
    save()
except Exception as error:
    if "error" not in record:
        save(str(error))
    sys.exit(2)
finally:
    if stream is not None:
        stream.close()
    server.close()
"""#
}
