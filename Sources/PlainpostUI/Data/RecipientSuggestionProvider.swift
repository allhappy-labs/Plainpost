import Combine
import Foundation
import PlainpostDB

/// A person a recipient field can offer as the user types.
struct RecipientSuggestion: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable { case contact, recent }

    /// The normalized address.
    let id: String
    let name: String?
    let address: String
    let source: Source
}

/// Recipient suggestions for a composer: matching Contacts first, then people the session's
/// accounts have mailed with, one row per address.
///
/// Nothing loads until a host asks. A host calls `refreshCorrespondents()` when it opens a
/// composer, so people mailed since the last open appear, and `prepareContactsIfNeeded()` when
/// a recipient field first gets focus: that loads recent correspondents if nothing has, and is
/// the only place the provider asks for Contacts access. The root's composer (the macOS app's)
/// reads Contacts from the environment and never calls either, so there it costs nothing.
@MainActor
final class RecipientSuggestionProvider: ObservableObject {
    /// The cached recent correspondents, newest first.
    @Published private(set) var correspondents: [Correspondent] = []

    let contacts: ContactDirectoryModel

    private let loadCorrespondents: () async -> [Correspondent]
    private var hasLoadedCorrespondents = false
    private var latestRefresh = 0
    private var contactChanges: AnyCancellable?

    init(contacts: ContactDirectoryModel, correspondents: @escaping () async -> [Correspondent]) {
        self.contacts = contacts
        self.loadCorrespondents = correspondents
        // Suggestions read the Contacts snapshot, so its changes are this provider's changes.
        contactChanges = contacts.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Call when a recipient field first gets focus. Loads recent correspondents if nothing has
    /// yet, then asks for Contacts access if the user hasn't decided; once they have, it never
    /// asks again.
    func prepareContactsIfNeeded() async {
        if !hasLoadedCorrespondents {
            await refreshCorrespondents()
        }
        guard contacts.snapshot.authorization == .notDetermined else { return }
        await contacts.requestAccessAndRefresh()
    }

    /// Reloads recent correspondents. When refreshes overlap, the newest one's result wins.
    func refreshCorrespondents() async {
        hasLoadedCorrespondents = true
        latestRefresh += 1
        let refresh = latestRefresh
        let loaded = await loadCorrespondents()
        guard refresh == latestRefresh, loaded != correspondents else { return }
        correspondents = loaded
    }

    /// Up to `limit` suggestions for `query` from the current Contacts snapshot and the cached
    /// correspondents, leaving out `excluding` (addresses already in the field).
    func suggestions(matching query: String, excluding: Set<String>, limit: Int = 8) -> [RecipientSuggestion] {
        Self.merge(
            contactMatches: contacts.snapshot.suggestions(matching: query, excluding: excluding, limit: limit),
            recent: correspondents,
            query: query,
            excluding: excluding,
            limit: limit
        )
    }

    /// Contacts matching `query` (ranked as the Contacts snapshot ranks them), then recent
    /// correspondents whose name has a word, or whose address, starting with it, in their
    /// stored order. Addresses compare normalized; an excluded or already taken address is
    /// skipped, and an empty query suggests no one.
    nonisolated static func merge(
        contacts: [MailContact],
        recent: [Correspondent],
        query: String,
        excluding: Set<String>,
        limit: Int
    ) -> [RecipientSuggestion] {
        merge(
            contactMatches: ContactDirectorySnapshot(authorization: .authorized, contacts: contacts)
                .suggestions(matching: query, excluding: excluding, limit: limit),
            recent: recent,
            query: query,
            excluding: excluding,
            limit: limit
        )
    }

    private nonisolated static func merge(
        contactMatches: [MailContact],
        recent: [Correspondent],
        query rawQuery: String,
        excluding: Set<String>,
        limit: Int
    ) -> [RecipientSuggestion] {
        let query = searchValue(rawQuery)
        guard !query.isEmpty, limit > 0 else { return [] }
        var taken = Set(excluding.map(MailContact.normalizedEmail))
        var result: [RecipientSuggestion] = []
        for contact in contactMatches {
            guard result.count < limit else { break }
            let address = MailContact.normalizedEmail(contact.emailAddress)
            guard taken.insert(address).inserted else { continue }
            // A contact without a name is listed under its address.
            let name = searchValue(contact.displayName) == address ? nil : contact.displayName
            result.append(RecipientSuggestion(id: address, name: name, address: contact.emailAddress, source: .contact))
        }
        for correspondent in recent {
            guard result.count < limit else { break }
            let address = MailContact.normalizedEmail(correspondent.address)
            guard MailContact.isPlausibleEmailAddress(address),
                  matches(correspondent, query: query),
                  taken.insert(address).inserted else { continue }
            result.append(RecipientSuggestion(
                id: address,
                name: correspondent.displayName,
                address: correspondent.address,
                source: .recent
            ))
        }
        return result
    }

    private nonisolated static func matches(_ correspondent: Correspondent, query: String) -> Bool {
        if searchValue(correspondent.address).hasPrefix(query) { return true }
        guard let name = correspondent.displayName else { return false }
        let fullName = searchValue(name)
        if fullName.hasPrefix(query) { return true }
        return fullName
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(query) }
    }

    /// Lowercased and folded as the Contacts search folds, so "elo" finds "Élodie".
    private nonisolated static func searchValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}
