import Foundation
import PlainpostAccountProtocol

public struct CentralServerConfiguration: Sendable, Equatable {
    public static let maximumDocumentBytes = 4096
    public static let legacyProductionOrigin = URL(string: "https://plainpost-api.olhapi.com")!

    public enum ValidationError: Error, Sendable, Equatable {
        case malformedConfiguration
        case httpsRequired
        case hostRequired
        case rootOriginRequired
        case forbiddenURLComponents
    }

    public let origin: URL

    public init(originText: String) throws {
        guard !originText.isEmpty,
              originText.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw ValidationError.malformedConfiguration }
        guard var components = URLComponents(string: originText), components.scheme != nil else {
            throw ValidationError.malformedConfiguration
        }
        guard components.scheme?.lowercased() == "https" else { throw ValidationError.httpsRequired }
        guard let host = components.host, !host.isEmpty else { throw ValidationError.hostRequired }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { throw ValidationError.forbiddenURLComponents }
        guard components.path.isEmpty || components.path == "/" else { throw ValidationError.rootOriginRequired }
        if let port = components.port, !(1 ... 65_535).contains(port) {
            throw ValidationError.forbiddenURLComponents
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        if components.port == 443 { components.port = nil }
        guard let url = components.url else { throw ValidationError.malformedConfiguration }
        origin = url
    }

    public static func decode(_ document: Data) throws -> Self {
        guard !document.isEmpty, document.count <= maximumDocumentBytes,
              String(data: document, encoding: .utf8) != nil
        else { throw ValidationError.malformedConfiguration }
        do { try AccountWireCodec.validateUniqueJSONKeys(document) }
        catch { throw ValidationError.malformedConfiguration }
        guard let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              Set(object.keys) == Set(["kind", "origin"]),
              object["kind"] as? String == "plainpost.central-server-config.v1",
              let originText = object["origin"] as? String
        else { throw ValidationError.malformedConfiguration }
        let value = try Self(originText: originText)
        guard value.canonicalDocument == document else { throw ValidationError.malformedConfiguration }
        return value
    }

    public var canonicalDocument: Data {
        Data(#"{"kind":"plainpost.central-server-config.v1","origin":"\#(origin.absoluteString)"}"#.utf8)
    }

    public var canonicalSelectionRecord: Data {
        Data(#"{"boundOrigin":"\#(origin.absoluteString)","configuration":{"kind":"plainpost.central-server-config.v1","origin":"\#(origin.absoluteString)"},"kind":"plainpost.central-server-selection.v1"}"#.utf8)
    }

    public static var bundledDocument: Data? {
        guard let url = Bundle.module.url(forResource: "central-server-config-v1", withExtension: "json") else { return nil }
        do {
            var document = try Data(contentsOf: url)
            if document.last == 0x0a { document.removeLast() }
            return document
        } catch {
            // A present but unreadable resource must reach the resolver as an
            // invalid source rather than silently behaving like no default.
            return Data()
        }
    }
}

public protocol CentralServerConfigurationStoring: Sendable {
    func loadSelection() throws -> Data?
    func installSelectionIfAbsent(_ canonicalRecord: Data) throws -> Bool
    func replacePristineSelection(expected: Data, replacement: Data) throws -> Bool
}

public final class KeychainCentralServerConfigurationStore: CentralServerConfigurationStoring, @unchecked Sendable {
    private let key: AccountSecretKey
    private let secretStore: any AccountSecretStoring

    public convenience init() {
        self.init(secretStore: KeychainAccountSecretStore())
    }
    public convenience init(accessGroup: String?) {
        self.init(secretStore: KeychainAccountSecretStore(), accessGroup: accessGroup)
    }
    public init(
        secretStore: any AccountSecretStoring,
        accessGroup: String? = nil
    ) {
        self.secretStore = secretStore
        key = AccountSecretKey(
            service: "com.marynavdovenko.Plainpost.Account",
            account: "central.server.selection.v1",
            accessGroup: accessGroup
        )
    }

    public func loadSelection() throws -> Data? {
        guard let record = try secretStore.load(key) else { return nil }
        guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
        return record.value
    }

    public func installSelectionIfAbsent(_ canonicalRecord: Data) throws -> Bool {
        try secretStore.compareAndSwap(
            expected: nil,
            replacement: canonicalRecord,
            key: key,
            attributes: .deviceOnly
        )
    }

    public func replacePristineSelection(expected: Data, replacement: Data) throws -> Bool {
        try secretStore.compareAndSwap(
            expected: expected,
            replacement: replacement,
            key: key,
            attributes: .deviceOnly
        )
    }
}

public struct CentralServerRepair: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case invalidSelection
        case invalidBundledConfiguration
        case originMismatch
        case legacyAccountRequiresKnownOrigin
        case accountStateUnavailable
        case storageUnavailable
        case invalidManualInput(CentralServerConfiguration.ValidationError)
        case concurrentChange
    }

    public let reason: Reason
    public let boundOrigin: URL?

    public init(reason: Reason, boundOrigin: URL? = nil) {
        self.reason = reason
        self.boundOrigin = boundOrigin
    }
}

public enum CentralServerResolution: Sendable, Equatable {
    case configured(CentralServerConfiguration)
    case setupRequired
    case repairRequired(CentralServerRepair)
}

public struct CentralServerConfigurationResolver: Sendable {
    private let store: any CentralServerConfigurationStoring

    public init(store: any CentralServerConfigurationStoring) { self.store = store }

    public func canReplacePristineOrigin(credentials: any AccountCredentialStoring) -> Bool {
        do { return try credentials.withAccountStateFence { try !accountStateExists(credentials) } }
        catch { return false }
    }

    public func resolve(
        bundledDocument: Data? = CentralServerConfiguration.bundledDocument,
        credentials: any AccountCredentialStoring
    ) -> CentralServerResolution {
        let hasAccountState: Bool
        do { hasAccountState = try accountStateExists(credentials) }
        catch { return .repairRequired(CentralServerRepair(reason: .accountStateUnavailable)) }

        let selectionDocument: Data?
        do { selectionDocument = try store.loadSelection() }
        catch { return .repairRequired(CentralServerRepair(reason: .storageUnavailable)) }

        if let selectionDocument {
            do { return .configured(try decodeSelection(selectionDocument)) }
            catch SelectionDecodeError.originMismatch(let boundOrigin) {
                return .repairRequired(CentralServerRepair(reason: .originMismatch, boundOrigin: boundOrigin))
            } catch { return .repairRequired(CentralServerRepair(reason: .invalidSelection)) }
        }

        let bundled: CentralServerConfiguration?
        if let bundledDocument {
            do { bundled = try CentralServerConfiguration.decode(bundledDocument) }
            catch { return .repairRequired(CentralServerRepair(reason: .invalidBundledConfiguration)) }
        } else { bundled = nil }

        if hasAccountState {
            guard let bundled,
                  bundled.origin == CentralServerConfiguration.legacyProductionOrigin
            else {
                return .repairRequired(CentralServerRepair(
                    reason: .legacyAccountRequiresKnownOrigin,
                    boundOrigin: CentralServerConfiguration.legacyProductionOrigin
                ))
            }
            return installOrReload(bundled, requiredOrigin: CentralServerConfiguration.legacyProductionOrigin)
        }

        guard let bundled else { return .setupRequired }
        return installOrReload(bundled)
    }

    public func saveManualOrigin(
        _ originText: String,
        bundledDocument: Data? = CentralServerConfiguration.bundledDocument,
        credentials: any AccountCredentialStoring
    ) -> CentralServerResolution {
        let configuration: CentralServerConfiguration
        do { configuration = try CentralServerConfiguration(originText: originText) }
        catch let error as CentralServerConfiguration.ValidationError {
            return .repairRequired(CentralServerRepair(reason: .invalidManualInput(error)))
        } catch {
            return .repairRequired(CentralServerRepair(reason: .invalidManualInput(.malformedConfiguration)))
        }

        let hasAccountState: Bool
        do { hasAccountState = try accountStateExists(credentials) }
        catch { return .repairRequired(CentralServerRepair(reason: .accountStateUnavailable)) }

        let current: Data?
        do { current = try store.loadSelection() }
        catch { return .repairRequired(CentralServerRepair(reason: .storageUnavailable)) }

        if hasAccountState {
            if let current {
                if let bound = try? decodeSelection(current), bound == configuration {
                    return .configured(bound)
                }
                if let parts = try? decodeSelectionParts(current),
                   parts.selected != parts.bound,
                   configuration == parts.bound {
                    do {
                        guard try store.replacePristineSelection(
                            expected: current,
                            replacement: parts.bound.canonicalSelectionRecord
                        ) else {
                            return .repairRequired(CentralServerRepair(
                                reason: .concurrentChange,
                                boundOrigin: parts.bound.origin
                            ))
                        }
                        return resolve(bundledDocument: bundledDocument, credentials: credentials)
                    } catch {
                        return .repairRequired(CentralServerRepair(reason: .storageUnavailable))
                    }
                } else {
                    return .repairRequired(CentralServerRepair(
                        reason: .originMismatch,
                        boundOrigin: (try? decodeSelectionParts(current))?.bound.origin
                    ))
                }
            }
            guard configuration.origin == CentralServerConfiguration.legacyProductionOrigin else {
                return .repairRequired(CentralServerRepair(
                    reason: .legacyAccountRequiresKnownOrigin,
                    boundOrigin: CentralServerConfiguration.legacyProductionOrigin
                ))
            }
        }

        guard let current else {
            return installOrReload(
                configuration,
                requiredOrigin: hasAccountState ? CentralServerConfiguration.legacyProductionOrigin : nil
            )
        }
        return replacePristineOrigin(
            configuration,
            expectedSelection: current,
            bundledDocument: bundledDocument,
            credentials: credentials
        )
    }

    public func replacePristineOrigin(
        _ configuration: CentralServerConfiguration,
        expectedSelection: Data,
        bundledDocument: Data? = CentralServerConfiguration.bundledDocument,
        credentials: any AccountCredentialStoring
    ) -> CentralServerResolution {
        do {
            return try credentials.withAccountStateFence {
                guard try !accountStateExists(credentials) else {
                    return .repairRequired(CentralServerRepair(
                        reason: .originMismatch,
                        boundOrigin: (try? decodeSelection(expectedSelection))?.origin
                    ))
                }
                guard try store.replacePristineSelection(
                    expected: expectedSelection,
                    replacement: configuration.canonicalSelectionRecord
                ) else {
                    guard let winner = try store.loadSelection() else {
                        return .repairRequired(CentralServerRepair(reason: .concurrentChange))
                    }
                    return .configured(try decodeSelection(winner))
                }
                return .configured(configuration)
            }
        } catch {
            return .repairRequired(CentralServerRepair(reason: .storageUnavailable))
        }
    }

    private func installOrReload(
        _ configuration: CentralServerConfiguration,
        requiredOrigin: URL? = nil
    ) -> CentralServerResolution {
        do {
            if try store.installSelectionIfAbsent(configuration.canonicalSelectionRecord) {
                return .configured(configuration)
            }
            guard let winner = try store.loadSelection() else {
                return .repairRequired(CentralServerRepair(reason: .concurrentChange))
            }
            let selected = try decodeSelection(winner)
            if let requiredOrigin, selected.origin != requiredOrigin {
                return .repairRequired(CentralServerRepair(
                    reason: .originMismatch,
                    boundOrigin: requiredOrigin
                ))
            }
            return .configured(selected)
        } catch {
            return .repairRequired(CentralServerRepair(reason: .storageUnavailable))
        }
    }

    private func accountStateExists(_ credentials: any AccountCredentialStoring) throws -> Bool {
        let session = try credentials.loadSession()
        let deletion = try credentials.loadLocalDeletion()
        let receipt = try credentials.loadCompletedDeletionReceipt()
        return session != nil || deletion != nil || receipt != nil
    }

    private func decodeSelection(_ document: Data) throws -> CentralServerConfiguration {
        let parts = try decodeSelectionParts(document)
        guard parts.selected == parts.bound else {
            throw SelectionDecodeError.originMismatch(parts.bound.origin)
        }
        return parts.selected
    }

    private func decodeSelectionParts(
        _ document: Data
    ) throws -> (selected: CentralServerConfiguration, bound: CentralServerConfiguration) {
        guard !document.isEmpty, document.count <= CentralServerConfiguration.maximumDocumentBytes,
              String(data: document, encoding: .utf8) != nil
        else { throw CentralServerConfiguration.ValidationError.malformedConfiguration }
        do { try AccountWireCodec.validateUniqueJSONKeys(document) }
        catch { throw CentralServerConfiguration.ValidationError.malformedConfiguration }
        guard let root = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              Set(root.keys) == Set(["boundOrigin", "configuration", "kind"]),
              root["kind"] as? String == "plainpost.central-server-selection.v1",
              let boundOrigin = root["boundOrigin"] as? String,
              let nested = root["configuration"] as? [String: Any],
              Set(nested.keys) == Set(["kind", "origin"]),
              nested["kind"] as? String == "plainpost.central-server-config.v1",
              let selectedOrigin = nested["origin"] as? String
        else { throw CentralServerConfiguration.ValidationError.malformedConfiguration }
        let selected = try CentralServerConfiguration(originText: selectedOrigin)
        let bound = try CentralServerConfiguration(originText: boundOrigin)
        let canonical = Data(#"{"boundOrigin":"\#(bound.origin.absoluteString)","configuration":{"kind":"plainpost.central-server-config.v1","origin":"\#(selected.origin.absoluteString)"},"kind":"plainpost.central-server-selection.v1"}"#.utf8)
        guard canonical == document else {
            throw CentralServerConfiguration.ValidationError.malformedConfiguration
        }
        return (selected, bound)
    }

    private enum SelectionDecodeError: Error {
        case originMismatch(URL?)
    }
}
