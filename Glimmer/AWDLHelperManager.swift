import Combine
import Foundation
import ServiceManagement
import os.log

// App-side integration for the privileged AWDL network helper (helper/, a root
// LaunchDaemon). The daemon parks awdl0 — the AirDrop/Continuity radio — while
// streaming, which kills the multi-second Wi-Fi delivery gaps AWDL contention
// causes on a single-radio Mac. This file owns: registering the daemon
// (SMAppService.daemon), the XPC client that drives it, and the observable
// state the UI binds to.

// MARK: - XPC interface (app-side mirror of helper/Protocol.swift)

// Deliberately a SEPARATE declaration from the daemon's copy so the daemon stays
// a standalone swiftc build with zero app dependencies. The two MUST stay in
// sync — same selectors, same signatures.
@objc protocol GlimmerHelperProtocol {
    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void)
    func currentStatus(reply: @escaping (Bool, Date?) -> Void)
    func ping(reply: @escaping (String) -> Void)
}

enum HelperConstants {
    /// The daemon's Mach service (matches helper/Protocol.swift + the launchd
    /// plist + the sandbox mach-lookup exception in Glimmer.entitlements).
    static let machServiceName = "io.ugfugl.glimmer.helper"
    /// The launchd plist filename in Contents/Library/LaunchDaemons/.
    static let daemonPlistName = "io.ugfugl.glimmer.helper.plist"
}

// MARK: - Single-resume continuation guard

/// An XPC call can complete via its reply OR via the connection's error handler.
/// This resumes the continuation exactly once across both paths.
private final class SingleResume<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - XPC client

/// Thin async client to the privileged helper. Lazily (re)connects; tears the
/// connection down on any interruption/invalidation so the next call reconnects.
actor HelperClient {
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "AWDLHelper")
    private var connection: NSXPCConnection?

    private func connect() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in Task { await self?.drop() } }
        conn.interruptionHandler = { [weak self] in Task { await self?.drop() } }
        conn.resume()
        connection = conn
        return conn
    }

    private func drop() { connection = nil }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// Returns true on success. Any XPC failure (helper not installed/approved,
    /// or it rejected our code signature) resolves to false.
    func setAWDLDown(_ down: Bool, reason: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = SingleResume(cont)
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] err in
                self?.log.error("helper XPC error: \(err.localizedDescription)")
                Task { await self?.drop() }
                once.resume(false)
            } as? GlimmerHelperProtocol
            guard let proxy else { once.resume(false); return }
            proxy.setAWDLDown(down, reason: reason) { ok in once.resume(ok) }
        }
    }

    /// (isDown, since) per the live daemon, or nil if it's unreachable.
    func currentStatus() async -> (Bool, Date?)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Date?)?, Never>) in
            let once = SingleResume(cont)
            let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { await self?.drop() }
                once.resume(nil)
            } as? GlimmerHelperProtocol
            guard let proxy else { once.resume(nil); return }
            proxy.currentStatus { isDown, since in once.resume((isDown, since)) }
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
    }

    @Published private(set) var state: State = .notRegistered
    /// True while awdl0 is actively parked (a stream is up).
    @Published private(set) var suppressing = false

    private let client = HelperClient()
    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "AWDLHelper")
    private static let promptSuppressedKey = "awdlHelperPromptSuppressed"

    private init() { refresh() }

    var isEnabled: Bool { state == .enabled }

    /// Registered with the system, whether or not the user has approved it yet
    /// in System Settings. Drives the toggle's on/off so flipping it on doesn't
    /// snap back while approval is pending.
    var isRegistered: Bool {
        switch state {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .unavailable: return false
        }
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
        switch service.status {
        case .enabled:          state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered:    state = .notRegistered
        case .notFound:         state = .unavailable("Helper not found in the app bundle")
        @unknown default:       state = .unavailable("Unknown status")
        }
    }

    /// Register the daemon. The first time, macOS surfaces a one-time approval in
    /// System Settings → General → Login Items & Extensions.
    func enable() {
        do {
            try service.register()
            log.info("AWDL helper registered")
        } catch {
            log.error("AWDL helper register failed: \(error.localizedDescription)")
            state = .unavailable(error.localizedDescription)
            return
        }
        refresh()
    }

    /// Stop suppressing, then unregister the daemon (launchd unloads it; awdl0
    /// returns to normal Continuity behaviour).
    func disable() {
        let client = self.client
        Task {
            _ = await client.setAWDLDown(false, reason: "user-disabled")
            await client.invalidate()
        }
        do { try service.unregister() } catch {
            log.error("AWDL helper unregister failed: \(error.localizedDescription)")
        }
        suppressing = false
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Stream-scoped suppression

    /// Park awdl0 for the duration of a stream. No-op unless the helper is enabled.
    func suppressForStream() {
        guard isEnabled else { return }
        let client = self.client
        Task { @MainActor in
            let ok = await client.setAWDLDown(true, reason: "stream-start")
            self.suppressing = ok
        }
    }

    /// Release awdl0 when a stream ends.
    func releaseForStream() {
        let client = self.client
        Task { @MainActor in
            _ = await client.setAWDLDown(false, reason: "stream-end")
            self.suppressing = false
        }
    }
}
