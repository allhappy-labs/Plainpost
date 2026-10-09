import CryptoKit
import Foundation
import PlainpostNodeTransport

struct CalendarAccountSettings: Codable, Equatable, Sendable {
    var timezoneID: String
    var visibleCalendarIDs: Set<String>
    var showDeclined: Bool
    // nil migrates the original settings using the last cached catalog.
    var knownCalendarIDs: Set<String>? = nil
}

/// Only transport projections and display preferences enter this store.
/// The root is the runtime's existing application-data directory.
struct CalendarSnapshotCache: Sendable {
    let directory: URL
    init(accountID: String, appDataRoot: URL) {
        directory = appDataRoot.appendingPathComponent("Calendar", isDirectory: true).appendingPathComponent(Self.digest(accountID), isDirectory: true)
    }
    func load(_ window: NodeCalendarWindow) throws -> NodeCalendarWindowSnapshot? {
        let snapshot: NodeCalendarWindowSnapshot? = try read(Self.key(window))
        guard snapshot?.window == window else { return nil }
        return snapshot
    }
    func save(_ snapshot: NodeCalendarWindowSnapshot) throws { try write(snapshot, name: Self.key(snapshot.window)) }
    func loadConnections() throws -> [NodeCalendarConnection]? { try read("connections.json") }
    func saveConnections(_ connections: [NodeCalendarConnection]) throws { try write(connections, name: "connections.json") }
    func loadSettings() throws -> CalendarAccountSettings? { try read("settings.json") }
    func saveSettings(_ settings: CalendarAccountSettings) throws { try write(settings, name: "settings.json") }
    func loadResponseIntents() throws -> [String: CalendarResponseIntent]? { try read("response-intents.json") }
    func saveResponseIntents(_ intents: [String: CalendarResponseIntent]) throws { try write(intents, name: "response-intents.json") }
    func clear() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    static func clearAll(appDataRoot: URL) throws {
        let root = appDataRoot.appendingPathComponent("Calendar", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func read<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 32_000_000 else { throw NodeCalendarError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let data = try JSONEncoder().encode(value)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let target = directory.appendingPathComponent(name)
        guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func key(_ window: NodeCalendarWindow) -> String { digest(window.start + "|" + window.end + "|" + window.timezone) + ".json" }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
