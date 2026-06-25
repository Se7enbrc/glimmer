//
//  SettingsPCsShortcutsPanes.swift
//
//  The PCs and Shortcuts settings panes (+ PC tile and hotkey row/badge
//  helpers), split out of SettingsView.swift. Internal so SettingsRoot can
//  compose them across files. (About lives in AboutPane.swift.)
//

import AppKit
import GameController
import os
import ServiceManagement
import SwiftUI

// MARK: - PCs

struct PCsPane: View {
    @Environment(MoonlightManager.self) private var moonlight
    @State private var showPairSheet = false
    @State private var initialPairAddress: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if moonlight.hosts.isEmpty {
                    // Unified with the launcher's EmptyPairingState - same
                    // tone (calm, plain) so a user landing here from the
                    // launcher's empty state doesn't experience copy
                    // whiplash. The Pair button below is the action; the
                    // empty-state copy just frames it.
                    VStack(spacing: 10) {
                        Image(systemName: "display.and.arrow.down")
                            .font(.system(size: 36, weight: .light))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                        Text("No PCs paired")
                            .font(.headline)
                        Text("Pair a PC to stream games to this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)], spacing: 14) {
                        ForEach(moonlight.hosts) { host in
                            PCTile(host: host)
                                .environment(moonlight)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        initialPairAddress = ""
                        showPairSheet = true
                    } label: {
                        Label("Pair a PC", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(StreamButtonStyle())
                    Button("Refresh paired PCs") {
                        moonlight.loadHosts()
                    }
                    .buttonStyle(.glass)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(initialAddress: initialPairAddress)
                .environment(moonlight)
                // Sheets on macOS 26 read better with the Tahoe glass
                // backdrop - `.thinMaterial` matches the Settings window
                // chrome so the PIN tiles' tinted glass layers cleanly on
                // top instead of stacking against an opaque sheet plate.
                .presentationBackground(.thinMaterial)
        }
    }
}

struct PCTile: View {
    let host: MoonlightHost
    @Environment(MoonlightManager.self) private var moonlight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monogram)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .frame(width: 36, height: 36)
                    .background(monoColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    moonlight.selectHost(host)
                } label: {
                    Image(systemName: host.id == moonlight.selectedHost?.id ? "star.fill" : "star")
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(host.id == moonlight.selectedHost?.id ? Color.yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Make default")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let addr = host.localAddress ?? host.manualAddress {
                    Text(addr)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let last = host.lastPlayedDescription {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if !host.apps.isEmpty {
                // App-icon chips grouped in a GlassEffectContainer so the
                // row composites as one cluster.
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(host.apps.prefix(3)) { app in
                            Image(systemName: app.systemImage)
                                .font(.system(size: 11, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 22, height: 22)
                                .glassEffect(.regular, in: .rect(cornerRadius: 6))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass tile - each PC card reads as a floating panel against the
        // settings background. Interactive so hover gives a subtle sheen
        // before the user opens the context menu / clicks the default star.
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            // Accent ring for the currently-selected default host. The ring
            // sits ON TOP of the glass; the rest of the tile uses the
            // material's natural rim highlight rather than a hardcoded
            // white stroke.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    host.id == moonlight.selectedHost?.id
                        ? Color.accentColor.opacity(0.85)
                        : Color.clear,
                    lineWidth: 2
                )
        }
        // Shared right-click affordance (Rename / Codec / Unpair).
        // Right-click is the canonical path; same menu on the launcher hero.
        .hostContextMenu(host)
    }

    private var monogram: String {
        let name = host.displayName
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let first = parts.first?.first, let second = parts.dropFirst().first?.first {
            return String([first, second]).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var monoColor: Color {
        // FNV-1a deterministic hash (NOT String.hashValue, which Swift
        // randomizes per process launch - would give the same PC tile a
        // different colour every app start). Hashed on host.id (UUID) so
        // a rename doesn't reroll the tile's colour - the monogram on
        // the LEFT changes when the user renames; the chip colour stays
        // stable to that physical PC.
        let hue = Double(host.id.deterministicHash() % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.55)
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @Environment(MoonlightManager.self) private var moonlight
    @State private var showChordCapture = false
    // Default-ON: linearize the Mac's mouse acceleration while a stream is
    // focused so only the game's own sensitivity shapes aim. Key mirrors
    // MouseAccelerationControl.enabledDefaultsKey (registered true in GlimmerApp,
    // which is what makes the non-UI UserDefaults.bool read default to on too).
    @AppStorage("disableMouseAccelWhileStreaming") private var rawMouseWhileStreaming: Bool = true

    var body: some View {
        // @Bindable shim - surfaces $moonlight.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var moonlight = moonlight
        Form {
            Section("In-stream shortcuts") {
                HotkeyRow(label: "Leave the stream", hotkey: $moonlight.quitHotkey)
                Text("Press this combo at any time during a stream to return to Glimmer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HotkeyRow(label: "Show or hide stream stats", hotkey: $moonlight.statsHotkey)
                // Session-scoped on purpose: the hotkey flips the overlay
                // only for the current stream. The next stream starts from
                // the stats-overlay toggle in Quality.
                Text("Flips the overlay on or off for the current stream only - the next stream starts from your Quality preference.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Controller quit") {
                // Hold-to-quit chord on the gamepad. Fires the same path as
                // the keyboard quit hotkey above - useful for couch
                // streaming where the keyboard isn't reachable.
                Picker("Hold to leave the stream", selection: $moonlight.controllerQuitChord) {
                    ForEach(ControllerQuitChord.allCases, id: \.self) { chord in
                        Text(chord.displayName).tag(chord)
                    }
                }
                if moonlight.controllerQuitChord == .custom {
                    HStack {
                        Text(moonlight.customControllerChord.isEmpty
                             ? "No chord recorded yet"
                             : ControllerButton.describe(moonlight.customControllerChord))
                            .foregroundStyle(moonlight.customControllerChord.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Record...") { showChordCapture = true }
                    }
                }
                Text("Hold these buttons simultaneously on the gamepad to quit the stream. "
                    + "Off by default - the keyboard chord stays available either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Raw-HID DualSense reader - co-located here (was in Troubleshooting)
            // so all raw input lives in one place. Shown when a pad is connected
            // or the feature is already on (its off-switch must not vanish with
            // the pad). RawHIDControl is defined in TroubleshootingPane.swift.
            if moonlight.controllerConnected || moonlight.rawHIDControllerEnabled {
                Section {
                    RawHIDControl()
                } header: {
                    Text("Extra DualSense buttons")
                } footer: {
                    Text("Reads controller buttons macOS hides - on a DualSense, "
                        + "the Options, Create/Share, and Mute buttons - for the "
                        + "Moonlight-style exit chord and to forward them to the host. "
                        + "Off by default; needs Input Monitoring.")
                }
            }

            Section("macOS keys") {
                Toggle(isOn: $moonlight.captureSysKeys) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use ⌘ shortcuts inside the game (this Mac stops answering them)")
                            .fontWeight(.medium)
                        Text("Forwards ⌘-Tab, ⌘-Space, etc. to your gaming PC. Off by default so macOS keeps owning these combos.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Help the curious: the change only applies to the next
                // session, since the InputForwarder snapshots this flag at
                // attach time.
                Text("Takes effect on the next stream. Your quit shortcut still works either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse") {
                Toggle(isOn: $rawMouseWhileStreaming) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aim with raw mouse motion while streaming").fontWeight(.medium)
                        Text("Only the game's own sensitivity shapes your aim - the Mac's pointer "
                            + "acceleration stops stacking on top while the stream is focused, and is "
                            + "restored the instant you leave. Mice only; the trackpad is untouched.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Linearizes the system mouse acceleration (like `com.apple.mouse.scaling -1`) for the duration of each focused stream.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChordCapture) {
            ChordCaptureSheet().environment(moonlight)
        }
    }
}

// MARK: - Controller chord capture (#9)

/// Records a custom controller exit chord by reading live held buttons. The
/// user holds the combo and releases; the set held just before release becomes
/// the chord. Reuses the input-test ControllerMonitor (to engage GameController
/// value updates) + the DualSense raw-HID reader for the center buttons.
private struct ChordCaptureSheet: View {
    @Environment(MoonlightManager.self) private var moonlight
    @Environment(\.dismiss) private var dismiss
    @State private var current: Set<ControllerButton> = []
    /// Sticky union of every button held during this recording - so releasing
    /// the combo one button at a time still captures the whole chord.
    @State private var accumulated: Set<ControllerButton> = []
    @State private var captured: Set<ControllerButton> = []
    @State private var recording = true
    @State private var observers: [NSObjectProtocol] = []
    @State private var hidRetained = false
    // Backstop the event-driven capture in case a release event is missed.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Text("Record exit chord").font(.headline)

            if recording {
                Text("Hold all the buttons for your chord at once, then **release** to capture.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(accumulated.isEmpty ? "Waiting for input..." : ControllerButton.describe(accumulated))
                    .font(.title3.monospaced())
                    .foregroundStyle(accumulated.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(minHeight: 28)
            } else {
                Text("Captured chord").font(.callout).foregroundStyle(.secondary)
                Text(ControllerButton.describe(captured))
                    .font(.title2.weight(.semibold)).foregroundStyle(.tint)
                Button("Record again") { startRecording() }
                    .buttonStyle(.bordered)
            }

            if DualSenseHID.isEnabled == false {
                Text("Tip: turn on Extra DualSense buttons (Settings → Input) to record "
                    + "the Options / Create / Mute buttons.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(captured.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { engage() }
        .onDisappear { disengage() }
        .onReceive(tick) { _ in poll() }
    }

    /// Register input handlers directly (rather than via the input-test
    /// ControllerMonitor) so capture works regardless of stream state, and so
    /// every press/release drives `poll()` - not just the timer.
    private func engage() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery {}
        setGamepadHandlers()
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { setGamepadHandlers() } })
        if DualSenseHID.isEnabled {
            DualSenseHID.shared.onChange = { poll() }
            DualSenseHID.shared.retain()
            hidRetained = true
        }
    }

    private func setGamepadHandlers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { _, _ in
                MainActor.assumeIsolated { poll() }
            }
        }
    }

    private func disengage() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        if hidRetained {
            DualSenseHID.shared.onChange = nil
            DualSenseHID.shared.release()
            hidRetained = false
        }
    }

    private func startRecording() {
        captured = []; accumulated = []; current = []; recording = true
    }

    private func poll() {
        guard recording, let pad = GCController.controllers().first?.extendedGamepad else { return }
        let held = heldControllerButtons(pad: pad)
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
        moonlight.customControllerChord = captured
        moonlight.controllerQuitChord = .custom
        dismiss()
    }
}

struct HotkeyRow: View {
    let label: String
    @Binding var hotkey: HotkeyChord

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyBadge(hotkey: $hotkey)
        }
    }
}

struct HotkeyBadge: View {
    @Binding var hotkey: HotkeyChord
    @State private var isCapturing = false
    @State private var livePreview = ""
    @State private var monitor: Any?

    var body: some View {
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
            // own keyboard-shortcut capture UI (System Settings ▸
            // Keyboard ▸ Keyboard Shortcuts).
            if isCapturing {
                Text("Press Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .onDisappear { stop() }
        .animation(.snappy(duration: 0.2), value: isCapturing)
    }

    private var displayText: String {
        if isCapturing {
            return livePreview.isEmpty ? "Press keys..." : livePreview
        }
        return hotkey.displayString
    }

    private func start() {
        isCapturing = true
        livePreview = ""
        // Local event monitor catches keys regardless of first-responder state.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // swallow so Cmd+Q etc. don't activate menu items
        }
    }

    private func stop() {
        isCapturing = false
        livePreview = ""
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
            livePreview = parts.isEmpty ? "" : parts.joined() + "..."
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
        hotkey = hk
        stop()
    }
}

// About pane: AboutPane.swift.
