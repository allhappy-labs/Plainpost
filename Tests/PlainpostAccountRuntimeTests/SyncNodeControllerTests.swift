import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostCore

final class SyncNodeControllerTests: XCTestCase {
    func testAuthorizedSelectionCreatesOneAuthoritySharedByEveryMailCapability() throws {
        let authority = ControllerTestAuthority()
        let recorder = FactoryCallRecorder()
        let controller = SyncNodeController(
            access: .authorized,
            makeAuthority: { _ in
                recorder.increment()
                return authority
            }
        )

        let selected = try controller.resolve()

        XCTAssertTrue((selected as AnyObject) === authority)
        XCTAssertEqual(recorder.count, 1)
        XCTAssertTrue((controller.snapshots as AnyObject) === (authority.snapshots as AnyObject))
        XCTAssertTrue((controller.search as AnyObject) === (authority.search as AnyObject))
        XCTAssertTrue((controller.messages as AnyObject) === (authority.messages as AnyObject))
        XCTAssertTrue((controller.mutations as AnyObject) === (authority.mutations as AnyObject))
        XCTAssertTrue((controller.attachments as AnyObject) === (authority.attachments as AnyObject))
    }

    func testCachedReadOnlySelectionRequiresExplicitPermissionAndNeverFallsBack() throws {
        let authority = ControllerTestAuthority()
        let denied = SyncNodeController(
            access: .cachedReadOnly,
            cachedReadOnlyPermitted: false,
            makeAuthority: { _ in authority }
        )

        XCTAssertThrowsError(try denied.resolve()) { error in
            XCTAssertEqual(error as? SyncNodeController.Error, .accessDenied)
        }
    }

    func testConcurrentResolutionInitializesTheAuthorityExactlyOnce() async throws {
        let authority = ControllerTestAuthority()
        let recorder = LockedFactoryCallRecorder()
        let controller = SyncNodeController(
            access: .authorized,
            makeAuthority: { _ in
                recorder.increment()
                // Make a duplicate initialization observable if the controller
                // ever releases its selection lock before invoking the factory.
                Thread.sleep(forTimeInterval: 0.01)
                return authority
            }
        )

        let identities = await withTaskGroup(of: ObjectIdentifier?.self, returning: [ObjectIdentifier?].self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    guard let selected = try? controller.resolve() else { return nil }
                    return ObjectIdentifier(selected as AnyObject)
                }
            }
            var values: [ObjectIdentifier?] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(Set(identities.compactMap { $0 }), Set([ObjectIdentifier(authority)]))
    }

    func testCachedReadOnlyAuthorityIsUsableWithoutCentralAndNeverUsesLegacyFallback() async throws {
        let authority = ControllerTestAuthority()
        let recorder = LockedFactoryCallRecorder()
        let controller = SyncNodeController(
            access: .cachedReadOnly,
            cachedReadOnlyPermitted: true,
            makeAuthority: { access in
                XCTAssertEqual(access, .cachedReadOnly)
                recorder.increment()
                return authority
            }
        )

        let selected = try controller.resolve()

        XCTAssertFalse((selected as AnyObject) === authority)
        XCTAssertEqual(recorder.count, 1)
        XCTAssertTrue((controller.authority as AnyObject?) === selected as AnyObject)
        do {
            _ = try await XCTUnwrap(controller.mutations).apply(canonicalOperation: Data([1]))
            XCTFail("cached read-only selection must not expose a mutation capability")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .permissionDenied("This cached mailbox is read-only while the account is offline."))
        }
        do {
            _ = try await XCTUnwrap(controller.mutations).perform(.archive(messageIDs: [MessageID("cached-message")]))
            XCTFail("cached read-only selection must not expose intent mutations")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .permissionDenied("This cached mailbox is read-only while the account is offline."))
        }
    }

    func testCachedReadOnlyAuthorityPreservesNodeDiagnosticsButNotProviderOnboarding() async throws {
        let authority = ControllerTestAuthority()
        let controller = SyncNodeController(
            access: .cachedReadOnly,
            makeAuthority: { _ in authority }
        )

        let selected = try controller.resolve()
        let diagnostics = try XCTUnwrap(selected as? any SyncNodeStatusProviding)
        let status = try await diagnostics.status()
        XCTAssertEqual(status.providerIdentity, "cached@example.com")
        XCTAssertFalse(selected is PlainpostNodeMailAuthority)
    }
}

private final class FactoryCallRecorder: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class LockedFactoryCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }
}

private final class ControllerTestAuthority: PlainpostMailAuthority, SyncNodeStatusProviding, @unchecked Sendable {
    let snapshots: any MailSnapshotServing = EmptySnapshotService()
    let search: any MailSearchService = EmptySearchService()
    let messages: any MailMessageServing = EmptyMessageService()
    let mutations: any MailMutationServing = EmptyMutationService()
    let attachments: any MailAttachmentServing = EmptyAttachmentService()

    func status() async throws -> SyncNodeStatus {
        SyncNodeStatus(
            version: "node-test",
            reachability: "reachable",
            syncLag: "0",
            storage: "managed",
            providerIdentity: "cached@example.com",
            assignments: [],
            backup: "not_reported",
            endpoint: "session-scoped",
            updateStatus: "current"
        )
    }
}

private final class EmptySnapshotService: MailSnapshotServing, @unchecked Sendable {
    func snapshot(after cursor: MailSearchCursor?, limit: Int) async throws -> MailSnapshotPage {
        MailSnapshotPage(messages: [], nextCursor: nil, revision: "1")
    }
}

private final class EmptySearchService: MailSearchService, @unchecked Sendable {
    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        MailSearchResponse(parsedQuery: try MailSearchQueryParser().parse(request), mode: request.mode, scope: request.scope, hits: [], nextCursor: nil, indexRevision: "1")
    }
    func suggestions(_ request: MailSearchSuggestionRequest) async throws -> [MailSearchSuggestionSection] { [] }
    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws {}
    func performMaintenanceIfDue(now: Date) async throws {}
}

private final class EmptyMessageService: MailMessageServing, @unchecked Sendable {
    func message(id: MessageID) async throws -> MessageSummary { throw PlainpostError.notFound("missing") }
}

private final class EmptyMutationService: MailMutationServing, @unchecked Sendable {
    func apply(canonicalOperation: Data) async throws -> MailMutationResult { throw PlainpostError.validationFailed("missing") }
}

private final class EmptyAttachmentService: MailAttachmentServing, @unchecked Sendable {
    func attachment(id: String) async throws -> MailAttachmentStream { throw PlainpostError.notFound("missing") }
}
