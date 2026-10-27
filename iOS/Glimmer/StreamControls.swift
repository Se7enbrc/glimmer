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
                    GeometryReader { geometry in
                        menu
                            .labelStyle(StreamMenuLabelStyle(titlesOnly: textSize.isAccessibilitySize))
                            .frame(width: min(max(0, geometry.size.width - 24),
                                              textSize.isAccessibilitySize ? 560 : 360),
                                   height: min(max(0, geometry.size.height - 24), menuHeight))
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
        .environment(\.colorScheme, model.overlayAppearance.colorScheme ?? colorScheme)
        .opacity(model.dismissWhenStopped ? 0 : 1)
        .allowsHitTesting(!model.dismissWhenStopped)
        .accessibilityHidden(model.dismissWhenStopped)
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
                    .navigationTitle("Stream controls")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingHelp = false }.accessibilityIdentifier("stream-help-done")
                        }
                    }
            }
        }
    }

    private var menuHeight: CGFloat {
        if textSize.isAccessibilitySize { return 720 }
        return model.phase == .streaming ? 560 : 280
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.launch.appName).font(.headline).lineLimit(1)
                        Text(model.launch.pcName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.vertical, 8)
                    status
                    if model.phase == .streaming { playActions }
                    if model.pictureNeedsReview {
                        Text("Does \(model.launch.appName) look right?")
                        Button("Keep this size") { model.keepSize?() }.accessibilityIdentifier("stream-size-keep")
                        Button("Use the previous size") { model.restoreSize?() }
                            .accessibilityIdentifier("stream-size-restore")
                    }
                    if let format = model.requestedFormat {
                        Text("Requested: \(format.summary)"
                             + (model.requestedStartKbps.map { " · starts at \($0 / 1000) Mbps" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.phase.isEnded {
                        Button("Quit \(model.launch.appName)…", systemImage: "stop", role: .destructive) {
                            confirmingQuit = true
                        }.disabled(model.phase == .stopping).accessibilityIdentifier("stream-quit")
                    }
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("stream-controls-actions")
            connectionActions.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .buttonStyle(StreamMenuActionStyle())
        .modifier(StreamOverlaySurface())
    }

    @ViewBuilder private var playActions: some View {
        Button("Resume", systemImage: "play.fill", action: model.resumeInput)
            .disabled(!model.hasGameInput)
            .accessibilityHint("Returns game input to the PC.")
            .accessibilityIdentifier("stream-resume")
        Button(model.statsShown ? "Hide Stream Stats" : "Show Stream Stats",
               systemImage: "chart.xyaxis.line", action: model.toggleStats)
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
        Button("Edit controls…", systemImage: "hand.draw") { model.editingTouchControls = true }
            .accessibilityIdentifier("stream-edit-controls")
        IOSControllerLayoutStreamButton(model: model)
        Button("How to play", systemImage: "questionmark.circle") { showingHelp = true }
            .accessibilityIdentifier("stream-help")
    }

    @ViewBuilder private var connectionActions: some View {
        Divider()
        Button(model.phase.isEnded ? "Done" : "Disconnect", systemImage: "xmark") {
            if model.phase.isEnded { close() } else { model.disconnect() }
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
            Label(model.waitingForVideo ? "Waiting for video…" : "Connecting to \(model.launch.pcName)…",
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
                Text(message).font(.callout).padding(12).modifier(StreamOverlaySurface())
            }
            if model.waitingForVideo, model.phase == .streaming {
                Label("Waiting for video…", systemImage: "clock")
                    .font(.callout).padding(12).modifier(StreamOverlaySurface())
            }
        }
        .frame(maxWidth: 360).fixedSize(horizontal: false, vertical: true)
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
