// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI
import GlimmerEngine
@testable import Glimmer

struct ControllerLayoutBeforePane: View {
    static let pointerDetail =
        "Captures or releases the pointer in a window or full screen."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @State private var showChordCapture = false
    @State private var nintendoPresence = NintendoControllerPresence()
    @AppStorage("disableMouseAccelWhileStreaming") private var rawMouseWhileStreaming: Bool = true

    private var chordNeedsExtraButtons: Bool {
        !model.rawHIDControllerEnabled
            && InputForwarder.needsRawHIDCenterButtons(chord: model.controllerQuitChord,
                                                       custom: model.customControllerChord)
    }

    var body: some View {
        @Bindable var model = model
        let stop = "Stop Streaming", stats = "Show or Hide Stream Stats"
        let pointer = "Capture or Release the Pointer", mini = "Mini Player", paste = "Paste as Text"
        let taken: [(name: String, chord: HotkeyChord)] = [
            (stop, model.quitHotkey), (stats, model.statsHotkey),
            (pointer, model.releasePointerHotkey), (mini, model.miniPlayerHotkey),
            ("Bookmark a Rough Moment", .defaultBookmark), (paste, PasteText.chord)
        ]
        Form {
            Section("In-stream shortcuts") {
                HotkeyRow(label: stop, detail: "Ends the stream and returns to Glimmer.",
                          hotkey: $model.quitHotkey, taken: taken)
                HotkeyRow(label: stats, detail: "For this stream only. The next stream follows Settings › Quality.",
                          hotkey: $model.statsHotkey, taken: taken)
                HotkeyRow(label: pointer,
                          detail: Self.pointerDetail,
                          hotkey: $model.releasePointerHotkey, taken: taken)
                HotkeyRow(label: mini,
                          detail: "Shrinks the stream to a small window over your other apps, and brings it back.",
                          hotkey: $model.miniPlayerHotkey, taken: taken)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paste)
                        Text("Types this Mac's clipboard into the PC as text. ⌘V does the same while ⌘ stays "
                            + "with this Mac.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StaticChordBadge(chord: PasteText.chord)
                }
            }

            Section("Stop streaming with a controller") {
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

            NintendoLayoutSettings(isConnected: nintendoPresence.isConnected)

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
                .accessibilityLabel("Send Command to the PC as the Windows key")
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
        .animation(Motion.layout(reduceMotion: reduceMotion), value: model.controllerConnected)
        .animation(Motion.layout(reduceMotion: reduceMotion), value: model.rawHIDControllerEnabled)
        .onAppear { nintendoPresence.start() }
        .onDisappear { nintendoPresence.stop() }
        .sheet(isPresented: $showChordCapture) {
            ChordCaptureSheet().environment(model)
        }
    }
}
