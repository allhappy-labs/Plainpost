import Darwin
import Foundation
import PlainpostCLI
import PlainpostServiceIPC

@main
struct PlainpostCLIExecutable {
    static func main() async {
        let cli = PlainpostCLI(
            serviceClient: PlainpostServiceClient(capability: .cli),
            stdout: {
                FileHandle.standardOutput.write(Data($0.utf8))
            },
            stderr: {
                FileHandle.standardError.write(Data($0.utf8))
            }
        )
        do {
            let status = try await cli.run(
                Array(CommandLine.arguments.dropFirst())
            )
            exit(Int32(status))
        } catch {
            FileHandle.standardError.write(
                Data("Plainpost CLI failed.\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
