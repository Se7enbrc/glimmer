//
//  PairSheet.swift
//
//  The "Pair a new PC" flow. Extracted from SettingsView (which was at its
//  file-length limit) and given a discover-first UX: the sheet opens to a live
//  mDNS list of PCs on the network (the Discovery actor, previously unwired),
//  the user picks one (or falls back to a manual address), and pairing then
//  auto-starts so the displayed PIN is immediately enterable on the host.
//
//  Also hosts PINTiles + FloatingWindowLevel, both used only here.
//

import AppKit
import Network
import SwiftUI

struct PairSheet: View {
    @Environment(MoonlightManager.self) private var moonlight
    @Environment(\.dismiss) private var dismiss
    @State private var hostnameOrIP: String
    @State private var pin: String = ""
    /// nil = still choosing a host; non-nil = a host was picked/entered and we
    /// move to the PIN/handshake step.
    @State private var chosen: Bool

    /// Optional pre-fill, used by the "re-pair" recovery path so the user
    /// doesn't retype the host's address - that path jumps straight to the PIN
    /// step. The normal "Pair a new PC" entry starts on the discovery chooser.
    init(initialAddress: String = "") {
        _hostnameOrIP = State(initialValue: initialAddress)
        _chosen = State(initialValue: !initialAddress.isEmpty)
    }

    private var isSuccess: Bool {
        if case .success = moonlight.pairingPhase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(titleText)
                .font(.title2.bold())
                .contentTransition(.opacity)

            if isSuccess {
                successBody
            } else if !chosen {
                HostChooser(selected: { addr in
                    hostnameOrIP = addr
                    chosen = true
                })
            } else {
                pinBody
            }

            footer
        }
        .padding(28)
        .frame(width: 480)
        // Float above all other Glimmer windows so the PIN being read off isn't
        // hidden behind the launcher or Settings. Reverts on dismiss.
        .background(FloatingWindowLevel())
    }

    private var titleText: String {
        if isSuccess { return "Paired" }
        return chosen ? "Pair a new PC" : "Choose a PC"
    }

    @ViewBuilder private var successBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: isSuccess)
            Text("\(hostnameOrIP) is ready to stream.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .sensoryFeedback(.success, trigger: isSuccess)
        // Auto-close after a brief beat so the check + haptic register; select
        // the freshly-paired host so the launcher lands on it.
        .task(id: isSuccess) {
            guard isSuccess else { return }
            selectPairedHost()
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { dismiss() }
        }
    }

    @ViewBuilder private var pinBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On \(hostnameOrIP), enter this code")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            PINTiles(pin: pin)
                .onAppear {
                    if pin.isEmpty { pin = moonlight.generatePairingPIN() }
                    // Showing the code IS the start of pairing - the handshake
                    // must be open on the host for the typed PIN to land.
                    startPairing()
                }
            Text("Open your PC's pairing page and type these four digits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let msg = moonlight.pairingMessage, !isSuccess {
            HStack(spacing: 8) {
                if moonlight.pairingInFlight {
                    ProgressView().controlSize(.small)
                } else if msg.lowercased().contains("fail")
                            || msg.lowercased().contains("couldn't")
                            || msg.lowercased().contains("invalid") {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                }
                Text(msg).font(.callout)
                Spacer()
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if isSuccess {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stream now") {
                    selectPairedHost()
                    moonlight.streamDefaultApp()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(StreamButtonStyle())
            } else if !chosen {
                Spacer()
                Button("Cancel") { dismiss() }
            } else {
                Spacer()
                Button("Back") {
                    chosen = false
                    pin = ""
                }
                Button("Cancel") { dismiss() }
                // Manual retry - pairing normally auto-starts with the code.
                Button("Retry") { startPairing() }
                    .buttonStyle(StreamButtonStyle())
                    .disabled(moonlight.pairingInFlight)
            }
        }
    }

    private func startPairing() {
        guard !moonlight.pairingInFlight, !isSuccess,
              !hostnameOrIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if pin.count != 4 { pin = moonlight.generatePairingPIN() }
        Task { await moonlight.pair(hostnameOrIP: hostnameOrIP, pin: pin) }
    }

    private func selectPairedHost() {
        let typed = hostnameOrIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = moonlight.hosts.first(where: {
            [$0.name, $0.displayName, $0.localAddress, $0.manualAddress]
                .compactMap { $0 }
                .contains { $0.caseInsensitiveCompare(typed) == .orderedSame }
        }) {
            moonlight.selectHost(host)
        }
    }
}

// MARK: - Discover-first host chooser

/// Live mDNS list of PCs on the network + a manual-address fallback. Picking a
/// row (or submitting the manual field) hands the resolved address back via
/// `selected`, which advances the sheet to the PIN step.
private struct HostChooser: View {
    let selected: (String) -> Void
    @State private var found: [HostDiscovery.Discovered] = []
    @State private var manual: String = ""
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if found.isEmpty && !showManual {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for PCs on your network...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            if !found.isEmpty {
                VStack(spacing: 8) {
                    ForEach(found) { host in
                        Button {
                            selected(host.host)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.displayName).fontWeight(.medium)
                                    Text(host.host).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if showManual {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hostname or IP")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. tower.local or 192.168.1.10", text: $manual)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .onSubmit { submitManual() }
                        Button("Continue") { submitManual() }
                            .buttonStyle(StreamButtonStyle())
                            .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                Button {
                    showManual = true
                } label: {
                    Label("Enter an address manually", systemImage: "keyboard")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .task {
            // Stream discovered hosts until the view goes away. HostDiscovery
            // is an actor; start() is actor-isolated so we await it, then
            // consume the AsyncStream it returns.
            let stream = await HostDiscovery.shared.start()
            for await hosts in stream {
                found = hosts
            }
            await HostDiscovery.shared.stop()
        }
    }

    private func submitManual() {
        let addr = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        selected(addr)
    }
}

// MARK: - Window level

/// Raises its hosting NSWindow to `.floating` while present so the pairing
/// sheet stays above the launcher + Settings windows.
private struct FloatingWindowLevel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = .floating }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.level = .floating }
    }
}

// MARK: - PIN tiles

/// Display-only tiles showing the four-digit PIN the user types on the HOST.
/// Static labels, not input fields - the digits are generated by Glimmer and
/// read off by the user, not typed here.
private struct PINTiles: View {
    let pin: String
    var body: some View {
        let digits = pin.padding(toLength: 4, withPad: " ", startingAt: 0)
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(digits.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch).trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .glassEffect(
                            .regular.tint(Color.accentColor.opacity(0.12)),
                            in: .rect(cornerRadius: 14)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code")
        .accessibilityValue(pin.map(String.init).joined(separator: " "))
    }
}
