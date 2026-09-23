//
//  SettingsPCsShortcutsPanes.swift
//
//  The PCs and Input settings panes (+ the PC tile), split out of
//  SettingsView.swift. Internal so SettingsRoot can compose them across files.
//  The shortcut and chord recorders live in SettingsShortcutRecorders.swift.
//

import SwiftUI

// MARK: - PCs

struct PCsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showPairSheet = false
    @State private var initialPairAddress: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.hosts.isEmpty {
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
                        ForEach(model.hosts) { host in
                            PCTile(host: host)
                                .environment(model)
                        }
                    }
                }

                Button {
                    initialPairAddress = ""
                    showPairSheet = true
                } label: {
                    Label("Pair a PC…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(StreamButtonStyle())
                .padding(.top, 4)
            }
            .padding(20)
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(initialAddress: initialPairAddress)
                .environment(model)
                // Sheets on macOS 26 read better with the Tahoe glass
                // backdrop - `.thinMaterial` matches the Settings window
                // chrome so the PIN tiles' tinted glass layers cleanly on
                // top instead of stacking against an opaque sheet plate.
                .presentationBackground(.thinMaterial)
        }
    }
}

struct PCTile: View {
    let host: Host
    @Environment(AppModel.self) private var model

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
                    model.selectHost(host)
                } label: {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(isDefault ? Color.yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(isDefault ? "The default PC" : "Make this the default PC")
                .accessibilityLabel("Default PC")
                .accessibilityAddTraits(isDefault ? .isSelected : [])
                // The right-click menu's items, visible so per-PC settings are
                // discoverable without knowing to right-click.
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .hostMenuButton(host)
                    .help("Settings and actions for this PC")
                    .accessibilityLabel("Actions for \(host.displayName)")
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
                    isDefault
                        ? Color.accentColor.opacity(0.85)
                        : Color.clear,
                    lineWidth: 2
                )
        }
        // Shared right-click menu, the same items as the visible button above
        // and the launcher hero's menu.
        .hostContextMenu(host)
    }

    private var isDefault: Bool { host.id == model.selectedHost?.id }

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
    @Environment(AppModel.self) private var model
    @State private var showChordCapture = false
    // Default-ON: no acceleration curve in game, Tracking Speed kept (macOS linear
    // scaling). Key mirrors MouseAccelerationControl.enabledDefaultsKey.
    @AppStorage("disableMouseAccelWhileStreaming") private var rawMouseWhileStreaming: Bool = true

    /// The chosen chord can't fire on a DualSense until the raw-HID reader is on.
    private var chordNeedsExtraButtons: Bool {
        !model.rawHIDControllerEnabled
            && InputForwarder.needsRawHIDCenterButtons(chord: model.controllerQuitChord,
                                                       custom: model.customControllerChord)
    }

    var body: some View {
        // @Bindable shim - surfaces $model.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var model = model
        // Row names double as the "Already used for" names, so a recording
        // can't copy another shortcut or a fixed one.
        let stop = "Stop Streaming", stats = "Show or Hide Stream Stats"
        let pointer = "Capture or Release the Pointer", mini = "Mini Player", paste = "Paste as Text"
        let taken: [(name: String, chord: HotkeyChord)] = [
            (stop, model.quitHotkey), (stats, model.statsHotkey),
            (pointer, model.releasePointerHotkey), (mini, model.miniPlayerHotkey),
            ("Bookmark a Rough Moment", .defaultBookmark), (paste, PasteText.chord)
        ]
        Form {
            Section("In-stream shortcuts") {
                HotkeyRow(label: stop, hotkey: $model.quitHotkey, taken: taken)
                Text("Ends the stream and brings you back to Glimmer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HotkeyRow(label: stats, hotkey: $model.statsHotkey, taken: taken)
                // Session-scoped on purpose: the hotkey flips the overlay
                // only for the current stream. The next stream starts from
                // the stream stats toggle in Quality.
                Text("Shows or hides stream stats for this stream only. The next stream follows "
                    + "Settings › Quality.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HotkeyRow(label: pointer, hotkey: $model.releasePointerHotkey, taken: taken)
                // Window mode only: in full screen the pointer is hidden for
                // the whole session and there is nothing to toggle, so the
                // chord reaches the PC there like any other key.
                Text("In a window, the game takes your mouse while the pointer is over the picture. Hold Esc "
                    + "or switch apps to get it back, or press this shortcut to take it or give it back "
                    + "without moving the mouse. In full screen this shortcut goes to the game.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HotkeyRow(label: mini, hotkey: $model.miniPlayerHotkey, taken: taken)
                Text("Shrinks the stream to a small window that floats over your other apps, and brings it "
                    + "back. Click the mini player to play; hold Esc to get the pointer back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(paste)
                    Spacer()
                    StaticChordBadge(chord: PasteText.chord)
                }
                Text("Types this Mac's clipboard into the PC as text, whatever the PC's keyboard layout. "
                    + "⌘V does the same while ⌘ stays with this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Stop streaming with a controller") {
                // Hold-to-quit chord on the gamepad. Fires the same path as
                // the keyboard quit hotkey above - useful for couch
                // streaming where the keyboard isn't reachable.
                Picker("Hold to stop streaming", selection: $model.controllerQuitChord) {
                    ForEach(ControllerQuitChord.allCases, id: \.self) { chord in
                        Text(chord.displayName).tag(chord)
                    }
                }
                if model.controllerQuitChord == .custom {
                    HStack {
                        Text(model.customControllerChord.isEmpty
                             ? "No chord recorded yet"
                             : ControllerButton.describe(model.customControllerChord))
                            .foregroundStyle(model.customControllerChord.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Record…") { showChordCapture = true }
                    }
                }
                // RawHIDControl while off is its "Turn On…" button and explainer.
                if chordNeedsExtraButtons {
                    HStack(spacing: 8) {
                        Label("On a DualSense this needs Extra DualSense buttons.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Spacer()
                        RawHIDControl()
                    }
                }
                Text("Hold these buttons together on the controller for a moment to stop streaming. "
                    + "L3 + R3 by default; the keyboard shortcut above always works too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Raw-HID DualSense reader. Shown when a pad is connected or the
            // feature is on (its off-switch must not vanish with the pad), but
            // not while the chord warning above already offers Turn On.
            if model.rawHIDControllerEnabled || (model.controllerConnected && !chordNeedsExtraButtons) {
                Section {
                    RawHIDControl()
                } header: {
                    Text("Extra DualSense buttons")
                } footer: {
                    Text("Reads the DualSense buttons macOS hides (Options, Create and Mute), so they "
                        + "reach the PC and a controller chord can use them. "
                        + "Off by default; needs Input Monitoring.")
                }
            }

            Section("macOS keys") {
                Toggle(isOn: $model.captureSysKeys) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send ⌘ to the PC as the Windows key")
                            .fontWeight(.medium)
                        Text("Includes ⌘-Tab and ⌘-Space while the game has the pointer. When you take "
                            + "the pointer back, ⌘ and its shortcuts belong to this Mac again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Help the curious: the change only applies to the next
                // session, since the InputForwarder snapshots this flag at
                // attach time.
                Text("Takes effect on the next stream. Your Stop Streaming shortcut works either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse") {
                Picker("Pointer while streaming", selection: $rawMouseWhileStreaming) {
                    Text("Linear scaling").tag(true)
                    Text("Mouse acceleration").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Linear scaling keeps your Tracking Speed and drops the acceleration curve while "
                    + "the stream is focused; Mouse acceleration leaves the Mac's pointer untouched.")
                Text("Linear scaling means only the game's own sensitivity shapes your aim, at the "
                    + "speed you are used to. Your setting comes back the moment you stop "
                    + "streaming. Mice only; the trackpad is untouched.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChordCapture) {
            ChordCaptureSheet().environment(model)
        }
    }
}

// About pane: AboutPane.swift.
