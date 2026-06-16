//
//  TroubleshootingPane.swift
//
//  Settings → Troubleshooting. A live controller input test (the diagnostic
//  for "controller input dies after Cmd-Tab" - it reads GameController
//  directly, so if signals stay live here but not in-stream, the stream's
//  forwarding is the culprit), a battery readout, and an in-app log viewer
//  (Sunshine-style - read the app's own unified-log entries without leaving
//  the app).
//

import AppKit
import GameController
import SwiftUI

struct TroubleshootingPane: View {
    @Environment(MoonlightManager.self) private var moonlight

    var body: some View {
        Form {
            // The "Extra DualSense buttons" raw-HID control now lives in
            // Settings → Input (alongside the mouse + controller-quit settings),
            // so all raw input shares one home. Troubleshooting keeps the live
            // input TEST + logs - the diagnostics, not the settings.
            Section {
                ControllerInputTest()
            } header: {
                Text("Controller input test")
            } footer: {
                Text("Reads the controller directly through macOS. If a signal "
                    + "lights up here but not in a stream, the issue is in how "
                    + "the stream forwards it - try this view right after a "
                    + "Cmd-Tab to confirm input is still live.")
            }

            Section {
                LogViewer()
            } header: {
                Text("Logs")
            } footer: {
                Text("Recent entries from Glimmer's unified log. Copy them when "
                    + "filing an issue.")
            }
        }
        .formStyle(.grouped)
    }
}

// Module-internal (was private) so Settings → Input can host it alongside the
// mouse + controller-quit settings; the live input test below stays here.
/// Opt-in control for the raw-HID DualSense reader. Off by default; turning it
/// on shows a plain-language explanation BEFORE macOS's "Input Monitoring"
/// prompt, so that scary system dialog is never a surprise.
struct RawHIDControl: View {
    @Environment(MoonlightManager.self) private var moonlight
    @State private var showExplain = false
    /// "Working" = reports are actually arriving. The TCC check
    /// (IOHIDCheckAccess) can read not-granted even while reports flow, which
    /// made this say "waiting for permission" when input was clearly working.
    /// Polled into @State by a timer (NOT a TimelineView wrapping the buttons -
    /// that recreated the Buttons + their accessibility modifiers every second
    /// and triggered a SwiftUI view-graph use-after-free). With @State the
    /// buttons are stable; the view only re-renders when `working` flips.
    @State private var working = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentlyWorking: Bool {
        DualSenseHID.shared.reportCount > 0 || DualSenseHID.accessGranted
    }

    var body: some View {
        if moonlight.rawHIDControllerEnabled {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(working ? "On" : "On - waiting for permission",
                          systemImage: working ? "checkmark.circle.fill" : "hourglass")
                        .foregroundStyle(working ? .green : .secondary)
                    Spacer()
                    Button("Turn Off") { moonlight.rawHIDControllerEnabled = false }
                }
                if !working { permissionCard }
            }
            .onAppear { working = currentlyWorking }
            .onReceive(poll) { _ in working = currentlyWorking }
        } else {
            Button("Enable...") { showExplain = true }
                .alert("Enable enhanced DualSense buttons?", isPresented: $showExplain) {
                    Button("Enable") { enable() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(MoonlightManager.rawHIDExplanation)
                }
        }
    }

    /// Friendly "you're one toggle away" card. We don't try to programmatically
    /// re-request (it silently no-ops once macOS has a stale/denied entry -
    /// common with unsigned dev builds); we just hand the user straight to the
    /// right System Settings pane.
    private var permissionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("One more step - turn on Input Monitoring").fontWeight(.medium)
                Text("Flip **Glimmer** on under Input Monitoring, then **quit & reopen** "
                    + "Glimmer - macOS only applies the change on relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { Self.registerAndOpen() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func enable() {
        moonlight.rawHIDControllerEnabled = true
        // For a never-asked user this prompts and grants; for a denied/stale
        // entry it no-ops, so the permission card guides them to System Settings.
        if !DualSenseHID.accessGranted { Self.registerAndOpen() }
    }

    /// IOHIDRequestAccess is the ONLY call that adds Glimmer to the Input
    /// Monitoring list (IOHIDCheckAccess never registers it - confirmed via
    /// OpenEmu/Karabiner). It also prompts when state is unknown. We then
    /// deep-link so the user can flip the toggle if it's still off.
    ///
    /// `IOHIDRequestAccess` is SYNCHRONOUS and blocks the calling thread for
    /// ~2s while it presents/resolves the TCC prompt, so we run it off the main
    /// thread and only hop back to main to open System Settings. This is the
    /// ONE sanctioned entry point for the permission request + Settings deep
    /// link - it fires only from this explicit "Open Settings" button, never
    /// automatically on controller connect.
    static func registerAndOpen() {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = DualSenseHID.requestAccess()
            guard !granted else { return } // granted → nothing to open
            DispatchQueue.main.async { openInputMonitoring() }
        }
    }

    @MainActor static func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
