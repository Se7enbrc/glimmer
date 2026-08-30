//
//  ContentView+PowerControls.swift
//
//  The hero's top-trailing Luna power cluster: the quiet power-glyph menu, its
//  destructive-verb confirmations, and the in-flight progress capsule for the
//  non-wake verbs. Split out of ContentViewSubviews.swift to keep each file
//  under the length limit. The hero's WAKE affordance is not here - it lives on
//  the StreamButton's `.wake` / `.waking` roles (ContentView+StreamButton.swift)
//  because a sleeping PC's one obvious action is the primary CTA.
//

import SwiftUI

/// Compact Luna power cluster, pinned top-TRAILING on the hero (the status
/// chip owns the top-leading corner; actions live right). HARD GATE (the spec
/// is LunaPower.swift's file header - probe order, minimum luna version, MAC
/// match, zeroed-MAC fail-closed, credential-free): renders NOTHING unless a
/// usable luna matched this host's MAC to a permission-granted UpSnap device.
/// One quiet power-glyph menu - offline offers a plain Wake (Wake & Connect
/// owns the hero CTA); online offers Sleep / Restart / Shut Down behind
/// confirmation. A non-wake action in flight shows a small progress capsule
/// (the hero CTA carries the wake progress, and its cancel).
struct HostPowerControls: View {
    @Environment(AppModel.self) private var model
    /// Pending destructive verb ("off"/"reboot") awaiting confirmation.
    @State private var confirmPowerVerb: String?

    private enum Phase { case offline, online }

    /// Power-relevant host phase off fresh polled truth; nil (no controls)
    /// while connecting/streaming or when the sample is stale/unknown.
    private var phase: Phase? {
        if case .connecting = model.streamPhase { return nil }
        if model.isStreaming { return nil }
        guard let host = model.selectedHost,
              let live = model.hostLiveStatus, live.hostID == host.id,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            return nil
        }
        switch live.state {
        case .asleep: return .offline
        case .idle: return .online
        default: return nil
        }
    }

    var body: some View {
        if let host = model.selectedHost,
           let device = LunaPower.shared.gatedDevice(for: host) {
            if let verb = LunaPower.shared.actionInFlight[host.id], verb != "on" {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verb == "off" ? "Shutting Down…"
                         : verb == "sleep" ? "Sleeping…" : "Restarting…")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
            } else if let phase, LunaPower.shared.actionInFlight[host.id] == nil {
                Menu {
                    switch phase {
                    case .offline:
                        Button("Wake") {
                            model.wakeHost(host, device: device, thenConnect: false)
                        }
                    case .online:
                        Button("Sleep") {
                            model.powerAction("sleep", host: host, device: device)
                        }
                        Button("Restart…") { confirmPowerVerb = "reboot" }
                        Divider()
                        Button("Shut Down…", role: .destructive) { confirmPowerVerb = "off" }
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("PC power menu")
                .confirmationDialog(
                    confirmPowerVerb == "off" ? "Shut down \(host.displayName)?"
                                              : "Restart \(host.displayName)?",
                    isPresented: Binding(
                        get: { confirmPowerVerb != nil },
                        set: { if !$0 { confirmPowerVerb = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(confirmPowerVerb == "off" ? "Shut Down" : "Restart",
                           role: .destructive) {
                        if let verb = confirmPowerVerb {
                            model.powerAction(verb, host: host, device: device)
                        }
                        confirmPowerVerb = nil
                    }
                    Button("Cancel", role: .cancel) { confirmPowerVerb = nil }
                }
            }
        }
    }
}
