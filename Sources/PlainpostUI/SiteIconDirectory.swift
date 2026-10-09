import Foundation
import SwiftUI

@MainActor
public final class SiteIconDirectoryModel: ObservableObject {
    @Published private var iconData: [String: Data] = [:]

    private let cache: SiteIconCache
    private let fetcher: SiteIconFetcher
    private let fetchEnabled: () -> Bool
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(cache: SiteIconCache, fetcher: SiteIconFetcher, defaults: UserDefaults = .standard) {
        self.cache = cache
        self.fetcher = fetcher
        self.fetchEnabled = { SiteIconPreference.fetchEnabled(defaults: defaults) }
    }

    private init(
        cache: SiteIconCache,
        fetcher: SiteIconFetcher,
        fetchEnabled: @escaping () -> Bool
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.fetchEnabled = fetchEnabled
    }

    public static func system() -> SiteIconDirectoryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("Plainpost/SiteIcons", isDirectory: true)
        return try! SiteIconDirectoryModel(cache: SiteIconCache(rootURL: root), fetcher: SiteIconFetcher())
    }

#if DEBUG
    public static func debugAcceptance(rootURL: URL) throws -> SiteIconDirectoryModel {
        try SiteIconDirectoryModel(
            cache: SiteIconCache(rootURL: rootURL.appendingPathComponent("SiteIcons", isDirectory: true)),
            fetcher: SiteIconFetcher(),
            fetchEnabled: { false }
        )
    }

    static func debugAcceptance(
        rootURL: URL,
        client: any SiteIconHTTPClient
    ) throws -> SiteIconDirectoryModel {
        try SiteIconDirectoryModel(
            cache: SiteIconCache(rootURL: rootURL),
            fetcher: SiteIconFetcher(client: client),
            fetchEnabled: { false }
        )
    }
#endif

    func data(for sender: String) -> Data? {
        guard let domain = SiteIconDomain(sender: sender) else { return nil }
        return iconData[domain.host]
    }

    func resolveIfNeeded(sender: String) {
        guard let domain = SiteIconDomain(sender: sender), iconData[domain.host] == nil, inFlight[domain.host] == nil else { return }
        inFlight[domain.host] = Task { [weak self] in
            await self?.resolve(domain)
        }
    }

    func clear() async {
        try? await cache.clear()
        iconData = [:]
    }

    func waitForIdleForTesting() async {
        while !inFlight.isEmpty { await Task.yield() }
    }

    private func resolve(_ domain: SiteIconDomain) async {
        defer { inFlight[domain.host] = nil }
        if let cached = try? await cache.cachedIcon(for: domain) {
            if let data = cached.pngData { iconData[domain.host] = data; return }
            if cached.isNegativeCached { return }
        }
        guard fetchEnabled() else { return }
        do {
            let data = try await fetcher.fetchPNG(for: domain)
            try await cache.storeSuccess(domain, pngData: data)
            iconData[domain.host] = data
        } catch {
            try? await cache.storeFailure(domain)
        }
    }
}

private struct MailSiteIconDirectoryKey: EnvironmentKey {
    static let defaultValue: SiteIconDirectoryModel? = nil
}

extension EnvironmentValues {
    var mailSiteIconDirectory: SiteIconDirectoryModel? {
        get { self[MailSiteIconDirectoryKey.self] }
        set { self[MailSiteIconDirectoryKey.self] = newValue }
    }
}

public extension View {
    func mailSiteIconDirectory(_ model: SiteIconDirectoryModel) -> some View {
        environment(\.mailSiteIconDirectory, model)
    }
}
