// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// The Input Monitoring flow is shared by every controller path.

import AppKit
import Combine
import SwiftUI

/// Opt-in control for the raw-HID DualSense reader. Turning it on explains the
/// permission before macOS's Input Monitoring prompt, so that dialog is never a surprise.
struct RawHIDControl: View {
    @Environment(AppModel.self) private var model
    @State private var showExplain = false
    /// Working means reports arrive or macOS says granted; the check alone can lag a grant.
    /// Polled into @State, not a TimelineView: rebuilding the buttons each tick crashed SwiftUI.
    @State private var working = false
    @State private var access = InputMonitoring.state
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentlyWorking: Bool {
        DualSenseHID.shared.reportCount > 0 || access == .granted
    }

    var body: some View {
        if model.rawHIDControllerEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(working ? "On" : "On, needs Input Monitoring",
                          systemImage: working ? "checkmark.circle.fill" : "hand.raised.fill")
                        .foregroundStyle(working ? .green : .secondary)
                    Spacer()
                    if !working {
                        Button(InputMonitoring.actionTitle(access)) { InputMonitoring.ask() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Turn Off") { model.rawHIDControllerEnabled = false }
                }
                if !working {
                    Text(InputMonitoring.guidance(access))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { refresh() }
            .onReceive(poll) { _ in refresh() }
        } else {
            Button("Turn On…") { showExplain = true }
                .alert("Turn on Extra DualSense buttons?", isPresented: $showExplain) {
                    Button(InputMonitoring.state == .denied ? "Open System Settings" : "Turn On") { enable() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(AppModel.rawHIDExplanation(InputMonitoring.state))
                }
        }
    }

    private func refresh() {
        access = InputMonitoring.state
        working = currentlyWorking
    }

    private func enable() {
        model.rawHIDControllerEnabled = true
        InputMonitoring.ask()
    }
}

/// Input Monitoring, asked one way everywhere. The system prompt only appears while macOS
/// has no answer, and it carries its own Open System Settings button, so Glimmer opens
/// System Settings itself only once there is an answer to change.
enum InputMonitoring {
    enum State: Equatable { case granted, denied, unknown }

    static var state: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .unknown
        }
    }

    static func actionTitle(_ state: State) -> String {
        state == .denied ? "Open System Settings" : "Continue"
    }

    /// A row that is on but still denied is also how a stale entry looks; removing it
    /// lets the next Continue register this copy of Glimmer again.
    static func guidance(_ state: State) -> String {
        state == .denied
            ? "Turn on Glimmer in Privacy & Security › Input Monitoring. If it's already on, "
                + "select it, remove it with the minus button, then come back and choose Continue."
            : "macOS asks once. Glimmer reads only the controller, never the keyboard."
    }

    enum Step: Equatable { case reopenReaders, openSettings, systemPrompt }

    /// Never System Settings while macOS can still prompt: it would cover the prompt.
    static func step(for state: State) -> Step {
        switch state {
        case .granted: .reopenReaders
        case .denied: .openSettings
        case .unknown: .systemPrompt
        }
    }

    /// The request blocks its thread while the prompt is up, so it never runs on main.
    @MainActor static func ask(
        access: State? = nil,
        reopen: @escaping @MainActor @Sendable () -> Void = { reopenReaders() },
        settings: @MainActor () -> Void = { openSettings() },
        request: @escaping @Sendable () -> Bool = { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    ) {
        switch step(for: access ?? state) {
        case .reopenReaders: reopen()
        case .openSettings: settings()
        case .systemPrompt:
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = request()
                if granted { DispatchQueue.main.async { reopen() } }
            }
        }
    }

    /// Readers opened before the grant see nothing until reopened.
    @MainActor static func reopenReaders() {
        DualSenseHID.shared.reopen()
        HIDGamepadManager.shared.reopenAll()
    }

    @MainActor private static var lastSeen = state

    /// On return to Glimmer, a grant made in System Settings takes effect without a relaunch.
    @MainActor static func noticeReturn(access: State? = nil, reopen: () -> Void = { reopenReaders() }) {
        let now = access ?? state
        defer { lastSeen = now }
        if now == .granted, lastSeen != .granted { reopen() }
    }

    @MainActor static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
