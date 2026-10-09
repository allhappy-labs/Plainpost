
import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI
import UniformTypeIdentifiers

public extension UTType {
    static let plainpostServerSetup = UTType(exportedAs: "com.marynavdovenko.plainpost.server-setup", conformingTo: .json)
}

@MainActor
struct SyncNodeBootstrapFileAccess {
    let startAccessing: (URL) -> Bool
    let stopAccessing: (URL) -> Void
    let read: (URL, Int) throws -> Data

    static let live = SyncNodeBootstrapFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        read: { url, maximumBytes in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AccountRuntimeError.untrustedResponse
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let document = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard !document.isEmpty, document.count <= maximumBytes else {
                throw AccountRuntimeError.untrustedResponse
            }
            return document
        }
    )
}

@MainActor
public final class SyncNodeBootstrapImportViewModel: ObservableObject {
    public enum ServerOriginUpdate: Equatable {
        case saved(origin: String, nodeFingerprint: String)
        case invalidAddress
        case unavailable
    }

    public enum Presentation: Equatable {
        case empty
        case imported(origin: String, nodeFingerprint: String)
        case failure(message: String)
    }

    public static let failureMessage = "Server setup couldn’t be imported. Check the file and try again."

    @Published public private(set) var presentation: Presentation = .empty
    @Published public var isFileImporterPresented = false
    @Published public private(set) var profileGeneration: UInt64 = 0

    private let store: any SyncNodeBootstrapProfileStoring
    private var currentIdentity: ProfileIdentity?
    var fileAccess: SyncNodeBootstrapFileAccess

    public init(store: any SyncNodeBootstrapProfileStoring) {
        self.store = store
        fileAccess = .live
        reloadPresentation()
    }

    init(store: any SyncNodeBootstrapProfileStoring, fileAccess: SyncNodeBootstrapFileAccess) {
        self.store = store
        self.fileAccess = fileAccess
        reloadPresentation()
    }

    public func presentFileImporter() {
        isFileImporterPresented = true
    }

    public func handleFileImporter(_ result: Result<[URL], Error>) {
        isFileImporterPresented = false
        guard case .success(let urls) = result, urls.count == 1, let url = urls.first else {
            presentation = .failure(message: Self.failureMessage)
            return
        }
        importFile(at: url)
    }

    public func importFile(at url: URL) {
        guard url.isFileURL, url.pathExtension == "plainpostserver" else {
            presentation = .failure(message: Self.failureMessage)
            return
        }
        let scoped = fileAccess.startAccessing(url)
        defer {
            if scoped { fileAccess.stopAccessing(url) }
        }
        do {
            var document = try fileAccess.read(url, SyncNodeBootstrapProfile.maximumDocumentBytes)
            defer { document.resetBytes(in: document.startIndex ..< document.endIndex) }
            let profile = try SyncNodeBootstrapProfile.decode(document)
            try store.importProfile(profile)
            publish(profile)
        } catch {
            presentation = .failure(message: Self.failureMessage)
        }
    }

    public func loadProfile() throws -> SyncNodeBootstrapProfile? {
        try store.load()
    }

    public func replaceServerOrigin(_ originText: String) -> ServerOriginUpdate {
        let origin: NodeEndpointURL
        do {
            origin = try NodeEndpointURL(
                originText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return .invalidAddress
        }
        do {
            guard let current = try store.load() else { return .unavailable }
            let replacement = try store.replaceOrigin(
                origin,
                expectedCapabilityID: current.capabilityID
            )
            publish(replacement)
            guard case .imported(let origin, let nodeFingerprint) = presentation else {
                return .unavailable
            }
            return .saved(origin: origin, nodeFingerprint: nodeFingerprint)
        } catch {
            return .unavailable
        }
    }

    public func retireProfile(expectedCapabilityID: Data) throws {
        try store.retire(expectedCapabilityID: expectedCapabilityID)
        reloadPresentation()
    }

    private func reloadPresentation() {
        do {
            guard let profile = try store.load() else {
                updateIdentity(nil)
                presentation = .empty
                return
            }
            publish(profile)
        } catch {
            presentation = .failure(message: Self.failureMessage)
        }
    }

    private func publish(_ profile: SyncNodeBootstrapProfile) {
        updateIdentity(ProfileIdentity(profile))
        presentation = .imported(
            origin: profile.canonicalOrigin.url.absoluteString,
            nodeFingerprint: profile.signingKeyDigest.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        )
    }

    private func updateIdentity(_ replacement: ProfileIdentity?) {
        guard currentIdentity != replacement else { return }
        currentIdentity = replacement
        profileGeneration &+= 1
    }

    private struct ProfileIdentity: Equatable {
        let canonicalOrigin: String
        let nodeDeviceID: String
        let signingKeyDigest: Data
        let capabilityID: Data

        init(_ profile: SyncNodeBootstrapProfile) {
            canonicalOrigin = profile.canonicalOrigin.url.absoluteString
            nodeDeviceID = profile.nodeDeviceID.rawValue
            signingKeyDigest = profile.signingKeyDigest
            capabilityID = profile.capabilityID
        }
    }
}

public struct SyncNodeBootstrapImportView: View {
    @ObservedObject private var model: SyncNodeBootstrapImportViewModel
    private let completeFileImport: ((Result<[URL], Error>) -> Void)?

    /// `completeFileImport` lets an owner route the picked file through its
    /// own profile-change handling; by default the model imports it directly.
    public init(
        model: SyncNodeBootstrapImportViewModel,
        completeFileImport: ((Result<[URL], Error>) -> Void)? = nil
    ) {
        self.model = model
        self.completeFileImport = completeFileImport
    }

    public var body: some View {
        VStack(spacing: 10) {
            switch model.presentation {
            case .empty:
                Button("Import Server Setup", systemImage: "externaldrive.badge.plus") {
                    model.presentFileImporter()
                }
                Text("Import the protected setup file for your Sync Node.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .imported(let origin, let nodeFingerprint):
                Label("Server setup imported", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text(origin)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("Node \(nodeFingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("Replace Server Setup") { model.presentFileImporter() }
#if os(macOS)
                    .buttonStyle(.link)
#endif
            case .failure(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") { model.presentFileImporter() }
            }
        }
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.plainpostServerSetup],
            allowsMultipleSelection: false,
            onCompletion: completeFileImport ?? model.handleFileImporter
        )
    }
}

/// Step 1 of Sync Node setup on the Settings page: import the Server Setup file, then show the
/// server it names with Verify Fingerprint and Use a Different File. The sign-in screen keeps
/// `SyncNodeBootstrapImportView`.
struct SyncNodeServerSetupStep: View {
    /// The server an enrollment model would connect to.
    struct Target: Equatable {
        var origin: String
        var fingerprint: String
    }

    @ObservedObject var model: SyncNodeBootstrapImportViewModel
    /// Once an enrollment model exists, its target is the server Connect uses, so it stays
    /// shown even when a later import fails; the failure is its own row.
    var target: Target?
    let completeFileImport: ((Result<[URL], Error>) -> Void)?
    @State private var showsFingerprint = false

    var body: some View {
        Section("1. Import Server Setup") {
            if let server {
                let origin = server.origin
                LabeledContent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Imported")
                } label: {
                    Text(AccountSecurityPresentation.host(origin) ?? origin)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("sync-node.settings.imported-server")
                Button("Verify Fingerprint…") { showsFingerprint = true }
                    .accessibilityIdentifier("sync-node-verify-fingerprint")
                    .sheet(isPresented: $showsFingerprint) {
                        SyncNodeFingerprintSheet(fingerprint: server.fingerprint)
                    }
            }
            if case .failure(let message) = model.presentation {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sync-node.settings.import-failure")
            }
            if server == nil {
                importButton("Import Server Setup…", identifier: "sync-node.settings.import-server-setup")
            } else {
                importButton("Use a Different File…", identifier: "sync-node.settings.use-different-file")
            }
        }
    }

    /// The enrollment's target, else the imported file's server.
    private var server: Target? {
        if let target { return target }
        if case .imported(let origin, let nodeFingerprint) = model.presentation {
            return Target(origin: origin, fingerprint: nodeFingerprint)
        }
        return nil
    }

    /// One importer per row; only one of these rows shows at a time.
    private func importButton(_ title: String, identifier: String) -> some View {
        Button(title) { model.presentFileImporter() }
            .accessibilityIdentifier(identifier)
            .fileImporter(
                isPresented: $model.isFileImporterPresented,
                allowedContentTypes: [.plainpostServerSetup],
                allowsMultipleSelection: false,
                onCompletion: completeFileImport ?? model.handleFileImporter
            )
    }
}
