import PlainpostAccountRuntime
import SwiftUI

@MainActor
public final class CentralServerSetupViewModel: ObservableObject {
    public typealias Save = @MainActor (String) async -> CentralServerResolution

    @Published public var originText: String
    @Published public private(set) var isBusy = false
    @Published public private(set) var errorMessage: String?
    private let save: Save

    public init(originText: String = "", save: @escaping Save) {
        self.originText = originText
        self.save = save
    }

    public func continueSetup() async {
        guard !isBusy else { return }
        let configuration: CentralServerConfiguration
        do { configuration = try CentralServerConfiguration(originText: originText) }
        catch let error as CentralServerConfiguration.ValidationError {
            errorMessage = Self.message(for: error)
            return
        } catch {
            errorMessage = "Enter a valid Central server address."
            return
        }
        originText = configuration.origin.absoluteString
        isBusy = true
        defer { isBusy = false }
        switch await save(originText) {
        case .configured:
            errorMessage = nil
        case .setupRequired:
            errorMessage = "The server configuration was not saved. Try again."
        case .repairRequired(let repair):
            errorMessage = Self.message(for: repair)
        }
    }

    public func apply(repair: CentralServerRepair?) {
        guard let boundOrigin = repair?.boundOrigin else { return }
        originText = boundOrigin.absoluteString
    }

    public static func message(for error: CentralServerConfiguration.ValidationError) -> String {
        switch error {
        case .httpsRequired: "Use an HTTPS server address."
        case .hostRequired: "Enter a server address with a host name."
        case .rootOriginRequired: "Enter the server root address without a path."
        case .forbiddenURLComponents: "Remove credentials, query text, or fragments from the address."
        case .malformedConfiguration: "Enter a valid Central server address."
        }
    }

    public static func message(for repair: CentralServerRepair) -> String {
        switch repair.reason {
        case .invalidManualInput(let error): message(for: error)
        case .originMismatch: "This account is bound to a different Central server."
        case .legacyAccountRequiresKnownOrigin: "Existing account data can only be restored with the original Plainpost server."
        case .invalidSelection, .invalidBundledConfiguration: "The saved server configuration is invalid. Enter the correct server address."
        case .accountStateUnavailable: "Plainpost could not safely read the existing account state."
        case .storageUnavailable: "Plainpost could not securely save the server configuration."
        case .concurrentChange: "The server configuration changed. Review the current address and try again."
        }
    }
}

public struct CentralServerSetupView: View {
    @ObservedObject private var model: CentralServerSetupViewModel
    private let repair: CentralServerRepair?
    private let cancel: (() -> Void)?

    public init(
        model: CentralServerSetupViewModel,
        repair: CentralServerRepair? = nil,
        cancel: (() -> Void)? = nil
    ) {
        self.model = model
        self.repair = repair
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "network")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(repair == nil ? "Connect to Plainpost" : "Repair Central server")
                .font(.title.bold())
            Text("Enter the HTTPS address of your Plainpost Central server. You’ll sign in with Apple after this connection is saved.")
                .foregroundStyle(.secondary)
            TextField("https://central.example.com", text: $model.originText)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .accessibilityIdentifier("central-server.origin")
            if let repair {
                Text(CentralServerSetupViewModel.message(for: repair))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("central-server.repair")
                if let boundOrigin = repair.boundOrigin {
                    Text("Required server: \(boundOrigin.absoluteString)")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("central-server.required-origin")
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("central-server.error")
            }
            HStack {
                if let cancel {
                    Button("Back", action: cancel)
                        .accessibilityIdentifier("central-server.back")
                }
                Spacer()
                Button("Continue") { Task { await model.continueSetup() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("central-server.continue")
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .onAppear { model.apply(repair: repair) }
        .onChange(of: repair) { _, repair in model.apply(repair: repair) }
    }
}
