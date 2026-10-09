import Foundation
import Contacts
import XCTest
@testable import PlainpostUI

final class ContactDirectoryTests: XCTestCase {
    func testSnapshotMatchesEmailCaseInsensitivelyAndPrefersDuplicateWithPhoto() throws {
        let photo = Data([0x01, 0x02])
        let snapshot = ContactDirectorySnapshot(
            authorization: .authorized,
            contacts: [
                MailContact(contactID: "plain", displayName: "Alice", emailAddress: "alice@example.com"),
                MailContact(contactID: "photo", displayName: "Alice Example", emailAddress: "ALICE@example.com", thumbnailImageData: photo)
            ]
        )

        let match = try XCTUnwrap(snapshot.contact(for: "Alice <Alice@Example.COM>"))
        XCTAssertEqual(match.contactID, "photo")
        XCTAssertEqual(match.thumbnailImageData, photo)
        XCTAssertEqual(snapshot.contacts.count, 1)
    }

    func testSuggestionsMatchNamesAndEmailsCaseAndDiacriticInsensitively() {
        let snapshot = ContactDirectorySnapshot(
            authorization: .authorized,
            contacts: [
                MailContact(contactID: "elodie", displayName: "Élodie Müller", emailAddress: "elodie@example.com"),
                MailContact(contactID: "alice", displayName: "Alice Baker", emailAddress: "alice@work.example"),
                MailContact(contactID: "malice", displayName: "Malice Example", emailAddress: "other@example.com"),
                MailContact(contactID: "phone", displayName: "Phone Only", emailAddress: "not-an-email")
            ]
        )

        XCTAssertEqual(snapshot.suggestions(matching: "elo").map(\.contactID), ["elodie"])
        XCTAssertEqual(snapshot.suggestions(matching: "WORK").map(\.contactID), ["alice"])
        XCTAssertEqual(snapshot.suggestions(matching: "ali").map(\.contactID), ["alice", "malice"])
        XCTAssertTrue(snapshot.suggestions(matching: "phone").isEmpty)
    }

    func testSuggestionsExcludeCompletedRecipientsAndRespectLimit() {
        let snapshot = ContactDirectorySnapshot(
            authorization: .authorized,
            contacts: [
                MailContact(contactID: "a", displayName: "Team Alpha", emailAddress: "alpha@example.com"),
                MailContact(contactID: "b", displayName: "Team Beta", emailAddress: "beta@example.com"),
                MailContact(contactID: "c", displayName: "Team Gamma", emailAddress: "gamma@example.com")
            ]
        )

        XCTAssertEqual(
            snapshot.suggestions(
                matching: "team",
                excluding: ["ALPHA@example.com"],
                limit: 1
            ).map(\.emailAddress),
            ["beta@example.com"]
        )
    }

    func testRecipientInputTracksAndReplacesOnlyActiveFragment() {
        let value = "alice@example.com; bob@example.com,  élo"

        XCTAssertEqual(ComposerRecipientInput.activeFragment(in: value), "élo")
        XCTAssertEqual(
            ComposerRecipientInput.completedAddresses(in: value),
            ["alice@example.com", "bob@example.com"]
        )
        XCTAssertEqual(
            ComposerRecipientInput.replacingActiveFragment(in: value, with: "elodie@example.com"),
            "alice@example.com; bob@example.com, elodie@example.com, "
        )
        XCTAssertEqual(
            ComposerRecipientInput.replacingActiveFragment(in: "ali", with: "alice@example.com"),
            "alice@example.com, "
        )
    }

    @MainActor
    func testDirectoryRequestsAccessAndLoadsContacts() async {
        let client = TestContactDirectoryClient(
            authorization: .notDetermined,
            authorizationAfterRequest: .authorized,
            contacts: [MailContact(contactID: "alice", displayName: "Alice", emailAddress: "alice@example.com")]
        )
        let model = ContactDirectoryModel(client: client)

        await model.requestAccessAndRefresh()

        XCTAssertEqual(model.snapshot.authorization, .authorized)
        XCTAssertEqual(model.snapshot.contactCount, 1)
        XCTAssertEqual(model.snapshot.contacts.map(\.emailAddress), ["alice@example.com"])
        XCTAssertNil(model.snapshot.errorMessage)
        let counts = await client.callCounts()
        XCTAssertEqual(counts.requests, 1)
        XCTAssertEqual(counts.fetches, 1)
    }

    @MainActor
    func testDirectoryDoesNotRequestAgainAfterDenial() async {
        let client = TestContactDirectoryClient(
            authorization: .denied,
            authorizationAfterRequest: .denied,
            contacts: []
        )
        let model = ContactDirectoryModel(client: client)

        await model.requestAccessAndRefresh()

        XCTAssertEqual(model.snapshot.authorization, .denied)
        let counts = await client.callCounts()
        XCTAssertEqual(counts.requests, 0)
        XCTAssertEqual(counts.fetches, 0)
    }

    @MainActor
    func testDirectoryRefreshesAuthorizationWhenAccessRequestThrows() async {
        let client = TestContactDirectoryClient(
            authorization: .notDetermined,
            authorizationAfterRequest: .denied,
            contacts: [],
            requestError: TestError.failed
        )
        let model = ContactDirectoryModel(client: client)

        await model.requestAccessAndRefresh()

        XCTAssertEqual(model.snapshot.authorization, .denied)
        XCTAssertNil(model.snapshot.errorMessage)
        XCTAssertFalse(model.snapshot.isLoading)
    }

    @MainActor
    func testRefreshFailurePreservesLastGoodContactsAndProvidesSafeError() async {
        let existing = MailContact(contactID: "alice", displayName: "Alice", emailAddress: "alice@example.com")
        let client = TestContactDirectoryClient(
            authorization: .authorized,
            authorizationAfterRequest: .authorized,
            contacts: [],
            fetchError: TestError.failed
        )
        let model = ContactDirectoryModel(
            client: client,
            initialSnapshot: ContactDirectorySnapshot(authorization: .authorized, contacts: [existing])
        )

        await model.refresh()

        XCTAssertEqual(model.snapshot.contacts, [existing])
        XCTAssertEqual(model.snapshot.errorMessage, "Contacts could not be refreshed. Try again.")
        XCTAssertFalse(model.snapshot.isLoading)
    }

    @MainActor
    func testSystemContactChangeRebuildsAuthorizedSnapshot() async {
        let alice = MailContact(contactID: "alice", displayName: "Alice", emailAddress: "alice@example.com")
        let bob = MailContact(contactID: "bob", displayName: "Bob", emailAddress: "bob@example.com")
        let client = TestContactDirectoryClient(
            authorization: .authorized,
            authorizationAfterRequest: .authorized,
            contacts: [alice]
        )
        let model = ContactDirectoryModel(client: client)
        await model.prepare()
        XCTAssertEqual(model.snapshot.contacts, [alice])

        await client.setContacts([bob])
        await Task.yield()
        NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil)

        let reloadedBy = ContinuousClock.now + .seconds(20)
        while model.snapshot.contacts != [bob], ContinuousClock.now < reloadedBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.snapshot.contacts, [bob])
        let counts = await client.callCounts()
        XCTAssertEqual(counts.fetches, 2)
    }

    @MainActor
    func testPrepareReloadsAfterAuthorizationChangesInSystemSettings() async {
        let contact = MailContact(contactID: "alice", displayName: "Alice", emailAddress: "alice@example.com")
        let client = TestContactDirectoryClient(
            authorization: .denied,
            authorizationAfterRequest: .denied,
            contacts: [contact]
        )
        let model = ContactDirectoryModel(client: client)

        await model.prepare()
        XCTAssertEqual(model.snapshot.authorization, .denied)
        XCTAssertTrue(model.snapshot.contacts.isEmpty)

        await client.setAuthorization(.authorized)
        await model.prepare()

        XCTAssertEqual(model.snapshot.authorization, .authorized)
        XCTAssertEqual(model.snapshot.contacts, [contact])
    }
}

private enum TestError: Error {
    case failed
}

private actor TestContactDirectoryClient: ContactDirectoryClient {
    private var authorization: ContactDirectoryAuthorization
    private let authorizationAfterRequest: ContactDirectoryAuthorization
    private var contacts: [MailContact]
    private let requestError: Error?
    private let fetchError: Error?
    private var requestCount = 0
    private var fetchCount = 0

    init(
        authorization: ContactDirectoryAuthorization,
        authorizationAfterRequest: ContactDirectoryAuthorization,
        contacts: [MailContact],
        requestError: Error? = nil,
        fetchError: Error? = nil
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.contacts = contacts
        self.requestError = requestError
        self.fetchError = fetchError
    }

    func authorizationStatus() -> ContactDirectoryAuthorization {
        authorization
    }

    func requestAccess() throws -> Bool {
        requestCount += 1
        authorization = authorizationAfterRequest
        if let requestError { throw requestError }
        return authorization.permitsReading
    }

    func fetchContacts() throws -> [MailContact] {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return contacts
    }

    func callCounts() -> (requests: Int, fetches: Int) {
        (requestCount, fetchCount)
    }


    func setContacts(_ contacts: [MailContact]) {
        self.contacts = contacts
    }

    func setAuthorization(_ authorization: ContactDirectoryAuthorization) {
        self.authorization = authorization
    }
}
