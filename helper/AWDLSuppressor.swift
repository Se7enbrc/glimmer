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
    /// Event-servicing queue: route socket, poll timer, SCDynamicStore handler.
    private let queue = DispatchQueue(label: "io.ugfugl.glimmer.helper.awdl", qos: .userInitiated)
    /// Interface-mutation queue. Serial (preserves re-suppress-count ordering)
    /// but SEPARATE from `queue` so the blocking ifconfig execs never stall the
    /// route socket from servicing the next kernel raise edge.
    private let execQueue = DispatchQueue(label: "io.ugfugl.glimmer.helper.awdl.exec", qos: .userInitiated)

    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    private var _suppressing = false
    private var _suppressionSince: Date?
    private var _lastHeartbeat = Date()
    private let stateLock = NSLock()
    private var pollTimer: DispatchSourceTimer?
    private var _initialDownDone = false
    private var _reSuppressCount = 0
    /// PF_ROUTE fast path — re-down awdl0 the instant the kernel re-raises it,
    /// event-driven (no poll) and far lower latency than SCDynamicStore.
    private var routeFd: Int32 = -1
    private var routeSource: DispatchSourceRead?
    /// Tight verify-retry per down: macOS can re-raise within ms, so confirm + retry.
    private static let maxDownAttempts = 3
    private static let downRetrySettleUs: UInt32 = 40_000

    var suppressing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _suppressing
    }

    var suppressionSince: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _suppressionSince
    }

    /// How many times macOS re-raised awdl0 this stream (the whack-a-mole rate).
    var reSuppressCount: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return UInt64(_reSuppressCount)
    }

    func start() {
        setupMonitoring()
        setupRouteSocket()
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
        // Mutate the interface on the serial `execQueue` so concurrent
        // re-suppressions serialize and can't double-count.
        if value {
            execQueue.async { [weak self] in self?.downIfUp() }
        } else {
            // Restore awdl0 - just clearing the flag leaves it down until macOS
            // re-raises it, breaking AirDrop/Continuity meanwhile.
            execQueue.async { [weak self] in self?.upIfDown() }
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

    private func downIfUp(fast: Bool = false) {
        guard isInterfaceUp() else { return }
        let confirmed = forceDownAwdl(fast: fast)
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
        if !confirmed {
            os_log("%{public}@ STILL up after %d down attempts", log: log, type: .error,
                   interfaceName, Self.maxDownAttempts)
        }
    }

    /// Down awdl0, strip its IPv6 link-local (macOS re-derives it on re-raise, so
    /// deleting it raises the cost of coming back), and VERIFY - a few tight retries
    /// because macOS can re-raise within ms. Returns true once confirmed down.
    /// `fast`: skip the inter-attempt settle sleep (route fast path - a real
    /// re-raise re-triggers us, so we don't block the exec queue spinning here).
    private func forceDownAwdl(fast: Bool = false) -> Bool {
        for attempt in 0..<Self.maxDownAttempts {
            _ = executeIfconfig(args: [interfaceName, "down"])
            for addr in ipv6LinkLocalAddrs() {
                _ = executeIfconfig(args: [interfaceName, "inet6", addr, "delete"])
            }
            if !isInterfaceUp() { return true }
            if !fast, attempt < Self.maxDownAttempts - 1 { usleep(Self.downRetrySettleUs) }
        }
        return !isInterfaceUp()
    }

    /// awdl0's current IPv6 addresses in `ifconfig … delete` form (scoped link-local).
    private func ipv6LinkLocalAddrs() -> [String] {
        guard let out = captureIfconfig() else { return [] }
        return out.components(separatedBy: "\n")
            .filter { $0.contains("inet6") }
            .compactMap { line -> String? in
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                return parts.count > 1 ? parts[1] : nil
            }
    }

    private func captureIfconfig() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = [interfaceName]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: Routing-socket fast path

    /// Listen on a PF_ROUTE socket for kernel interface events and re-down awdl0 the
    /// instant it's re-raised - event-driven, no polling, far lower latency than
    /// SCDynamicStore, so the firmware barely gets an AWDL scan window in.
    private func setupRouteSocket() {
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard fd >= 0 else { os_log("route socket failed (errno %d)", log: log, type: .error, errno); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        routeFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drainRouteSocket() }
        src.setCancelHandler { close(fd) }
        src.resume()
        routeSource = src
        os_log("route-socket fast path armed (fd %d)", log: log, type: .default, fd)
    }

    /// Drain pending routing messages then re-assert the down if awdl0 popped up. We
    /// don't parse message types - `downIfUp` is the filter (no-op unless awdl0 is
    /// actually up) - so this stays simple and catches every raise edge.
    private func drainRouteSocket() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var sawEvent = false
        while read(routeFd, &buf, buf.count) > 0 { sawEvent = true }
        guard sawEvent else { return }
        stateLock.lock(); let suppressing = _suppressing; stateLock.unlock()
        // Hop the blocking ifconfig exec onto execQueue so this read source stays
        // free to drain the NEXT raise edge. `fast`: skip the inter-attempt sleep
        // on the route path - we'll be re-triggered if a retry is actually needed.
        if suppressing { execQueue.async { [weak self] in self?.downIfUp(fast: true) } }
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
            // 1s backstop re-assert (in case the route socket missed an edge) -
            // on execQueue so this poll on `queue` doesn't block servicing.
            execQueue.async { [weak self] in self?.downIfUp() }
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
        execQueue.async { [weak self] in
            guard let self else { return }
            guard self.suppressing else { return }
            self.downIfUp()
        }
    }
}
