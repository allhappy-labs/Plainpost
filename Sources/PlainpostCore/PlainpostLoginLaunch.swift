import Foundation

/// The login item is a bundled launchd agent that starts the app with an
/// explicit flag. The flag is the only launch-context signal the app trusts
/// to start hidden; `SMAppService.mainApp` gives none.
public enum PlainpostLoginLaunch {
    public static let plistName = "com.marynavdovenko.Plainpost.LoginApp.plist"
    public static let label = "com.marynavdovenko.Plainpost.LoginApp"
    public static let argument = "--launched-at-login"
    /// User preference, on by default.
    public static let preferenceKey = "Plainpost.openAtLogin"

    public enum StartupDecision: Equatable, Sendable {
        /// Continue launching.
        case run
        /// Another Plainpost is already running: exit without touching it.
        case yield
        /// The user turned the login item off while it could not be removed:
        /// remove it now (which ends this process) and exit.
        case retire
    }

    /// Exact match on a launch argument after the executable path.
    public static func isLoginLaunch(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    public static func openAtLogin(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// Registering the login item loads its `RunAtLoad` job at once, which
    /// starts a second copy of the app next to the one the user is using.
    /// Only a login launch can be that copy, so only a login launch yields.
    public static func startupDecision(
        arguments: [String],
        otherInstanceRunning: Bool,
        openAtLogin: Bool
    ) -> StartupDecision {
        guard isLoginLaunch(arguments: arguments) else { return .run }
        if otherInstanceRunning { return .yield }
        return openAtLogin ? .run : .retire
    }

    public static func bundledPlistURL(appBundleURL: URL) -> URL {
        appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
    }

    /// Identifies one install of the bundle: its path plus the size and
    /// modification time of the login plist, `Info.plist` and every main
    /// executable. A reinstall replaces those files, so the value changes.
    public static func bundleFingerprint(appBundleURL: URL) -> String? {
        let fileManager = FileManager.default
        let macOSDirectory = appBundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executables = ((try? fileManager.contentsOfDirectory(atPath: macOSDirectory.path)) ?? [])
            .sorted()
            .map { macOSDirectory.appendingPathComponent($0) }
        let files = [
            bundledPlistURL(appBundleURL: appBundleURL),
            appBundleURL.appendingPathComponent("Contents/Info.plist"),
        ] + executables
        var parts = [appBundleURL.standardizedFileURL.path]
        var foundLoginPlist = false
        for (index, file) in files.enumerated() {
            guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else {
                if index == 0 { return nil }
                continue
            }
            if index == 0 { foundLoginPlist = true }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            parts.append("\(file.lastPathComponent):\(size):\(modified)")
        }
        return foundLoginPlist ? parts.joined(separator: "|") : nil
    }
}

/// Keeps the bundled login item registered while the user wants Plainpost
/// to open at login. Production closures wrap `SMAppService.agent`.
public struct PlainpostLoginItemRegistrar: Sendable {
    public enum Status: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        /// Not a packaged app, or the bundle has no login item plist.
        case unavailable
        /// Turned off while this process is the login job's own process.
        /// Removing the job now would end the app, so it goes when the app
        /// next launches at login.
        case enabledUntilQuit
    }

    public typealias Register = @Sendable () async throws -> Void
    public typealias Unregister = @Sendable () async throws -> Void
    public typealias CurrentStatus = @Sendable () -> Status

    /// Which install the item was last registered from. SMAppService needs
    /// an agent registered again after its plist or executable changed, or
    /// it may not launch.
    public struct RegistrationStamp: Sendable {
        public var current: @Sendable () -> String?
        public var load: @Sendable () -> String?
        public var save: @Sendable (String?) -> Void

        public init(
            current: @escaping @Sendable () -> String?,
            load: @escaping @Sendable () -> String?,
            save: @escaping @Sendable (String?) -> Void
        ) {
            self.current = current
            self.load = load
            self.save = save
        }
    }

    private let appBundleURL: URL
    private let installedLocations: [URL]?
    private let currentProcessIsLoginItem: Bool
    private let registrationStamp: RegistrationStamp?
    private let register: Register
    private let unregister: Unregister
    private let status: CurrentStatus

    /// `installedLocations`: folders an installed copy lives directly in;
    /// a bundle anywhere else (a build output, an acceptance fixture) is
    /// never registered. `nil` accepts any location.
    public init(
        appBundleURL: URL,
        installedLocations: [URL]? = nil,
        currentProcessIsLoginItem: Bool = false,
        registrationStamp: RegistrationStamp? = nil,
        register: @escaping Register,
        unregister: @escaping Unregister,
        status: @escaping CurrentStatus
    ) {
        self.appBundleURL = appBundleURL
        self.installedLocations = installedLocations
        self.currentProcessIsLoginItem = currentProcessIsLoginItem
        self.registrationStamp = registrationStamp
        self.register = register
        self.unregister = unregister
        self.status = status
    }

    /// True for a packaged `.app` that carries a regular login item plist.
    /// SwiftPM and test runs never reach `SMAppService`.
    public static func defaultInstalledLocations(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    public var isPackaged: Bool {
        guard appBundleURL.pathExtension == "app" else { return false }
        if let installedLocations {
            let parent = appBundleURL.standardizedFileURL.resolvingSymlinksInPath()
                .deletingLastPathComponent().path
            guard installedLocations.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path == parent
            }) else { return false }
        }
        let plistURL = PlainpostLoginLaunch.bundledPlistURL(appBundleURL: appBundleURL)
        guard let values = try? plistURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    public func currentStatus() -> Status {
        isPackaged ? status() : .unavailable
    }

    /// Registers when `enabled` and the item is not registered yet, or was
    /// registered from a different install; unregisters when not `enabled`.
    /// Every registration launches the app once more (the copy yields), so
    /// an item registered from this install is left alone.
    public func reconcile(enabled: Bool) async -> Status {
        guard isPackaged else { return .unavailable }
        let current = status()
        if enabled {
            switch current {
            case .unavailable:
                return current
            case .enabledUntilQuit:
                return .enabled
            case .enabled, .requiresApproval:
                // A reinstall re-registers, including an item still waiting
                // for approval: the approval belongs to the old install.
                //
                // A login launch never refreshes its own job, even after a
                // reinstall: unregistering the job that started this
                // process kills it, and a register after that would start
                // a fresh copy. launchd started this process from the
                // current bundle, so the job works; the next manual launch
                // (not the job's process) refreshes it, because the stamp
                // is left pointing at the old install.
                guard !currentProcessIsLoginItem, let registrationStamp,
                      let install = registrationStamp.current(),
                      registrationStamp.load() != install
                else { return current }
                try? await unregister()
                return await registerRecordingInstall()
            case .disabled:
                return await registerRecordingInstall()
            }
        }
        switch current {
        case .disabled, .unavailable:
            return current
        case .enabled, .requiresApproval, .enabledUntilQuit:
            if currentProcessIsLoginItem { return .enabledUntilQuit }
            try? await unregister()
            let after = status()
            if after == .disabled { registrationStamp?.save(nil) }
            return after
        }
    }

    private func registerRecordingInstall() async -> Status {
        do {
            try await register()
        } catch {
            return status()
        }
        let after = status()
        if after == .enabled, let registrationStamp {
            registrationStamp.save(registrationStamp.current())
        }
        return after
    }
}

/// Which build of the service a process runs: its bundle path plus a stamp
/// of `CFBundleVersion` and the executable file (inode, size, modification
/// time). A service captures its own identity at launch, so after a
/// reinstall replaces the files it still reports the build it started from.
public struct PlainpostServiceBuildIdentity: Equatable, Sendable {
    public let bundlePath: String
    public let buildStamp: String

    public init(bundlePath: String, buildStamp: String) {
        self.bundlePath = bundlePath
        self.buildStamp = buildStamp
    }

    public static func of(bundleURL: URL) -> PlainpostServiceBuildIdentity? {
        guard bundleURL.pathExtension == "app" else { return nil }
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty
        else { return nil }
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/\(executable)")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path) else {
            return nil
        }
        let version = info["CFBundleVersion"] as? String ?? "-"
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
        return PlainpostServiceBuildIdentity(
            bundlePath: canonicalPath(bundleURL),
            buildStamp: "\(version)|\(inode):\(size):\(modified)"
        )
    }

    /// The service bundled inside an app bundle.
    public static func bundledService(appBundleURL: URL) -> PlainpostServiceBuildIdentity? {
        of(bundleURL: appBundleURL.appendingPathComponent(
            "Contents/Library/Helpers/PlainpostService.app", isDirectory: true
        ))
    }

    public static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Whether an installation's bundle is provably gone. `fileExists` is false
/// for privacy (TCC) denials, unreadable folders and network-mount errors,
/// which would make a valid installation look deleted; only a missing path
/// counts, and a path on `/Volumes/<name>` also needs that volume unmounted.
public enum PlainpostBundlePresence {
    /// `lstat` errno for a path, nil when it succeeds.
    public typealias StatError = (String) -> Int32?
    /// Whether a mount point is currently mounted.
    public typealias IsMounted = (String) -> Bool

    public static func isGone(
        path: String,
        statError: StatError = PlainpostBundlePresence.lstatError,
        isMounted: IsMounted = PlainpostBundlePresence.isMountPoint
    ) -> Bool {
        guard let error = statError(path) else { return false }
        guard error == ENOENT || error == ENOTDIR else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            return !isMounted("/Volumes/\(components[1])")
        }
        return true
    }

    public static func lstatError(_ path: String) -> Int32? {
        var info = stat()
        return lstat(path, &info) == 0 ? nil : errno
    }

    public static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == path
    }
}

/// Counts consecutive `.busy` identity answers so a hung service is
/// eventually restarted.
public final class PlainpostServiceBusyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var since: Date?

    public init() {}

    /// Records one answer; returns the busy streak including it.
    public func record(
        _ reported: PlainpostBundledServiceRefreshPolicy.Reported,
        now: Date = Date()
    ) -> (count: Int, duration: TimeInterval) {
        lock.withLock {
            guard reported == .busy else {
                count = 0
                since = nil
                return (0, 0)
            }
            count += 1
            let start = since ?? now
            since = start
            return (count, now.timeIntervalSince(start))
        }
    }

    public func reset() {
        lock.withLock {
            count = 0
            since = nil
        }
    }
}

/// Who runs the background service the app is talking to.
public enum PlainpostServiceOwnership: Equatable, Sendable {
    case unknown
    case own
    /// Another Plainpost installation's service answers on the shared Mach
    /// service name.
    case foreign(bundlePath: String)

    public static func evaluate(
        reported: PlainpostServiceBuildIdentity?,
        expected: PlainpostServiceBuildIdentity?
    ) -> PlainpostServiceOwnership {
        guard let reported, let expected else { return .unknown }
        guard reported.bundlePath == expected.bundlePath else {
            return .foreign(bundlePath: reported.bundlePath)
        }
        return .own
    }
}

/// Decides whether launching the app must reload the bundled service.
/// Bouncing it kills the running service (and its Node mirror), so it
/// happens only when the job is missing, unloaded or unreachable, or runs a
/// build other than the one in this bundle.
public enum PlainpostBundledServiceRefreshPolicy {
    public enum Reported: Equatable, Sendable {
        /// The Mach service did not answer: the job is missing or unloaded.
        case unreachable
        /// It answered without an identity (an older build, or an
        /// unbundled service).
        case unidentified
        /// It timed out twice: loaded but busy starting (for example a
        /// database migration at login). Bouncing it would restart that work.
        case busy
        case identity(PlainpostServiceBuildIdentity)
    }

    public enum Decision: Equatable, Sendable {
        case keepRunning
        case refresh
        /// Another installation's service holds the job; leave it alone.
        case foreign(bundlePath: String)
    }

    /// A service that stays busy this many checks in a row, or this long,
    /// is treated as hung and restarted.
    public static let busyCheckLimit = 3
    public static let busyDurationLimit: TimeInterval = 300

    public static func decide(
        isRegistered: Bool,
        reported: Reported,
        expected: PlainpostServiceBuildIdentity?,
        consecutiveBusyChecks: Int = 1,
        busyDuration: TimeInterval = 0,
        bundleIsGone: (String) -> Bool = { PlainpostBundlePresence.isGone(path: $0) }
    ) -> Decision {
        if case .identity(let identity) = reported,
           let expected,
           identity.bundlePath != expected.bundlePath {
            // Only a service whose installation is provably deleted is an
            // orphan this app may take over; an unreadable path stays foreign.
            return bundleIsGone(identity.bundlePath) ? .refresh : .foreign(bundlePath: identity.bundlePath)
        }
        if case .busy = reported, isRegistered {
            let hung = consecutiveBusyChecks >= busyCheckLimit || busyDuration >= busyDurationLimit
            return hung ? .refresh : .keepRunning
        }
        guard isRegistered, let expected else { return .refresh }
        guard case .identity(let identity) = reported else { return .refresh }
        return identity.buildStamp == expected.buildStamp ? .keepRunning : .refresh
    }
}

/// One Plainpost app process per user. A second hidden login launch that
/// slipped past the running-instance check exits instead of running a
/// second runtime; durable per-event leases already keep two processes from
/// posting the same notification.
public final class PlainpostInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    /// Returns nil when another process holds the lock.
    public static func acquire(at url: URL) -> PlainpostInstanceLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return PlainpostInstanceLock(descriptor: descriptor)
    }
}

/// Reloads a bundled `SMAppService` agent on launch so the running job is
/// the one in the current bundle.
public enum PlainpostBundledAgentRefresh {
    /// Packaging boots the old job out before it replaces the bundle, and
    /// `launchctl bootstrap` cannot load an `SMAppService` job again. The
    /// stale registration may then refuse to unregister; that must not skip
    /// the register call that loads the new job.
    public static func refresh(
        isEnabled: Bool,
        unregister: () async throws -> Void,
        register: () async throws -> Void
    ) async throws {
        if isEnabled {
            try? await unregister()
        }
        try await register()
    }
}
