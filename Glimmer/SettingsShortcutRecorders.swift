//
//  SettingsShortcutRecorders.swift
//
//  The Input pane's recorders: HotkeyRow / HotkeyBadge for the keyboard
//  shortcuts and ChordCaptureSheet for the controller chord, with the rules
//  that keep a recording from clashing with another shortcut or with the Mac.
//

import AppKit
import Combine
import GameController
import SwiftUI

// MARK: - Recording rules

@MainActor
extension HotkeyChord {
    /// Why this chord can't be an in-stream shortcut, or nil when it can.
    /// `taken` lists every other shortcut by the name Settings shows.
    func recordingProblem(taken: [(name: String, chord: HotkeyChord)],
                          menu: NSMenu? = NSApp.mainMenu) -> String? {
        if shift, !ctrl, !alt, !cmd {
            return "Add ⌃, ⌥ or ⌘. With ⇧ alone, every capital letter would trigger it."
        }
        // The main menu answers its key equivalents before the stream sees them.
        if let menu, let title = menuItemTitle(in: menu) {
            return "Already used for \(title.hasSuffix("…") ? String(title.dropLast()) : title)."
        }
        if let owner = taken.first(where: { $0.chord.displayString == displayString }) {
            return "Already used for \(owner.name)."
        }
        return nil
    }

    /// The title of the visible menu item this chord triggers, searching submenus.
    private func menuItemTitle(in menu: NSMenu) -> String? {
        for item in menu.items where !item.isHidden {
            if triggers(item) { return item.title }
            if let submenu = item.submenu, let title = menuItemTitle(in: submenu) { return title }
        }
        return nil
    }

    /// An uppercase key equivalent implies ⇧, as AppKit reads it.
    private func triggers(_ item: NSMenuItem) -> Bool {
        let key = item.keyEquivalent, mods = item.keyEquivalentModifierMask
        guard !key.isEmpty, key.lowercased() == keyChar.lowercased() else { return false }
        return mods.contains(.command) == cmd && mods.contains(.option) == alt && mods.contains(.control) == ctrl
            && (mods.contains(.shift) || key != key.lowercased()) == shift
    }
}

// MARK: - Keyboard shortcut recorder

struct HotkeyRow: View {
    let label: String
    @Binding var hotkey: HotkeyChord
    /// Every shortcut on the pane plus the fixed ones; this row's own is skipped.
    let taken: [(name: String, chord: HotkeyChord)]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            HotkeyBadge(hotkey: $hotkey, taken: taken.filter { $0.name != label })
        }
    }
}

struct HotkeyBadge: View {
    @Binding var hotkey: HotkeyChord
    let taken: [(name: String, chord: HotkeyChord)]
    @State private var isCapturing = false
    @State private var livePreview = ""
    /// Why the last chord pressed wasn't saved; capture stays open for another.
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isCapturing { stop() } else { start() }
                } label: {
                    Text(displayText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(minWidth: 120, minHeight: 22)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        // Capture state tints the glass with the accent color so it
                        // reads as "live", otherwise it's a neutral glass capsule.
                        .glassEffect(
                            isCapturing
                                ? .regular.interactive().tint(Color.accentColor.opacity(0.22))
                                : .regular.interactive(),
                            in: .capsule
                        )
                        .overlay(
                            Capsule().stroke(
                                isCapturing ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                        )
                        .foregroundStyle(isCapturing ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)

                // Esc-to-cancel hint shown only during capture. Mirrors macOS's
                // own keyboard-shortcut capture UI (System Settings ›
                // Keyboard › Keyboard Shortcuts).
                if isCapturing {
                    Text("Press Esc to cancel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { stop() }
        .animation(.snappy(duration: 0.2), value: isCapturing)
    }

    private var displayText: String {
        if isCapturing {
            return livePreview.isEmpty ? "Press keys…" : livePreview
        }
        return hotkey.displayString
    }

    private func start() {
        isCapturing = true
        livePreview = ""
        problem = nil
        // Local event monitor catches keys regardless of first-responder state.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // swallow so Cmd+Q etc. don't activate menu items
        }
    }

    private func stop() {
        isCapturing = false
        livePreview = ""
        problem = nil
        if let activeMonitor = monitor {
            NSEvent.removeMonitor(activeMonitor)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Update live modifier preview on flagsChanged
        if event.type == .flagsChanged {
            var parts: [String] = []
            if mods.contains(.control) { parts.append("⌃") }
            if mods.contains(.option) { parts.append("⌥") }
            if mods.contains(.shift) { parts.append("⇧") }
            if mods.contains(.command) { parts.append("⌘") }
            livePreview = parts.isEmpty ? "" : parts.joined() + "…"
            return
        }

        // keyDown: commit the chord if it's a letter or number
        // ESC = cancel
        if event.keyCode == 53 {
            stop()
            return
        }

        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let char = chars.first,
              char.isLetter || char.isNumber else {
            return
        }
        let hk = HotkeyChord(
            ctrl: mods.contains(.control),
            alt: mods.contains(.option),
            shift: mods.contains(.shift),
            cmd: mods.contains(.command),
            keyChar: String(char).lowercased()
        )
        guard hk.ctrl || hk.alt || hk.shift || hk.cmd else { return }
        if let reason = hk.recordingProblem(taken: taken) {
            problem = reason
            livePreview = ""
            return
        }
        hotkey = hk
        stop()
    }
}

// MARK: - Controller chord capture (#9)

/// Records a custom controller chord from live held buttons: the user holds
/// the combo and releases, and everything held before release is the chord.
/// Reads GameController pads, raw-HID pads and the DualSense centre buttons.
struct ChordCaptureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current: Set<ControllerButton> = []
    /// Sticky union of every button held during this recording - so releasing
    /// the combo one button at a time still captures the whole chord.
    @State private var accumulated: Set<ControllerButton> = []
    @State private var captured: Set<ControllerButton> = []
    @State private var recording = true
    @State private var hidRetained = false
    // Drives poll(): capture reads pad state, so a live stream keeps its handlers.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// One button would stop the stream whenever a game has you hold it.
    nonisolated static func canSave(_ chord: Set<ControllerButton>) -> Bool { chord.count >= 2 }

    var body: some View {
        VStack(spacing: 16) {
            Text("Record a chord to stop streaming").font(.headline)

            if recording {
                Text("Hold all the buttons for your chord at once, then **release** to capture.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(accumulated.isEmpty ? "Waiting for input…" : ControllerButton.describe(accumulated))
                    .font(.title3.monospaced())
                    .foregroundStyle(accumulated.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(minHeight: 28)
            } else {
                Text("Captured chord").font(.callout).foregroundStyle(.secondary)
                Text(ControllerButton.describe(captured))
                    .font(.title2.weight(.semibold)).foregroundStyle(.tint)
                if !Self.canSave(captured) {
                    Text("Use at least two buttons, so a single press in a game can't stop the stream.")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Button("Record Again") { startRecording() }
                    .buttonStyle(.bordered)
            }

            if DualSenseHID.isEnabled == false {
                Text("To record Options, Create or Mute on a DualSense, turn on "
                    + "Extra DualSense buttons in Settings › Input.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSave(captured))
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { engage() }
        .onDisappear { disengage() }
        .onReceive(tick) { _ in poll() }
    }

    /// Poll-driven capture (the 30 Hz tick plus sticky accumulation), so the
    /// sheet never takes the single-slot input handlers a live stream owns.
    private func engage() {
        HIDGamepadManager.shared.retain()
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery {}
        if DualSenseHID.isEnabled {
            DualSenseHID.shared.retain()
            hidRetained = true
        }
    }

    private func disengage() {
        HIDGamepadManager.shared.release()
        GCController.stopWirelessControllerDiscovery()
        if hidRetained {
            DualSenseHID.shared.release()
            hidRetained = false
        }
    }

    private func startRecording() {
        captured = []; accumulated = []; current = []; recording = true
    }

    private func poll() {
        guard recording else { return }
        var held: Set<ControllerButton> = []
        for pad in GCController.controllers().compactMap(\.extendedGamepad) {
            held.formUnion(heldControllerButtons(pad: pad))
        }
        for pad in HIDGamepadManager.shared.devices.values {
            let state = pad.state
            held.formUnion(heldControllerButtons(buttons: state.buttons, leftTrigger: state.analog.leftTrigger,
                                                 rightTrigger: state.analog.rightTrigger))
        }
        current = held
        if !held.isEmpty {
            // Sticky: remember every button touched during the hold, so a
            // staggered release still yields the full chord.
            accumulated.formUnion(held)
        } else if !accumulated.isEmpty {
            // Fully released after a held combo → that's the chord.
            captured = accumulated
            recording = false
        }
    }

    private func save() {
        model.customControllerChord = captured
        model.controllerQuitChord = .custom
        dismiss()
    }
}
