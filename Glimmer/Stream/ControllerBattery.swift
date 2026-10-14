// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController
import GlimmerEngine

extension ControllerBattery {
    static let shared = ControllerBattery()

    @MainActor
    func register(slot: UInt8, controller: GCController) -> UInt16 {
        guard controller.battery != nil
            || (controller.extendedGamepad is GCDualSenseGamepad && DualSenseHID.shared.isActive) else {
            unregister(slot: slot)
            Diag.info("controller \(slot) exposes no battery (\(controller.vendorName ?? "Unknown")) - battery cap not advertised",
                      Self.logCategory)
            return 0
        }
        return register(slot: slot, capture: ControllerBatteryCapture { [weak controller] in
            guard let controller else { return nil }
            if controller.extendedGamepad is GCDualSenseGamepad, DualSenseHID.shared.isActive,
               let hid = DualSenseHID.shared.state(for: ObjectIdentifier(controller))?.battery {
                return ControllerBatterySample(state: hid.charging ? .charging : .discharging,
                    level: Float(min(max(hid.percent, 0), 100)) / 100)
            }
            return controller.battery.map(Self.sample)
        })
    }

    @MainActor
    func register(slot: UInt8, hid: HIDGamepadDevice) -> UInt16 {
        guard hid.hasBattery else { unregister(slot: slot); return 0 }
        return register(slot: slot, capture: ControllerBatteryCapture { [weak hid] in
            hid?.batteryPercentage.map { ControllerBatterySample(state: .discharging, level: Float($0) / 100) }
        })
    }

    @MainActor
    static func sample(_ battery: GCDeviceBattery) -> ControllerBatterySample {
        let state: ControllerBatterySample.State
        switch battery.batteryState {
        case .full: state = .full
        case .charging: state = .charging
        case .discharging: state = .discharging
        default: state = .unknown
        }
        return ControllerBatterySample(state: state, level: battery.batteryLevel)
    }

    @MainActor
    static func uiReading(_ battery: GCDeviceBattery) -> (percent: Int, charging: Bool?)? {
        uiReading(sample(battery))
    }
}

// MARK: - Local overlay read (StreamSession+Watchdog)

extension InputForwarder {
    /// First attached controller's REAL battery reading as
    /// (percent 0...100, charging), or nil when none has one. `charging` nil
    /// is the unknown-state-with-real-level case - the overlay's formatter
    /// already renders that as the bare "N %" with no "Charging"/"On
    /// battery" claim, exactly the honesty uiReading encodes. Pads carrying
    /// the no-data sentinel are SKIPPED rather than rendered as 0%, so a
    /// second pad with real data still gets the row. Read from our own
    /// attached set rather than the global `GCController.controllers()`
    /// registry so we report the pad the stream is actually using. Lives
    /// here (moved from ControllerForwarder) so the overlay read and the
    /// host uplink - the same GCDeviceBattery, two consumers - sit in one
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
