import Foundation
import Darwin
import SystemConfiguration
import os.log

/// Owns the awdl0 suppression state.
///
/// When `suppressing == true`, the suppressor actively forces `awdl0` down whenever
/// macOS attempts to bring it up (for AirDrop, Sidecar, AirPlay, Continuity).
/// When `suppressing == false`, it leaves AWDL alone.
final class AWDLSuppressor: @unchecked Sendable {
    private let interfaceName = "awdl0"
    private let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "AWDL")
    private let queue = DispatchQueue(label: "io.ugfugl.glimmer.helper.awdl", qos: .userInitiated)

    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    private var _suppressing = false
    private var _suppressionSince: Date?
    private var _lastHeartbeat = Date()
    private let stateLock = NSLock()
    private var pollTimer: DispatchSourceTimer?
    private var _initialDownDone = false
    private var _reSuppressCount = 0

    var suppressing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _suppressing
    }

    var suppressionSince: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _suppressionSince
    }

    func start() {
        setupMonitoring()
        startPolling()
        os_log("AWDL suppressor started", log: log, type: .default)
    }

    func setSuppressing(_ value: Bool, reason: String) {
        stateLock.lock()
        let wasSuppressing = _suppressing
        _suppressing = value
        if value { _lastHeartbeat = Date() }
        if value, _suppressionSince == nil {
            _suppressionSince = Date()
            _initialDownDone = false
            _reSuppressCount = 0
        }
        if !value { _suppressionSince = nil }
        stateLock.unlock()

        // Log only the on/off TRANSITION - the client heartbeats setSuppressing(true)
        // ~1/s, so logging every call would bury the signal. .default persists to disk.
        if wasSuppressing != value {
            os_log("suppression %{public}@ (reason: %{public}@)", log: log, type: .default,
                   value ? "ON" : "OFF", reason)
        }
        // Mutate the interface on `queue` (shared with poll + the SCDynamicStore
        // handler) so concurrent re-suppressions serialize and can't double-count.
        if value {
            queue.async { [weak self] in self?.downIfUp() }
        } else {
            // Restore awdl0 - just clearing the flag leaves it down until macOS
            // re-raises it, breaking AirDrop/Continuity meanwhile.
            queue.async { [weak self] in self?.upIfDown() }
        }
    }

    /// True if awdl0 is currently UP per the kernel.
    func isInterfaceUp() -> Bool {
        var ifaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaces) == 0, let first = ifaces else { return false }
        defer { freeifaddrs(ifaces) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if name == interfaceName {
                let isUp = (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0
                return isUp
            }
            ptr = cur.pointee.ifa_next
        }
        return false
    }

    private func downIfUp() {
        guard isInterfaceUp() else { return }
        guard executeIfconfig(args: [interfaceName, "down"]) else {
            os_log("Failed to bring %{public}@ down", log: log, type: .error, interfaceName)
            return
        }
        stateLock.lock()
        let initial = !_initialDownDone
        _initialDownDone = true
        if !initial { _reSuppressCount += 1 }
        let count = _reSuppressCount
        stateLock.unlock()
        if initial {
            os_log("%{public}@ forced down - suppressing", log: log, type: .default, interfaceName)
        } else {
            // macOS re-raised awdl0 on its own: recent macOS auto-enables it for
            // AirDrop/Continuity even while we hold it down. Each re-enable is a brief
            // AWDL-contention window that can hitch a stream; logged at .default so it
            // persists in `log show` for exactly this diagnosis.
            os_log("%{public}@ re-enabled by macOS (#%ld this stream) - re-suppressed",
                   log: log, type: .default, interfaceName, count)
        }
    }

    /// Restore awdl0 to its normal (up) state once suppression ends - mirror of
    /// downIfUp. macOS resumes managing the interface from there.
    private func upIfDown() {
        guard !isInterfaceUp() else { return }
        guard executeIfconfig(args: [interfaceName, "up"]) else {
            os_log("Failed to bring %{public}@ up", log: log, type: .error, interfaceName)
            return
        }
        os_log("%{public}@ restored (up) - suppression ended", log: log, type: .default, interfaceName)
    }

    // MARK: Heartbeat poll - state-driven safety net

    /// Stay down while the client heartbeats (setSuppressing(true) ~1s); release
    /// awdl0 if the heartbeat goes stale, and exit once idle so the daemon never
    /// lingers as a zombie running stale code.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        stateLock.lock()
        let suppressing = _suppressing
        let idle = Date().timeIntervalSince(_lastHeartbeat)
        stateLock.unlock()
        if suppressing {
            if idle > 3 {
                os_log("heartbeat stale %.1fs - releasing awdl0", log: log, type: .default, idle)
                setSuppressing(false, reason: "heartbeat-timeout")
            }
        } else if idle > 8 {
            os_log("idle %.0fs - exiting for a clean reload", log: log, type: .default, idle)
            exit(0)
        }
    }

    @discardableResult
    private func executeIfconfig(args: [String]) -> Bool {
        let task = Process()
        task.launchPath = "/sbin/ifconfig"
        task.arguments = args
        task.standardError = Pipe()
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: SCDynamicStore monitoring

    private func setupMonitoring() {
        var ctx = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        ctx.info = unmanagedSelf

        let storeOpt = withUnsafeMutablePointer(to: &ctx) { ctxPtr -> SCDynamicStore? in
            return SCDynamicStoreCreate(
                nil,
                "io.ugfugl.glimmer.helper" as CFString,
                { _, changedKeys, info in
                    guard let info else { return }
                    let owner = Unmanaged<AWDLSuppressor>.fromOpaque(info).takeUnretainedValue()
                    owner.handleStoreChange(keys: changedKeys as? [String] ?? [])
                },
                ctxPtr
            )
        }
        guard let store = storeOpt else {
            os_log("Failed to create SCDynamicStore", log: log, type: .error)
            return
        }
        dynamicStore = store

        let patterns = [
            "State:/Network/Interface/awdl0/Link" as CFString,
            "State:/Network/Interface/awdl0/IPv4" as CFString,
            "State:/Network/Interface/awdl0/IPv6" as CFString,
        ]
        SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)

        let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handleStoreChange(keys: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.suppressing else { return }
            self.downIfUp()
        }
    }
}
