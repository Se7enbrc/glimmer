//
//  DiagnosticsPane.swift
//
//  Settings → Diagnostics. The single hideable home for the debug/tuning wires.
//  HIDDEN by default (gated on `AppModel.showDiagnostics`, which the
//  sidebar consults) and only revealed by an option-click on the version line in
//  About - normal users never see this. It houses:
//    * the Telemetry opt-in toggle (the gate `TelemetryGate.isEnabled` reads at
//      stream start) - applies on the NEXT stream;
//    * the telemetry-bookmark chord (⌃B), shown for discoverability - it's the
//      client-only "that felt bad" marker, intercepted ONLY while telemetry is on;
//    * a status line: where the telemetry log dir lives (the NDJSON + scorecard
//      files are the portable artifacts; see docs/PROFILING.md).
//
//  Nothing here changes streaming behaviour; it's all observation/opt-in.
//

import AppKit
import SwiftUI

struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    /// Debug lines reach the in-app log and session file only with this on (a debug
    /// session once ran 30-105k lines an hour). Resolved at session start, like telemetry.
    @AppStorage("diagFileLogDebug") private var fileLogDebug = false

    var body: some View {
        // @Bindable shim - surfaces $model.x bindings from the @Observable
        // environment value (matches the other Settings panes).
        @Bindable var model = model
        Form {
            // Always-visible support surface (formerly the Troubleshooting pane):
            // a live controller input test + the in-app log viewer. These need to
            // stay reachable by normal users - they're how you debug "my
            // controller stopped" or grab logs for a bug report - so they are NOT
            // behind the option-click reveal below.
            Section {
                ControllerInputTest()
            } header: {
                Text("Controller input test")
            } footer: {
                Text("Reads the controller through macOS directly. If it lights up here "
                    + "but not in a stream, the stream's forwarding is at fault.")
            }

            Section {
                LogViewer()
            } header: {
                Text("Logs")
            } footer: {
                Text("Recent entries from Glimmer's unified log. Copy them when "
                    + "filing an issue.")
            }

            // Power-user wires - revealed ONLY by the option-click gesture on the
            // About version line (showDiagnostics). Telemetry + tuning live behind
            // it so normal users never trip the opt-in toggles; the support
            // surface above is always available either way.
            if model.showDiagnostics {
                Section {
                    Toggle(isOn: $model.telemetryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Performance telemetry").fontWeight(.medium)
                            Text("Exposes per-second stream metrics over a local "
                                + "Prometheus endpoint and an NDJSON log, plus a "
                                + "richer per-session diagnostic log. Off by default; "
                                + "carries only performance numbers, never secrets.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $fileLogDebug) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verbose session log file").fontWeight(.medium)
                            Text("Keeps debug-level lines in the in-app log and the "
                                + "per-session diagnostic log file too (info and "
                                + "above by default). Console always carries everything.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // The exporter (and the file sink's level) snapshot their gates
                    // when a session starts, so a mid-session flip does nothing
                    // until the next stream.
                    Text("Applies on the next stream.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Telemetry")
                }

                Section {
                    HStack {
                        Text("Bookmark a Rough Moment")
                        Spacer()
                        StaticChordBadge(chord: .defaultBookmark)
                    }
                    Text("Press \(HotkeyChord.defaultBookmark.displayString) during a "
                        + "stream when it \u{201C}feels bad\u{201D} to drop a "
                        + "timestamped marker into the telemetry. The marker stays on "
                        + "this Mac, and the shortcut is only caught while telemetry is "
                        + "on; otherwise it goes to the PC like any other key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("In-stream marker")
                }

                Section {
                    LabeledContent("Telemetry logs") {
                        HStack(spacing: 8) {
                            Text(abbreviatedLogPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                revealLogDir()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                    }
                } header: {
                    Text("Where the data goes")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Show the path with a leading `~` instead of the absolute home so it reads
    /// cleanly and matches how the doc comments refer to it.
    private var abbreviatedLogPath: String {
        (TelemetryExporter.logsDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private func revealLogDir() {
        let dir = TelemetryExporter.logsDirectory
        // Create it if it doesn't exist yet (telemetry may never have run) so
        // the reveal lands somewhere instead of silently no-opping.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

/// Fixed shortcuts show plain key notation, so nothing that can't be recorded
/// looks like a recorder.
struct StaticChordBadge: View {
    let chord: HotkeyChord

    var body: some View {
        Text(chord.displayString)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
