//
//  DualSenseHID.swift
//
//  Raw-HID side channel for the DualSense over IOHIDManager (as moonlight-qt
//  and SDL do). GameController never delivers the centre buttons (Options,
//  Create, Mute), so they are read from the raw report alongside it.
//
//  Non-exclusive open: gamecontrollerd keeps sticks, face, triggers, touchpad,
//  rumble and light; this reads the report next to it and writes the OUTPUT
//  report (adaptive triggers, plus lightbar and rumble re-emitted with them).
//
//  Needs the Input Monitoring permission (TCC ListenEvent). Not App Store
//  compatible: a Mac App Store target must drop this file and its call sites.
//

import Foundation
import IOKit.hid
import os.log

/// The DualSense buttons GameController hides, plus L1/R1 from the same byte
/// so the quit chord reads one coherent report (the host's L1/R1 still ride
/// GameController; GameController withholds input around bound gestures).
struct DualSenseExtraButtons: Equatable, Sendable {
    var options = false    // ≡  → Start  (PLAY_FLAG)
    var create = false     // Share/Create → Back/Select (BACK_FLAG)
    var ps = false         // PS → Guide  (SPECIAL_FLAG)
    var mute = false       // Mic mute → MISC_FLAG
    var l1 = false         // chord-only; host L1 rides GameController
    var r1 = false         // chord-only; host R1 rides GameController
}

/// Battery from the raw report: opening the pad over HID makes gamecontrollerd
/// drop the enhanced battery field, so `GCController.battery` reads nil while
/// this reader is live and callers prefer this value.
struct DualSenseBattery: Equatable, Sendable {
    var percent: Int       // 0...100
    var charging: Bool
}

/// One merged OUTPUT report (0x02 USB / 0x31 BT): rumble, lightbar and both
/// trigger blocks travel together, so every write re-emits all of them.
/// Defaults are neutral (motors off, bar off, trigger mode 0x00).
struct DualSenseOutputState: Equatable, Sendable {
    var rumbleLeft: UInt8 = 0   // low-freq / heavy motor
    var rumbleRight: UInt8 = 0  // high-freq / light motor
    var lightR: UInt8 = 0
    var lightG: UInt8 = 0
    var lightB: UInt8 = 0
    var lightSet: Bool = false
    /// 11 bytes each: [mode][10 params]. 0x00 mode = trigger off (neutral).
    var leftTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
    var rightTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
}

/// Reports per second over the last full one-second window; nil until one
/// completes. Measures the raw pad cadence next to GameController's.
struct HIDReportRate: Equatable, Sendable {
    private(set) var perSecond: Double?
    private var windowStart: TimeInterval?
    private var windowCount = 0

    mutating func record(at time: TimeInterval) {
        if let start = windowStart, time - start >= 1 {
            perSecond = Double(windowCount) / (time - start)
            windowStart = time
            windowCount = 0
        } else if windowStart == nil {
            windowStart = time
        }
        windowCount += 1
    }
}

final class DualSenseHID: @unchecked Sendable {
    static let shared = DualSenseHID()

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "DualSenseHID")
    private let manager: IOHIDManager
    private let lock = NSLock()

    // All mutable state below is guarded by `lock`.
    private var deviceStates: [UnsafeMutableRawPointer: DualSenseDeviceState] = [:]
    private var retainCount = 0
    private var running = false
    // Per-device input-report buffers, keyed by the device's opaque pointer. IOKit
    // holds the pointer for the device object's lifetime (the manager keeps those
    // across close/open), so a buffer is never freed, only reused on re-match.
    private var deviceBuffers: [UnsafeMutableRawPointer: UnsafeMutablePointer<UInt8>] = [:]
    private let bufLen = 128 // ≥ 78 (BT) / 64 (USB)

    // Strong references keep devices alive while queued output writes finish.
    // Bluetooth needs report 0x31 plus a CRC32; USB uses 0x02 without one, so
    // each device's transport is cached at match time.
    private var writeDevices: [UnsafeMutableRawPointer: (device: IOHIDDevice, bluetooth: Bool)] = [:]
    /// Per-device merged OUTPUT state; a trigger write re-sends that pad's
    /// lightbar and rumble so they are never clobbered to zero.
    private var outputStates: [UnsafeMutableRawPointer: DualSenseOutputState] = [:]
    /// Latch so the "SetReport refused" breadcrumb logs once, not per write
    /// (host re-arms triggers can arrive at frame rate).
    private var loggedWriteFailure = false
    /// Latch for the first successful OUTPUT write (proves the raw-HID write
    /// path reached the device).
    private var loggedWriteSuccess = false

    private let writeQueue = DispatchQueue(label: "io.ugfugl.Glimmer.dualsense-hid-write",
                                           qos: .userInitiated)

    /// Called on the main queue whenever the decoded buttons change - lets the
    /// input-test UI refresh. The forwarder routes it to the bound slot.
    @MainActor var onChange: (@MainActor (DualSenseDeviceKey) -> Void)?

    /// Total raw input reports received since the manager opened - a live
    /// "is the device delivering anything?" signal for the input test. Zero
    /// while Input Monitoring is denied.
    private var reportCountLocked = 0
    var reportCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reportCountLocked
    }

    /// The fastest open pad's raw report rate (see HIDReportRate), for telemetry.
    var reportsPerSecond: Double? {
        lock.lock(); defer { lock.unlock() }
        return deviceStates.values.compactMap(\.reportRate.perSecond).max()
    }

    func state(for controllerID: ObjectIdentifier) -> DualSenseDeviceState? {
        guard let device = DualSenseRouting.shared.device(for: controllerID),
              let key = UnsafeMutableRawPointer(bitPattern: device) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return deviceStates[key]
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Sony vendor 0x054C, DualSense (0x0CE6) + DualSense Edge (0x0DF2).
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6],
            [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0DF2]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "rawHIDControllerEnabled") }

    // MARK: Input Monitoring permission

    /// Current Input Monitoring access without prompting.
    static var accessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    static var accessDenied: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
    }

    /// Present the Input Monitoring prompt if the state is still unknown.
    /// Returns true if already/now granted.
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Lifecycle (ref-counted)

    func retain() {
        lock.lock()
        retainCount += 1
        let shouldStart = retainCount == 1 && !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { start() }
    }

    func release() {
        lock.lock()
        retainCount = max(0, retainCount - 1)
        let shouldStop = retainCount == 0 && running
        if shouldStop { running = false }
        lock.unlock()
        if shouldStop { stop() }
    }

    /// After an in-app grant: re-open a running reader so reports flow without
    /// a relaunch (HIDGamepadManager.reopenAll's twin). Main thread only.
    func reopen() {
        guard isActive else { return }
        stop()
        start()
    }

    private func start() {
        // Permission is requested by the opt-in UI; opening here never prompts.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let monitoring = Self.accessGranted ? "granted"
            : (Self.accessDenied ? "DENIED" : "not-yet-determined")
        let usable = (rc == kIOReturnSuccess && Self.accessGranted)
        let buttonsState = usable ? "available"
            : "UNAVAILABLE (reports won't deliver until Input Monitoring is granted)"
        Diag.notice("DualSense HID open rc=0x\(String(rc, radix: 16)) inputMonitoring=\(monitoring) "
            + "- raw-HID centre buttons/battery \(buttonsState)", "Controller")
    }

    private func stop() {
        resetTriggersBeforeClose()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        // Closing the manager leaves the per-device report callbacks registered;
        // drop them here. The buffers stay allocated (see `deviceBuffers`).
        lock.lock()
        let open = writeDevices.compactMap { key, entry in deviceBuffers[key].map { (entry.device, $0) } }
        lock.unlock()
        for (device, buf) in open {
            IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, nil, nil)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        writeDevices.removeAll()
        let removed = deviceStates.keys.map { UInt(bitPattern: $0) }
        deviceStates.removeAll()
        reportCountLocked = 0
        outputStates.removeAll()
        lock.unlock()
        for device in removed { DualSenseRouting.shared.disconnectDevice(device) }
        log.info("DualSense HID closed")
    }

    // MARK: Device match / removal

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue().registerDevice(device)
    }
    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue().unregisterDevice(device)
    }

    private func registerDevice(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let isBluetooth = !transport.localizedCaseInsensitiveContains("usb")
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let identity = serial.flatMap { $0.isEmpty ? nil : $0 }.map(DualSenseDeviceState.Identity.serial)
            ?? .registry(registryID)
        lock.lock()
        guard writeDevices[key] == nil else { lock.unlock(); return }
        // Same buffer as any earlier registration on this device, so IOKit's
        // callback set sees one entry and its report pointer is always live.
        let buf = deviceBuffers[key] ?? Self.makeReportBuffer(bufLen)
        deviceBuffers[key] = buf
        writeDevices[key] = (device: device, bluetooth: isBluetooth)
        deviceStates[key] = DualSenseDeviceState(identity: identity, transport: transport)
        outputStates[key] = DualSenseOutputState()
        lock.unlock()
        // Seed the full matching set before the first callback can infer a single pair.
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [device]
        let ids = Set(devices.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) })
        MainActor.assumeIsolated { DualSenseRouting.shared.syncControllers() }
        DualSenseRouting.shared.connectDevices(ids)
        notifyChange(UInt(bitPattern: key))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, Self.reportCallback, ctx)
        log.info("DualSense HID device matched (transport=\(transport, privacy: .public))")
    }

    private func unregisterDevice(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock()
        let wasOpen = writeDevices.removeValue(forKey: key) != nil
        deviceStates[key] = nil
        outputStates[key] = nil
        let buf = deviceBuffers[key]
        lock.unlock()
        let deviceID = UInt(bitPattern: key)
        MainActor.assumeIsolated { onChange?(deviceID) }
        DualSenseRouting.shared.disconnectDevice(deviceID)
        guard wasOpen, let buf else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, nil, nil)
    }

    private static func makeReportBuffer(_ length: Int) -> UnsafeMutablePointer<UInt8> {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buf.initialize(repeating: 0, count: length)
        return buf
    }

    // MARK: Report decode

    // C-function-pointer-compatible (no captures). `report` is non-optional.
    private static let reportCallback: IOHIDReportCallback = { context, result, sender, _, reportID, report, length in
        guard result == kIOReturnSuccess, let context, let sender else { return }
        let me = Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue()
        me.decode(device: sender, reportID: reportID, report: report, length: length)
    }

    /// Per-report entry from the IOKit callback: the pure decode lives in
    /// DualSenseHID+Decode.swift; this half owns the lock, the change edge,
    /// and the main-queue hop to `onChange`.
    private func decode(device: UnsafeMutableRawPointer, reportID: UInt32,
                        report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard let decoded = Self.decodeInputReport(
            reportID: reportID, bytes: UnsafeBufferPointer(start: report, count: length)) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard var state = deviceStates[device] else { lock.unlock(); return }
        let previous = state
        let pressed = state.apply(decoded)
        state.reportRate.record(at: time)
        let changed = state.buttons != previous.buttons || state.battery != previous.battery
        deviceStates[device] = state
        reportCountLocked += 1
        lock.unlock()
        let key = UInt(bitPattern: device)
        if !pressed.isEmpty { DualSenseRouting.shared.hid(device: key, pressed: pressed, at: time) }
        if changed { notifyChange(key) }
    }

    private func notifyChange(_ device: DualSenseDeviceKey) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?(device) } }
    }

    func setAdaptiveTriggers(device: DualSenseDeviceKey, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8,
                             left: [UInt8], right: [UInt8]) {
        // DS_EFFECT_RIGHT_TRIGGER 0x04 / DS_EFFECT_LEFT_TRIGGER 0x08.
        let wantRight = (eventFlags & 0x04) != 0
        let wantLeft = (eventFlags & 0x08) != 0
        guard wantRight || wantLeft else { return }
        lock.lock()
        guard let key = UnsafeMutableRawPointer(bitPattern: device),
              var outputState = outputStates[key] else { lock.unlock(); return }
        if wantLeft { outputState.leftTrigger = Self.triggerBlock(mode: typeLeft, params: left) }
        if wantRight { outputState.rightTrigger = Self.triggerBlock(mode: typeRight, params: right) }
        outputStates[key] = outputState
        lock.unlock()
        scheduleWrite(device: device)
    }

    /// Merge only: GameController still drives the light; trigger writes preserve its latest color.
    func setLightbarState(device: DualSenseDeviceKey, red: UInt8, green: UInt8, blue: UInt8) {
        lock.lock()
        guard let key = UnsafeMutableRawPointer(bitPattern: device),
              var outputState = outputStates[key] else { lock.unlock(); return }
        outputState.lightR = red; outputState.lightG = green; outputState.lightB = blue
        outputState.lightSet = true
        outputStates[key] = outputState
        lock.unlock()
    }

    /// Feed the host's latest rumble pair into the merged output state (8-bit,
    /// already down-scaled from the 16-bit wire by the caller). Merge-only, like
    /// setLightbarState - rumble itself still rides GameController haptics.
    func setRumbleState(device: DualSenseDeviceKey, left: UInt8, right: UInt8) {
        lock.lock()
        guard let key = UnsafeMutableRawPointer(bitPattern: device),
              var outputState = outputStates[key] else { lock.unlock(); return }
        outputState.rumbleLeft = left; outputState.rumbleRight = right
        outputStates[key] = outputState
        lock.unlock()
    }

    /// Park the triggers to neutral and re-emit, called from stop() while the
    /// device is still open. Best-effort - a refused write is fine, the pad
    /// loses power on disconnect anyway.
    private func resetTriggersBeforeClose() {
        lock.lock()
        let devices = outputStates.keys.map { UInt(bitPattern: $0) }
        for key in outputStates.keys {
            outputStates[key]?.leftTrigger = [UInt8](repeating: 0, count: 11)
            outputStates[key]?.rightTrigger = [UInt8](repeating: 0, count: 11)
        }
        lock.unlock()
        writeQueue.sync {
            for device in devices { self.writeCurrentOutput(device: device) }
        }
    }

    /// One trigger block = [mode][10 params], clamped to 11 bytes. Rejects the
    /// 0xFC-0xFE debug/calibration modes (they can corrupt trigger state) by
    /// neutralizing to "off" - defensive against a malformed host value.
    private static func triggerBlock(mode: UInt8, params: [UInt8]) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 11)
        guard mode < 0xFC else { return block } // 0x00 = off
        block[0] = mode
        for i in 0..<min(params.count, 10) { block[i + 1] = params[i] }
        return block
    }

    private func scheduleWrite(device: DualSenseDeviceKey) {
        writeQueue.async { [weak self] in self?.writeCurrentOutput(device: device) }
    }

    private func writeCurrentOutput(device: DualSenseDeviceKey) {
        guard let key = UnsafeMutableRawPointer(bitPattern: device) else { return }
        lock.lock()
        let state = outputStates[key]
        let entry = writeDevices[key]
        lock.unlock()
        guard let state, let entry else { return }
        writeOutputReport(to: entry.device, bluetooth: entry.bluetooth, state: state)
    }

    private static func effectsState(_ s: DualSenseOutputState) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 47)
        d[0] = 0x01 | 0x02
        d[2] = s.rumbleRight   // ucRumbleRight (high-freq)
        d[3] = s.rumbleLeft    // ucRumbleLeft  (low-freq)
        if s.lightSet {
            d[1] = 0x04
            d[44] = s.lightR; d[45] = s.lightG; d[46] = s.lightB
        }
        // rgucRightTriggerEffect[11] @10, rgucLeftTriggerEffect[11] @21.
        for i in 0..<11 { d[10 + i] = s.rightTrigger[i] }
        for i in 0..<11 { d[21 + i] = s.leftTrigger[i] }
        return d
    }

    private func writeOutputReport(to device: IOHIDDevice, bluetooth: Bool,
                                   state: DualSenseOutputState) {
        let payload = Self.effectsState(state)
        let reportID: UInt8
        var data: [UInt8]
        if bluetooth {
            // BT report 0x31: data = [0x02 seq/feature flag][47-byte effects]
            // [pad to 74][CRC32 LE 4]. The CRC seed is 0xA2 (the BT output report
            // tag), then the report-ID byte, then the data-up-to-CRC.
            reportID = 0x31
            data = [UInt8](repeating: 0, count: 78 - 1) // 77 data bytes (report total 78 incl. ID)
            data[0] = 0x02
            for i in 0..<47 { data[1 + i] = payload[i] }
            let crc = Self.dualSenseBTCrc(reportID: reportID, data: Array(data[0..<(data.count - 4)]))
            let base = data.count - 4
            data[base + 0] = UInt8(crc & 0xFF)
            data[base + 1] = UInt8((crc >> 8) & 0xFF)
            data[base + 2] = UInt8((crc >> 16) & 0xFF)
            data[base + 3] = UInt8((crc >> 24) & 0xFF)
        } else {
            // USB report 0x02: data = 47-byte effects state (SDL writes 48 incl.
            // the report ID; the data we hand SetReport is the 47 after it).
            reportID = 0x02
            data = payload
        }
        let rc = data.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, buf.count)
        }
        if rc == kIOReturnSuccess {
            if !loggedWriteWasSuccessful() {
                let transport = bluetooth ? "BT" : "USB"
                log.info("DualSense OUTPUT write OK over \(transport, privacy: .public) - adaptive triggers live")
            }
        } else if !loggedWriteWasRefused() {
            let hex = String(UInt32(bitPattern: rc), radix: 16)
            log.error("DualSense OUTPUT write refused rc=0x\(hex, privacy: .public) - adaptive triggers disabled")
        }
    }

    /// First-success latch (lock-guarded). Returns the PRIOR value so the caller
    /// logs only on the first success.
    private func loggedWriteWasSuccessful() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = loggedWriteSuccess
        loggedWriteSuccess = true
        return was
    }
    /// First-failure latch (lock-guarded), same shape.
    private func loggedWriteWasRefused() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = loggedWriteFailure
        loggedWriteFailure = true
        return was
    }

    private static func dualSenseBTCrc(reportID: UInt8, data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func feed(_ byte: UInt8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        feed(0xA2)          // BT output-report CRC seed tag
        feed(reportID)      // 0x31
        for b in data { feed(b) }
        return crc ^ 0xFFFF_FFFF
    }
}
