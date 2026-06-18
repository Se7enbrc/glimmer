//
//  DualSenseHID.swift
//
//  Raw-HID side-channel for the Sony DualSense, read over IOKit's
//  IOHIDManager - exactly how moonlight-qt / SDL's HIDAPI driver does it.
//  macOS's GameController framework does NOT deliver the DualSense's centre
//  buttons (Options ≡, Create/Share, Mute) to apps, so a controller-only exit
//  chord and full button parity are impossible through GCController alone.
//  This reads the raw input report alongside GameController (non-exclusive
//  open - it never seizes the device, so GCController keeps everything it
//  already provides: sticks, face, shoulders, triggers, touchpad, battery).
//
//  Surfaces only the three buttons GameController drops. Everything else stays
//  on the GameController path.
//
//  REQUIRES the "Input Monitoring" privacy permission (TCC kTCCServiceListenEvent
//  - it covers game controllers, not just keyboards). Raw-HID open works under
//  the unsandboxed Developer-ID build with no device.* entitlement. NOT
//  Mac-App-Store-compatible (raw device HID is a hard App-Review reject).
//  MAS-STRIP: a future Mac App Store target must remove this file and the call
//  sites that reference DualSenseHID (ControllerForwarder / InputForwarder /
//  TroubleshootingPane).
//

import Foundation
import IOKit.hid
import os.log

/// The three DualSense buttons GameController doesn't expose, mapped to the
/// host's button semantics by `ControllerForwarder`.
struct DualSenseExtraButtons: Equatable, Sendable {
    var options = false    // ≡  → Start  (PLAY_FLAG)
    var create = false     // Share/Create → Back/Select (BACK_FLAG)
    var ps = false         // PS → Guide  (SPECIAL_FLAG)
    var mute = false       // Mic mute → MISC_FLAG
}

/// Battery decoded straight from the DualSense report. We read this ourselves
/// because opening the pad over raw HID makes `gamecontrollerd` drop the
/// enhanced-report battery field, so `GCController.battery` goes nil while the
/// HID reader is live (confirmed via SDL/Linux hid-playstation). Callers prefer
/// this whenever `DualSenseHID` is running.
struct DualSenseBattery: Equatable, Sendable {
    var percent: Int       // 0...100
    var charging: Bool
}

/// The merged state we write into the DualSense OUTPUT report (0x02 USB / 0x31
/// BT). All three families (rumble, lightbar, adaptive triggers) share one
/// report, so we keep the latest of each and re-emit the whole thing on any
/// update. Trigger blocks are the DualSense-native MODE byte + 10 param bytes
/// (the Sunshine wire passes these through verbatim). Defaults are the neutral
/// state: motors off, lightbar off, triggers off (mode 0x00 = no effect).
struct DualSenseOutputState: Equatable, Sendable {
    var rumbleLeft: UInt8 = 0   // low-freq / heavy motor
    var rumbleRight: UInt8 = 0  // high-freq / light motor
    var lightR: UInt8 = 0
    var lightG: UInt8 = 0
    var lightB: UInt8 = 0
    /// True once the host has sent a lightbar color this session. Until then we
    /// must NOT assert LIGHTBAR_CONTROL_ENABLE in an output write - doing so
    /// with the default (0,0,0) would blank a bar that gamecontrollerd/Sunshine
    /// already lit (the pre-first-color window an adaptive-trigger write hits).
    var lightSet: Bool = false
    /// 11 bytes each: [mode][10 params]. 0x00 mode = trigger off (neutral).
    var leftTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
    var rightTrigger: [UInt8] = [UInt8](repeating: 0, count: 11)
}

/// Reference-counted singleton owning one IOHIDManager for the DualSense raw
/// report. Both the live stream (InputForwarder) and the Troubleshooting input
/// test `retain()` it; it opens on the first retain and closes on the last
/// release. Single-pad assumption: the decoded button state applies to the
/// DualSense the user is holding (a Moonlight client streams one pad).
final class DualSenseHID: @unchecked Sendable {
    static let shared = DualSenseHID()

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "DualSenseHID")
    private let manager: IOHIDManager
    private let lock = NSLock()

    // All mutable state below is guarded by `lock`.
    private var buttonsLocked = DualSenseExtraButtons()
    private var retainCount = 0
    private var running = false
    // Per-device input-report buffers, kept alive while a device-level report
    // callback is registered. Keyed by the device's opaque pointer.
    private var deviceBuffers: [UnsafeMutableRawPointer: UnsafeMutablePointer<UInt8>] = [:]
    private let bufLen = 128 // ≥ 78 (BT) / 64 (USB)

    // Matched devices, kept so the OUTPUT-report write path (adaptive triggers)
    // can address them. Retained (a +1 from IOHIDManager's matching set isn't
    // guaranteed to outlive a callback), keyed by the same opaque pointer as
    // `deviceBuffers`. Bluetooth devices need report ID 0x31 + a trailing CRC32;
    // USB uses 0x02 with no CRC, so we cache each device's transport at match.
    private var writeDevices: [UnsafeMutableRawPointer: (device: IOHIDDevice, bluetooth: Bool)] = [:]
    /// Merged DualSense OUTPUT state. The 0x02/0x31 report carries lightbar +
    /// rumble + both trigger blocks together (all-or-nothing), so a trigger
    /// write MUST re-send the current lightbar + rumble or it would clobber
    /// them to zero. ControllerHaptics feeds lightbar/rumble here when raw-HID
    /// is live; setAdaptiveTriggers feeds the trigger blocks. Lock-guarded.
    private var outputState = DualSenseOutputState()
    /// Latch so the "SetReport refused" breadcrumb logs once, not per write
    /// (host re-arms triggers can arrive at frame rate).
    private var loggedWriteFailure = false
    /// Latch for the first successful OUTPUT write (proves the raw-HID write
    /// path reached the device).
    private var loggedWriteSuccess = false

    /// Serial queue for the IOKit OUTPUT-report writes. The host feedback
    /// callbacks fire on the enet receive thread; we hop here so a SetReport
    /// (which can block briefly) never stalls the control channel's ACK path,
    /// the same off-thread discipline ControllerHaptics uses for rumble.
    private let writeQueue = DispatchQueue(label: "io.ugfugl.Glimmer.dualsense-hid-write",
                                           qos: .userInitiated)

    /// Called on the main queue whenever the decoded buttons change - lets the
    /// input-test UI refresh. Set by the consumer; cleared on the last release.
    var onChange: (@MainActor () -> Void)?

    /// Total raw input reports received since the manager opened - a live
    /// "is the device delivering anything?" signal for the input test. Zero
    /// while Input Monitoring is denied.
    private var reportCountLocked = 0
    var reportCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reportCountLocked
    }

    /// Battery decoded from the HID status byte; nil until a report with a
    /// valid battery field arrives (the simple 10-byte BT report has none).
    private var batteryLocked: DualSenseBattery?
    var battery: DualSenseBattery? {
        lock.lock(); defer { lock.unlock() }
        return batteryLocked
    }

    /// Latest decoded button state (thread-safe snapshot).
    var buttons: DualSenseExtraButtons {
        lock.lock(); defer { lock.unlock() }
        return buttonsLocked
    }

    /// True while the IOHIDManager is open (someone holds a `retain()`). The
    /// battery uplink reads this to decide whether to trust the raw-HID battery
    /// decode (which only fills while the reader is live) over GCController's
    /// (which goes .unknown for a DualSense in enhanced-report mode).
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

    /// Opt-in gate (mirrors MoonlightManager.rawHIDControllerEnabled). Read
    /// from non-UI code (ControllerForwarder) so the raw-HID reader - and its
    /// Input Monitoring prompt - only ever engage when the user has turned the
    /// feature on in Settings.
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

    private func start() {
        // NOTE: we deliberately do NOT call IOHIDRequestAccess() here - it
        // BLOCKS the main thread while presenting the TCC prompt, which hung
        // the Troubleshooting pane. Permission is requested explicitly from the
        // enable flow / a "Grant" button instead. Opening without the grant
        // succeeds but silently delivers no reports.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // DEVICE-level input-report callbacks (registered per matched device in
        // the DeviceMatching callback, each with its own buffer). The
        // MANAGER-level report callback traps in IOKit because it has no
        // per-device buffer to hand the device applier. Scheduled on the main
        // run loop so the trivial report decode and the ControllerForwarder
        // reads share one thread.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // NON-exclusive (kIOHIDOptionsTypeNone): we never seize the pad - the
        // open is shared with gamecontrollerd so GCController keeps everything
        // it already provides (sticks/face/triggers/touchpad/rumble/light), and
        // we read the centre buttons + battery alongside it. A non-exclusive
        // open still permits IOHIDDeviceSetReport(Output) - the adaptive-trigger
        // write path below - for an already-matched device (degrades to a clean
        // no-op if the write is refused; see writeOutputReport).
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // NOTICE (was INFO): the open-rc + Input-Monitoring state is the one fact
        // that tells "are the DualSense centre buttons / battery actually
        // readable" - and it being INFO-only made the broken-quit-chord regression
        // un-diagnosable from shipped logs. Ship it.
        let monitoring = Self.accessGranted ? "granted"
            : (Self.accessDenied ? "DENIED" : "not-yet-determined")
        let usable = (rc == kIOReturnSuccess && Self.accessGranted)
        let buttonsState = usable ? "available"
            : "UNAVAILABLE (reports won't deliver until Input Monitoring is granted)"
        Diag.notice("DualSense HID open rc=0x\(String(rc, radix: 16)) inputMonitoring=\(monitoring) "
            + "- raw-HID centre buttons/battery \(buttonsState)", "Controller")
    }

    private func stop() {
        // Best-effort: park the triggers (and re-emit current light/rumble) so
        // a stream ending mid-effect doesn't strand a stiff trigger on the pad.
        // MUST run BEFORE IOHIDManagerClose - the SetReport needs the manager
        // (and the device's open) still live, and writeDevices still populated.
        resetTriggersBeforeClose()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // Close unregistered the device callbacks; now free the buffers.
        lock.lock()
        let bufs = deviceBuffers
        deviceBuffers.removeAll()
        writeDevices.removeAll()
        buttonsLocked = DualSenseExtraButtons()
        batteryLocked = nil
        reportCountLocked = 0
        outputState = DualSenseOutputState()
        lock.unlock()
        for (_, buf) in bufs { buf.deallocate() }
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
        // Transport classification for the OUTPUT report (USB 0x02 vs BT 0x31 +
        // CRC). kIOHIDTransportKey is a string like "USB" / "Bluetooth"; treat
        // anything that isn't plain USB as Bluetooth (covers "Bluetooth" and
        // "Bluetooth Low Energy"), the conservative choice since BT needs the
        // CRC the device would otherwise reject.
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let isBluetooth = !transport.localizedCaseInsensitiveContains("usb")
        lock.lock()
        guard deviceBuffers[key] == nil else { lock.unlock(); return }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        buf.initialize(repeating: 0, count: bufLen)
        deviceBuffers[key] = buf
        // Stored as a strong Swift reference - ARC retains the bridged CF
        // object for the lifetime of the map entry, so a SetReport can't race
        // device deallocation. (The `key` opaque pointer is only an identity
        // token, NOT the retain; do not switch this value to Unmanaged.)
        writeDevices[key] = (device: device, bluetooth: isBluetooth)
        lock.unlock()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, Self.reportCallback, ctx)
        log.info("DualSense HID device matched (transport=\(transport, privacy: .public))")
    }

    private func unregisterDevice(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock()
        let buf = deviceBuffers.removeValue(forKey: key)
        writeDevices.removeValue(forKey: key)
        lock.unlock()
        if let buf {
            IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, nil, nil)
            buf.deallocate()
        }
    }

    // MARK: Report decode

    // C-function-pointer-compatible (no captures). `report` is non-optional.
    private static let reportCallback: IOHIDReportCallback = { context, result, _, _, reportID, report, reportLength in
        guard result == kIOReturnSuccess, let context else { return }
        let me = Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue()
        me.decode(reportID: reportID, report: report, length: reportLength)
    }

    private func decode(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Locate the button bytes robustly. Some IOKit stacks strip the report
        // ID into `reportID` (so report[0] is the first payload byte); others
        // leave it at report[0]. Detect by sniffing report[0] for a known
        // DualSense report ID. Then:
        //   USB (0x01): [ID?] LX LY RX RY ...   → LX at (idPresent ? 1 : 0)
        //   BT  (0x31): [ID?] tag LX LY ...      → one extra tag byte before LX
        // Button bytes sit a fixed distance after LX (identical masks USB/BT,
        // per Linux hid-playstation / SDL ps5):
        //   buttons[1] (Create 0x10 / Options 0x20) at LX+8
        //   buttons[2] (PS 0x01 / Mute 0x04)         at LX+9
        let idPresent = length > 0 && (report[0] == 0x01 || report[0] == 0x31)
        let rid = idPresent ? UInt32(report[0]) : reportID
        let lxIndex = (idPresent ? 1 : 0) + (rid == 0x31 ? 1 : 0)
        let b1Index = lxIndex + 8
        let b2Index = lxIndex + 9
        guard length > b2Index else { return }

        let b1 = report[b1Index]
        let b2 = report[b2Index]
        var next = DualSenseExtraButtons()
        next.create = (b1 & 0x10) != 0
        next.options = (b1 & 0x20) != 0
        next.ps = (b2 & 0x01) != 0
        next.mute = (b2 & 0x04) != 0

        // Battery: the status byte sits 52 bytes past LX (SDL ps5 / Linux
        // hid-playstation). Low nibble = level 0...10 (percent ≈ level*10+5),
        // high nibble = charge state (1 = charging, 2 = full). The simple
        // 10-byte BT report has no battery field, so guard on length and on
        // the 0x0C "not reporting" sentinel.
        var nextBattery: DualSenseBattery?
        let statusIndex = lxIndex + 52
        if length > statusIndex {
            let status = report[statusIndex]
            let level = status & 0x0F
            if level != 0x0C {
                let charge = (status >> 4) & 0x0F
                let pct = (charge == 0x02) ? 100 : min(Int(level) * 10 + 5, 100)
                nextBattery = DualSenseBattery(percent: pct, charging: charge == 0x01 || charge == 0x02)
            }
        }

        lock.lock()
        if let nextBattery { batteryLocked = nextBattery }
        reportCountLocked += 1
        let changed = next != buttonsLocked
        buttonsLocked = next
        let notify = onChange
        lock.unlock()

        if changed, let notify {
            DispatchQueue.main.async { MainActor.assumeIsolated { notify() } }
        }
    }

    // MARK: OUTPUT report (adaptive triggers + lightbar/rumble merge)
    //
    // The DualSense OUTPUT report (0x02 over USB, 0x31 + CRC over Bluetooth) is
    // all-or-nothing: rumble, lightbar, and BOTH adaptive-trigger blocks ride
    // ONE report. So every write re-emits the full merged `outputState`. We own
    // adaptive triggers exclusively (GameController has no API for them); we
    // re-emit the host's last lightbar + rumble alongside so a trigger update
    // doesn't zero them. (Wire facts: SDL SDL_hidapi_ps5.c DS5EffectsState_t,
    // Sunshine adaptive-trigger pass-through, Linux hid-playstation.c CRC seed.)

    /// Apply a host SET_ADAPTIVE_TRIGGERS (0x5503) to the open DualSense. Only
    /// the trigger blocks whose `eventFlags` bit is set are updated (the other
    /// is left at its current state); `typeLeft`/`typeRight` are the
    /// DualSense-native mode bytes and `left`/`right` are the 10 param bytes -
    /// passed straight through (moonlight-qt's shape). A no-op when no device is
    /// open or the write is refused.
    func setAdaptiveTriggers(eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8,
                             left: [UInt8], right: [UInt8]) {
        // DS_EFFECT_RIGHT_TRIGGER 0x04 / DS_EFFECT_LEFT_TRIGGER 0x08.
        let wantRight = (eventFlags & 0x04) != 0
        let wantLeft = (eventFlags & 0x08) != 0
        guard wantRight || wantLeft else { return }
        lock.lock()
        if wantLeft { outputState.leftTrigger = Self.triggerBlock(mode: typeLeft, params: left) }
        if wantRight { outputState.rightTrigger = Self.triggerBlock(mode: typeRight, params: right) }
        lock.unlock()
        scheduleWrite()
    }

    /// Feed the host's latest lightbar color into the merged output state
    /// (called by ControllerHaptics when raw-HID is live). Does NOT itself
    /// write - the lightbar still rides GameController's GCDeviceLight; this
    /// only keeps our merge current so an adaptive-trigger write re-emits the
    /// right color instead of blanking the bar.
    func setLightbarState(red: UInt8, green: UInt8, blue: UInt8) {
        lock.lock()
        outputState.lightR = red; outputState.lightG = green; outputState.lightB = blue
        outputState.lightSet = true
        lock.unlock()
    }

    /// Feed the host's latest rumble pair into the merged output state (8-bit,
    /// already down-scaled from the 16-bit wire by the caller). Merge-only, like
    /// setLightbarState - rumble itself still rides GameController haptics.
    func setRumbleState(left: UInt8, right: UInt8) {
        lock.lock()
        outputState.rumbleLeft = left; outputState.rumbleRight = right
        lock.unlock()
    }

    /// Park the triggers to neutral and re-emit, called from stop() while the
    /// device is still open. Best-effort - a refused write is fine, the pad
    /// loses power on disconnect anyway.
    private func resetTriggersBeforeClose() {
        lock.lock()
        let hadDevice = !writeDevices.isEmpty
        outputState.leftTrigger = [UInt8](repeating: 0, count: 11)
        outputState.rightTrigger = [UInt8](repeating: 0, count: 11)
        lock.unlock()
        guard hadDevice else { return }
        // Synchronous on the write queue so it completes before the manager
        // closes underneath us (stop() clears writeDevices right after).
        writeQueue.sync { self.writeCurrentOutput() }
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

    private func scheduleWrite() {
        writeQueue.async { [weak self] in self?.writeCurrentOutput() }
    }

    /// Build the merged OUTPUT report from the current state and write it to
    /// every open device. Runs on `writeQueue`.
    private func writeCurrentOutput() {
        lock.lock()
        let state = outputState
        let devices = writeDevices
        lock.unlock()
        guard !devices.isEmpty else { return }
        for (_, entry) in devices {
            writeOutputReport(to: entry.device, bluetooth: entry.bluetooth, state: state)
        }
    }

    /// The 47-byte DS5EffectsState payload (the report DATA after any report-ID
    /// / BT magic byte). Offsets are SDL's DS5EffectsState_t. We set the
    /// enable/valid flags for rumble + lightbar + the LED effect, and copy both
    /// trigger blocks unconditionally (the device applies them when present -
    /// there is no separate trigger valid-flag bit in SDL / mainline Linux).
    private static func effectsState(_ s: DualSenseOutputState) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 47)
        // valid_flag0: COMPATIBLE_VIBRATION 0x01 | HAPTICS_SELECT 0x02 - enable
        // the rumble motor bytes. (0,0) here is a harmless "motors off"; the
        // DualSense's CHHaptics voice-coil path is separate, so we never fight
        // the live rumble GameController drives.
        d[0] = 0x01 | 0x02
        d[2] = s.rumbleRight   // ucRumbleRight (high-freq)
        d[3] = s.rumbleLeft    // ucRumbleLeft  (low-freq)
        // valid_flag1: LIGHTBAR_CONTROL_ENABLE 0x04 - ONLY when the host has set
        // a color this session. Asserting it with the default (0,0,0) would
        // blank a bar gamecontrollerd/Sunshine already lit before the first
        // SET_RGB_LED (see DualSenseOutputState.lightSet). Until then we leave
        // the LED bytes + flag at zero so the bar is left untouched.
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
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID),
                                 buf.baseAddress!, buf.count)
        }
        if rc == kIOReturnSuccess {
            if !loggedWriteWasSuccessful() {
                log.info("DualSense OUTPUT report write OK (transport=\(bluetooth ? "BT" : "USB", privacy: .public)) - adaptive triggers live")
            }
        } else if !loggedWriteWasRefused() {
            // SAFETY no-op: a refused write (e.g. kIOReturnNotPermitted, or an
            // exclusive grab by gamecontrollerd) degrades to "no adaptive
            // triggers". Everything else - the read path, buttons, battery - is
            // unaffected. Logged once so the verdict is in the log.
            log.error("DualSense OUTPUT report write refused rc=0x\(String(UInt32(bitPattern: rc), radix: 16), privacy: .public) - adaptive triggers disabled (degraded no-op)")
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

    /// CRC32 over the DualSense Bluetooth OUTPUT report: seed byte 0xA2, then
    /// the report-ID byte, then the report data up to (not including) the 4 CRC
    /// bytes. Standard IEEE 802.3 CRC32 (reflected, poly 0xEDB88320), the
    /// algorithm SDL/Linux use for the BT effects report. Computed on the fly
    /// (no static table) - this runs at most a few times per second.
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
