import Combine
import Foundation
import ServiceManagement
import SwiftUI
import os.log

// The root helper parks the shared AirDrop/Continuity radio to avoid Wi-Fi delivery gaps.
// Restoration outlives cancelled registration requests; registration waits
// until the daemon acknowledges release even when interface work is blocked.

enum HelperConstants {
    /// The launchd plist filename in Contents/Library/LaunchDaemons/.
    static let daemonPlistName = "io.ugfugl.glimmer.helper.plist"
}

// MARK: - Single-resume continuation guard

/// An XPC call can complete via its reply OR via the connection's error handler.
/// The lock protects the continuation and allows exactly one resume.
private final class SingleResume<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock(); let pending = cont; cont = nil; lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

// MARK: - XPC client

/// Keeps interrupted connections alive so launchd can relaunch the idle daemon.
actor HelperClient {
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "AWDLHelper")
    private var connection: NSXPCConnection?
    /// Which connection a late invalidation or deadline belongs to. Not ObjectIdentifier:
    /// that is an address, and a freed connection's replacement can reuse it.
    private var generation = 0
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let makeProxy: @Sendable (NSXPCConnection, @escaping @Sendable (Error) -> Void) -> GlimmerHelperProtocol?

    init(
        makeConnection: @escaping @Sendable () -> NSXPCConnection = {
            NSXPCConnection(machServiceName: glimmerHelperMachServiceName, options: .privileged)
        },
        makeProxy: @escaping @Sendable (NSXPCConnection, @escaping @Sendable (Error) -> Void) -> GlimmerHelperProtocol? = {
            $0.remoteObjectProxyWithErrorHandler($1) as? GlimmerHelperProtocol
        }
    ) {
        self.makeConnection = makeConnection
        self.makeProxy = makeProxy
    }

    private func connect() -> (connection: NSXPCConnection, generation: Int) {
        if let existing = connection { return (existing, generation) }
        let conn = makeConnection()
        conn.remoteObjectInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        generation += 1
        let token = generation
        conn.invalidationHandler = { [weak self] in Task { await self?.drop(token) } }
        conn.resume()
        connection = conn
        return (conn, token)
    }

    /// Drops the connection only if it is still the one `token` was issued for.
    func drop(_ token: Int) {
        guard token == generation, let current = connection else { return }
        connection = nil
        current.invalidate()
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // A connected daemon can stop replying without invalidating XPC. Bound every
    // wait and drop that connection so missing replies cannot accumulate in XPC.
    private func reply<Value: Sendable>(
        fallback: Value,
        send: (NSXPCConnection, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        let (connection, token) = connect()
        return await withCheckedContinuation { continuation in
            let once = SingleResume(continuation)
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if once.resume(fallback) { drop(token) }
            }
            send(connection) { value in
                deadline.cancel()
                once.resume(value)
            }
        }
    }

    /// A missing reply is not proof that suppression failed; callers still owe release.
    func setAWDLDown(_ down: Bool, reason: String) async -> Bool {
        await reply(fallback: false) { connection, complete in
            let proxy = makeProxy(connection) { [weak self] err in
                self?.log.error("helper XPC error: \(err.localizedDescription, privacy: .private)")
                complete(false)
            }
            guard let proxy else { complete(false); return }
            proxy.setAWDLDown(down, reason: reason, reply: complete)
        }
    }

    /// (isDown, since) per the live daemon, or nil if it's unreachable.
    func currentStatus() async -> (Bool, Date?)? {
        await reply(fallback: nil) { connection, complete in
            let proxy = makeProxy(connection) { _ in complete(nil) }
            guard let proxy else { complete(nil); return }
            proxy.currentStatus { isDown, since in complete((isDown, since)) }
        }
    }

    /// The daemon's whack-a-mole count (macOS re-raises of awdl0 this stream), or
    /// nil if unreachable. Read on the suppress heartbeat for the contention gauge.
    func reSuppressCount() async -> UInt64? {
        await reply(fallback: nil) { connection, complete in
            let proxy = makeProxy(connection) { _ in complete(nil) }
            guard let proxy else { complete(nil); return }
            proxy.reSuppressCount { count in complete(count) }
        }
    }
}

// MARK: - Manager (app-facing, UI binds to this)

@MainActor
final class AWDLHelperManager: ObservableObject {
    static let shared = AWDLHelperManager()

    enum State: Equatable {
        case notRegistered          // helper has never been enabled
        case requiresApproval       // registered; user must toggle it on in System Settings
        case enabled                // installed + approved + ready
        case unavailable(String)    // SMAppService error / daemon not found in the bundle

        /// The case stays public; `.unavailable` can carry SMAppService error text.
        var diagDescription: DiagMessage {
            guard case .unavailable(let why) = self else { return "\(self)" }
            return "unavailable(\"\(why, privacy: .private)\")"
        }
    }

    @Published private(set) var state: State = .notRegistered
    /// True while awdl0 is actively parked (a stream is up).
    private(set) var suppressing = false

    struct Operations {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () async throws -> Void
        var setDown: (Bool, String) async -> Bool
        var invalidate: () async -> Void
        var reachable: () async -> Bool
        var count: () async -> UInt64?
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var telemetry: (Bool, UInt64) -> Void = {
            TelemetryCounters.shared.setAWDLHelper(.init(suppressing: $0, reSuppressTotal: $1))
        }
    }

    private let operations: Operations
    private let defaults: UserDefaults
    @Published private var enabledIntent: Bool
    @Published private var changingRegistration = false
    @Published private var restoring = false
    private var registrationTask: Task<Void, Never>?
    private var serviceTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var requestID = 0
    private var streamRequested = false
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "AWDLHelper")
    private static let promptSuppressedKey = "awdlHelperPromptSuppressed"
    /// Saved intent lets registration self-heal after an update without undoing an explicit off choice.
    private static let enabledIntentKey = "awdlHelperEnabled"

    // MARK: Diagnostics messaging

    /// Distinguish missing packaging from a stuck system record after a bundle swap:
    /// SMAppService can report .notFound even when the daemon is bundled.
    private static var daemonIsBundled: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(HelperConstants.daemonPlistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A wedged BTM record survives reboot; log resetbtm recovery for support,
    /// but direct users to Apple's Login Items guide instead of a root command.
    private static let wedgedRegistrationMessage =
        "macOS left a stuck background-item record (a known glitch after an app "
        + "update), so it won't register the helper. You can manage Glimmer's "
        + "background items in System Settings › General › Login Items & Extensions."

    /// Apple's official Login Items & Extensions guide - a credible reference for
    /// managing the stuck background item, shown instead of asking the user to run
    /// a raw `sudo` command.
    static let loginItemsHelpURL = URL(string:
        "https://support.apple.com/guide/mac-help/change-login-items-extensions-settings-mtusr003/mac")

    /// `.notFound` is ambiguous: a genuine packaging miss, or a wedged record while
    /// the daemon IS present. Tell them apart so the message isn't a red herring.
    private static var notFoundMessage: String {
        daemonIsBundled ? wedgedRegistrationMessage : "Helper not found in the app bundle."
    }

    private static func isWedgedRegistration(_ ns: NSError) -> Bool {
        ns.domain == "SMAppServiceErrorDomain" && ns.code == 1
    }

    private convenience init() {
        let client = HelperClient()
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        self.init(operations: Operations(
            status: { service.status }, register: { try service.register() },
            unregister: { try await service.unregister() },
            setDown: { await client.setAWDLDown($0, reason: $1) },
            invalidate: { await client.invalidate() },
            reachable: { await client.currentStatus() != nil },
            count: { await client.reSuppressCount() }), defaults: .standard)
    }

    init(operations: Operations, defaults: UserDefaults) {
        self.operations = operations
        self.defaults = defaults
        enabledIntent = defaults.object(forKey: Self.enabledIntentKey) as? Bool
            ?? (operations.status() == .enabled || operations.status() == .requiresApproval)
        refresh()
    }

    var isEnabled: Bool { enabledIntent && !changingRegistration && !restoring && state == .enabled }

    /// Registered with the system, whether or not the user has approved it yet
    /// in System Settings. Drives the toggle's on/off so flipping it on doesn't
    /// snap back while approval is pending.
    var isRegistered: Bool {
        guard enabledIntent else { return false }
        switch state {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .unavailable: return false
        }
    }

    /// Only the known wedged-registration message gets Apple's recovery guide.
    /// Match the same constant used to build state rather than guessing from prose.
    var recoveryDocURL: URL? {
        if case .unavailable(let why) = state, why == Self.wedgedRegistrationMessage {
            return Self.loginItemsHelpURL
        }
        return nil
    }

    /// User opted out of the launch-time enable nudge ("Don't ask again").
    var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.promptSuppressedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.promptSuppressedKey) }
    }

    /// Whether to show the launch nudge: only while not yet enabled and the user
    /// hasn't dismissed it for good.
    var shouldPromptToEnable: Bool { !promptSuppressed && state != .enabled }

    func refresh() {
        let status = operations.status()
        let newState: State
        switch status {
        case .enabled:          newState = .enabled
        case .requiresApproval: newState = .requiresApproval
        case .notRegistered:    newState = .notRegistered
        case .notFound:         newState = .unavailable(Self.notFoundMessage)
        @unknown default:       newState = .unavailable("Unknown status")
        }
        if newState != state { state = newState }
        log.notice("""
            AWDL daemon status raw=\(status.rawValue, privacy: .public) \
            state=\(self.state.diagDescription.systemLogText, privacy: .public)
            """)
    }

    /// Register the daemon. The first time, macOS surfaces a one-time approval in
    /// System Settings → General → Login Items & Extensions.
    func enable() {
        setIntent(true)
        let (previous, restoration, identifier) = prepareRegistration()
        // Capture predecessors before publishing this task: reading serviceTask inside
        // the task would let an immediate disable create a circular wait. Even cancelled
        // tasks wait for their predecessor so successors cannot bypass older teardown.
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await restoration?.value
            guard !Task.isCancelled else { return }
            // Bundle swaps can wedge BTM registration. Clear the old record and let
            // macOS settle before registering the replacement.
            try? await operations.unregister()
            do { try await operations.sleep(.milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            do {
                try operations.register()
                log.info("AWDL helper registered")
                refresh()
            } catch {
                let ns = error as NSError
                let detail = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
                // A wedged BTM record refuses both operations. Show Apple's guide;
                // keep the reliable resetbtm recovery in support logs, not the UI.
                if Self.isWedgedRegistration(ns) {
                    log.error("""
                        AWDL helper register failed: \(ns.localizedDescription, privacy: .private) \
                        [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)] - wedged Background Task \
                        Management record; reliable clear is 'sudo sfltool resetbtm' + restart
                        """)
                    state = .unavailable(Self.wedgedRegistrationMessage)
                } else {
                    log.error("""
                        AWDL helper register failed: \(ns.localizedDescription, privacy: .private) \
                        [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]
                        """)
                    state = .unavailable(detail)
                }
            }
            finishRegistration(identifier)
        }
        registrationTask = task
        serviceTask = task
    }

    private func setIntent(_ value: Bool) {
        if enabledIntent != value { enabledIntent = value }
        defaults.set(value, forKey: Self.enabledIntentKey)
    }

    private func prepareRegistration() -> (Task<Void, Never>?, Task<Void, Never>?, Int) {
        registrationTask?.cancel()
        registrationTask = nil
        requestID += 1
        if !changingRegistration { changingRegistration = true }
        stopHeartbeat(reason: "user-disabled")
        return (serviceTask, restorationTask, requestID)
    }

    private func finishRegistration(_ identifier: Int) {
        guard identifier == requestID else { return }
        changingRegistration = false
        serviceTask = nil
        registrationTask = nil
        startHeartbeatIfRequested()
    }

    /// Stop suppressing, then unregister the daemon (launchd unloads it; awdl0
    /// returns to normal Continuity behaviour).
    func disable() {
        setIntent(false)
        streamRequested = false
        let (previous, restoration, identifier) = prepareRegistration()
        // Teardown is never cancelled: every successor must inherit its release obligation.
        serviceTask = Task { @MainActor in
            await previous?.value
            await restoration?.value
            await operations.invalidate()
            do { try await operations.unregister() } catch {
                log.error("AWDL helper unregister failed: \(error.localizedDescription, privacy: .private)")
            }
            refresh()
            finishRegistration(identifier)
        }
    }

    /// Bundle replacement can wedge registration. Healthy daemons idle-exit and
    /// reload on demand; unreachable or drifted registrations need repair.
    /// Only repair when the saved intent still wants protection.
    func reconcileAfterUpdate() {
        refresh()
        guard enabledIntent, !changingRegistration, !restoring else { return }
        // Migrate a live registration only when no explicit off intent was saved.
        setIntent(true)
        let identifier = requestID
        switch state {
        case .enabled:
            // A delete-and-recopy install (Homebrew) can leave `.enabled` with no launchd job
            // behind it, so every stream's calls fail. Only a reply proves the daemon is there.
            Task {
                guard !(await operations.reachable()), enabledIntent, requestID == identifier else { return }
                log.notice("AWDL daemon enabled but unreachable after an update - self-healing")
                enable()
            }
        case .requiresApproval:
            log.notice("AWDL daemon awaiting approval in System Settings ▸ Login Items")
        case .notRegistered, .unavailable:
            log.notice("""
                AWDL daemon registration drifted after an update \
                (\(self.state.diagDescription.systemLogText, privacy: .public)) - self-healing
                """)
            enable()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Stream-scoped suppression

    private var heartbeatTask: Task<Void, Never>?
    private var downRequested = false

    /// Park awdl0 for the life of a stream. Heartbeats the daemon every second so
    /// it keeps awdl0 down and can detect if we go away (stream end / crash) and
    /// restore it. No-op unless the helper is enabled.
    func suppressForStream() {
        // Approval can change outside the app; keep the enabled fast path quiet.
        AWDLStreamLease.refreshIfNeeded(isEnabled: { self.isEnabled }, refresh: { self.refresh() })
        guard enabledIntent, state == .enabled else {
            Diag.notice("AWDL helper NOT engaged - state \(state.diagDescription); awdl0 left to macOS", "Stream")
            return
        }
        streamRequested = true
        startHeartbeatIfRequested()
    }

    private func startHeartbeatIfRequested() {
        guard streamRequested, isEnabled, heartbeatTask == nil else { return }
        Diag.notice("AWDL helper engaged - parking awdl0 for the stream", "Stream")
        heartbeatTask = Task { @MainActor in
            var tick = 0
            var lastLogged: UInt64 = 0
            while !Task.isCancelled {
                downRequested = true
                let down = await operations.setDown(true, "stream")
                guard !Task.isCancelled else { break }
                suppressing = down
                // Pull the contention gauge every five ticks, with a breadcrumb on change.
                if tick % 5 == 0, let count = await operations.count() {
                    guard !Task.isCancelled else { break }
                    operations.telemetry(suppressing, count)
                    if count > lastLogged {
                        lastLogged = count
                        Diag.info("AWDL re-suppress \(count) - macOS re-raised awdl0 this stream", "Stream")
                    }
                }
                guard !Task.isCancelled else { break }
                tick &+= 1
                do { try await operations.sleep(.seconds(1)) } catch { break }
            }
        }
    }

    private func stopHeartbeat(reason: String) {
        guard let heartbeat = heartbeatTask else { return }
        heartbeat.cancel()
        heartbeatTask = nil
        suppressing = false
        operations.telemetry(false, 0)
        guard downRequested else { return }
        downRequested = false
        restoring = true
        restorationTask = Task { @MainActor in
            // Wait for the down reply or its deadline, then release even if it timed out.
            await heartbeat.value
            await restoreAfterHeartbeat(reason: reason)
            restoring = false
            restorationTask = nil
            if reason == "stream-end" { Diag.info("AWDL helper release recovery finished (stream end)", "Stream") }
            startHeartbeatIfRequested()
        }
    }

    private func restoreAfterHeartbeat(reason: String) async {
        for delay in [1, 2, 4] {
            if await operations.setDown(false, reason) { return }
            try? await operations.sleep(.seconds(delay))
        }
        if await operations.setDown(false, reason) { return }
        await operations.invalidate()
        // A watchdog deadline cannot prove that queued interface work finished.
        // Keep registration and new streams waiting for an acknowledged release.
        while true {
            try? await operations.sleep(.seconds(10))
            if await operations.setDown(false, reason) { return }
            await operations.invalidate()
        }
    }

    /// A queued next stream can end before the previous stream finishes restoring.
    func releaseForStream() {
        streamRequested = false
        AWDLStreamLease.releaseIfHeartbeatExists(hasHeartbeat: { self.heartbeatTask != nil }, release: {
            self.stopHeartbeat(reason: "stream-end")
        })
    }
}

// MARK: - Launch-time enable prompt

/// The enable nudge and "Don't ask again" are independent: enabling need not
/// silence future asks, and dismissing need not opt out forever.
struct AWDLEnablePrompt: View {
    @ObservedObject var manager: AWDLHelperManager
    @Environment(\.dismiss) private var dismiss
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth out Wi-Fi stutter").font(.headline)
                    Text("Recommended for wireless streaming")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("AirDrop and Continuity share your Mac's Wi-Fi radio. While you stream they "
                + "can grab the channel and cause multi-second freezes. Glimmer can park that "
                + "radio for the length of each stream and restore it the instant you stop.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Installs a small helper that needs a one-time approval in System Settings.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't ask again", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Not Now") {
                    if dontAskAgain { manager.promptSuppressed = true }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Enable") {
                    if dontAskAgain { manager.promptSuppressed = true }
                    manager.enable()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}
