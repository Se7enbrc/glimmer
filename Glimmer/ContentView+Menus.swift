//
//  ContentView+Menus.swift
//
//  The shared per-host menu (Rename / Codec / Wake on LAN / Pair Again / Quit / Unpair):
//  the right-click menu on the hero card and Settings' PCTile, and the tile's
//  visible menu button. The menu bar item's panel lives in MenuBarPanel.swift.
//

import AppKit
import SwiftUI

// MARK: - Shared per-host menu

/// Actions for a paired host, one item list for the right-click menu and the
/// visible menu button. Carries its own dialogs, alerts and pair sheet;
/// needs the AppModel in the environment.
private struct HostContextMenu: ViewModifier {
    let host: Host
    /// Turns the content into a menu button instead of adding a right-click menu.
    let asButton: Bool
    @Environment(AppModel.self) private var model
    @State private var showUnpairConfirm = false
    @State private var showRename = false
    @State private var showPairAgain = false
    @State private var draftName = ""
    @State private var codecPref: HostCodecPreference
    /// The app the Quit item named when it was chosen; nil when the PC didn't say.
    @State private var quitApp: String?
    @State private var showQuitConfirm = false
    @State private var quitFailure: String?
    private var quitName: String { quitApp ?? "the running app" }

    init(host: Host, asButton: Bool) {
        self.host = host
        self.asButton = asButton
        _codecPref = State(initialValue: HostCodecPreference.load(for: host.id))
    }

    /// Unpairing or re-pairing the PC mid-stream would pull its pin out from
    /// under the live session.
    private var isStreamingThisPC: Bool { model.streamingHostID == host.id }

    func body(content: Content) -> some View {
        Group {
            if asButton {
                Menu { items } label: { content }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
            } else {
                // Make the WHOLE frame (incl. padding) right-clickable; keep the
                // secondary click out of any interactive-glass press underneath.
                content
                    .contentShape(Rectangle())
                    .contextMenu { items }
            }
        }
        // Outside the menu, so a change made from either surface is saved.
        .onChange(of: codecPref) { _, newValue in
            HostCodecPreference.save(newValue, for: host.id)
            // Spec chip/summary read the codec via UserDefaults; bump
            // the observable sentinel so SwiftUI recomputes the Mbps.
            model.displayInfoRevision &+= 1
        }
        .alert("Rename \(host.displayName)", isPresented: $showRename) {
            TextField("Display name", text: $draftName)
            Button("Save") { model.renameHost(host, to: draftName) }
            // Not destructive - it just clears the custom name back to the
            // PC's own hostname, so no red styling.
            Button("Use Default Name") {
                model.renameHost(host, to: "")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shown in the launcher and PC list. Leave it empty to show the PC's own name.")
        }
        .confirmationDialog(
            "Quit \(quitName) on \(host.displayName)?",
            isPresented: $showQuitConfirm,
            titleVisibility: .visible
        ) {
            Button("Quit \(quitApp ?? "App")", role: .destructive) { quitRunningApp() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anything unsaved in \(quitName) will be lost.")
        }
        .alert("Couldn't quit \(quitName)", isPresented: Binding(
            get: { quitFailure != nil }, set: { if !$0 { quitFailure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(quitFailure ?? "")
        }
        .confirmationDialog(
            "Unpair \(host.displayName)?",
            isPresented: $showUnpairConfirm,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { model.unpair(host) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Glimmer will forget \(host.displayName). You can pair it again at any time.")
        }
        // Pre-filled so it lands on the PIN step; pairing re-pins the PC's certificate.
        .sheet(isPresented: $showPairAgain) {
            PairSheet(initialAddress: host.localAddress ?? host.manualAddress ?? "", initialName: host.displayName)
                .environment(model)
        }
    }

    @ViewBuilder private var items: some View {
        Button {
            draftName = host.customName ?? ""
            showRename = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        // Per-host codec cap. Automatic negotiates AV1 → HEVC → H.264 against
        // this PC's encoder, so the override is only for a PC whose preferred
        // codec misbehaves: a submenu here, not a Quality-pane item.
        Picker(selection: $codecPref) {
            ForEach(HostCodecPreference.allCases) { pref in
                Text(pref.displayName).tag(pref)
            }
        } label: {
            Label("Codec", systemImage: "film.stack")
        }
        .pickerStyle(.menu)
        // Several surfaces mount this menu; reload at present-time so a
        // change on one is reflected in the other's checkmark.
        .onAppear { codecPref = HostCodecPreference.load(for: host.id) }
        // Wake on LAN needs the MAC Sunshine reports; without one the switch
        // is off and disabled, and its title says why.
        let hasMac = WakeOnLAN.normalizeMac(host.macAddress) != nil
        Toggle(isOn: Binding(
            get: { host.wakeOnLAN && hasMac },
            set: { model.setWakeOnLAN(host, enabled: $0) })) {
            Label(hasMac ? "Wake on LAN" : "Wake on LAN (PC hasn't reported its network address)",
                  systemImage: "powersleep")
        }
        .disabled(!hasMac)
        Divider()
        Button {
            showPairAgain = true
        } label: {
            Label("Pair Again…", systemImage: "key")
        }
        .disabled(isStreamingThisPC)
        // Only while the chip says an app is running; `app` is nil when the PC didn't name it.
        if !isStreamingThisPC, case .streamingElsewhere(let app) = model.polledChip(for: host) {
            Button {
                quitApp = app
                showQuitConfirm = true
            } label: {
                Label("Quit \(app ?? "the Running App") on \(host.displayName)…", systemImage: "xmark.circle")
            }
        }
        Button(role: .destructive) {
            showUnpairConfirm = true
        } label: {
            Label("Unpair…", systemImage: "minus.circle")
        }
        .disabled(isStreamingThisPC)
    }

    private func quitRunningApp() {
        Task {
            do {
                try await model.quitRunningApp(on: host)
            } catch {
                quitFailure = AppModel.quitFailureMessage(for: error, hostName: host.displayName)
            }
        }
    }
}

extension View {
    /// Attach the shared per-host right-click menu.
    func hostContextMenu(_ host: Host) -> some View {
        modifier(HostContextMenu(host: host, asButton: false))
    }

    /// Make this view a button that opens the same per-host menu.
    func hostMenuButton(_ host: Host) -> some View {
        modifier(HostContextMenu(host: host, asButton: true))
    }
}
