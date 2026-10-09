import Contacts
import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum ContactDirectoryAuthorization: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
    case unavailable

    var permitsReading: Bool {
        self == .authorized || self == .limited
    }

    var settingsLabel: String {
        switch self {
        case .notDetermined: "Not enabled"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Enabled"
        case .limited: "Limited"
        case .unavailable: "Unavailable"
        }
    }
}

struct MailContact: Identifiable, Equatable, Sendable {
    let id: String
    let contactID: String
    let displayName: String
    let emailAddress: String
    let thumbnailImageData: Data?

    init(
        contactID: String,
        displayName: String,
        emailAddress: String,
        thumbnailImageData: Data? = nil
    ) {
        self.contactID = contactID
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.thumbnailImageData = thumbnailImageData
        self.id = "\(contactID):\(Self.normalizedEmail(emailAddress))"
    }

    var monogram: String {
        let words = displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String((words.first.map(String.init) ?? emailAddress).prefix(2)).uppercased()
    }

    static func normalizedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.lastIndex(of: "<"),
           let end = trimmed[trimmed.index(after: start)...].firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return trimmed.lowercased()
    }

    static func isPlausibleEmailAddress(_ value: String) -> Bool {
        let normalized = normalizedEmail(value)
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first,
              let domain = parts.last,
              !local.isEmpty,
              domain.contains("."),
              !normalized.contains(where: \.isWhitespace)
        else {
            return false
        }
        return true
    }
}

struct ContactDirectorySnapshot: Equatable, Sendable {
    static let empty = ContactDirectorySnapshot(authorization: .unavailable)

    let authorization: ContactDirectoryAuthorization
    let contacts: [MailContact]
    let isLoading: Bool
    let errorMessage: String?
    private let contactsByEmail: [String: MailContact]

    init(
        authorization: ContactDirectoryAuthorization,
        contacts: [MailContact] = [],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.authorization = authorization
        self.contacts = Self.deduplicated(contacts)
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.contactsByEmail = Dictionary(
            uniqueKeysWithValues: self.contacts.map {
                (MailContact.normalizedEmail($0.emailAddress), $0)
            }
        )
    }

    var contactCount: Int {
        Set(contacts.map(\.contactID)).count
    }

    func contact(for emailAddress: String) -> MailContact? {
        contactsByEmail[MailContact.normalizedEmail(emailAddress)]
    }

    func suggestions(
        matching rawQuery: String,
        excluding excludedAddresses: Set<String> = [],
        limit: Int = 8
    ) -> [MailContact] {
        let query = Self.searchValue(rawQuery)
        guard !query.isEmpty, limit > 0 else { return [] }
        let excluded = Set(excludedAddresses.map(MailContact.normalizedEmail))

        return contacts
            .filter { !excluded.contains(MailContact.normalizedEmail($0.emailAddress)) }
            .compactMap { contact -> (MailContact, Int)? in
                guard let score = Self.matchScore(contact: contact, query: query) else {
                    return nil
                }
                return (contact, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let leftName = Self.searchValue(lhs.0.displayName)
                let rightName = Self.searchValue(rhs.0.displayName)
                if leftName != rightName { return leftName < rightName }
                return MailContact.normalizedEmail(lhs.0.emailAddress)
                    < MailContact.normalizedEmail(rhs.0.emailAddress)
            }
            .prefix(limit)
            .map(\.0)
    }

    func updating(
        authorization: ContactDirectoryAuthorization? = nil,
        contacts: [MailContact]? = nil,
        isLoading: Bool? = nil,
        errorMessage: String?? = nil
    ) -> ContactDirectorySnapshot {
        ContactDirectorySnapshot(
            authorization: authorization ?? self.authorization,
            contacts: contacts ?? self.contacts,
            isLoading: isLoading ?? self.isLoading,
            errorMessage: errorMessage ?? self.errorMessage
        )
    }

    private static func deduplicated(_ contacts: [MailContact]) -> [MailContact] {
        var byEmail: [String: MailContact] = [:]
        for contact in contacts {
            let email = MailContact.normalizedEmail(contact.emailAddress)
            guard MailContact.isPlausibleEmailAddress(email) else { continue }
            if let existing = byEmail[email] {
                if shouldPrefer(contact, over: existing) {
                    byEmail[email] = contact
                }
            } else {
                byEmail[email] = contact
            }
        }
        return byEmail.values.sorted {
            let leftName = searchValue($0.displayName)
            let rightName = searchValue($1.displayName)
            if leftName != rightName { return leftName < rightName }
            return MailContact.normalizedEmail($0.emailAddress) < MailContact.normalizedEmail($1.emailAddress)
        }
    }

    private static func shouldPrefer(_ candidate: MailContact, over existing: MailContact) -> Bool {
        let candidatePhoto = candidate.thumbnailImageData != nil
        let existingPhoto = existing.thumbnailImageData != nil
        if candidatePhoto != existingPhoto { return candidatePhoto }

        let candidateHasName = searchValue(candidate.displayName) != MailContact.normalizedEmail(candidate.emailAddress)
        let existingHasName = searchValue(existing.displayName) != MailContact.normalizedEmail(existing.emailAddress)
        if candidateHasName != existingHasName { return candidateHasName }
        return candidate.contactID < existing.contactID
    }

    private static func matchScore(contact: MailContact, query: String) -> Int? {
        let name = searchValue(contact.displayName)
        let email = searchValue(contact.emailAddress)
        if name == query || email == query { return 0 }
        if name.hasPrefix(query) || email.hasPrefix(query) { return 1 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) { return 2 }
        if name.contains(query) || email.contains(query) { return 3 }
        return nil
    }

    private static func searchValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}

enum ComposerRecipientInput {
    private static let delimiters: Set<Character> = [",", ";", "\n"]

    static func activeFragment(in value: String) -> String {
        String(value.split(omittingEmptySubsequences: false, whereSeparator: { delimiters.contains($0) }).last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func completedAddresses(in value: String) -> Set<String> {
        let pieces = value.split(omittingEmptySubsequences: false, whereSeparator: { delimiters.contains($0) })
        return Set(pieces.dropLast().compactMap { piece in
            let normalized = MailContact.normalizedEmail(String(piece))
            return normalized.isEmpty ? nil : normalized
        })
    }

    static func replacingActiveFragment(in value: String, with emailAddress: String) -> String {
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return value }
        guard let delimiterIndex = value.lastIndex(where: { delimiters.contains($0) }) else {
            return "\(email), "
        }
        let prefix = value[...delimiterIndex]
        return "\(prefix) \(email), "
    }
}

protocol ContactDirectoryClient: Sendable {
    func authorizationStatus() async -> ContactDirectoryAuthorization
    func requestAccess() async throws -> Bool
    func fetchContacts() async throws -> [MailContact]
}

private struct PreviewContactDirectoryClient: ContactDirectoryClient {
    func authorizationStatus() async -> ContactDirectoryAuthorization {
        .notDetermined
    }

    func requestAccess() async throws -> Bool {
        false
    }

    func fetchContacts() async throws -> [MailContact] {
        []
    }
}

#if DEBUG
private struct ContactAutocompleteAcceptanceClient: ContactDirectoryClient {
    private let contact = MailContact(
        contactID: "contact-autocomplete-acceptance",
        displayName: "Autocomplete Contact",
        emailAddress: "autocomplete@example.test"
    )

    func authorizationStatus() async -> ContactDirectoryAuthorization { .authorized }
    func requestAccess() async throws -> Bool { true }
    func fetchContacts() async throws -> [MailContact] { [contact] }
}
#endif

actor SystemContactDirectoryClient: ContactDirectoryClient {
    private let store = CNContactStore()

    func authorizationStatus() -> ContactDirectoryAuthorization {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unavailable
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    func fetchContacts() throws -> [MailContact] {
        let keys: [any CNKeyDescriptor] = [
            CNContactIdentifierKey as any CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
            CNContactThumbnailImageDataKey as any CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var contacts: [MailContact] = []

        try store.enumerateContacts(with: request) { contact, _ in
            let formattedName = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let organizationName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)

            for labeledEmail in contact.emailAddresses {
                let email = (labeledEmail.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !email.isEmpty else { continue }
                let displayName = if let formattedName, !formattedName.isEmpty {
                    formattedName
                } else if !organizationName.isEmpty {
                    organizationName
                } else {
                    email
                }
                contacts.append(
                    MailContact(
                        contactID: contact.identifier,
                        displayName: displayName,
                        emailAddress: email,
                        thumbnailImageData: contact.thumbnailImageData
                    )
                )
            }
        }
        return contacts
    }
}

@MainActor
public final class ContactDirectoryModel: ObservableObject {
    @Published private(set) var snapshot: ContactDirectorySnapshot

    private let client: any ContactDirectoryClient
    private var isPrepared = false
    private var hasLoadedContacts = false
    private var changeTask: Task<Void, Never>?

    init(
        client: any ContactDirectoryClient,
        initialSnapshot: ContactDirectorySnapshot = ContactDirectorySnapshot(authorization: .notDetermined)
    ) {
        self.client = client
        self.snapshot = initialSnapshot
    }

    public static func system() -> ContactDirectoryModel {
        ContactDirectoryModel(client: SystemContactDirectoryClient())
    }

    public static func designPreview() -> ContactDirectoryModel {
        ContactDirectoryModel(client: PreviewContactDirectoryClient())
    }

    /// A directory with no Contacts behind it, for sessions without the app's directory
    /// (previews, tests, the session `makeRootView` builds). It reports Contacts as unavailable, so
    /// nothing ever asks the user for access.
    static func unavailable() -> ContactDirectoryModel {
        ContactDirectoryModel(client: PreviewContactDirectoryClient(), initialSnapshot: .empty)
    }

    #if DEBUG
    public static func contactAutocompleteAcceptancePreview() -> ContactDirectoryModel {
        ContactDirectoryModel(client: ContactAutocompleteAcceptanceClient())
    }
    #endif

    deinit {
        changeTask?.cancel()
    }

    public func prepare() async {
        if !isPrepared {
            isPrepared = true
            startObservingContactChanges()
        }
        let previousAuthorization = snapshot.authorization
        let authorization = await client.authorizationStatus()
        guard authorization.permitsReading else {
            hasLoadedContacts = false
            snapshot = ContactDirectorySnapshot(authorization: authorization)
            return
        }
        snapshot = snapshot.updating(authorization: authorization, errorMessage: .some(nil))
        if !hasLoadedContacts || previousAuthorization != authorization {
            await refresh()
        }
    }

    func requestAccessAndRefresh() async {
        if !isPrepared {
            await prepare()
        }
        switch snapshot.authorization {
        case .authorized, .limited:
            if !hasLoadedContacts {
                await refresh()
            }
        case .notDetermined:
            snapshot = snapshot.updating(isLoading: true, errorMessage: .some(nil))
            do {
                let granted = try await client.requestAccess()
                var authorization = await client.authorizationStatus()
                if granted && authorization == .notDetermined {
                    authorization = .authorized
                } else if !granted && authorization == .notDetermined {
                    authorization = .denied
                }
                snapshot = snapshot.updating(authorization: authorization, isLoading: false)
                if authorization.permitsReading {
                    await refresh()
                }
            } catch {
                let authorization = await client.authorizationStatus()
                snapshot = snapshot.updating(
                    authorization: authorization,
                    isLoading: false,
                    errorMessage: .some(
                        authorization == .notDetermined
                            ? "Contacts access could not be requested. Try again."
                            : nil
                    )
                )
                if authorization.permitsReading {
                    await refresh()
                }
            }
        case .denied, .restricted, .unavailable:
            break
        }
    }

    func refresh() async {
        let authorization = await client.authorizationStatus()
        guard authorization.permitsReading else {
            snapshot = ContactDirectorySnapshot(authorization: authorization)
            return
        }
        snapshot = snapshot.updating(
            authorization: authorization,
            isLoading: true,
            errorMessage: .some(nil)
        )
        do {
            let contacts = try await client.fetchContacts()
            snapshot = ContactDirectorySnapshot(
                authorization: authorization,
                contacts: contacts,
                isLoading: false
            )
            hasLoadedContacts = true
        } catch {
            snapshot = snapshot.updating(
                authorization: authorization,
                isLoading: false,
                errorMessage: .some("Contacts could not be refreshed. Try again.")
            )
        }
    }

    private func startObservingContactChanges() {
        guard changeTask == nil else { return }
        changeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                guard let self else { return }
                if self.snapshot.authorization.permitsReading {
                    await self.refresh()
                }
            }
        }
    }
}

private struct MailContactDirectorySnapshotKey: EnvironmentKey {
    static let defaultValue = ContactDirectorySnapshot.empty
}

private struct MailContactDirectoryModelKey: EnvironmentKey {
    static let defaultValue: ContactDirectoryModel? = nil
}

extension EnvironmentValues {
    var mailContactDirectorySnapshot: ContactDirectorySnapshot {
        get { self[MailContactDirectorySnapshotKey.self] }
        set { self[MailContactDirectorySnapshotKey.self] = newValue }
    }

    var mailContactDirectoryModel: ContactDirectoryModel? {
        get { self[MailContactDirectoryModelKey.self] }
        set { self[MailContactDirectoryModelKey.self] = newValue }
    }
}

private struct MailContactDirectoryModifier: ViewModifier {
    @ObservedObject var model: ContactDirectoryModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.mailContactDirectorySnapshot, model.snapshot)
            .environment(\.mailContactDirectoryModel, model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.prepare() }
                }
            }
    }
}

public extension View {
    func mailContactDirectory(_ model: ContactDirectoryModel) -> some View {
        modifier(MailContactDirectoryModifier(model: model))
    }
}

struct MailContactPhoto: View {
    let contact: MailContact
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbnailImage {
                thumbnailImage
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [MailDesign.accentBlue, MailDesign.accentTeal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        Text(contact.monogram)
                            .font(.system(size: max(9, size * 0.32), weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var thumbnailImage: Image? {
        guard let data = contact.thumbnailImageData else { return nil }
#if canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
#elseif canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
#else
        return nil
#endif
    }
}
