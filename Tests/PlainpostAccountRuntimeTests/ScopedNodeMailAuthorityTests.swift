import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

final class ScopedNodeMailAuthorityTests: XCTestCase {
    func testScopedAuthorityReadsAndMutatesOnlyItsAccount() async throws {
        let server = TwoAccountNodeSender()   // canonical /v1/mail/accounts, /v1/mail/snapshot, /v1/search, /v1/mutations, signing
        let client = NodeSyncClient(sender: server)
        let catalog = try await NodeMailAccountCatalog.load(client)
        XCTAssertTrue(catalog.multiAccount)
        let grace = try XCTUnwrap(catalog.accounts.first { $0.providerIdentity == "grace@example.test" })
        XCTAssertFalse(grace.isPrimary)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        _ = try await authority.snapshots.snapshot(after: nil, limit: 20)
        _ = try await authority.mutations.perform(.setRead(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")], read: true))

        let requests = await server.requests()
        let snapshot = try XCTUnwrap(requests.first { $0.path == "/v1/mail/snapshot" })
        XCTAssertEqual(try NodeSyncMailModeCodec.decodeAccountSnapshotRequest(snapshot.body).logicalMailboxID, grace.logicalMailboxID)
        let mutation = try XCTUnwrap(requests.first { $0.path == "/v1/mutations" })
        let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest(mutation.body).canonicalOperation)
        XCTAssertEqual(operation.unsigned.logicalMailboxID, grace.logicalMailboxID)
        XCTAssertFalse(requests.contains { $0.path == "/v1/snapshot" })
    }

    func testScopedAuthoritySignsWithTheCallersIdempotencyKey() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let catalog = try await NodeMailAccountCatalog.load(client)
        let grace = try XCTUnwrap(catalog.accounts.first { $0.providerIdentity == "grace@example.test" })
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        let operationID = "00000000-0000-4000-8000-000000000161"

        _ = try await authority.mutations.perform(
            .archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]), idempotencyKey: operationID
        )
        _ = try await authority.mutations.perform(.setRead(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)], read: true))

        let requests = await server.requests()
        let keys = try requests.filter { $0.path == "/v1/mutations" }.map {
            try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest($0.body).canonicalOperation).unsigned.idempotencyKey
        }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first, operationID, "the caller's operation ID is the Node idempotency key")
        XCTAssertNotEqual(keys.last, operationID)
    }

    func testUnscopedAuthoritySignsWithTheCallersIdempotencyKey() async throws {
        let server = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: server), accountID: AccountID("plainpost-account"),
            senderAddress: EmailAddress("ada@example.test")
        )
        let operationID = "00000000-0000-4000-8000-000000000162"

        _ = try await authority.mutations.perform(.delete(messageIDs: [MessageID("1789")]), idempotencyKey: operationID)

        let requests = await server.requests()
        let mutation = try XCTUnwrap(requests.first { $0.path == "/v1/mutations" })
        let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest(mutation.body).canonicalOperation)
        XCTAssertEqual(operation.unsigned.idempotencyKey, operationID)
    }

    func testOlderNodeYieldsSinglePrimaryAccountFromLegacyStatus() async throws {
        let server = LegacySingleAccountNodeSender(identity: "ada@example.test") // 404 for /v1/mail/accounts
        let catalog = try await NodeMailAccountCatalog.load(NodeSyncClient(sender: server))
        XCTAssertFalse(catalog.multiAccount)
        XCTAssertEqual(catalog.accounts.map(\.providerIdentity), ["ada@example.test"])
        XCTAssertEqual(catalog.accounts.map(\.isPrimary), [true])
    }

    func testCatalogListsEveryAccountWithItsMailboxesInNodeOrder() async throws {
        let catalog = try await NodeMailAccountCatalog.load(NodeSyncClient(sender: TwoAccountNodeSender()))
        XCTAssertEqual(catalog.accounts.map(\.providerIdentity), ["ada@example.test", "grace@example.test"])
        XCTAssertEqual(catalog.accounts.map(\.isPrimary), [true, false])
        XCTAssertEqual(catalog.accounts.map(\.providerKind), ["gmail", "gmail"])
        let grace = catalog.accounts[1]
        XCTAssertEqual(grace.id, TwoAccountNodeSender.graceLogicalMailboxID)
        XCTAssertEqual(grace.mailboxes.map(\.role), ["inbox", "drafts"])
        XCTAssertTrue(grace.mailboxes.allSatisfy { $0.logicalMailboxID == grace.logicalMailboxID })
    }

    func testOlderNodeCatalogCarriesLegacyAssignmentsAndScopedAuthorityKeepsLegacySnapshotRoute() async throws {
        let server = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let client = NodeSyncClient(sender: server)
        let catalog = try await NodeMailAccountCatalog.load(client)
        let ada = try XCTUnwrap(catalog.accounts.first)
        XCTAssertEqual(ada.logicalMailboxID, LegacySingleAccountNodeSender.logicalMailboxID)
        XCTAssertEqual(ada.state, .ready)
        XCTAssertEqual(ada.mailboxes.map(\.role), ["inbox", "drafts"])

        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: ada, multiAccount: catalog.multiAccount)
        _ = try await authority.snapshots.snapshot(after: nil, limit: 20)
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("1789")]))

        let requests = await server.requests()
        XCTAssertTrue(requests.contains { $0.path == "/v1/snapshot" })
        XCTAssertFalse(requests.contains { $0.path == "/v1/mail/snapshot" })
        let routed = try await server.lastMutationLogicalMailboxID()
        XCTAssertEqual(routed, ada.logicalMailboxID)
    }

    func testSecondaryAccountDraftSaveAndSendUseItsDraftsRoleAndLogicalMailbox() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"),
                                                  mailAccount: grace, multiAccount: true,
                                                  nodeSendJournal: ScopedSendTestJournal())
        let draft = Self.draft(id: "grace-draft", from: "grace@example.test")

        let saved = try await authority.mutations.perform(.saveDraft(draft))
        let sent = try await authority.mutations.perform(.send(draft))

        XCTAssertEqual(saved.state, "applied")
        XCTAssertEqual(sent.state, "applied")
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [grace.logicalMailboxID, grace.logicalMailboxID])
        let operations = try await Self.operations(server)
        guard case let .saveDraft(_, saveRevision, _, _) = operations[0].unsigned.operation,
              case let .send(_, sendRevision) = operations[1].unsigned.operation else {
            return XCTFail("expected save followed by send")
        }
        XCTAssertEqual(saveRevision, "0")
        XCTAssertEqual(sendRevision, "2")
        XCTAssertTrue(operations.allSatisfy { $0.unsigned.authorityEpoch == "3" }, "grace's own authority epoch signs its operations")
    }

    func testLegacyConnectedAccountCanSendWithoutLocalSourceJournal() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: AccountID("plainpost-account"),
            mailAccount: grace, multiAccount: true, access: .authorized,
            requiresSendJournal: false
        )
        let draft = Self.draft(id: "legacy-connected-send", from: "grace@example.test")
        _ = try await authority.mutations.perform(.saveDraft(draft))
        let sent = try await authority.mutations.perform(
            .send(draft)
        )
        XCTAssertEqual(sent.state, "applied")
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [grace.logicalMailboxID, grace.logicalMailboxID])
    }

    func testCatalogedLocalAccountRejectsSendWithoutJournal() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: AccountID("local-provider-account"),
            mailAccount: grace, multiAccount: true, access: .authorized
        )
        let draft = Self.draft(id: "unreserved-local-send", from: "grace@example.test")
        _ = try await authority.mutations.perform(.saveDraft(draft))
        do {
            _ = try await authority.mutations.perform(.send(draft))
            XCTFail("Cataloged local Node sends must require a durable reservation")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [grace.logicalMailboxID], "Only the draft save may reach the Node")
    }

    func testSecondaryAccountWithoutDraftsAssignmentRejectsDraftSaveBeforeSigning() async throws {
        let server = TwoAccountNodeSender(graceHasDrafts: false)
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        do {
            _ = try await authority.mutations.perform(.saveDraft(Self.draft(id: "no-drafts", from: "grace@example.test")))
            XCTFail("a draft needs the account's own drafts mailbox")
        } catch let error as PlainpostError {
            guard case .notFound = error else { return XCTFail("unexpected error \(error)") }
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [])
    }

    func testScopedSearchSendsExactlyItsLogicalMailbox() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        _ = try await authority.search.search(MailSearchRequest(query: "invoice", limit: 10))
        let ownScope = MailSearchSelectionScope(mailboxIDs: [MailboxID(try NodeSyncCodec.encodeLogicalMailboxID(grace.logicalMailboxID))])
        _ = try await authority.search.search(MailSearchRequest(query: "invoice", scope: ownScope, limit: 10))

        let searches = await server.requests().filter { $0.path == "/v1/search" }
        XCTAssertEqual(searches.count, 2)
        for search in searches {
            XCTAssertEqual(try NodeSyncCodec.decodeSearchRequest(search.body).logicalMailboxIDs, [grace.logicalMailboxID])
        }
    }

    func testScopedSearchRefusesAnotherAccountsMailboxWithoutSending() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        let foreign = MailSearchSelectionScope(mailboxIDs: [MailboxID(try NodeSyncCodec.encodeLogicalMailboxID(TwoAccountNodeSender.adaLogicalMailboxID))])

        do {
            _ = try await authority.search.search(MailSearchRequest(query: "invoice", scope: foreign, limit: 10))
            XCTFail("a scoped authority must not search another account")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else { return XCTFail("unexpected error \(error)") }
        }
        let searches = await server.requests().filter { $0.path == "/v1/search" }
        XCTAssertEqual(searches.count, 0)
    }

    func testAuthenticationRequiredAccountRefusesMutationsWithReauthorizeOnYourMac() async throws {
        let server = TwoAccountNodeSender(graceState: .authenticationRequired)
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        XCTAssertEqual(grace.state, .authenticationRequired)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
            XCTFail("an account that needs reauthorization must not mutate")
        } catch let error as PlainpostError {
            guard case let .permissionDenied(message) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(message.contains("Sign in again on your Mac"), message)
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [])
        // Reads stay available so the account remains selectable read-only.
        _ = try await authority.snapshots.snapshot(after: nil, limit: 20)
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
    }

    func testStatusRefreshPublishesTheCatalogEntryAndReenablesAReauthorizedAccount() async throws {
        let server = TwoAccountNodeSender(graceState: .authenticationRequired)
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        await server.setState(.ready, for: grace.logicalMailboxID)
        let status = try await authority.status()

        // /v1/status names the primary (ada); the scoped status never adopts it.
        XCTAssertEqual(status.providerIdentity, "grace@example.test")
        XCTAssertEqual(status.state, "ready")
        XCTAssertTrue(status.assignments.allSatisfy { $0.logicalMailboxID == grace.logicalMailboxID })
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        XCTAssertEqual(authority.mailAccount?.state, .ready)
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
        let routed = try await server.lastMutationLogicalMailboxID()
        XCTAssertEqual(routed, grace.logicalMailboxID)
    }

    func testStatusRefreshMarksAnAccountNeedingReauthorizationDegradedAndRefusesMutations() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        await server.setState(.authenticationRequired, for: grace.logicalMailboxID)
        let status = try await authority.status()

        XCTAssertEqual(status.state, "degraded")
        XCTAssertEqual(authority.mailAccount?.state, .authenticationRequired)
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
            XCTFail("reauthorization must block mutations")
        } catch let error as PlainpostError {
            guard case let .permissionDenied(message) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(message.contains("Sign in again on your Mac"), message)
        }
    }

    func testStatusRefreshAfterAccountRemovalFailsClosed() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        await server.removeAccount(grace.logicalMailboxID)
        do {
            _ = try await authority.status()
            XCTFail("a removed account must not keep its authority")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        XCTAssertNil(authority.senderAddress)
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
            XCTFail("a removed account must not mutate")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else { return XCTFail("unexpected error \(error)") }
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [])
    }

    func testPrimaryPromotionKeepsAScopedAuthorityOnItsOwnAccount() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        await server.removeAccount(TwoAccountNodeSender.adaLogicalMailboxID)
        let status = try await authority.status()

        XCTAssertEqual(status.providerIdentity, "grace@example.test")
        XCTAssertEqual(authority.mailAccount?.isPrimary, true)
        XCTAssertEqual(authority.mailAccount?.logicalMailboxID, grace.logicalMailboxID)
    }

    func testScopedFactoryAppliesTheSameAccessRules() async throws {
        let client = NodeSyncClient(sender: TwoAccountNodeSender())
        let grace = try await Self.account("grace@example.test", client: client)

        let authorized = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true, access: .authorized
        )
        let scoped = try XCTUnwrap(authorized as? PlainpostNodeMailAuthority)
        XCTAssertEqual(scoped.mailAccount, grace)
        XCTAssertEqual(scoped.senderAddress, EmailAddress("grace@example.test"))

        let cached = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true, access: .cachedReadOnly
        )
        XCTAssertFalse(cached is PlainpostNodeMailAuthority)
    }

    func testUnscopedAuthorityHasNoMailAccount() {
        let authority = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: TwoAccountNodeSender()), accountID: AccountID("plainpost-account"))
        XCTAssertNil(authority.mailAccount)
    }

    // MARK: - Fresh catalog state at mutation time (Task 7 M2)

    func testMutationRefusesAnAccountThatBecameAuthenticationRequiredSinceTheLastStatus() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        // No status refresh: only the encoder's catalog read sees the change.
        await server.setState(.authenticationRequired, for: grace.logicalMailboxID)
        for attempt in 0..<2 {
            do {
                _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))
                XCTFail("attempt \(attempt): an account that now needs reauthorization must not mutate")
            } catch let error as PlainpostError {
                guard case let .permissionDenied(message) = error else { return XCTFail("unexpected error \(error)") }
                XCTAssertTrue(message.contains("Sign in again on your Mac"), message)
            }
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [])
        XCTAssertEqual(authority.mailAccount?.state, .authenticationRequired)
        // Reads and the sender stay, as for an account that started auth-required.
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        _ = try await authority.snapshots.snapshot(after: nil, limit: 20)

        // Only an authenticated status refresh re-enables it.
        await server.setState(.ready, for: grace.logicalMailboxID)
        _ = try await authority.status()
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))
        let afterRefresh = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(afterRefresh, [grace.logicalMailboxID])
    }

    // A changed provider identity, discovered only by the encoder's
    // mutation-time catalog read, must fail this call directly. The identity
    // guard throws right after invalidateAfterAmbiguousAssignment() instead
    // of falling through to a later requireAvailable() check, which a
    // concurrent status() completing in between could otherwise race past
    // and let the mismatched mutation silently succeed.
    func testMutationRefusesAnAccountWhoseIdentityChangedSinceTheLastStatus() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))

        // No status refresh: only the encoder's catalog read at mutation time
        // sees the logical mailbox now answering under another identity.
        await server.setIdentity("mallory@example.test", for: grace.logicalMailboxID)
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))
            XCTFail("a changed provider identity must not mutate")
        } catch let error as PlainpostError {
            guard case let .permissionDenied(message) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(message.contains("awaiting authenticated status confirmation"), message)
        }
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [], "the mismatched identity must never reach signing")
        XCTAssertNil(authority.senderAddress, "the sender is cleared, awaiting a fresh authenticated status")

        // The scope never adopted the new identity, so it stays failed closed
        // even across a further authenticated status read.
        do {
            _ = try await authority.status()
            XCTFail("an identity that no longer matches its scope must not recover on its own")
        } catch let error as SyncNodeProviderController.Error {
            XCTAssertEqual(error, .providerUnavailable)
        }
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))
            XCTFail("a permanently mismatched identity must keep refusing mutations")
        } catch let error as PlainpostError {
            guard case .permissionDenied = error else { return XCTFail("unexpected error \(error)") }
        }
        let stillNothing = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(stillNothing, [])
    }

    func testMutationTimeCatalogReadRefreshesAPromotedAccount() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        XCTAssertFalse(authority.providerController.allowsGoogleOnboarding)

        await server.removeAccount(TwoAccountNodeSender.adaLogicalMailboxID)
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))

        XCTAssertEqual(authority.mailAccount?.isPrimary, true)
        XCTAssertTrue(authority.providerController.allowsGoogleOnboarding, "the promoted primary owns the onboarding flow")
    }

    // MARK: - Older single-account Node status (Task 7 M3, M5)

    func testLegacyStatusRefreshPublishesTheSynthesizedAccount() async throws {
        let server = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let client = NodeSyncClient(sender: server)
        let catalog = try await NodeMailAccountCatalog.load(client)
        let ada = try XCTUnwrap(catalog.accounts.first)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: ada, multiAccount: false)
        let published = PublishedStatuses()
        authority.onStatusRefresh = { published.append($0) }
        let loadRequests = await server.requests().count

        let status = try await authority.status()

        XCTAssertEqual(status.state, "ready")
        XCTAssertEqual(status.providerIdentity, "ada@example.test")
        XCTAssertEqual(status.assignments.map(\.role), ["inbox", "drafts"])
        XCTAssertEqual(published.values().map(\.state), ["ready"])
        XCTAssertEqual(authority.senderAddress, EmailAddress("ada@example.test"))
        XCTAssertEqual(authority.mailAccount, ada)
        let paths = await server.requests().dropFirst(loadRequests).map(\.path)
        XCTAssertTrue(paths.contains("/v1/status"))
        XCTAssertTrue(paths.contains("/v1/mailboxes/assignments"))
        XCTAssertFalse(paths.contains("/v1/mail/accounts"), "a legacy scope never asks the older Node for the catalog route again")
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("1789")]))
        let routed = try await server.lastMutationLogicalMailboxID()
        XCTAssertEqual(routed, ada.logicalMailboxID)
    }

    func testLegacyUnavailableStatusWithAnIdentityFailsClosedLikeTheUnscopedAuthority() async throws {
        let server = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let client = NodeSyncClient(sender: server)
        let adaCatalog = try await NodeMailAccountCatalog.load(client)
        let ada = try XCTUnwrap(adaCatalog.accounts.first)
        let scoped = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: ada, multiAccount: false)
        let unscoped = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), senderAddress: EmailAddress("ada@example.test"))

        await server.setLegacyStatusState("unavailable")
        let scopedStatus = try await scoped.status()
        let unscopedStatus = try await unscoped.status()

        XCTAssertEqual(scopedStatus.state, "unavailable")
        XCTAssertEqual(unscopedStatus.state, "unavailable")
        for authority in [scoped, unscoped] {
            XCTAssertNil(authority.senderAddress)
            do {
                _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("1789")]))
                XCTFail("an unavailable Node must not mutate")
            } catch let error as PlainpostError {
                guard case .permissionDenied = error else { return XCTFail("unexpected error \(error)") }
            }
        }
        let routed = await server.requests().filter { $0.path == "/v1/mutations" }
        XCTAssertEqual(routed.count, 0)

        await server.setLegacyStatusState("ready")
        _ = try await scoped.status()
        XCTAssertEqual(scoped.senderAddress, EmailAddress("ada@example.test"))
        _ = try await scoped.mutations.perform(.archive(messageIDs: [MessageID("1789")]))
    }

    // MARK: - Snapshot IDs (Task 7 M5)

    func testScopedSnapshotMapsNamespacedMessageIDsOfItsOwnAccountOnly() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)

        let page = try await authority.snapshots.snapshot(after: nil, limit: 20)

        XCTAssertEqual(page.messages.map(\.id), [MessageID(TwoAccountNodeSender.graceMessageID)])
        XCTAssertEqual(page.messages.first?.threadID, ThreadID("thread-\(TwoAccountNodeSender.graceMessageID)"))
        XCTAssertEqual(page.messages.first?.attachments.map(\.id), [TwoAccountNodeSender.graceAttachmentID])
        // The namespaced ID round-trips into a mutation signed for grace.
        let id = try XCTUnwrap(page.messages.first?.id)
        _ = try await authority.mutations.perform(.setRead(messageIDs: [id], read: false))
        let operations = try await server.requests().filter { $0.path == "/v1/mutations" }.map {
            try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest($0.body).canonicalOperation)
        }
        XCTAssertEqual(operations.map(\.unsigned.logicalMailboxID), [grace.logicalMailboxID])
        guard case let .setRead(messageIDs, _) = operations.first?.unsigned.operation else { return XCTFail("expected set_read") }
        XCTAssertEqual(messageIDs, [TwoAccountNodeSender.graceMessageID])
    }

    // MARK: - Google onboarding on non-primary scopes (Task 7 M6)

    func testNonPrimaryScopedAuthorityRefusesGoogleConfigureAndAssignWithoutInvalidatingItself() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        let controller = authority.providerController
        let before = await server.requests().count

        XCTAssertFalse(controller.allowsGoogleOnboarding)
        XCTAssertThrowsError(try controller.makeGoogleAuthorizationRequest(clientID: "client", redirectURI: "https://plainpost.example/oauth/google")) {
            XCTAssertEqual($0 as? SyncNodeProviderController.Error, .googleOnboardingRequiresPrimaryAccount)
        }
        await Self.assertThrows(.googleOnboardingRequiresPrimaryAccount) {
            _ = try await controller.completeGoogleAuthorization(callbackURL: URL(string: "https://plainpost.example/oauth/google?state=s&code=c")!)
        }
        await Self.assertThrows(.googleOnboardingRequiresPrimaryAccount) {
            _ = try await controller.assignGoogleMailboxes([SyncNodeMailboxSelection(displayName: "Inbox", mailboxHandle: "INBOX", role: "inbox", logicalMailboxID: grace.logicalMailboxID)])
        }
        await Self.assertThrows(.googleOnboardingRequiresPrimaryAccount) {
            _ = try await controller.waitForTrustedProviderStatus(timeout: .seconds(1))
        }

        let after = await server.requests().count
        XCTAssertEqual(after, before, "a refused onboarding call sends nothing, so it cannot touch the primary account")
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID(TwoAccountNodeSender.graceMessageID)]))
        let routed = await server.mutationLogicalMailboxIDs()
        XCTAssertEqual(routed, [grace.logicalMailboxID])
    }

    func testPrimaryLegacyAndUnscopedAuthoritiesKeepGoogleOnboarding() async throws {
        let client = NodeSyncClient(sender: TwoAccountNodeSender())
        let ada = try await Self.account("ada@example.test", client: client)
        let primary = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: ada, multiAccount: true)
        XCTAssertTrue(primary.providerController.allowsGoogleOnboarding)
        XCTAssertNoThrow(try primary.providerController.makeGoogleAuthorizationRequest(clientID: "client", redirectURI: "https://plainpost.example/oauth/google"))

        let legacyClient = NodeSyncClient(sender: LegacySingleAccountNodeSender(identity: "ada@example.test"))
        let legacyCatalog = try await NodeMailAccountCatalog.load(legacyClient)
        let legacyAccount = try XCTUnwrap(legacyCatalog.accounts.first)
        let legacy = PlainpostNodeMailAuthority(client: legacyClient, accountID: AccountID("plainpost-account"), mailAccount: legacyAccount, multiAccount: false)
        XCTAssertTrue(legacy.providerController.allowsGoogleOnboarding)

        let unscoped = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"))
        XCTAssertTrue(unscoped.providerController.allowsGoogleOnboarding)
    }

    func testStatusRefreshAfterPromotionEnablesGoogleOnboarding() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        XCTAssertFalse(authority.providerController.allowsGoogleOnboarding)

        await server.removeAccount(TwoAccountNodeSender.adaLogicalMailboxID)
        _ = try await authority.status()

        XCTAssertTrue(authority.providerController.allowsGoogleOnboarding)
    }

    // MARK: - Owner-scoped message and attachment reads

    func testScopedAuthorityReadsMessagesAndAttachmentsThroughItsLogicalMailbox() async throws {
        let server = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: server)
        let grace = try await Self.account("grace@example.test", client: client)
        let authority = PlainpostNodeMailAuthority(client: client, accountID: AccountID("plainpost-account"), mailAccount: grace, multiAccount: true)
        let encodedGrace = try NodeSyncCodec.encodeLogicalMailboxID(grace.logicalMailboxID)

        let own = try await authority.messages.message(id: MessageID(TwoAccountNodeSender.graceMessageID))
        XCTAssertEqual(own.id, MessageID(TwoAccountNodeSender.graceMessageID))
        do {
            _ = try await authority.messages.message(id: MessageID(TwoAccountNodeSender.adaMessageID))
            XCTFail("a scoped authority must not open another account's message")
        } catch let error as PlainpostError {
            guard case .notFound = error else { return XCTFail("unexpected error \(error)") }
        }
        let attachment = try await authority.attachments.attachment(id: TwoAccountNodeSender.graceAttachmentID)
        var bytes = Data()
        for try await chunk in attachment.bytes { bytes.append(chunk) }
        XCTAssertEqual(bytes, Data("body".utf8))
        do {
            _ = try await authority.attachments.attachment(id: TwoAccountNodeSender.adaAttachmentID)
            XCTFail("a scoped authority must not open another account's attachment")
        } catch let error as PlainpostError {
            guard case .notFound = error else { return XCTFail("unexpected error \(error)") }
        }

        let paths = await server.requests().map(\.path)
        let reads = paths.filter { $0.contains("/messages/") || $0.contains("/attachments/") }
        XCTAssertEqual(reads.count, 4)
        XCTAssertTrue(reads.allSatisfy { $0.hasPrefix("/v1/mail/messages/\(encodedGrace)/") || $0.hasPrefix("/v1/mail/attachments/\(encodedGrace)/") }, "\(reads)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("/v1/messages/") || $0.hasPrefix("/v1/attachments/") })
    }

    func testLegacyScopedAndUnscopedAuthoritiesKeepTheLegacyReadRoutes() async throws {
        let legacyServer = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let legacyClient = NodeSyncClient(sender: legacyServer)
        let legacyCatalog = try await NodeMailAccountCatalog.load(legacyClient)
        let ada = try XCTUnwrap(legacyCatalog.accounts.first)
        let legacy = PlainpostNodeMailAuthority(client: legacyClient, accountID: AccountID("plainpost-account"), mailAccount: ada, multiAccount: false)
        _ = try await legacy.messages.message(id: MessageID("1789"))
        let legacyPaths = await legacyServer.requests().map(\.path)
        XCTAssertTrue(legacyPaths.contains { $0.hasPrefix("/v1/messages/") })
        XCTAssertFalse(legacyPaths.contains { $0.hasPrefix("/v1/mail/messages/") })

        let server = TwoAccountNodeSender()
        let unscoped = PlainpostNodeMailAuthority(client: NodeSyncClient(sender: server), accountID: AccountID("plainpost-account"))
        _ = try await unscoped.messages.message(id: MessageID(TwoAccountNodeSender.adaMessageID))
        let paths = await server.requests().map(\.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("/v1/messages/") })
        XCTAssertFalse(paths.contains { $0.hasPrefix("/v1/mail/messages/") })
    }

    private static func assertThrows(
        _ expected: SyncNodeProviderController.Error,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SyncNodeProviderController.Error, expected, file: file, line: line)
        }
    }

    private static func account(_ identity: String, client: NodeSyncClient) async throws -> NodeMailAccount {
        let catalog = try await NodeMailAccountCatalog.load(client)
        return try XCTUnwrap(catalog.accounts.first { $0.providerIdentity == identity })
    }

    private static func draft(id: String, from: String) -> Draft {
        Draft(
            id: DraftID(id), accountID: AccountID("plainpost-account"),
            from: EmailAddress(from), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Scoped", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )
    }

    private static func operations(_ server: TwoAccountNodeSender) async throws -> [NodeSyncOperation] {
        try await server.requests().filter { $0.path == "/v1/mutations" }.map {
            try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest($0.body).canonicalOperation)
        }
    }
}

private final class PublishedStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [SyncNodeStatus] = []
    func append(_ status: SyncNodeStatus) { lock.lock(); statuses.append(status); lock.unlock() }
    func values() -> [SyncNodeStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
}

private struct ScopedSendTestJournal: NodeSendJournal {
    func unresolvedSendOperations(accountID: AccountID) throws -> [Data] { [] }
    func reserveSend(canonicalOperation: Data) throws {}
    func settleSend(canonicalOperation: Data, state: NodeSendOutcome) throws {}
}
