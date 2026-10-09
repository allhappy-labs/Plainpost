import Foundation

struct SiteIconCacheLookup: Sendable {
    let pngData: Data?
    let isNegativeCached: Bool
}

actor SiteIconCache {
    private static let failurePolicyVersion = 3
    private static let successLifetime: TimeInterval = 30 * 86_400
    private static let failureLifetime: TimeInterval = 7 * 86_400

    private enum Outcome: String, Codable { case success, failure }
    private struct Entry: Codable {
        let outcome: Outcome
        let filename: String?
        let expiresAt: Date
        let failurePolicyVersion: Int?
    }
    private struct Index: Codable { let version: Int; var entries: [String: Entry] }

    private let rootURL: URL
    private let indexURL: URL
    private var entries: [String: Entry]

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        self.indexURL = rootURL.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data), index.version == 1 {
            entries = index.entries
        } else {
            entries = [:]
        }
    }

    func cachedIcon(for domain: SiteIconDomain, now: Date = .now) throws -> SiteIconCacheLookup {
        guard let entry = entries[domain.host] else { return .init(pngData: nil, isNegativeCached: false) }
        guard entry.expiresAt > now else { try remove(domain.host, entry: entry); return .init(pngData: nil, isNegativeCached: false) }
        guard entry.outcome == .success else {
            guard entry.failurePolicyVersion == Self.failurePolicyVersion else {
                try remove(domain.host, entry: entry)
                return .init(pngData: nil, isNegativeCached: false)
            }
            return .init(pngData: nil, isNegativeCached: true)
        }
        guard let filename = entry.filename, let data = try? Data(contentsOf: rootURL.appendingPathComponent(filename)), !data.isEmpty else {
            try remove(domain.host, entry: entry); return .init(pngData: nil, isNegativeCached: false)
        }
        return .init(pngData: data, isNegativeCached: false)
    }

    func storeSuccess(_ domain: SiteIconDomain, pngData: Data, now: Date = .now) throws {
        let filename = "\(domain.host).png"
        try pngData.write(to: rootURL.appendingPathComponent(filename), options: .atomic)
        entries[domain.host] = Entry(outcome: .success, filename: filename, expiresAt: now.addingTimeInterval(Self.successLifetime), failurePolicyVersion: nil)
        try writeIndex()
    }

    func storeFailure(_ domain: SiteIconDomain, now: Date = .now) throws {
        entries[domain.host] = Entry(outcome: .failure, filename: nil, expiresAt: now.addingTimeInterval(Self.failureLifetime), failurePolicyVersion: Self.failurePolicyVersion)
        try writeIndex()
    }

    func clear() throws {
        try FileManager.default.removeItem(at: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        entries = [:]
    }

    private func remove(_ host: String, entry: Entry) throws {
        if let filename = entry.filename { try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(filename)) }
        entries.removeValue(forKey: host)
        try writeIndex()
    }

    private func writeIndex() throws {
        let data = try JSONEncoder().encode(Index(version: 1, entries: entries))
        try data.write(to: indexURL, options: .atomic)
    }
}
