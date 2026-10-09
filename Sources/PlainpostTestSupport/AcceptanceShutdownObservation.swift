#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum AcceptanceEndpointObservation: Equatable, Sendable {
    case present
    case absent
    case unknown
}

public enum AcceptanceProcessObservation {
    public static func classifyExistenceProbe(result: Int32, error: Int32) -> AcceptanceEndpointObservation {
        if result == 0 {
            return .present
        }
        return error == ESRCH ? .absent : .unknown
    }
}

#if canImport(Darwin)
public struct AcceptanceProcessStartIdentity: Equatable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct AcceptanceProcessSnapshotIdentity: Equatable, Sendable {
    public let userID: uid_t
    public let startIdentity: AcceptanceProcessStartIdentity
    public let status: UInt32

    public init(
        userID: uid_t,
        startIdentity: AcceptanceProcessStartIdentity,
        status: UInt32
    ) {
        self.userID = userID
        self.startIdentity = startIdentity
        self.status = status
    }
}

public enum AcceptanceProcessIdentityCapture: Equatable, Sendable {
    case present(AcceptanceProcessStartIdentity)
    case absent
    case unknown
}

public enum AcceptanceListenerFailureCategory: Equatable, Sendable {
    case none
    case timeout
    case cancelled
    case posix(POSIXErrorCode)
    case dns
    case tls
    case other

    fileprivate var sanitizedLabel: String {
        switch self {
        case .none:
            return "none"
        case .timeout:
            return "timeout"
        case .cancelled:
            return "cancelled"
        case .posix(let code):
            return "posix.\(Self.posixName(code))"
        case .dns:
            return "dns"
        case .tls:
            return "tls"
        case .other:
            return "other"
        }
    }

    private static func posixName(_ code: POSIXErrorCode) -> String {
        switch code {
        case .EADDRNOTAVAIL:
            return "EADDRNOTAVAIL"
        case .EADDRINUSE:
            return "EADDRINUSE"
        case .ECONNABORTED:
            return "ECONNABORTED"
        case .ECONNREFUSED:
            return "ECONNREFUSED"
        case .ECONNRESET:
            return "ECONNRESET"
        case .EHOSTUNREACH:
            return "EHOSTUNREACH"
        case .ENETUNREACH:
            return "ENETUNREACH"
        case .ENOTCONN:
            return "ENOTCONN"
        case .EPIPE:
            return "EPIPE"
        case .ETIMEDOUT:
            return "ETIMEDOUT"
        default:
            return "unknown"
        }
    }
}

public struct AcceptanceListenerBindProbeResult: Equatable, Sendable {
    public let observation: AcceptanceEndpointObservation
    public let failure: AcceptanceListenerFailureCategory

    public init(
        observation: AcceptanceEndpointObservation,
        failure: AcceptanceListenerFailureCategory
    ) {
        self.observation = observation
        self.failure = failure
    }
}

public struct AcceptanceListenerBindProbe: Sendable {
    private let numericIPv4Host: String
    private let port: UInt16

    public init(numericIPv4Host: String, port: UInt16) {
        self.numericIPv4Host = numericIPv4Host
        self.port = port
    }

    public func observe() -> AcceptanceListenerBindProbeResult {
        guard port > 0 else {
            return .init(observation: .unknown, failure: .other)
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .init(observation: .unknown, failure: Self.failure(errno))
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, numericIPv4Host, &address.sin_addr) == 1 else {
            return .init(observation: .unknown, failure: .other)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        return Self.classify(bindResult: bindResult, error: errno)
    }

    public static func classify(
        bindResult: Int32,
        error: Int32
    ) -> AcceptanceListenerBindProbeResult {
        if bindResult == 0 {
            return .init(observation: .absent, failure: .none)
        }
        let failure = failure(error)
        if error == EADDRINUSE {
            return .init(observation: .present, failure: failure)
        }
        return .init(observation: .unknown, failure: failure)
    }

    private static func failure(_ code: Int32) -> AcceptanceListenerFailureCategory {
        POSIXErrorCode(rawValue: code).map(AcceptanceListenerFailureCategory.posix)
            ?? .other
    }
}

public enum AcceptanceShutdownDiagnosticPhase: String, Equatable, Sendable {
    case transition
    case timeout
}

public struct AcceptanceShutdownDiagnosticSnapshot: Equatable, Sendable {
    public let cleanupSucceeded: Bool
    public let process: AcceptanceEndpointObservation
    public let listener: AcceptanceEndpointObservation
    public let listenerFailure: AcceptanceListenerFailureCategory

    public init(
        cleanupSucceeded: Bool,
        process: AcceptanceEndpointObservation,
        listener: AcceptanceEndpointObservation,
        listenerFailure: AcceptanceListenerFailureCategory
    ) {
        self.cleanupSucceeded = cleanupSucceeded
        self.process = process
        self.listener = listener
        self.listenerFailure = listenerFailure
    }

    public func sanitizedLine(
        phase: AcceptanceShutdownDiagnosticPhase,
        elapsedMilliseconds: UInt64? = nil
    ) -> String {
        let elapsedField = elapsedMilliseconds.map { " elapsedMilliseconds=\($0)" } ?? ""
        return "Plainpost acceptance control: \(phase.rawValue)\(elapsedField) " +
            "cleanupSucceeded=\(cleanupSucceeded) " +
            "process=\(Self.label(process)) listener=\(Self.label(listener)) " +
            "listenerFailure=\(listenerFailure.sanitizedLabel)"
    }

    private static func label(_ observation: AcceptanceEndpointObservation) -> String {
        switch observation {
        case .present:
            return "present"
        case .absent:
            return "absent"
        case .unknown:
            return "unknown"
        }
    }
}

public struct AcceptanceProcessIdentityInspector: Sendable {
    private enum InspectionError: Error {
        case unavailable
    }

    private let processID: pid_t
    private let expectedExecutableURL: URL
    private let expectedUserID: uid_t
    private let expectedStartIdentity: AcceptanceProcessStartIdentity?

    public init(
        processID: pid_t,
        expectedExecutableURL: URL,
        expectedUserID: uid_t,
        expectedStartIdentity: AcceptanceProcessStartIdentity? = nil
    ) {
        self.processID = processID
        self.expectedExecutableURL = expectedExecutableURL
        self.expectedUserID = expectedUserID
        self.expectedStartIdentity = expectedStartIdentity
    }

    public func observe() -> AcceptanceEndpointObservation {
        let existence = existenceObservation()
        guard existence == .present else { return existence }
        guard let information = try? processInformation() else { return .unknown }
        let beforePathValidation = Self.snapshotIdentity(from: information)
        let preliminary = Self.classifySnapshot(
            expectedUserID: expectedUserID,
            expectedStartIdentity: expectedStartIdentity,
            observedUserID: beforePathValidation.userID,
            observedStartIdentity: beforePathValidation.startIdentity,
            observedStatus: beforePathValidation.status,
            executableMatches: nil
        )
        if preliminary != .unknown || information.pbi_status == UInt32(SZOMB) {
            return preliminary
        }
        guard let executableMatches = try? validateExecutableIdentity() else { return .unknown }
        guard let afterInformation = try? processInformation() else { return .unknown }
        return Self.classifyStableSnapshot(
            expectedUserID: expectedUserID,
            expectedStartIdentity: expectedStartIdentity,
            beforePathValidation: beforePathValidation,
            afterPathValidation: Self.snapshotIdentity(from: afterInformation),
            executableMatches: executableMatches
        )
    }

    public func captureIdentity() -> AcceptanceProcessIdentityCapture {
        let existence = existenceObservation()
        guard existence == .present else {
            return existence == .absent ? .absent : .unknown
        }
        guard let information = try? processInformation() else { return .unknown }
        guard information.pbi_uid == expectedUserID else { return .absent }
        guard information.pbi_status != UInt32(SZOMB) else { return .unknown }
        guard let executableMatches = try? validateExecutableIdentity() else { return .unknown }
        guard let afterInformation = try? processInformation() else { return .unknown }
        let beforePathValidation = Self.snapshotIdentity(from: information)
        let observation = Self.classifyStableSnapshot(
            expectedUserID: expectedUserID,
            expectedStartIdentity: nil,
            beforePathValidation: beforePathValidation,
            afterPathValidation: Self.snapshotIdentity(from: afterInformation),
            executableMatches: executableMatches
        )
        guard observation == .present else {
            return observation == .absent ? .absent : .unknown
        }
        return .present(beforePathValidation.startIdentity)
    }

    public static func observe(
        existenceProbe: () -> (result: Int32, error: Int32),
        identityValidation: () throws -> Bool
    ) -> AcceptanceEndpointObservation {
        let existence = existenceProbe()
        switch AcceptanceProcessObservation.classifyExistenceProbe(
            result: existence.result,
            error: existence.error
        ) {
        case .absent:
            return .absent
        case .unknown:
            return .unknown
        case .present:
            do {
                return try identityValidation() ? .present : .absent
            } catch {
                return .unknown
            }
        }
    }

    public static func classifySnapshot(
        expectedUserID: uid_t,
        expectedStartIdentity: AcceptanceProcessStartIdentity?,
        observedUserID: uid_t,
        observedStartIdentity: AcceptanceProcessStartIdentity,
        observedStatus: UInt32,
        executableMatches: Bool?
    ) -> AcceptanceEndpointObservation {
        guard observedUserID == expectedUserID else { return .absent }
        if let expectedStartIdentity {
            guard observedStartIdentity == expectedStartIdentity else { return .absent }
            if observedStatus == UInt32(SZOMB) { return .absent }
        } else if observedStatus == UInt32(SZOMB) {
            return .unknown
        }
        guard let executableMatches else { return .unknown }
        return executableMatches ? .present : .absent
    }

    public static func classifyStableSnapshot(
        expectedUserID: uid_t,
        expectedStartIdentity: AcceptanceProcessStartIdentity?,
        beforePathValidation: AcceptanceProcessSnapshotIdentity,
        afterPathValidation: AcceptanceProcessSnapshotIdentity,
        executableMatches: Bool
    ) -> AcceptanceEndpointObservation {
        if expectedStartIdentity == nil,
           beforePathValidation != afterPathValidation {
            return .unknown
        }
        let before = classifySnapshot(
            expectedUserID: expectedUserID,
            expectedStartIdentity: expectedStartIdentity,
            observedUserID: beforePathValidation.userID,
            observedStartIdentity: beforePathValidation.startIdentity,
            observedStatus: beforePathValidation.status,
            executableMatches: executableMatches
        )
        guard before == .present else { return before }
        return classifySnapshot(
            expectedUserID: expectedUserID,
            expectedStartIdentity: expectedStartIdentity,
            observedUserID: afterPathValidation.userID,
            observedStartIdentity: afterPathValidation.startIdentity,
            observedStatus: afterPathValidation.status,
            executableMatches: executableMatches
        )
    }

    private func existenceObservation() -> AcceptanceEndpointObservation {
        let result = Darwin.kill(processID, 0)
        return AcceptanceProcessObservation.classifyExistenceProbe(result: result, error: errno)
    }

    private func processInformation() throws -> proc_bsdinfo {
        var processInformation = proc_bsdinfo()
        let informationSize = MemoryLayout<proc_bsdinfo>.size
        let copied = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInformation,
            Int32(informationSize)
        )
        guard copied == informationSize else { throw InspectionError.unavailable }
        return processInformation
    }

    private func validateExecutableIdentity() throws -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0 else { throw InspectionError.unavailable }
        let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let processURL = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .resolvingSymlinksInPath().standardizedFileURL
        let expectedURL = expectedExecutableURL.resolvingSymlinksInPath().standardizedFileURL
        guard processURL == expectedURL else { return false }

        var executableInformation = stat()
        guard lstat(expectedURL.path, &executableInformation) == 0 else {
            throw InspectionError.unavailable
        }
        return (executableInformation.st_mode & S_IFMT) == S_IFREG
            && executableInformation.st_uid == expectedUserID
            && (executableInformation.st_mode & S_IXUSR) != 0
    }

    private static func startIdentity(
        from information: proc_bsdinfo
    ) -> AcceptanceProcessStartIdentity {
        AcceptanceProcessStartIdentity(
            seconds: information.pbi_start_tvsec,
            microseconds: information.pbi_start_tvusec
        )
    }

    private static func snapshotIdentity(
        from information: proc_bsdinfo
    ) -> AcceptanceProcessSnapshotIdentity {
        AcceptanceProcessSnapshotIdentity(
            userID: information.pbi_uid,
            startIdentity: startIdentity(from: information),
            status: information.pbi_status
        )
    }
}
#endif

public enum AcceptanceListenerObservation {
    public static func classifyConnectionRefused() -> AcceptanceEndpointObservation {
        .absent
    }

    public static func classifyTimeout() -> AcceptanceEndpointObservation {
        .unknown
    }
}

public enum PackagedMacShutdownReadiness {
    public static func isComplete(
        cleanupSucceeded: Bool,
        process: AcceptanceEndpointObservation,
        listener: AcceptanceEndpointObservation
    ) -> Bool {
        cleanupSucceeded && process == .absent && listener == .absent
    }
}
