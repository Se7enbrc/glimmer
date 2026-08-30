//
//  ContentView+Menus.swift
//
//  The launcher's two menu surfaces: the MenuBarExtra dropdown (open / stream /
//  switch PC / controller charm / Settings / updates / quit) and the shared
//  per-host right-click menu (Rename / Codec / Unpair) that both the hero card
//  and Settings' PCTile mount via `.hostContextMenu(host)`. Split out of
//  ContentView.swift to keep each file under the length limit; the window,
//  connect surface, and hero live there.
//

import AppKit
import SwiftUI

// MARK: - Menu bar content

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Icon-forward, sectioned layout within `.menu`-style MenuBarExtra
            // constraints (system NSMenu: Labels show their SF Symbol,
            // Sections render titled groups, custom materials are NOT
            // honoured - lean on iconography + structure, not glass). Item
            // order: navigational ("Open Glimmer") FIRST, then stream actions,
            // then app-wide (Settings / Quit) - Apple's first-party agent
            // pattern (Time Machine, Bluetooth).
            Button {
                openWindow(id: "main")
                activate()
            } label: {
                Label("Open Glimmer", systemImage: "macwindow")
            }

            if let host = model.selectedHost {
                // "Connected to" only when actually streaming this host - the
                // selected host is not necessarily the connected one.
                Section(model.isStreaming ? "Connected to \(host.displayName)" : host.displayName) {
                    Button {
                        model.streamDefaultApp()
                        activate()
                    } label: {
                        Label("Stream \(model.defaultAppName)", systemImage: "play.fill")
                    }
                    .disabled(model.isStreaming)

                    if model.hosts.count > 1 {
                        Menu {
                            ForEach(model.hosts) { host in
                                Button {
                                    model.selectHost(host)
                                } label: {
                                    if host.id == model.selectedHost?.id {
                                        Label(host.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(host.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label("Switch PC", systemImage: "desktopcomputer")
                        }
                    }
                }
            } else {
                Section {
                    Label("No PC paired", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                }
            }

            // Controller battery charm - shown whenever a pad reporting battery
            // is connected to the Mac (sampled on menu open).
            if let battery = model.menuBarControllerBattery {
                Section("Controller") {
                    Label(
                        "\(battery.percent)% battery\(battery.charging ? " · charging" : "")",
                        systemImage: battery.charging ? "battery.100.bolt" : "gamecontroller"
                    )
                }
            }

            Divider()

            Button {
                openSettings()
                activate()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            #if canImport(Sparkle)
            // The menu-bar dropdown is the reliable surface for the accessory
            // (no-window) case, where the app menu's "Check for Updates..." isn't
            // visible. `activate()` brings Glimmer forward so Sparkle's panel shows.
            Button {
                UpdaterController.shared.updater.checkForUpdates()
                activate()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            #endif

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Glimmer", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }

    private func activate() {
        // NSApp.activate() is the macOS 14+ replacement for
        // activate(ignoringOtherApps:) - the OS decides foreground policy
        // system-side now, so the "ignoringOtherApps: true" knob is gone.
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
