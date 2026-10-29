// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import SwiftUI

@MainActor
struct StreamControls: View {
    let model: StreamSessionModel
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingQuit = false
    @State private var showingHelp = false
    @State private var keyboardConnected = GCKeyboard.coalesced != nil

    private var chromeVisible: Bool {
        model.canStart && !model.phase.isEnded && model.phase != .stopping
            && (model.controlsVisible || model.touchControlsVisible || model.menuVisibility.visible
                || model.phase != .streaming || model.waitingForVideo || model.controllerModeMessage != nil)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if !model.editingTouchControls {
                if model.controlsVisible || model.phase != .streaming {
                    if model.phase == .streaming {
                        Button(action: model.resumeInput) { Color.clear.contentShape(.rect) }
                            .buttonStyle(.plain)
                            .ignoresSafeArea()
                            .focusable(false)
                            .accessibilityHidden(true)
                            .disabled(!model.hasGameInput)
                    }
                    GeometryReader { geometry in
                        // A short landscape window lays actions out in two columns so every row fits.
                        let wide = !textSize.isAccessibilitySize && geometry.size.height < 500
                            && geometry.size.width >= 600
                        menu(columns: wide ? 2 : 1)
                            .labelStyle(StreamMenuLabelStyle(titlesOnly: textSize.isAccessibilitySize))
                            .frame(width: min(max(0, geometry.size.width - 24),
                                              textSize.isAccessibilitySize ? 560 : wide ? 520 : 360))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                model.overlayAppearance.menuFrame = frame.isEmpty ? nil : frame
                            }
                            .onDisappear { model.overlayAppearance.menuFrame = nil }
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                } else if model.externalDisplayActive {
                    Label("Playing on the connected display", systemImage: "display")
                        .padding().modifier(StreamOverlaySurface())
                        .frame(maxWidth: .infinity)
                        .accessibilityAction(named: "Show controls", model.showControls)
                }
            }
            TouchOverlay(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { noticeOverlay }
        // Before the first sample a card sits on a black picture, so it starts dark; play follows the sampler.
        .environment(\.colorScheme, model.overlayAppearance.colorScheme
            ?? (model.phase == .streaming ? colorScheme : .dark))
        .opacity(model.dismissWhenStopped ? 0 : 1)
        .allowsHitTesting(!model.dismissWhenStopped)
        .accessibilityHidden(model.dismissWhenStopped)
        .controllerMenuDismissal(active: model.controlsVisible && model.phase == .streaming
            && model.canStart && !model.editingTouchControls && !showingHelp && !confirmingQuit,
            perform: model.resumeInput)
        .onChange(of: chromeVisible, initial: true) { _, visible in model.showOverlayChrome(visible) }
        .onChange(of: model.phase.isEnded && model.dismissWhenStopped, initial: true) { _, finished in
            if finished { close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboardConnected = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            keyboardConnected = GCKeyboard.coalesced != nil
        }
        .confirmationDialog("Quit \(model.launch.appName) on \(model.launch.pcName)?",
                            isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit \(model.launch.appName)", role: .destructive, action: model.quitGame)
                .accessibilityIdentifier("stream-quit-confirm")
            Button("Cancel", role: .cancel) { }.accessibilityIdentifier("stream-quit-cancel")
        } message: {
            Text("Unsaved progress may be lost. Other streams from \(model.launch.pcName) will stop.")
        }
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                StreamControlsHelp(model: model, keyboardConnected: keyboardConnected)
                    .navigationTitle("Help")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingHelp = false }.accessibilityIdentifier("stream-help-done")
                        }
                    }
            }
        }
    }

    // Sized to its rows when they fit; otherwise the rows scroll under the pinned Disconnect.
    private func menu(columns: Int) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) { menuRows(columns: columns); connectionActions }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("stream-controls-actions")
            ScrollView { menuRows(columns: columns) }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicatorsFlash(onAppear: true)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
                .accessibilityIdentifier("stream-controls-actions")
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    // Opaque enough that rows scrolling beneath never read through at large text.
                    connectionActions.background(.thickMaterial)
                }
        }
        .buttonStyle(StreamMenuActionStyle())
        .clipShape(.rect(cornerRadius: 24))
        .modifier(StreamOverlaySurface())
    }

    private func menuRows(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.launch.appName).font(.headline).lineLimit(1)
                // At accessibility sizes the PC name and format would push play actions out of view.
                if !textSize.isAccessibilitySize {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 8).padding(.bottom, 4)
            Group { status }.padding(.horizontal, 8).padding(.vertical, 6)
            // The size question needs an answer before anything else on the list.
            if model.pictureNeedsReview {
                Text("Does \(model.launch.appName) look right?").font(.headline)
                    .accessibilityAddTraits(.isHeader).padding(.horizontal, 8).padding(.vertical, 6)
                Button("Keep this size", systemImage: "checkmark") { model.keepSize?() }
                    .accessibilityIdentifier("stream-size-keep")
                Button("Use the previous size", systemImage: "arrow.uturn.backward") { model.restoreSize?() }
                    .accessibilityIdentifier("stream-size-restore")
            }
            if model.phase == .streaming {
                if columns > 1 {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())],
                              alignment: .leading, spacing: 0) { playActions }
                } else {
                    playActions
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var playActions: some View {
        Button("Resume", systemImage: "play.fill", action: model.resumeInput)
            .disabled(!model.hasGameInput)
            .accessibilityHint("Returns game input to the PC.")
            .accessibilityIdentifier("stream-resume")
        Button(model.statsShown ? "Hide stream stats" : "Show stream stats",
               systemImage: "chart.xyaxis.line", action: model.toggleStats)
            .contentTransition(.identity)
            .accessibilityIdentifier("stream-stats-toggle")
        if model.controllerConnected || model.hardwareInputConnected {
            Button(model.touchControlsRequested ? "Hide touch controls" : "Show touch controls",
                   systemImage: "hand.draw", action: model.toggleTouchControls)
                .accessibilityIdentifier("stream-touch-toggle")
        }
        if model.menuController != nil {
            Button(model.menuControllerUsesMouse ? "Use gamepad mode" : "Use mouse mode",
                   systemImage: "computermouse", action: model.toggleControllerMouseMode)
                .accessibilityIdentifier("stream-controller-mode")
        }
        Button("Edit controls…", systemImage: "slider.horizontal.3") { model.editingTouchControls = true }
            .accessibilityIdentifier("stream-edit-controls")
        IOSControllerLayoutStreamButton(model: model)
        Button("Help", systemImage: "questionmark.circle") { showingHelp = true }
            .accessibilityIdentifier("stream-help")
    }

    private var subtitle: String {
        guard let format = model.requestedFormat else { return model.launch.pcName }
        return "\(model.launch.pcName) · \(format.summary)"
            + (model.requestedStartKbps.map { " · starts at \($0 / 1000) Mbps" } ?? "")
    }

    // Quit and Disconnect share the pinned bar, side by side when the app's name allows.
    private var connectionActions: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { quitButton; disconnectButton }
                VStack(spacing: 0) { quitButton; disconnectButton }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    @ViewBuilder private var quitButton: some View {
        if !model.phase.isEnded {
            Button("Quit \(model.launch.appName)…", systemImage: "stop", role: .destructive) {
                confirmingQuit = true
            }.disabled(model.phase == .stopping).accessibilityIdentifier("stream-quit")
        }
    }

    private var disconnectButton: some View {
        Button {
            if model.phase.isEnded { close() } else { model.disconnect() }
        } label: {
            if model.phase.isEnded { Text("Done") } else { Label("Disconnect", systemImage: "xmark") }
        }
        .disabled(model.phase == .stopping)
        .accessibilityIdentifier("stream-disconnect")
        .accessibilityHint(model.phase.isEnded ? "Returns to your apps."
            : model.launch.leaveGamesRunning ? "Ends this stream and leaves the game running on the PC."
            : "Ends this stream and quits the game on the PC.")
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle, .connecting:
            Label(model.waitingForVideo ? "Waiting for video…" : "Connecting…",
                  systemImage: "network")
        case .stopping: Label("Disconnecting…", systemImage: "network")
        case .reconnecting: Label(model.recoveryText, systemImage: "wifi.exclamationmark")
        case .ended(let message): Text(message)
        case .streaming:
            if !model.hasGameInput { Text("Make this window larger to use touch controls.") }
            if model.audioUnavailable { Label("Audio is unavailable", systemImage: "speaker.slash") }
            if model.connectionPoor { Label("Connection is unstable", systemImage: "wifi.exclamationmark") }
        }
    }

    private var noticeOverlay: some View {
        GeometryReader { geometry in
            if model.inputFocused {
                notices
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        model.overlayAppearance.noticeFrame = frame.isEmpty ? nil : frame
                    }
                    .onDisappear { model.overlayAppearance.noticeFrame = nil }
                    .padding(.horizontal, 12)
                    .padding(.top, model.touchControlsVisible
                             ? TouchLayout.menuFrame(in: TouchOverlay.area(geometry)).maxY + 8 : 12)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .allowsHitTesting(false)
    }

    private var notices: some View {
        VStack(spacing: 8) {
            if let message = model.controllerModeMessage {
                StreamNoticeView(text: message, symbol: model.controllerModeSymbol).transition(.opacity)
            }
            if model.waitingForVideo, model.phase == .streaming {
                StreamNoticeView(text: "Waiting for video…", symbol: "clock")
            }
        }
        .frame(maxWidth: textSize.isAccessibilitySize ? 560 : 360).fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }
}

struct StreamOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque

    func body(content: Content) -> some View {
        if opaque {
            content.background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 24))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

struct StreamMenuActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(configuration.role == .destructive ? Color.red : .primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 8)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
            .opacity(enabled ? 1 : 0.45)
            .hoverEffect(.highlight)
    }
}

private struct StreamMenuLabelStyle: LabelStyle {
    let titlesOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if titlesOnly { configuration.title } else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}
