import Darwin
import Foundation
import PlainpostNodeMailMode
import PlainpostServiceIPC
import PlainpostServiceRuntime

struct PlainpostServiceExecutable {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            print("PlainpostService 0.1.0")
            return
        }
        guard arguments == ["--xpc-service"] else {
            writeStandardError(
                "PlainpostService supports only --xpc-service and --version.\n"
            )
            exit(EX_USAGE)
        }

        do {
            let composition = try PlainpostServiceComposition.production(
                databaseURL: try serviceDatabaseURL()
            )
            let listener = NSXPCListener(
                machServiceName: PlainpostServiceClient.machServiceName
            )
            listener.delegate = composition.listener
            listener.resume()
            // Node mail mode (mirror, router session provider, reachability
            // supervisor) runs for the service's lifetime, app or no app.
            let nodeMailMirror = composition.nodeMailMirror
            let nodeReachability = composition.nodeReachability
            let mailIntentRouter = composition.mailIntentRouter
            Task {
                await PlainpostServiceComposition.startNodeMailMode(
                    router: mailIntentRouter, mirror: nodeMailMirror, reachability: nodeReachability
                )
            }
            let shutdownSignals = makeShutdownSignals(
                lifecycle: composition.lifecycle,
                nodeMailMirror: nodeMailMirror,
                nodeReachability: nodeReachability
            )
            withExtendedLifetime(
                (composition, listener, shutdownSignals)
            ) {
                dispatchMain()
            }
        } catch {
            writeStandardError("PlainpostService failed to start.\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func serviceDatabaseURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let directory: URL
        if let configuredPath = environment["PLAINPOST_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty
        {
            directory = URL(
                fileURLWithPath: configuredPath,
                isDirectory: true
            )
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw PlainpostServiceStartupError.applicationSupportUnavailable
            }
            directory = applicationSupport.appendingPathComponent(
                "Plainpost",
                isDirectory: true
            )
        }
        return directory.appendingPathComponent("Plainpost.sqlite")
    }

    private static func makeShutdownSignals(
        lifecycle: PlainpostServiceLifecycleCoordinator,
        nodeMailMirror: NodeMailMirrorLoop?,
        nodeReachability: NodeReachabilitySupervisor?
    ) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global()
            )
            source.setEventHandler {
                Task {
                    await PlainpostServiceComposition.stopNodeMailMode(
                        mirror: nodeMailMirror, reachability: nodeReachability
                    )
                    await lifecycle.shutdown()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
            return source
        }
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private enum PlainpostServiceStartupError: Error {
    case applicationSupportUnavailable
}

PlainpostServiceExecutable.main()
