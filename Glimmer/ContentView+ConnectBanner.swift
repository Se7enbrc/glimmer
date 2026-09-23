//
//  ContentView+ConnectBanner.swift
//
//  The connect-failure banner above the hero card and the recovery it offers,
//  split out of ContentView.swift for length.
//

import SwiftUI

/// Which recovery the connect-failure banner offers, read off the sentence
/// `AppModel.connectFailureBanner` wrote. Nothing sets `nativeStreamErrorKind`
/// yet; once the connect path does, switch to it and delete this matching.
enum ConnectBannerAction: Equatable {
    case wakeAndConnect
    case pairAgain
    case tryAgain

    static func forError(_ message: String, canWake: Bool) -> ConnectBannerAction {
        // Every pairing or trust sentence (not paired, rejected client cert,
        // changed PC cert) says "pair", whatever it points at; no other does.
        if message.localizedCaseInsensitiveContains("pair") { return .pairAgain }
        // Only the genuine "never reached the host" sentences start this way
        // (see connectFailureBanner) - a host that answered but refused gets
        // its own honest copy instead, so it never lands here.
        if canWake, message.hasPrefix("Couldn't reach") { return .wakeAndConnect }
        return .tryAgain
    }
}

/// Tip-style banner above the hero card. Shows for stream errors. Stays out
/// of the way otherwise. Internal (not private): ConnectSurface, which
/// mounts it, lives in ContentView.swift.
struct ConnectBanner: View {
    @Environment(AppModel.self) private var model
    /// Owned by ConnectSurface: Pair Again clears the error, which empties
    /// this view, so a sheet hung off it would have nothing to attach to.
    @Binding var showRePair: Bool

    var body: some View {
        Group {
            // The "stream is in the background" affordance lives on the
            // StreamButton itself (its Back to Stream role), so the banner only
            // handles the load-bearing recovery case: stream errors.
            if let err = model.nativeStreamError, !err.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                    Text(err)
                        .textSelection(.enabled)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actionButton(for: err)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(model.selectedHost == nil || model.isStreaming)
                    // The action is disabled with no host selected or mid-
                    // stream, so without this the banner could otherwise
                    // become permanent.
                    Button {
                        model.nativeStreamError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Liquid Glass floating-panel chrome with the red stroke on
                // top - the stroke is the load-bearing severity affordance.
                .glassEffect(
                    .regular.tint(Color.red.opacity(0.12)),
                    in: .rect(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red, lineWidth: 1)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: model.nativeStreamError)
    }

    /// The banner's single action, chosen from the failure copy: a sleeping
    /// PC gets Wake and Connect, a pairing or trust failure opens the re-pair
    /// sheet, and anything else retries.
    @ViewBuilder
    private func actionButton(for error: String) -> some View {
        switch ConnectBannerAction.forError(error, canWake: model.selectedHost.map(model.canWake) ?? false) {
        case .wakeAndConnect:
            Button {
                model.nativeStreamError = nil
                if let host = model.selectedHost { model.wakeHost(host, thenConnect: true) }
            } label: {
                Label("Wake and Connect", systemImage: "power")
            }
        case .pairAgain:
            Button("Pair Again…") {
                model.nativeStreamError = nil
                showRePair = true
            }
        case .tryAgain:
            Button("Try Again") {
                model.nativeStreamError = nil
                model.retryLastLaunch()
            }
        }
    }
}
