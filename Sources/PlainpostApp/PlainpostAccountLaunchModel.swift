import Foundation
import PlainpostAccountRuntime
import PlainpostUI

@MainActor
final class PlainpostAccountLaunchModel: ObservableObject {
    typealias AccountFactory = @MainActor (CentralServerConfiguration) throws -> AccountSessionViewModel
    typealias AccountShutdown = @MainActor (AccountSessionViewModel) async -> Void

    @Published private(set) var accountModel: AccountSessionViewModel?
    @Published private(set) var repair: CentralServerRepair?
    @Published private(set) var showsSetup = false
    @Published private(set) var isChangingServer = false
    @Published private(set) var selectedServer: CentralServerConfiguration?
    @Published private(set) var canChangeServer = false
    var canCancelServerChange: Bool { expectedPristineSelection != nil }

    private let resolver: CentralServerConfigurationResolver
    private let store: any CentralServerConfigurationStoring
    private let credentials: any AccountCredentialStoring
    private let bundledDocument: Data?
    private let makeAccountModel: AccountFactory
    private let shutdownAccountModel: AccountShutdown
    private var expectedPristineSelection: Data?

    init(
        resolver: CentralServerConfigurationResolver,
        store: any CentralServerConfigurationStoring,
        credentials: any AccountCredentialStoring,
        bundledDocument: Data? = CentralServerConfiguration.bundledDocument,
        makeAccountModel: @escaping AccountFactory,
        shutdownAccountModel: @escaping AccountShutdown = { model in await model.shutdownForServerChange() }
    ) {
        self.resolver = resolver
        self.store = store
        self.credentials = credentials
        self.bundledDocument = bundledDocument
        self.makeAccountModel = makeAccountModel
        self.shutdownAccountModel = shutdownAccountModel
        apply(resolver.resolve(bundledDocument: bundledDocument, credentials: credentials))
    }

    func save(originText: String) async {
        guard !isChangingServer else { return }
        let resolution: CentralServerResolution
        if let expectedPristineSelection,
           let configuration = try? CentralServerConfiguration(originText: originText) {
            resolution = resolver.replacePristineOrigin(
                configuration,
                expectedSelection: expectedPristineSelection,
                bundledDocument: bundledDocument,
                credentials: credentials
            )
        } else {
            resolution = resolver.saveManualOrigin(
                originText,
                bundledDocument: bundledDocument,
                credentials: credentials
            )
        }
        apply(resolution)
    }

    func changeServer() async {
        guard !isChangingServer, canChangeServer, let accountModel else { return }
        let expected: Data?
        do { expected = try store.loadSelection() }
        catch {
            repair = CentralServerRepair(reason: .storageUnavailable)
            return
        }
        self.accountModel = nil
        selectedServer = nil
        showsSetup = false
        isChangingServer = true
        canChangeServer = false
        await shutdownAccountModel(accountModel)
        isChangingServer = false
        expectedPristineSelection = expected
        repair = nil
        showsSetup = true
    }

    func cancelChangeServer() {
        guard !isChangingServer, expectedPristineSelection != nil else { return }
        expectedPristineSelection = nil
        apply(resolver.resolve(bundledDocument: bundledDocument, credentials: credentials))
    }

    private func apply(_ resolution: CentralServerResolution) {
        isChangingServer = false
        switch resolution {
        case .configured(let server):
            if selectedServer == server, accountModel != nil {
                showsSetup = false
                repair = nil
                return
            }
            do {
                accountModel = try makeAccountModel(server)
                selectedServer = server
                canChangeServer = resolver.canReplacePristineOrigin(credentials: credentials)
                expectedPristineSelection = nil
                showsSetup = false
                repair = nil
            } catch {
                accountModel = nil
                selectedServer = nil
                canChangeServer = false
                showsSetup = false
                repair = CentralServerRepair(reason: .storageUnavailable)
            }
        case .setupRequired:
            accountModel = nil
            selectedServer = nil
            canChangeServer = false
            showsSetup = true
            repair = nil
        case .repairRequired(let repair):
            accountModel = nil
            selectedServer = nil
            canChangeServer = false
            showsSetup = true
            self.repair = repair
        }
    }
}
