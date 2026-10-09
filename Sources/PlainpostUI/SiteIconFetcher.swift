import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol SiteIconHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int, mimeType: String?, redirectLocation: String?)
}

enum SiteIconFetchError: Error {
    case invalidResponse
    case invalidImage
}

struct SiteIconFetcher: Sendable {
    static let timeout: TimeInterval = 8
    static let candidateTimeout: TimeInterval = 2.5
    static let maximumResponseBytes = 512 * 1_024

    private let client: any SiteIconHTTPClient

    init(client: any SiteIconHTTPClient = URLSessionSiteIconHTTPClient()) {
        self.client = client
    }

    func fetchPNG(for domain: SiteIconDomain) async throws -> Data {
        let parent = domain.host.split(separator: ".").dropFirst().joined(separator: ".")
        var hosts = [domain.host]
        if parent.contains(".") { hosts.append(parent) }
        if let site = hosts.last, !site.hasPrefix("www.") { hosts.append("www.\(site)") }
        let deadline = Date().addingTimeInterval(Self.timeout)

        for path in ["favicon.ico", "apple-touch-icon.png"] {
            for host in hosts {
                guard deadline.timeIntervalSinceNow > 0 else { throw SiteIconFetchError.invalidResponse }
                guard let url = URL(string: "https://\(host)/\(path)") else { continue }
                if let png = try? await fetchPNG(at: url, deadline: deadline) {
                    return png
                }
            }
        }
        throw SiteIconFetchError.invalidResponse
    }

    private func fetchPNG(at url: URL, deadline: Date) async throws -> Data {
        var currentURL = url
        for redirectCount in 0...2 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SiteIconFetchError.invalidResponse }
            var request = URLRequest(
                url: currentURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: min(Self.candidateTimeout, remaining)
            )
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("image/*", forHTTPHeaderField: "Accept")

            let response = try await client.data(for: request)
            guard response.data.count <= Self.maximumResponseBytes else { throw SiteIconFetchError.invalidResponse }
            if (300..<400).contains(response.statusCode),
               redirectCount < 2,
               let location = response.redirectLocation,
               location.count <= 2_048,
               let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
               nextURL.scheme == "https",
               nextURL.host?.lowercased() == url.host?.lowercased(),
               nextURL.user == nil,
               nextURL.password == nil,
               nextURL.port == nil || nextURL.port == 443 {
                currentURL = nextURL
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw SiteIconFetchError.invalidResponse }
            return try SiteIconImageNormalizer.pngData(from: response.data)
        }
        throw SiteIconFetchError.invalidResponse
    }
}

private final class SiteIconRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class URLSessionSiteIconHTTPClient: NSObject, SiteIconHTTPClient, @unchecked Sendable {
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SiteIconRedirectBlockingDelegate(), delegateQueue: nil)
        super.init()
    }

    func data(for request: URLRequest) async throws -> (data: Data, statusCode: Int, mimeType: String?, redirectLocation: String?) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SiteIconFetchError.invalidResponse }
        return (data, http.statusCode, http.mimeType, http.value(forHTTPHeaderField: "Location"))
    }
}

private enum SiteIconImageNormalizer {
    static func pngData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw SiteIconFetchError.invalidImage }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw SiteIconFetchError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw SiteIconFetchError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SiteIconFetchError.invalidImage }
        return output as Data
    }
}
