//
//  ControllerInputTestView.swift
//
//  The Troubleshooting controller input test: a live 30 Hz view of every
//  connected controller's buttons, sticks, triggers, and touchpad. Split out
//  of TroubleshootingPane.swift to keep each file focused.
//

import AppKit
import GameController
import SwiftUI

/// Drives a live view of connected controllers. macOS's GameController
/// framework only refreshes an element's polled value once an app has
/// registered a value-changed handler on that controller - passive polling
/// reads nothing (which is why this test showed a controller but no button
/// reaction). This monitor registers a lightweight handler that bumps
/// `revision` to refresh the SwiftUI view, and tears it down on disappear. It
/// refuses to engage while a stream is live so it can't steal the
/// StreamSession's input handlers.
@MainActor @Observable
final class ControllerMonitor {
    private(set) var revision = 0
    /// Live count of GameController value-changed callbacks - the diagnostic
    /// for "does GameController deliver input to us in this context at all?"
    private(set) var gcEventCount = 0
    private var observers: [NSObjectProtocol] = []
    private var engaged: [ObjectIdentifier: GCController] = [:]
    private var hidRetained = false
    private let isStreaming: () -> Bool

    init(isStreaming: @escaping () -> Bool) { self.isStreaming = isStreaming }

    func start() {
        GCController.startWirelessControllerDiscovery {}
        // Receive controller input even though the Settings window - not a
        // game window - is key. Without this, GameController appears to deliver
        // nothing to a non-game foreground context (GC events stay 0).
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engage() }
            })
        }
        // Raw-HID side-channel for the DualSense center buttons (Options /
        // Create / Mute) that GameController doesn't deliver - same source the
        // stream uses. ONLY when the user has opted in (gates the Input
        // Monitoring prompt). Refresh the view when they change.
        // Don't install during a live stream: onChange is a single-owner slot the
        // stream's ControllerForwarder holds, so grabbing it here would drop the
        // stream's center-button uplink until a resync.
        if DualSenseHID.isEnabled, !isStreaming() {
            DualSenseHID.shared.onChange = { [weak self] in self?.revision &+= 1 }
            DualSenseHID.shared.retain()
            hidRetained = true
        }
        engage()
    }

    private func engage() {
        guard !isStreaming() else { revision &+= 1; return }
        for controller in GCController.controllers() {
            let id = ObjectIdentifier(controller)
            guard engaged[id] == nil else { continue }
            controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.gcEventCount &+= 1
                    self?.revision &+= 1
                }
            }
            engaged[id] = controller
        }
        revision &+= 1
    }

    func stop() {
        for (_, controller) in engaged { controller.extendedGamepad?.valueChangedHandler = nil }
        engaged.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        if hidRetained {
            DualSenseHID.shared.onChange = nil
            DualSenseHID.shared.release()
            hidRetained = false
        }
    }
}

struct ControllerInputTest: View {
    @Environment(MoonlightManager.self) private var moonlight
    @State private var monitor: ControllerMonitor?

    var body: some View {
        // Reading monitor.revision establishes the @Observable dependency, so a
        // value-changed handler firing re-renders this view (which then reads
        // the now-live element values).
        // Poll on a 30 Hz timeline so the chips reflect live element state.
        // (Input IS arriving - the counters prove it - but a revision-based
        // re-render wasn't repainting the chips; a timeline is reliable.)
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let pads = GCController.controllers()
            VStack(alignment: .leading, spacing: 12) {
                diagnosticLine
                if pads.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(pads.enumerated()), id: \.offset) { _, pad in
                        ControllerCard(pad: pad, tick: context.date)
                    }
                }
            }
        }
        .onAppear {
            let monitor = ControllerMonitor(isStreaming: { moonlight.isStreaming })
            monitor.start()
            self.monitor = monitor
        }
        .onDisappear {
            monitor?.stop()
            monitor = nil
        }
    }

    /// Live "is anything arriving?" readout (re-read by the parent timeline).
    /// GameController events count value-changed callbacks; HID reports count
    /// raw DualSense reports - so if a chip never lights you can still see
    /// whether input is reaching the app at all.
    private var diagnosticLine: some View {
        let gc = monitor?.gcEventCount ?? 0
        let hid = DualSenseHID.shared.reportCount
        return Label("GameController events: \(gc)  •  HID reports: \(hid)",
                     systemImage: "waveform.path.ecg")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No controller connected").fontWeight(.medium)
                Text("Pair a controller over Bluetooth or plug it in - it'll "
                    + "appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct ControllerCard: View {
    let pad: GCController
    /// Changes every TimelineView tick. `pad` is a stable object reference, so
    /// without a value-typed input that actually changes, SwiftUI considers
    /// this view unchanged and skips re-evaluating `body` - the chips would
    /// never repaint even as the controller state changes. Reading `tick` in
    /// `body` ties the repaint to the timeline.
    let tick: Date

    /// PlayStation pads label face buttons ✕○□△; everything else (Xbox, MFi,
    /// generic) uses A/B/X/Y. The underlying GCExtendedGamepad.buttonA/B/X/Y
    /// are physical-position-stable, so only the glyphs differ.
    private var isPlayStation: Bool {
        let category = pad.productCategory
        return category == GCProductCategoryDualSense || category == GCProductCategoryDualShock4
    }

    var body: some View {
        _ = tick // tie the repaint to the timeline (see `tick`)
        return VStack(alignment: .leading, spacing: 12) {
            header
            if let gp = pad.extendedGamepad {
                buttonsRow(gp)
                HStack(alignment: .top, spacing: 18) {
                    StickPad(label: "L",
                             x: gp.leftThumbstick.xAxis.value, y: gp.leftThumbstick.yAxis.value,
                             clicked: gp.leftThumbstickButton?.isPressed ?? false)
                    StickPad(label: "R",
                             x: gp.rightThumbstick.xAxis.value, y: gp.rightThumbstick.yAxis.value,
                             clicked: gp.rightThumbstickButton?.isPressed ?? false)
                    VStack(spacing: 8) {
                        TriggerBar(label: "L2", value: gp.leftTrigger.value)
                        TriggerBar(label: "R2", value: gp.rightTrigger.value)
                    }
                }
                if let tp = touchpad(of: gp) {
                    TouchpadView(fingers: [
                        TouchPoint(x: tp.primary.xAxis.value, y: tp.primary.yAxis.value),
                        TouchPoint(x: tp.secondary.xAxis.value, y: tp.secondary.yAxis.value)
                    ], clicked: tp.button.isPressed)
                }
            } else {
                Text("Connected, but exposes no extended-gamepad profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(pad.vendorName ?? "Controller").fontWeight(.semibold)
                Text(pad.productCategory).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            BatteryBadge(reading: batteryReading)
        }
    }

    /// Prefer the HID-decoded battery (GameController's `battery` goes nil while
    /// the raw-HID reader is open - see DualSenseBattery); fall back to
    /// GameController when raw HID isn't running. The fallback resolves
    /// through ControllerBattery.uiReading: macOS's .unknown + 0.0 no-data
    /// sentinel (Xbox over BT) becomes nil - "No battery info", not the old
    /// alarming orange "0%" - while an unknown STATE with a real level
    /// (DualSense: 0.95/.unknown) keeps its percentage with charging nil.
    /// The 30Hz repaint re-reads, so a reading that materialises appears.
    private var batteryReading: (percent: Int, charging: Bool?)? {
        if let hid = DualSenseHID.shared.battery { return (hid.percent, hid.charging) }
        if let b = pad.battery { return ControllerBattery.uiReading(b) }
        return nil
    }

    private func buttonsRow(_ gp: GCExtendedGamepad) -> some View {
        let face: [(String, Bool)] = isPlayStation
            ? [("✕", gp.buttonA.isPressed), ("○", gp.buttonB.isPressed),
               ("□", gp.buttonX.isPressed), ("△", gp.buttonY.isPressed)]
            : [("A", gp.buttonA.isPressed), ("B", gp.buttonB.isPressed),
               ("X", gp.buttonX.isPressed), ("Y", gp.buttonY.isPressed)]
        // Standard row: face buttons, dpad, shoulders, stick clicks.
        let standard: [(String, Bool)] = face + [
            ("↑", gp.dpad.up.isPressed), ("↓", gp.dpad.down.isPressed),
            ("←", gp.dpad.left.isPressed), ("→", gp.dpad.right.isPressed),
            ("L1", gp.leftShoulder.isPressed), ("R1", gp.rightShoulder.isPressed),
            ("L3", gp.leftThumbstickButton?.isPressed ?? false),
            ("R3", gp.rightThumbstickButton?.isPressed ?? false)
        ]
        // System row, wider + full labels. On a DualSense, Options/Create/PS/
        // Mute come from the raw-HID reader (GameController returns false for
        // them); on Xbox/MFi they come from GameController.
        let hid = DualSenseHID.shared.buttons
        let tpClicked = touchpad(of: gp)?.button.isPressed ?? false
        let system: [(String, Bool)] = isPlayStation
            ? [("Options", hid.options), ("Create", hid.create),
               ("PS", hid.ps), ("Mute", hid.mute), ("Touchpad", tpClicked)]
            : [("Menu", gp.buttonMenu.isPressed),
               ("View", gp.buttonOptions?.isPressed ?? false),
               ("Guide", gp.buttonHome?.isPressed ?? false)]
        return VStack(alignment: .leading, spacing: 6) {
            FlowChips(chips: standard)
            FlowChips(chips: system, minWidth: 72)
        }
    }

    private func touchpad(of gp: GCExtendedGamepad)
        -> (primary: GCControllerDirectionPad, secondary: GCControllerDirectionPad, button: GCControllerButtonInput)? {
        if let ds = gp as? GCDualSenseGamepad {
            return (ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton)
        }
        if let ds4 = gp as? GCDualShockGamepad {
            return (ds4.touchpadPrimary, ds4.touchpadSecondary, ds4.touchpadButton)
        }
        return nil
    }
}

/// A left-to-right wrapping row of button chips. `minWidth` widens the cells
/// for labelled system buttons (Options / Create / Touchpad).
private struct FlowChips: View {
    let chips: [(String, Bool)]
    var minWidth: CGFloat = 38
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: minWidth), spacing: 6)] }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip.0)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(chip.1 ? Color.white : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(chip.1 ? Color.accentColor : Color.secondary.opacity(0.12))
                    )
            }
        }
    }
}

private struct StickPad: View {
    let label: String
    // Live axis values (not the GCControllerDirectionPad object - passing the
    // object made SwiftUI skip re-rendering on stick motion, so the dot only
    // moved when `clicked` flipped).
    let x: Float
    let y: Float
    let clicked: Bool
    private let size: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(clicked ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: clicked ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08)))
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(x) * (size / 2 - 8),
                            y: CGFloat(-y) * (size / 2 - 8))
            }
            .frame(width: size, height: size)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct TriggerBar: View {
    let label: String
    let value: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * CGFloat(value)))
                }
            }
            .frame(height: 8)
            Text("\(Int(value * 100))").font(.caption2.monospaced())
                .frame(width: 28, alignment: .trailing).foregroundStyle(.secondary)
        }
        .frame(width: 150)
    }
}

/// A single touchpad contact as plain values (so SwiftUI re-renders on motion,
/// not just on click).
struct TouchPoint: Equatable {
    let x: Float
    let y: Float
    var active: Bool { x != 0 || y != 0 } // (0,0) == no contact
}

private struct TouchpadView: View {
    let fingers: [TouchPoint]
    let clicked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let count = fingers.filter(\.active).count
            Text("Touchpad\(clicked ? " · click" : count > 0 ? " · \(count) touch" : "")")
                .font(.caption2)
                .foregroundStyle(clicked || count > 0 ? Color.accentColor : .secondary)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(clicked ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: clicked ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08)))
                    ForEach(Array(fingers.enumerated()), id: \.offset) { _, finger in
                        if finger.active {
                            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                                .position(x: (CGFloat(finger.x) + 1) / 2 * geo.size.width,
                                          y: (1 - CGFloat(finger.y)) / 2 * geo.size.height)
                        }
                    }
                }
            }
            .frame(height: 56)
        }
    }
}

private struct BatteryBadge: View {
    /// `charging` nil = the level is real but the charge DIRECTION is
    /// unknown (DualSense reads 0.95/.unknown on macOS) - render the bare
    /// number with no glyph and no orange: the fill glyph and the low-battery
    /// alarm both assert "not charging", which we don't know. A pad that may
    /// well be docked must not scream empty; the truthful claim is just the
    /// percentage.
    let reading: (percent: Int, charging: Bool?)?

    var body: some View {
        if let reading {
            let pct = reading.percent
            if let charging = reading.charging {
                HStack(spacing: 4) {
                    Image(systemName: charging ? "battery.100.bolt" : symbol(pct))
                    Text("\(pct)%").font(.caption.monospacedDigit())
                }
                .foregroundStyle(pct <= 15 && !charging ? Color.orange : .secondary)
            } else {
                Text("\(pct)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("No battery info").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func symbol(_ pct: Int) -> String {
        switch pct {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }
}
