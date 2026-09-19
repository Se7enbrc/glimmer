//
//  ContentView+Menus.swift
//
//  The launcher's two menu surfaces: the MenuBarExtra dropdown and the shared
//  per-host right-click menu (Rename / Codec / Unpair) that both the hero card
//  and Settings' PCTile mount via `.hostContextMenu(host)`.
//

import AppKit
import SwiftUI

// MARK: - Menu bar content

/// The dropdown: the action you need now first, then what is going on, then
/// the app. A standard menu (no popover): rows, checkmarks and submenus only.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            attentionRows
            primaryRows
            streamingRows
            pcRows
            controllerRows
            Divider()
            Button {
                openWindow(id: "main")
                activate()
            } label: {
                Label("Open Glimmer", systemImage: "macwindow")
            }
            Button {
                openSettings()
                activate()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Glimmer", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .onAppear { model.startMenuBarRefresh() }
        .onDisappear { model.stopMenuBarRefresh() }
    }

    /// One line of the existing failure copy and the one action that helps.
    @ViewBuilder private var attentionRows: some View {
        if let error = model.nativeStreamError {
            Section {
                Text(error)
                if error.localizedCaseInsensitiveContains("pair") {
                    Button("Open Glimmer") { openWindow(id: "main"); activate() }
                } else {
                    Button("Try Again") {
                        model.nativeStreamError = nil
                        model.retryLastLaunch()
                    }
                }
            }
        }
    }

    @ViewBuilder private var primaryRows: some View {
        Section {
            switch model.menuBarPrimaryAction {
            case .stream(let app):
                Button {
                    model.streamHeroApp()
                    activate()
                } label: {
                    Label("Stream \(app)", systemImage: "play.fill")
                }
                if let host = model.selectedHost {
                    let apps = host.apps.filter { !$0.hidden }
                    if apps.count > 1 {
                        Menu {
                            ForEach(apps) { app in
                                Button(app.name) { model.requestStream(app: app, on: host); activate() }
                            }
                        } label: {
                            Label("Stream App", systemImage: "square.grid.2x2")
                        }
                    }
                }
            case .cancelConnection:
                Button {
                    model.cancelConnect()
                } label: {
                    Label("Cancel Connection", systemImage: "xmark.circle")
                }
            case .backToStream:
                Button {
                    model.resumeStreamWindow()
                    activate()
                } label: {
                    Label("Back to Stream", systemImage: "play.rectangle")
                }
                Button {
                    model.stopStreamFromMenu()
                } label: {
                    Label(model.menuStopInProgress ? "Stopping…" : "Stop Streaming", systemImage: "stop.fill")
                }
                .disabled(model.menuStopInProgress)
            case .none:
                Label("No PC paired", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
        }
    }

    /// The status line and Connection Details, only while streaming.
    @ViewBuilder private var streamingRows: some View {
        if let status = model.menuBarStatusLine {
            Section {
                Text(status)
                Menu {
                    ForEach(model.menuBarDetailLines, id: \.self) { Text($0) }
                    Divider()
                    Toggle("Show Stream Statistics", isOn: Binding(
                        get: { model.statsOverlayShown },
                        set: { _ in model.toggleStatsOverlayFromMenu() }))
                } label: {
                    Label("Connection Details", systemImage: "waveform.path.ecg")
                }
            }
        }
    }

    /// The selected PC's readiness, Wake and Connect when it applies, and the
    /// PCs submenu; while streaming, a pick here is the next connection.
    @ViewBuilder private var pcRows: some View {
        if let host = model.selectedHost {
            Section(model.isStreaming ? "Next connection" : host.displayName) {
                if let readiness = model.menuBarReadiness, !model.isStreaming {
                    Text(readiness)
                }
                wakeRows(host: host)
                if model.hosts.count > 1 {
                    Menu {
                        ForEach(model.hosts) { candidate in
                            Button {
                                model.selectHost(candidate)
                            } label: {
                                if candidate.id == host.id {
                                    Label(candidate.displayName, systemImage: "checkmark")
                                } else {
                                    Text(candidate.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("PCs", systemImage: "desktopcomputer")
                    }
                }
            }
        }
    }

    @ViewBuilder private func wakeRows(host: Host) -> some View {
        if !model.isStreaming, let device = LunaPower.shared.gatedDevice(for: host) {
            if LunaPower.shared.actionInFlight[host.id] == "on" {
                Text("Waking \(host.displayName)…")
                Button("Stop Waiting") { model.cancelWake(host) }
            } else if model.menuBarHostAsleep, LunaPower.shared.actionInFlight[host.id] == nil {
                Button {
                    model.wakeHost(host, device: device, thenConnect: true)
                } label: {
                    Label("Wake and Connect", systemImage: "power")
                }
            }
        }
    }

    @ViewBuilder private var controllerRows: some View {
        let pads = model.menuBarControllers
        if pads.count == 1, let pad = pads.first {
            Section("Controller") {
                Label(MenuBarPresentation.batteryRow(name: pad.name, percent: pad.percent, charging: pad.charging),
                      systemImage: pad.charging ? "battery.100.bolt" : "gamecontroller")
            }
        } else if pads.count > 1 {
            Section {
                Menu {
                    ForEach(Array(pads.enumerated()), id: \.offset) { _, pad in
                        Text(MenuBarPresentation.batteryRow(name: pad.name, percent: pad.percent, charging: pad.charging))
                    }
                } label: {
                    Label("Controllers", systemImage: "gamecontroller")
                }
            }
        }
    }

    private func activate() {
        // The OS decides foreground policy on macOS 14+; this is the request.
        NSApp.activate()
    }
}

// MARK: - Shared per-host right-click menu

/// Right-click actions for a paired host (Rename / Codec / Unpair),
/// shared by the launcher hero and the Settings PCTile. Right-click is the
/// canonical affordance (no visible button). Carries its own confirmation
/// dialogs + rename alert; apply via `.hostContextMenu(host)` with the
/// AppModel in the environment.
private struct HostContextMenu: ViewModifier {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var showUnpairConfirm = false
    @State private var showRename = false
    @State private var draftName = ""
    @State private var codecPref: HostCodecPreference

    init(host: Host) {
        self.host = host
        _codecPref = State(initialValue: HostCodecPreference.load(for: host.id))
    }

    func body(content: Content) -> some View {
        content
            // Make the WHOLE frame (incl. padding) right-clickable; keep the
            // secondary click out of any interactive-glass press underneath.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    draftName = host.customName ?? ""
                    showRename = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                // Per-host codec cap. Automatic negotiates AV1 → HEVC → H.264
                // against what this host's encoder supports, so the override
                // exists only for the host whose preferred codec misbehaves -
                // hence a submenu here, not a Quality-pane item.
                Picker(selection: $codecPref) {
                    ForEach(HostCodecPreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                } label: {
                    Label("Codec", systemImage: "film.stack")
                }
                .pickerStyle(.menu)
                // Two surfaces mount this menu; reload at present-time so a
                // change on one is reflected in the other's checkmark.
                .onAppear { codecPref = HostCodecPreference.load(for: host.id) }
                .onChange(of: codecPref) { _, newValue in
                    HostCodecPreference.save(newValue, for: host.id)
                    // Spec chip/summary read the codec via UserDefaults; bump
                    // the observable sentinel so SwiftUI recomputes the Mbps.
                    model.displayInfoRevision &+= 1
                }
                Divider()
                Button(role: .destructive) {
                    showUnpairConfirm = true
                } label: {
                    Label("Unpair…", systemImage: "minus.circle")
                }
            }
            .alert("Rename \(host.displayName)", isPresented: $showRename) {
                TextField("Display name", text: $draftName)
                Button("Save") { model.renameHost(host, to: draftName) }
                // Not destructive - it just clears the custom name back to the
                // PC's own hostname, so no red styling.
                Button("Use default name") {
                    model.renameHost(host, to: "")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Shown in the launcher and PC list. Leave empty (or 'Use default name') to show the PC's own hostname.")
            }
            .confirmationDialog(
                "Unpair \(host.displayName)?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair(host) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Glimmer will forget this PC and leave a clean state. You can pair again at any time.")
            }
    }
}

extension View {
    /// Attach the shared per-host right-click menu (Rename / Codec / Unpair).
    func hostContextMenu(_ host: Host) -> some View {
        modifier(HostContextMenu(host: host))
    }
}
