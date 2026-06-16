//
//  ControllerBattery.swift
//
//  Controller battery, every direction it is consumed: the host uplink that
//  makes LI_CCAP_BATTERY_STATE an honest advertisement (the
//  LiSendControllerBatteryEvent path — the host mirrors the reading onto its
//  emulated pad), and the local UI reads — stats-overlay row, menu-bar charm,
//  controller-test badge — which all resolve through uiReading() below
//  (moved from ControllerForwarder so everything battery, including the
//  sentinel honesty rules, lives in exactly one file and cannot drift).
//
//  PROTOCOL (verified against moonlight-common-c + Sunshine master):
//   * Packet: SS_CONTROLLER_BATTERY_PACKET (Input.h), magic 0x55000007 — see
//     InputEncoder.controllerBattery for the byte layout.
//   * Gate: LiSendControllerBatteryEvent (InputStream.c) checks ONLY
//     `initialized` + IS_SUNSHINE — unlike touch/motion there is NO LI_FF_*
//     feature-flag requirement, and Sunshine's handler (input.cpp) accepts
//     the packet for any allocated pad without re-checking the advertised
//     caps. Channel: CTRL_CHANNEL_GAMEPAD_BASE + controllerNumber, reliable.
//   * States (Limelight.h): GameController maps onto full/charging/
//     discharging/unknown; percentage is batteryLevel * 100 with
//     LI_BATTERY_PERCENTAGE_UNKNOWN for an unreadable level.
//
//  CADENCE mirrors moonlight-ios ControllerSupport.m (the only upstream
//  client on the GCDeviceBattery API): a 30-second poll with send-on-change
//  suppression — battery moves glacially, and GCDeviceBattery is not
//  documented KVO-compliant, so polling is the upstream-proven shape. One
//  shared timer scans all pads (per-pad timers are the motion sampler's
//  shape, needed there because the HOST tunes each sensor's rate; battery
//  has one fixed client-chosen cadence). On top of the poll, every arrival
//  announcement sends a baseline immediately, so the host never waits a poll
//  period to learn the state — and since setReady(true) replays arrivals,
//  each new stream session gets its own fresh baseline.
//
//  THREADING: all mutable state is MainActor-confined (GameController's home
//  isolation in this codebase). Every entry point is called from the
//  forwarder (main) or the main-queue timer.
//

import Foundation
import GameController

/// Singleton monitor: ControllerForwarder registers slot→pad on attach (the
/// registration probe is also where the LI_CCAP_BATTERY_STATE bit comes
/// from) and announces a baseline behind each arrival event; a shared 30s
/// poll forwards changes for as long as the pad stays attached.
/// `@unchecked Sendable`: every entry point is @MainActor.
final class ControllerBattery: @unchecked Sendable {
    static let shared = ControllerBattery()
    static let logCategory = "Controller"

    /// Poll cadence — moonlight-ios's 30-second batteryTimer.
    private static let pollSeconds: Double = 30

    // MARK: - MainActor-confined state

    /// slot (the forwarder's 0..15 controllerNumber) → reporting state.
    @MainActor private var pads: [UInt8: Pad] = [:]
    /// The live stream's input uplink. Battery is deliberately NOT a
    /// StreamingBackend requirement: NativeBackend is the only backend, and
    /// widening the protocol for a report only the native wire carries would
    /// be ceremony — so the monitor binds to the native uplink directly (the
    /// one downcast lives in announce()). If a second backend ever appears,
    /// promote sendControllerBattery to a requirement like
    /// sendControllerMotion. Weak: the backend's lifetime belongs to
    /// StreamSession; a torn-down stream simply stops the reports.
    @MainActor private weak var uplink: NativeBackend?
    /// The shared poll timer; nil while no battery pad is registered.
    @MainActor private var timer: DispatchSourceTimer?
    /// First-failure-per-code log latch for report() sends (the
    /// InputForwarder.loggedFailureCodes pattern). Never cleared: rc codes
    /// are a tiny closed set, and once per process is exactly the desired
    /// "visible but can't flood" bound.
    @MainActor private var loggedReportFailureCodes: Set<Int32> = []

    private init() {}

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Probe the pad for a battery and map `slot` for reporting. Returns the
    /// LI_CCAP_BATTERY_STATE bit to ADVERTISE — 0 when the pad exposes no
    /// GCDeviceBattery — so the cap promised is a cap delivered.
    /// Registration alone sends nothing; reports start at announce() or the
    /// next poll tick.
    @MainActor
    func register(slot: UInt8, controller: GCController) -> UInt16 {
        // A re-attach can reuse a slot before detach bookkeeping settles;
        // drop any stale entry so the swap can't inherit its suppression.
        unregister(slot: slot)
        guard controller.battery != nil else {
            // Bounded by attach frequency. A declined probe used to be fully
            // silent, making "no reports all session" unadjudicable: nil here
            // (flaky BT battery exposure) vs every send failing. With this
            // and the report() failure breadcrumb, the next session answers.
            Diag.info("controller \(slot) exposes no battery "
                + "(\(controller.vendorName ?? "Unknown")) — battery cap not advertised",
                Self.logCategory)
            return 0
        }
        pads[slot] = Pad(controller: controller)
        startTimerIfNeeded()
        return UInt16(StreamProtocol.LI_CCAP_BATTERY_STATE)
    }

    /// Drop a slot's mapping (controller detach / deallocation). No farewell
    /// packet: the host retires the whole pad via the detach
    /// multiController event, battery state included. The last pad out also
    /// cancels the poll, so an idle app burns no timer.
    @MainActor
    func unregister(slot: UInt8) {
        guard pads.removeValue(forKey: slot) != nil else { return }
        if pads.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Arrival baseline (ControllerForwarder.sendArrival, main thread)

    /// Arm the uplink and send `slot`'s baseline reading right behind its
    /// arrival event: the host learns the pad exists, then what its battery
    /// holds, without waiting up to a poll period. Clearing the suppression
    /// latch first guarantees the send even when the reading hasn't changed
    /// since a previous session — a new host has seen none of them.
    @MainActor
    func announce(slot: UInt8, backend: StreamingBackend?) {
        // Arm/refresh the uplink even when THIS pad has no battery; the
        // arrival replay at stream start must arm it for the pads that do.
        uplink = backend as? NativeBackend
        guard let pad = pads[slot] else { return }
        pad.lastSent = nil
        report(slot: slot, pad: pad)
    }

    // MARK: - Poll (main)

    /// Start the shared scan timer on first registration. Coarse leeway:
    /// battery cadence tolerates any coalescing the OS wants.
    @MainActor
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now() + Self.pollSeconds,
                      repeating: Self.pollSeconds,
                      leeway: .seconds(5))
        poll.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (slot, pad) in self.pads { self.report(slot: slot, pad: pad) }
            }
        }
        timer = poll
        poll.resume()
    }

    /// Read → map → duplicate-suppress → send one pad's reading. `lastSent`
    /// latches ONLY on a queued send (rc 0): a -2 between streams must not
    /// suppress the same reading from reaching the NEXT session (announce
    /// clears the latch too — this is the belt to that braces).
    @MainActor
    private func report(slot: UInt8, pad: Pad) {
        guard let backend = uplink else { return }
        // Prefer the raw-HID battery for a DualSense whose HID reader is live:
        // opening the pad over raw HID puts it in enhanced-report mode, which
        // makes gamecontrollerd drop the GCDeviceBattery field — `battery` goes
        // .unknown/nil exactly when DualSenseHID is running (see DualSenseHID's
        // header). DualSenseHID decodes a REAL level + charge state from the
        // status byte itself, so route that to the host when available and fall
        // back to GCController.battery otherwise (Xbox, or DualSense without the
        // opt-in raw-HID feature on).
        guard let reading = hidReading(for: pad) ?? pad.controller?.battery.map(Self.wireReading)
        else { return }
        if let last = pad.lastSent, last == reading { return }
        let rc = backend.sendControllerBattery(num: slot, state: reading.state,
                                               percentage: reading.percentage)
        guard rc == 0 else {
            // First failure per rc code (the InputForwarder.record discipline):
            // this path was fully silent, which left a whole session's missing
            // battery reports unadjudicable — uplink failing vs pad never
            // mapped. Once per code keeps a persistent -1 burst out of the ring.
            if !loggedReportFailureCodes.contains(rc) {
                loggedReportFailureCodes.insert(rc)
                Diag.info("controller \(slot) battery report failed (rc \(rc)); "
                    + "suppressing repeats of this code", Self.logCategory)
            }
            return
        }
        pad.lastSent = reading
        if reading.state == UInt8(StreamProtocol.LI_BATTERY_STATE_UNKNOWN),
           reading.percentage == UInt8(StreamProtocol.LI_BATTERY_PERCENTAGE_UNKNOWN) {
            // The no-data sentinel is NOT a reading — say so, instead of the
            // old "battery reported: unknown 0%" that read like a real (and
            // alarming) empty battery. The wire still carries it (an honest
            // UNKNOWN/0xFF the host may mirror); real data arrives via
            // send-on-change at a later poll. Only truly level-less pads
            // (Xbox over BT) land here now — an unknown STATE with a real
            // level (DualSense: 0.95/.unknown) takes the other branch and
            // logs "unknown N%", percentage on the wire from the baseline.
            Diag.info("controller \(slot) battery: not reported", Self.logCategory)
        } else {
            Diag.info("controller \(slot) battery reported: \(Self.label(reading))",
                      Self.logCategory)
        }
    }

    // MARK: - Raw-HID (DualSense) battery → wire mapping

    /// The wire reading from the raw-HID DualSense decode, or nil when this pad
    /// is not a DualSense, the raw-HID reader is not live, or no battery report
    /// has been decoded yet. Single-pad assumption matches DualSenseHID's: the
    /// decoded battery belongs to the DualSense the user is holding. The HID
    /// decode carries percent + charging directly, so map it straight onto the
    /// FULL/CHARGING/DISCHARGING states the wire wants (no .unknown-with-level
    /// corner — the raw status byte always gives a real percent when present).
    @MainActor
    private func hidReading(for pad: Pad) -> (state: UInt8, percentage: UInt8)? {
        guard pad.controller?.extendedGamepad is GCDualSenseGamepad,
              DualSenseHID.shared.isActive,
              let hid = DualSenseHID.shared.battery else { return nil }
        // `DualSenseBattery.charging` collapses the decode's "charging" (charge
        // nibble 0x01) and "full" (0x02) into one Bool, so a pad charging at
        // level 10 is indistinguishable from a full one. Report CHARGING for
        // both rather than fabricate a FULL the pad may not have reached — the
        // percentage carries the real level, and DISCHARGING otherwise.
        let state: Int32 = hid.charging ? StreamProtocol.LI_BATTERY_STATE_CHARGING
                                        : StreamProtocol.LI_BATTERY_STATE_DISCHARGING
        let pct = UInt8(min(max(hid.percent, 0), 100))
        return (UInt8(state), pct)
    }

    // MARK: - GCDeviceBattery → wire mapping

    /// State mapping is moonlight-ios ControllerSupport.m's: full/charging/
    /// discharging map 1:1, anything else (including .unknown) is UNKNOWN —
    /// GameController can't distinguish NOT_PRESENT/NOT_CHARGING.
    ///
    /// Percentage HONESTY: macOS reports "no battery data" as batteryState
    /// .unknown + batteryLevel 0.0 — NOT the negative level the moonlight-ios
    /// mapping guards (proven in session logs: every no-data pad printed
    /// "unknown 0%", never "?%", so 0 was going on the wire and Sunshine
    /// mirrored a false empty battery onto the emulated pad). But an UNKNOWN
    /// state does NOT condemn the level: a DualSense on this Mac was probed
    /// at batteryLevel 0.95 with state .unknown — the OS knows the charge,
    /// just not the charging direction. So state and percentage are judged
    /// independently: UNKNOWN state with a positive level sends the REAL
    /// percentage (the host UI can still show a number), and only UNKNOWN
    /// with level <= 0 — indistinguishable from the no-data sentinel — sends
    /// LI_BATTERY_PERCENTAGE_UNKNOWN. A genuine dying pad still reads
    /// honestly: discharging + 0.0 is a REAL (discharging, 0%) reading, and
    /// the negative-level guard stays as belt-and-braces for the documented
    /// -1 sentinel.
    @MainActor
    private static func wireReading(_ battery: GCDeviceBattery) -> (state: UInt8, percentage: UInt8) {
        let state: Int32
        switch battery.batteryState {
        case .full: state = StreamProtocol.LI_BATTERY_STATE_FULL
        case .charging: state = StreamProtocol.LI_BATTERY_STATE_CHARGING
        case .discharging: state = StreamProtocol.LI_BATTERY_STATE_DISCHARGING
        default: state = StreamProtocol.LI_BATTERY_STATE_UNKNOWN
        }
        let level = battery.batteryLevel
        let percentage: UInt8
        if levelIsReal(level, stateIsKnown: state != StreamProtocol.LI_BATTERY_STATE_UNKNOWN) {
            percentage = UInt8((min(level, 1) * 100).rounded())
        } else {
            percentage = UInt8(StreamProtocol.LI_BATTERY_PERCENTAGE_UNKNOWN)
        }
        return (UInt8(state), percentage)
    }

    /// The ONE level-validity rule, shared by the wire mapping and the local
    /// UI mapping so the consumers can't drift apart:
    ///  * known state: level >= 0 is real — discharging + 0.0 IS an empty
    ///    battery; only the documented -1 "unreadable" sentinel is invalid.
    ///  * .unknown state: the level must be STRICTLY positive. .unknown + 0.0
    ///    is macOS's no-data shape (every Xbox BT pad, all session), and a
    ///    real dead-flat pad at exactly 0.0 is indistinguishable from it. We
    ///    eat that corner deliberately: a missing number self-heals on the
    ///    next poll/repaint once the OS reports data, but a fabricated "0%"
    ///    alarm was the soak's measured fault.
    private static func levelIsReal(_ level: Float, stateIsKnown: Bool) -> Bool {
        stateIsKnown ? level >= 0 : level > 0
    }

    // MARK: - GCDeviceBattery → local UI mapping

    /// wireReading's local twin: the single honest source for every UI that
    /// shows controller battery (stats-overlay row, menu-bar charm,
    /// controller-test badge). nil means render NOTHING — each UI's nil
    /// branch already exists (em-dash, hidden charm, "No battery info"),
    /// whereas the unguarded reads turned macOS's .unknown + 0.0 no-data
    /// sentinel into an alarming orange "0%".
    ///
    /// `charging` is nil for the UNKNOWN-state-with-real-level case (the
    /// DualSense 0.95/.unknown probe): the level deserves showing, but
    /// claiming "Charging" or "On battery" would be invented — callers
    /// render the bare percentage with no charging adornment. Nothing here
    /// latches: every consumer re-reads on its own cadence (1Hz overlay
    /// tick, menu open, 30Hz test repaint), so the full reading appears the
    /// moment macOS starts reporting state.
    @MainActor
    static func uiReading(_ battery: GCDeviceBattery) -> (percent: Int, charging: Bool?)? {
        let stateIsKnown = battery.batteryState != .unknown
        guard levelIsReal(battery.batteryLevel, stateIsKnown: stateIsKnown) else {
            // Covers BOTH sentinels: .unknown + level <= 0 (no data) and a
            // known state + negative level (-1 "unreadable"). The wire can
            // still carry a bare state in the latter; a percent-shaped UI
            // cannot, so it shows nothing rather than a fabricated number.
            return nil
        }
        let percent = Int((min(battery.batteryLevel, 1) * 100).rounded())
        return (percent, stateIsKnown ? battery.batteryState == .charging : nil)
    }

    /// Human label for a wire reading in breadcrumbs.
    private static func label(_ reading: (state: UInt8, percentage: UInt8)) -> String {
        let name: String
        switch Int32(reading.state) {
        case StreamProtocol.LI_BATTERY_STATE_FULL: name = "full"
        case StreamProtocol.LI_BATTERY_STATE_CHARGING: name = "charging"
        case StreamProtocol.LI_BATTERY_STATE_DISCHARGING: name = "discharging"
        default: name = "unknown"
        }
        let pct = reading.percentage == UInt8(StreamProtocol.LI_BATTERY_PERCENTAGE_UNKNOWN)
            ? "?" : "\(reading.percentage)"
        return "\(name) \(pct)%"
    }

    // MARK: - Per-pad state

    /// Constructed and mutated exclusively on the main actor.
    @MainActor
    private final class Pad {
        /// Weak: GameController owns the pad's lifetime; a disconnect must
        /// deallocate it even if our unregister is still in flight.
        weak var controller: GCController?
        /// Last reading the host actually got, for send-on-change suppression.
        var lastSent: (state: UInt8, percentage: UInt8)?

        init(controller: GCController) { self.controller = controller }
    }
}

// MARK: - NativeBackend battery uplink

extension NativeBackend {
    /// = LiSendControllerBatteryEvent (InputStream.c). Routes the report
    /// through the batcher's quiet pass-through (ordering preserved, no
    /// input-activity stamp — a device report is not user input) on the
    /// pad's gamepad channel, the C's channel choice. Deliberately NO
    /// feature-flag gate: unlike touch/motion, the C checks only
    /// `initialized` (readyBatcher here) and IS_SUNSHINE (structural — this
    /// wire only speaks Sunshine). Lives here, not NativeBackend+Input.swift,
    /// so the battery uplink reads end-to-end in this file.
    public func sendControllerBattery(num: UInt8, state: UInt8, percentage: UInt8) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        return batcher.passThroughReport(
            InputEncoder.controllerBattery(num: num, state: state, percentage: percentage),
            channel: gamepadChannel(Int(num)))
    }
}

// MARK: - Local overlay read (StreamSession+Watchdog)

extension InputForwarder {
    /// First attached controller's REAL battery reading as
    /// (percent 0...100, charging), or nil when none has one. `charging` nil
    /// is the unknown-state-with-real-level case — the overlay's formatter
    /// already renders that as the bare "N %" with no "Charging"/"On
    /// battery" claim, exactly the honesty uiReading encodes. Pads carrying
    /// the no-data sentinel are SKIPPED rather than rendered as 0%, so a
    /// second pad with real data still gets the row. Read from our own
    /// attached set rather than the global `GCController.controllers()`
    /// registry so we report the pad the stream is actually using. Lives
    /// here (moved from ControllerForwarder) so the overlay read and the
    /// host uplink — the same GCDeviceBattery, two consumers — sit in one
    /// file.
    func currentControllerBattery() -> (percent: Int, charging: Bool?)? {
        for state in attachedControllers.values {
            guard let batt = state.controller?.battery,
                  let reading = ControllerBattery.uiReading(batt) else { continue }
            return reading
        }
        return nil
    }
}
