//
//  ContentView+Menus.swift
//
//  The shared per-host right-click menu (Rename / Codec / Unpair) that both the
//  hero card and Settings' PCTile mount via `.hostContextMenu(host)`. The menu
//  bar item's panel lives in MenuBarPanel.swift.
//

import AppKit
import SwiftUI

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
