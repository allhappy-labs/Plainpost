import Darwin
import Foundation
import PlainpostServiceIPC

@main
struct PlainpostBackgroundAgentExecutable {
    static func main() async {
        do {
            _ = try await PlainpostServiceClient(
                capability: .agent
            ).processBackgroundJobs()
            exit(EXIT_SUCCESS)
        } catch PlainpostServiceClientError.vaultLocked {
            // Background work is intentionally quiet while the vault is
            // locked. A foreground app/CLI unlock will make a later wake useful.
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("Plainpost background agent could not reach PlainpostService.\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
