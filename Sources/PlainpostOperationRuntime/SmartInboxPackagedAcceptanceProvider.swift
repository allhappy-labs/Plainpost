#if DEBUG
import Darwin
import PlainpostAI
import PlainpostCore
import PlainpostOperations
import Foundation

package enum SmartInboxPackagedAcceptanceGateError: Error, Equatable {
    case invalidEnvironment
    case invalidMarker
    case unableToCreateGate
    case releaseTimedOut
}

package struct SmartInboxPackagedAcceptanceGateConfiguration: Equatable, Sendable {
    private static let servicePrefix = "com.marynavdovenko.Plainpost.Acceptance."
    private static let enableKey = "PLAINPOST_SMART_INBOX_ACCEPTANCE_GATE"

    package let rootURL: URL
    package let databaseURL: URL
    package let keychainService: String
    package let gateDirectoryURL: URL
    fileprivate let gateDevice: dev_t
    fileprivate let gateInode: ino_t

    package static func resolve(
        environment: [String: String]
    ) throws -> SmartInboxPackagedAcceptanceGateConfiguration? {
        guard environment["PLAINPOST_ACCEPTANCE_MODE"] == "smart-inbox"
                || environment[enableKey] != nil else {
            return nil
        }
        guard environment[enableKey] == "1",
              environment["PLAINPOST_ACCEPTANCE_MODE"] == "smart-inbox",
              let rawRoot = environment["PLAINPOST_ACCEPTANCE_ROOT"],
              let rawDatabase = environment["PLAINPOST_ACCEPTANCE_DATABASE_PATH"],
              let rawDataDirectory = environment["PLAINPOST_DATA_DIR"],
              let acceptanceService = environment["PLAINPOST_ACCEPTANCE_KEYCHAIN_SERVICE"],
              let inheritedService = environment["PLAINPOST_KEYCHAIN_SERVICE"],
              acceptanceService == inheritedService,
              acceptanceService.hasPrefix(servicePrefix),
              acceptanceService.count > servicePrefix.count else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }

        let requestedRoot = URL(fileURLWithPath: rawRoot)
        guard !isSymbolicLink(requestedRoot) else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }
        let rootURL = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard rootURL.lastPathComponent.hasPrefix("plainpost-acceptance."),
              approvedTemporaryRoots.contains(rootURL.deletingLastPathComponent()) else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: rootURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: geteuid()),
              attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o700) else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }

        let requestedDatabaseURL = URL(fileURLWithPath: rawDatabase)
        let requestedDataDirectoryURL = URL(fileURLWithPath: rawDataDirectory)
        guard requestedDatabaseURL
                == requestedRoot.appendingPathComponent("Plainpost.sqlite"),
              requestedDataDirectoryURL == requestedRoot else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }
        let databaseURL = rootURL.appendingPathComponent("Plainpost.sqlite").standardizedFileURL
        if FileManager.default.fileExists(atPath: requestedDatabaseURL.path) {
            guard !isSymbolicLink(requestedDatabaseURL),
                  requestedDatabaseURL.resolvingSymlinksInPath().standardizedFileURL
                    == databaseURL else {
                throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
            }
        }

        let gateDirectoryURL = rootURL.appendingPathComponent(
            "SmartInboxAcceptanceGate",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: gateDirectoryURL.path) {
            guard !isSymbolicLink(gateDirectoryURL) else {
                throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
            }
            let gateAttributes = try FileManager.default.attributesOfItem(atPath: gateDirectoryURL.path)
            guard gateAttributes[.type] as? FileAttributeType == .typeDirectory,
                  gateAttributes[.ownerAccountID] as? NSNumber == NSNumber(value: geteuid()),
                  gateAttributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o700) else {
                throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: gateDirectoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw SmartInboxPackagedAcceptanceGateError.unableToCreateGate
            }
        }
        var gateInformation = stat()
        guard lstat(gateDirectoryURL.path, &gateInformation) == 0,
              (gateInformation.st_mode & S_IFMT) == S_IFDIR,
              gateInformation.st_uid == geteuid(),
              (gateInformation.st_mode & 0o7777) == 0o700 else {
            throw SmartInboxPackagedAcceptanceGateError.invalidEnvironment
        }
        return Self(
            rootURL: rootURL,
            databaseURL: databaseURL,
            keychainService: acceptanceService,
            gateDirectoryURL: gateDirectoryURL,
            gateDevice: gateInformation.st_dev,
            gateInode: gateInformation.st_ino
        )
    }

    private static var approvedTemporaryRoots: Set<URL> {
        [
            URL(fileURLWithPath: "/private/tmp"),
            URL(fileURLWithPath: "/private/var/tmp"),
            FileManager.default.temporaryDirectory,
        ].reduce(into: Set<URL>()) {
            $0.insert($1.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }
}

package enum SmartInboxPackagedAcceptanceProviderResolver {
    package static func fallbackSelection(
        input: PlainpostAIOperationInput,
        environment: [String: String]
    ) -> LocalAIProviderSelection {
        let chatModelID = input.operation == .recategorizeInbox
            ? input.resolvedSmartInboxClassifierIdentity.modelID
            : environment["PLAINPOST_OLLAMA_CHAT_MODEL"] ?? "qwen3:8b"
        return LocalAIProviderSelection(
            providerID: input.providerID,
            ollamaBaseURL: environment["PLAINPOST_OLLAMA_URL"].flatMap(URL.init(string:)),
            ollamaChatModelID: chatModelID,
            ollamaEmbeddingModelID:
                environment["PLAINPOST_OLLAMA_EMBEDDING_MODEL"] ?? "mxbai-embed-large"
        )
    }
}

package struct SmartInboxPackagedAcceptanceProvider: AIProvider {
    package let id = "deterministic"
    package let displayName = "Deterministic Local"
    package let capabilities = DeterministicAIProvider().capabilities

    private let deterministic = DeterministicAIProvider()
    private let gate: SmartInboxPackagedAcceptanceInvocationGate

    package init(configuration: SmartInboxPackagedAcceptanceGateConfiguration) {
        gate = SmartInboxPackagedAcceptanceInvocationGate(configuration: configuration)
    }

    package func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        try await deterministic.generate(request)
    }

    package func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        try await deterministic.embed(request)
    }

    package func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        try await deterministic.classify(request)
    }

    package func classifyBatch(
        _ request: AIClassificationBatchRequest
    ) async throws -> AIClassificationBatchResponse {
        let invocation = try await gate.begin(messageIDs: request.messages.map(\.id.rawValue))
        let response = try await deterministic.classifyBatch(request)
        try await gate.finish(invocation: invocation)
        return response
    }
}

private actor SmartInboxPackagedAcceptanceInvocationGate {
    private let configuration: SmartInboxPackagedAcceptanceGateConfiguration

    init(configuration: SmartInboxPackagedAcceptanceGateConfiguration) {
        self.configuration = configuration
    }

    func begin(messageIDs: [String]) async throws -> Int {
        let invocation = try withGateDirectoryDescriptor { directoryDescriptor in
            let invocation = try nextInvocation(directoryDescriptor: directoryDescriptor)
            let stem = String(format: "invocation-%04d", invocation)
            try createMarker(
                named: "\(stem).started",
                data: Data((messageIDs.joined(separator: "\n") + "\n").utf8),
                directoryDescriptor: directoryDescriptor
            )
            return invocation
        }
        let releaseName = String(format: "invocation-%04d.release", invocation)
        for _ in 0..<2_400 {
            try Task.checkCancellation()
            if try withGateDirectoryDescriptor({ directoryDescriptor in
                try validatedMarkerExists(
                    named: releaseName,
                    directoryDescriptor: directoryDescriptor
                )
            }) {
                return invocation
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SmartInboxPackagedAcceptanceGateError.releaseTimedOut
    }

    func finish(invocation: Int) throws {
        let stem = String(format: "invocation-%04d", invocation)
        try withGateDirectoryDescriptor { directoryDescriptor in
            try createMarker(
                named: "\(stem).finished",
                data: Data(),
                directoryDescriptor: directoryDescriptor
            )
        }
    }

    private func nextInvocation(directoryDescriptor: Int32) throws -> Int {
        for invocation in 1...9_999 {
            let name = String(format: "invocation-%04d.started", invocation)
            if try !validatedMarkerExists(
                named: name,
                directoryDescriptor: directoryDescriptor
            ) {
                return invocation
            }
        }
        throw SmartInboxPackagedAcceptanceGateError.invalidMarker
    }

    private func withGateDirectoryDescriptor<T>(
        _ operation: (Int32) throws -> T
    ) throws -> T {
        let descriptor = open(
            configuration.gateDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              (information.st_mode & 0o7777) == 0o700,
              information.st_dev == configuration.gateDevice,
              information.st_ino == configuration.gateInode else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        return try operation(descriptor)
    }

    private func validatedMarkerExists(
        named name: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var pathInformation = stat()
        guard fstatat(
            directoryDescriptor,
            name,
            &pathInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return false }
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        guard isValidMarker(pathInformation) else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }

        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        defer { close(descriptor) }
        var descriptorInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              isValidMarker(descriptorInformation),
              descriptorInformation.st_dev == pathInformation.st_dev,
              descriptorInformation.st_ino == pathInformation.st_ino else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        return true
    }

    private func createMarker(
        named name: String,
        data: Data,
        directoryDescriptor: Int32
    ) throws {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw errno == EEXIST
                ? SmartInboxPackagedAcceptanceGateError.invalidMarker
                : SmartInboxPackagedAcceptanceGateError.unableToCreateGate
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SmartInboxPackagedAcceptanceGateError.unableToCreateGate
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              isValidMarker(information) else {
            throw SmartInboxPackagedAcceptanceGateError.invalidMarker
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw SmartInboxPackagedAcceptanceGateError.unableToCreateGate
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SmartInboxPackagedAcceptanceGateError.unableToCreateGate
        }
    }

    private func isValidMarker(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFREG
            && information.st_uid == geteuid()
            && (information.st_mode & 0o7777) == 0o600
    }
}
#endif
