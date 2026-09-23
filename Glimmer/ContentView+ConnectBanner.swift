//
//  ContentView+ConnectBanner.swift
//
//  The connect-failure banner above the hero card and the recovery it offers,
//  split out of ContentView.swift for length.
//

import SwiftUI

/// The recovery a stream error offers, in the banner and the menu bar's
/// Attention card, from the kind the connect path recorded with the error.
enum ConnectBannerAction: Equatable {
    case wakeAndConnect
    case pairAgain
    case tryAgain

    init(kind: AppModel.StreamErrorKind, canWake: Bool) {
        switch kind {
        case .pairing: self = .pairAgain
        case .unreachable where canWake: self = .wakeAndConnect
        case .unreachable, .other: self = .tryAgain
        }
    }

    var title: String {
        switch self {
        case .wakeAndConnect: "Wake and Connect"
        case .pairAgain: "Pair Again…"
        case .tryAgain: "Try Again"
        }
    }

    var systemImage: String {
        switch self {
        case .wakeAndConnect: "power"
        case .pairAgain: "key"
        case .tryAgain: "arrow.clockwise"
        }
    }
}

extension AppModel {
    /// The recovery the current stream error offers for the selected PC.
    var streamErrorAction: ConnectBannerAction {
        ConnectBannerAction(kind: nativeStreamErrorKind, canWake: selectedHost.map(canWake) ?? false)
    }

    /// Clears the error and runs its recovery.
    func runStreamErrorAction() {
        let action = streamErrorAction
        nativeStreamError = nil
        switch action {
        case .wakeAndConnect: if let host = selectedHost { wakeHost(host, thenConnect: true) }
        case .pairAgain: requestPairing(for: selectedHost)
        case .tryAgain: retryLastLaunch()
        }
    }
}

/// Tip-style banner above the hero card. Shows for stream errors. Stays out
/// of the way otherwise. Internal (not private): ConnectSurface, which
/// mounts it, lives in ContentView.swift.
struct ConnectBanner: View {
    @Environment(AppModel.self) private var model

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
                    // A sleeping PC gets Wake and Connect, a pairing or trust
                    // failure opens the re-pair sheet, anything else retries.
                    let action = model.streamErrorAction
                    Button { model.runStreamErrorAction() } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
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
}
