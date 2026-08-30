//
//  LunaPower.swift
//
//  Host power controls (wake/shutdown/sleep/reboot/status) via the `luna` CLI
//  (whaleyshire upstream: dev/luna, backed by UpSnap). THIS HEADER IS THE SPEC -
//  the standalone docs/LUNA_POWER.md is gone; every other file points here.
//
//  THE GATE (the whole product rule): power UI exists ONLY when (a) a usable
//  luna binary >= 2026.7.1 is found AND (b) the host's stored MAC matches an
//  UpSnap device from `luna devices --json` (the permission-scoped list - the
//  UpSnap grant doubles as the per-client allowlist). Either check failing =>
//  ZERO footprint: no buttons, no settings, no disabled states. Fail closed on
//  zeroed/absent MACs (a Sunshine NIC quirk); no IP fallback, no manual
//  binding in v1.
//
//  PROBE ORDER (first candidate that is executable AND prints a calver >=
//  2026.7.1 from `luna version` wins): ~/.local/bin/luna, /opt/homebrew/bin/
//  luna, /usr/local/bin/luna, then <dir>/luna for every entry of the inherited
//  PATH, left to right. 2026.7.1 is the first release with `devices --json`,
//  so anything older fails the gate outright. Re-probed at launch and on every
//  app-foreground, so a luna installed or upgraded mid-session is picked up
//  without a relaunch.
//
//  Luna owns the UpSnap endpoint + credentials (keychain item `upsnap-power`);
//  Glimmer never reads, stores, or passes credentials - only sets
//  UPSNAP_DEVICE=<matched id> per call. UpSnap's power routes are SYNCHRONOUS:
//  luna exit 0 is a CONFIRMATION the device state actually flipped (~36s cold
//  wake, ~9s off), so no client-side did-it-work polling is layered on top.
//
//  That synchronous contract is also why a wake can block for up to 200s, so
//  `perform` is ABANDONABLE: `cancelAction(hostID:)` terminates the child luna
//  process the wait is parked on. It abandons OUR wait only - the UpSnap call
//  luna already made is server-side and keeps running, so the PC may still come
//  up. A cancel is not a failure and records no `lastActionError`.
//
//  Zero-footprint acceptance: on a machine without luna, the only work ever
//  done is a file-existence probe per candidate path at launch/foreground -
//  a subprocess spawns only when a candidate FILE exists.
//

import AppKit
import Foundation
import os.log

/// Cancellable handle to one luna child process. Spawned on a background queue
/// but terminated from the main actor, so both sides go through the lock.
/// Adoption happens BEFORE `run()` and the spawn side re-checks afterwards, so
/// a cancel landing on either side of the spawn still kills the child instead
/// of orphaning it. File-scope (not nested in the `@MainActor` LunaPower) so it
/// stays non-isolated - the spawn side touches it off the main actor.
final class LunaRunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Register the not-yet-started child. Returns false when the cancel
    /// already landed, meaning the caller must not start it at all.
    fileprivate func adopt(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    fileprivate var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    fileprivate func release() {
        lock.lock(); process = nil; lock.unlock()
    }

    /// Terminate the child, or arm the pre-spawn refusal when it has not
    /// started yet.
    fileprivate func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
}

@MainActor
@Observable
final class LunaPower {
    static let shared = LunaPower()
    @ObservationIgnored private let log = Logger(
        subsystem: "io.ugfugl.Glimmer", category: "LunaPower")

    /// One permission-scoped UpSnap device from `luna devices --json`.
    struct Device: Decodable, Sendable {
        let id: String
        let name: String
        let mac: String
        let ip: String?
        let status: String?
    }

    /// Discovered usable binary (nil = gate closed everywhere). Re-probed at
    /// launch and on every app-foreground.
    private(set) var binaryURL: URL?
    /// Cached permission-scoped device list + fetch stamp (short TTL).
    private(set) var devices: [Device] = []
    @ObservationIgnored private var devicesFetchedAt: Date?
    /// Power action in flight, keyed host id → verb ("on"/"off"/"sleep"/
    /// "reboot"). Drives the hero's "Waking…" state vs the trailing cluster's
    /// progress capsule, and disables controls while one runs.
    private(set) var actionInFlight: [String: String] = [:]
    /// Last action error, keyed by host id (surfaced as tile subtext; cleared
    /// on the next action or gate re-evaluation).
    private(set) var lastActionError: [String: String] = [:]
    /// Live child-process handle per in-flight action, so `cancelAction` can
    /// terminate the wait `perform` is parked on. Torn down in `perform`'s
    /// defer, so a cancelled action leaves nothing behind for the next one.
    @ObservationIgnored private var runHandles: [String: LunaRunHandle] = [:]
    /// Host ids whose in-flight action the user abandoned. `perform` reads this
    /// to swallow the terminated child's non-zero exit - a deliberate cancel is
    /// not a failure, so it must not paint the tile's error subtext. Cleared in
    /// the same defer as `runHandles`.
    @ObservationIgnored private var cancelledActions: Set<String> = []

    /// Devices-list TTL: refreshed lazily past this age, plus on any power-
    /// action failure and on host-store changes (spec: ~60s).
    private static let devicesTTL: TimeInterval = 60
    /// First calver with `devices --json`; anything older fails the gate.
    private static let minimumVersion = [2026, 7, 1]

    private init() {
        // Re-probe the binary (and expire the device cache) on foreground -
        // luna installed/upgraded while Glimmer runs is picked up without a
        // relaunch. Weak-self: the singleton never deallocs, but discipline.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.devicesFetchedAt = nil
                Task {
                    await self?.refreshBinary()
                    // Fresh device list on foreground: a revoked UpSnap grant
                    // makes the controls vanish here (gatedDevice reads this
                    // observable list, so SwiftUI re-renders on the change).
                    await self?.refreshDevicesIfStale(force: true)
                }
            }
        }
        // Initial probe + device fetch. The foreground observer above can MISS
        // the launch activation (this singleton initializes lazily, usually
        // after didBecomeActive already fired), so init must fully bootstrap
        // the gate itself - binary AND devices.
        Task {
            await refreshBinary()
            await refreshDevicesIfStale()
        }
    }

    // MARK: - Gate

    /// The gate, evaluated per host from CACHED state (pure - never spawns).
    /// Returns the matched device when power controls may draw, else nil.
    func gatedDevice(for host: Host) -> Device? {
        guard binaryURL != nil,
              let hostMac = Self.normalizeMac(host.macAddress) else { return nil }
        return devices.first { Self.normalizeMac($0.mac) == hostMac }
    }

    /// Refresh the device list when stale, then reconcile the host's persisted
    /// binding (bind on first match; UNBIND when the device disappeared - the
    /// revocation case). Called from the tile when a host renders offline/online
    /// and before any power action.
    func reevaluate(for host: Host, model: AppModel) async {
        // Self-bootstrapping: an early caller racing init's probe must not
        // strand the gate closed until the next foreground - re-probe here
        // (cheap: file-exists + one `luna version` when a candidate exists).
        if binaryURL == nil {
            await refreshBinary()
            guard binaryURL != nil else { return }
        }
        await refreshDevicesIfStale()
        let matched = gatedDevice(for: host)
        if matched?.id != host.lunaDeviceId {
            model.bindLunaDevice(hostID: host.id, deviceID: matched?.id)
        }
    }

    // MARK: - Discovery

    /// Probe for a usable luna binary. File-existence checks first (no spawn
    /// on machines without luna); `luna version` runs only on candidates that
    /// exist and must print a calver >= 2026.7.1 (2026.7.0 lacks
    /// `devices --json` and fails the gate).
    func refreshBinary() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/luna",
            "/opt/homebrew/bin/luna",
            "/usr/local/bin/luna"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/luna" }
        }
        var found: URL?
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let url = URL(fileURLWithPath: candidate)
            if let out = try? await Self.run(url, args: ["version"], timeout: 5),
               out.status == 0,
               Self.calverAtLeast(Self.calver(out.stdout), Self.minimumVersion) {
                found = url
                break
            }
        }
        if found?.path != binaryURL?.path {
            log.info("luna gate: \(found?.path ?? "no usable binary", privacy: .public)")
        }
        binaryURL = found
        if found == nil {
            devices = []
            devicesFetchedAt = nil
        }
    }

    /// Fetch `luna devices --json` when the cache is stale. Failure clears the
    /// list (gate closes) - fail closed, never stale-open.
    func refreshDevicesIfStale(force: Bool = false) async {
        guard let binary = binaryURL else { return }
        if !force, let at = devicesFetchedAt, Date().timeIntervalSince(at) < Self.devicesTTL {
            return
        }
        do {
            let out = try await Self.run(binary, args: ["devices", "--json"], timeout: 15)
            guard out.status == 0, let data = out.stdout.data(using: .utf8) else {
                throw LunaError.failed(out.stderr.isEmpty ? "devices exit \(out.status)" : out.stderr)
            }
            devices = try JSONDecoder().decode([Device].self, from: data)
            devicesFetchedAt = Date()
        } catch {
            log.error("luna devices failed: \(error.localizedDescription, privacy: .public)")
            devices = []
            devicesFetchedAt = Date()   // don't hammer a broken luna; TTL still applies
        }
    }

    // MARK: - Actions

    enum LunaError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let reason) = self {
                return reason.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }

    /// Run one power verb against a bound device. Blocks (off-main) until luna
    /// CONFIRMS the state flip - `on` measured ~36s cold (cap 200s), `off` ~9s.
    /// Throws with luna's one-line stderr reason on failure and forces a device
    /// re-fetch so a revoked grant closes the gate promptly. Throws
    /// `CancellationError` (and records NO error) when `cancelAction` abandoned
    /// the wait.
    func perform(_ verb: String, deviceID: String, hostID: String) async throws {
        guard let binary = binaryURL else { throw LunaError.failed("luna not available") }
        actionInFlight[hostID] = verb
        lastActionError[hostID] = nil
        let handle = LunaRunHandle()
        runHandles[hostID] = handle
        // One teardown site for every exit path (success, failure, cancel), so
        // a cancelled wake can never leave the tile latched or strand a stale
        // handle in front of the next Wake.
        defer {
            actionInFlight[hostID] = nil
            runHandles[hostID] = nil
            cancelledActions.remove(hostID)
        }
        do {
            let timeout: TimeInterval = verb == "on" ? 200 : 90
            let out = try await Self.run(
                binary, args: [verb], env: ["UPSNAP_DEVICE": deviceID],
                timeout: timeout, handle: handle)
            // Checked BEFORE the exit status: a terminated child reports a
            // non-zero status, and that is the cancel arriving, not a failure.
            if cancelledActions.contains(hostID) { throw CancellationError() }
            guard out.status == 0 else {
                throw LunaError.failed(out.stderr.isEmpty ? "\(verb) failed" : out.stderr)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastActionError[hostID] = error.localizedDescription
            await refreshDevicesIfStale(force: true)
            throw error
        }
    }

    /// Abandon the in-flight action for a host: terminate the child luna
    /// process `perform` is parked on so it returns promptly. The UpSnap call
    /// luna already issued is server-side and unaffected - this gives the user
    /// their UI back, it does not un-send the wake. No-op when nothing is in
    /// flight for that host.
    func cancelAction(hostID: String) {
        guard let handle = runHandles[hostID] else { return }
        cancelledActions.insert(hostID)
        lastActionError[hostID] = nil
        handle.cancel()
    }

    // MARK: - Helpers (pure; unit-tested)

    /// Normalize a MAC for matching: lowercase, colon-separated, two hex
    /// digits per octet. Returns nil for absent, malformed, or ZEROED input
    /// (the Sunshine quirk the gate must fail closed on).
    nonisolated static func normalizeMac(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.lowercased()
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
            .map { $0.count == 1 ? "0\($0)" : String($0) }
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        let joined = parts.joined(separator: ":")
        return joined == "00:00:00:00:00:00" ? nil : joined
    }

    /// Parse "2026.7.1" → [2026,7,1] for lexicographic comparison; malformed
    /// input compares as [0] (fails any minimum).
    nonisolated static func calver(_ raw: String) -> [Int] {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .compactMap { Int($0) }
        return parts.count == 3 ? parts : [0]
    }

    /// Lexicographic component compare: version >= minimum.
    nonisolated static func calverAtLeast(_ version: [Int], _ minimum: [Int]) -> Bool {
        for (part, floor) in zip(version, minimum) where part != floor { return part > floor }
        return version.count >= minimum.count
    }

    // MARK: - Subprocess (off-main)

    /// Run luna with a bounded timeout; never on the main thread. Environment
    /// is inherited plus overrides (UPSNAP_DEVICE) - luna resolves its own
    /// credentials (keychain / UPSNAP_PASSWORD); Glimmer passes none. Pass a
    /// `handle` for a wait the user is allowed to abandon (see `cancelAction`).
    nonisolated static func run(
        _ url: URL, args: [String], env: [String: String] = [:], timeout: TimeInterval,
        handle: LunaRunHandle? = nil
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = url
                process.arguments = args
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in env { environment[key] = value }
                process.environment = environment
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                // Cancel that beat the spawn: never start the child at all.
                guard handle?.adopt(process) ?? true else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                defer { handle?.release() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Cancel that landed between adopt and run saw a not-yet-running
                // process, so its terminate() was a no-op - collect it here.
                if handle?.isCancelled == true, process.isRunning { process.terminate() }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                let stdout = String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let stderr = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
        }
    }
}
