import XCTest
import PlainpostDB
@testable import PlainpostUI

@MainActor
final class RecipientSuggestionProviderTests: XCTestCase {
    func testContactsComeFirstAndRecentsFillWithoutDuplicates() {
        let contacts = [MailContact(contactID: "k1", displayName: "Maria Chen", emailAddress: "maria@northwind.example")]
        let recent = [
            Correspondent(address: "MARIA@northwind.example", displayName: "Maria", lastSeen: nil),
            Correspondent(address: "mark@stein.example", displayName: "Mark Stein", lastSeen: nil),
        ]
        let result = RecipientSuggestionProvider.merge(contacts: contacts, recent: recent, query: "ma", excluding: [], limit: 8)
        XCTAssertEqual(result.map(\.address), ["maria@northwind.example", "mark@stein.example"])
        XCTAssertEqual(result.map(\.source), [.contact, .recent])
        XCTAssertEqual(result.map(\.name), ["Maria Chen", "Mark Stein"])
        XCTAssertEqual(result.map(\.id), ["maria@northwind.example", "mark@stein.example"])
    }

    func testExcludesAlreadyAddedRecipients() {
        let recent = [Correspondent(address: "tom@okafor.example", displayName: "Tom", lastSeen: nil)]
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "to", excluding: ["TOM@okafor.example"], limit: 8), [])
        let contacts = [MailContact(contactID: "k", displayName: "Tom Okafor", emailAddress: "tom@okafor.example")]
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: contacts, recent: [], query: "to", excluding: ["Tom <tom@okafor.example>"], limit: 8), [])
    }

    func testMatchesNameOrAddressPrefixCaseInsensitively() {
        let recent = [Correspondent(address: "e.rossi@clinic.example", displayName: "Dr. Elena Rossi", lastSeen: nil)]
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "elena", excluding: [], limit: 8).count, 1)
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "E.RO", excluding: [], limit: 8).count, 1)
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "xyz", excluding: [], limit: 8).count, 0)
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "clinic", excluding: [], limit: 8).count, 0,
                       "a recent address matches only from its start")
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "  ", excluding: [], limit: 8), [])
    }

    func testMergeCapsAtTheLimitAndKeepsRecentOrder() {
        let contacts = [
            MailContact(contactID: "a", displayName: "Sam Able", emailAddress: "sam.able@example.com"),
            MailContact(contactID: "b", displayName: "Sam Baker", emailAddress: "sam.baker@example.com"),
        ]
        let recent = [
            Correspondent(address: "sam.zed@example.com", displayName: nil, lastSeen: nil),
            Correspondent(address: "sam.young@example.com", displayName: nil, lastSeen: nil),
            Correspondent(address: "not-an-address", displayName: "Sam Broken", lastSeen: nil),
        ]
        XCTAssertEqual(
            RecipientSuggestionProvider.merge(contacts: contacts, recent: recent, query: "sam", excluding: [], limit: 3).map(\.address),
            ["sam.able@example.com", "sam.baker@example.com", "sam.zed@example.com"]
        )
        XCTAssertEqual(
            RecipientSuggestionProvider.merge(contacts: [], recent: recent, query: "sam", excluding: [], limit: 8).map(\.address),
            ["sam.zed@example.com", "sam.young@example.com"]
        )
        XCTAssertEqual(RecipientSuggestionProvider.merge(contacts: contacts, recent: recent, query: "sam", excluding: [], limit: 0), [])
    }

    func testCreatingAndRefreshingNeverAsksForContacts() async {
        let client = CountingContactClient(authorization: .notDetermined)
        var loads = 0
        let provider = RecipientSuggestionProvider(contacts: ContactDirectoryModel(client: client)) {
            loads += 1
            return [Correspondent(address: "ivy@example.com", displayName: "Ivy", lastSeen: nil)]
        }
        XCTAssertEqual(loads, 0, "the provider loads nothing until asked")
        XCTAssertEqual(provider.suggestions(matching: "ivy", excluding: []), [])

        await provider.refreshCorrespondents()

        XCTAssertEqual(loads, 1)
        XCTAssertEqual(provider.suggestions(matching: "ivy", excluding: []).map(\.address), ["ivy@example.com"])
        let requests = await client.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testPreparingAsksForContactsOnlyWhileUndecidedAndLoadsRecentsOnce() async {
        let client = CountingContactClient(
            authorization: .notDetermined,
            authorizationAfterRequest: .authorized,
            contacts: [MailContact(contactID: "k", displayName: "Ivy Contact", emailAddress: "ivy.c@example.com")]
        )
        var loads = 0
        let provider = RecipientSuggestionProvider(contacts: ContactDirectoryModel(client: client)) {
            loads += 1
            return [Correspondent(address: "ivy@example.com", displayName: nil, lastSeen: nil)]
        }

        await provider.prepareContactsIfNeeded()
        await provider.prepareContactsIfNeeded()

        let requests = await client.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(loads, 1, "later focuses reuse the cache; a host refreshes it explicitly")
        XCTAssertEqual(
            provider.suggestions(matching: "ivy", excluding: []).map(\.source),
            [.contact, .recent]
        )
    }

    func testPreparingNeverAsksOnceContactsAreDenied() async {
        let client = CountingContactClient(authorization: .denied)
        let contacts = ContactDirectoryModel(client: client, initialSnapshot: ContactDirectorySnapshot(authorization: .denied))
        let provider = RecipientSuggestionProvider(contacts: contacts) { [] }

        await provider.prepareContactsIfNeeded()

        let requests = await client.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testNewestRefreshWins() async {
        var release: CheckedContinuation<Void, Never>?
        var loads = 0
        let provider = RecipientSuggestionProvider(contacts: .unavailable()) {
            loads += 1
            guard loads == 1 else {
                return [Correspondent(address: "new@example.com", displayName: nil, lastSeen: nil)]
            }
            await withCheckedContinuation { release = $0 }
            return [Correspondent(address: "old@example.com", displayName: nil, lastSeen: nil)]
        }

        let slow = Task { await provider.refreshCorrespondents() }
        while release == nil { await Task.yield() }
        await provider.refreshCorrespondents()
        release?.resume()
        await slow.value

        XCTAssertEqual(provider.correspondents.map(\.address), ["new@example.com"])
    }

    func testUnavailableContactsNeverPrompt() async {
        let contacts = ContactDirectoryModel.unavailable()
        let provider = RecipientSuggestionProvider(contacts: contacts) { [] }

        await provider.prepareContactsIfNeeded()

        XCTAssertEqual(contacts.snapshot.authorization, .unavailable)
    }
}

private actor CountingContactClient: ContactDirectoryClient {
    private var authorization: ContactDirectoryAuthorization
    private let authorizationAfterRequest: ContactDirectoryAuthorization
    private let contacts: [MailContact]
    private(set) var requestCount = 0

    init(
        authorization: ContactDirectoryAuthorization,
        authorizationAfterRequest: ContactDirectoryAuthorization = .denied,
        contacts: [MailContact] = []
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.contacts = contacts
    }

    func authorizationStatus() -> ContactDirectoryAuthorization { authorization }

    func requestAccess() -> Bool {
        requestCount += 1
        authorization = authorizationAfterRequest
        return authorization.permitsReading
    }

    func fetchContacts() -> [MailContact] { contacts }
}
