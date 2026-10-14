// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Main-actor battery policy, with native state supplied by prepared probes and sampling shared across
/// registered slots.
package final class ControllerBattery: @unchecked Sendable {
    package static let logCategory = "Controller"

    /// Poll cadence - moonlight-ios's 30-second batteryTimer.
    private static let pollSeconds: Double = 30

    // MARK: - MainActor-confined state

    /// slot (the forwarder's 0..15 controllerNumber) → reporting state.
    @MainActor private var pads: [UInt8: Pad] = [:]
    /// Retain the live input uplink only while active. Battery state uses the same existing input
    /// channel as controller feedback.
    @MainActor private weak var uplink: NativeBackend?
    /// The shared poll timer; nil while no battery pad is registered.
    @MainActor private var timer: DispatchSourceTimer?
    /// Log the first send failure per code; clear the latch for a fresh active stream.
    @MainActor private var loggedReportFailureCodes: Set<Int32> = []

    package init() {}

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Register prepared capture capabilities and the slot mapping; native probing remains with the
    /// adapter.
    @MainActor
    package func register(slot: UInt8, capture: ControllerBatteryCapture, token: UUID = UUID()) -> UInt16 {
        unregister(slot: slot)
        pads[slot] = Pad(capture: capture, token: token)
        startTimerIfNeeded()
        return UInt16(StreamProtocol.LI_CCAP_BATTERY_STATE)
    }

    /// Unregister a slot without sending a farewell reading. Exact tokens prevent delayed teardown from
    /// removing a replacement.
    @MainActor
    package func unregister(slot: UInt8, token: UUID? = nil) {
        if let token, pads[slot]?.token != token { return }
        guard pads.removeValue(forKey: slot) != nil else { return }
        if pads.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Arrival baseline (ControllerForwarder.sendArrival, main thread)

    /// Send the initial battery reading after successful controller arrival, then use the existing
    /// shared poll cadence.
    @MainActor
    package func announce(slot: UInt8, backend: StreamingBackend?) {
        // Arm/refresh the uplink even when THIS pad has no battery; the
        // arrival replay at stream start must arm it for the pads that do.
        uplink = backend as? NativeBackend
        guard let pad = pads[slot] else { return }
        pad.lastSent = nil
        report(slot: slot, pad: pad)
    }

    @MainActor
    package func stopAll() {
        timer?.cancel()
        timer = nil
        pads.removeAll()
        uplink = nil
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
            MainActor.assumeIsolated { self?.pollTick() }
        }
        timer = poll
        poll.resume()
    }

    /// One poll: report every registered pad. The timer's body; tests call it directly.
    @MainActor
    package func pollTick() {
        for (slot, pad) in pads { report(slot: slot, pad: pad) }
    }

    /// Read, map and suppress duplicate battery values; update lastSent only after the backend accepts
    /// the reading.
    @MainActor
    private func report(slot: UInt8, pad: Pad) {
        guard let backend = uplink else { return }
        // The native probe chooses its authoritative source. Shared policy handles unknown data and
        // protocol conversion consistently.
        guard let sample = pad.capture.read() else { return }
        let reading = Self.wireReading(sample)
        if let last = pad.lastSent, last == reading { return }
        let rc = backend.sendControllerBattery(num: slot, state: reading.state,
                                               percentage: reading.percentage)
        guard rc == 0 else {
            // Log each send failure code once; a persistent failure must not add a recurring notice.
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
            // Unknown/no-data is distinct from an empty battery. Preserve the sentinel until the native
            // probe supplies a usable reading.
            Diag.info("controller \(slot) battery: not reported", Self.logCategory)
        } else {
            Diag.info("controller \(slot) battery reported: \(Self.label(reading))",
                      Self.logCategory)
        }
    }

    // MARK: - GCDeviceBattery → wire mapping

    /// Preserve Moonlight battery states and percentage rounding. Unknown/no-data maps to the protocol
    /// sentinel rather than fabricated zero charge.
    @MainActor
    private static func wireReading(_ battery: ControllerBatterySample) -> (state: UInt8, percentage: UInt8) {
        let state: Int32
        switch battery.state {
        case .full: state = StreamProtocol.LI_BATTERY_STATE_FULL
        case .charging: state = StreamProtocol.LI_BATTERY_STATE_CHARGING
        case .discharging: state = StreamProtocol.LI_BATTERY_STATE_DISCHARGING
        default: state = StreamProtocol.LI_BATTERY_STATE_UNKNOWN
        }
        let level = battery.level
        let percentage: UInt8
        if levelIsReal(level, stateIsKnown: state != StreamProtocol.LI_BATTERY_STATE_UNKNOWN) {
            percentage = UInt8((min(level, 1) * 100).rounded())
        } else {
            percentage = UInt8(StreamProtocol.LI_BATTERY_PERCENTAGE_UNKNOWN)
        }
        return (UInt8(state), percentage)
    }

    /// Shared validity rule for protocol reports and native UI: negative/nonfinite levels and unknown
    /// zero values are unavailable.
    private static func levelIsReal(_ level: Float, stateIsKnown: Bool) -> Bool {
        level.isFinite && (stateIsKnown ? level >= 0 : level > 0)
    }

    // MARK: - GCDeviceBattery → local UI mapping

    /// The same state/level validity and mapping feeds local battery UI so diagnostics cannot disagree
    /// with the PC report.
    @MainActor
    package static func uiReading(_ battery: ControllerBatterySample) -> (percent: Int, charging: Bool?)? {
        let stateIsKnown = battery.state != .unknown
        guard levelIsReal(battery.level, stateIsKnown: stateIsKnown) else {
            // Both native unknown-zero and negative-level sentinels remain unavailable to the local UI.
            return nil
        }
        let percent = Int((min(battery.level, 1) * 100).rounded())
        return (percent, stateIsKnown ? battery.state == .charging : nil)
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
        /// Prepared capture closures retain only the native adapter lease.
        let capture: ControllerBatteryCapture
        let token: UUID
        /// Last reading the host actually got, for send-on-change suppression.
        var lastSent: (state: UInt8, percentage: UInt8)?

        init(capture: ControllerBatteryCapture, token: UUID) { self.capture = capture; self.token = token }
    }
}
