// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

@MainActor
struct LauncherView: View {
    static let pcSymbol = "display"
    private let styleOverride: LauncherStyle?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var controllers = ControllerMonitor()
    @State private var model: LauncherModel
    @AppStorage("launcherStyle", store: PersistentStorage.defaults)
    private var launcherStyle: LauncherStyle = .buttons
    @State private var addingPC = false
    @State private var pendingAddress: String?
    @State private var showingSettings = false
    @State private var pendingAddPC = false
    @State private var pendingPC: HostDiscovery.Discovered?
    @AppStorage("leaveGamesRunning", store: PersistentStorage.defaults) private var leaveGamesRunning = false
    @AppStorage("streamProfile", store: PersistentStorage.defaults) private var profile: StreamProfile = .native120
    @AppStorage(AdaptiveBandwidth.defaultsKey, store: PersistentStorage.defaults) private var adaptiveBandwidth = false
    @AppStorage("touchMouseEnabled", store: PersistentStorage.defaults) private var touchMouseEnabled = true
    @AppStorage("controllerMouseStick", store: PersistentStorage.defaults)
    private var mouseStick: ControllerMouseStick = .right

    init(model: LauncherModel = .make(), style: LauncherStyle? = nil) {
        _model = State(initialValue: model)
        styleOverride = style
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        pcHeader
                        LauncherGallery(model: model, style: styleOverride ?? launcherStyle,
                                        size: CGSize(width: max(0, geometry.size.width - 48),
                                                     height: geometry.size.height))
                        if let ended = model.endedGame {
                            Button(model.endedFormat == nil ? "Start \(ended.name)"
                                   : "Start \(ended.name) at the previous size", action: model.startEndedGame)
                                .buttonStyle(.bordered).disabled(model.busy)
                        }
                        if model.busy {
                            HStack {
                                ProgressView("Connecting…")
                                Button("Cancel", role: .cancel, action: model.cancelOperation)
                            }
                        }
                        if let message = model.message { Text(message).foregroundStyle(.secondary) }
                        if model.savedPCs.isEmpty, model.selectedName == nil {
                            Button("Set up a PC", systemImage: "plus") { showingSettings = true }
                                .buttonStyle(.glassProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .keyboardShortcut(",", modifiers: .command)
                        .disabled(model.busy || addingPC || model.pairing != nil || model.stream != nil)
                }
            }
        }
        .tint(Color("AccentColor"))
        .sheet(isPresented: $showingSettings, onDismiss: finishSettings) {
            GlimmerSettings(profile: $profile, stick: $mouseStick, model: model,
                addPC: { pendingAddPC = true; showingSettings = false },
                pairPC: { pendingPC = $0; showingSettings = false })
        }
        .onChange(of: leaveGamesRunning, initial: true) { _, enabled in model.leaveGamesRunning = enabled }
        .modifier(RunningGameConfirmation(model: model))
        .onChange(of: touchMouseEnabled, initial: true) { _, enabled in model.touchMouseEnabled = enabled }
        .onChange(of: profile, initial: true) { _, profile in model.streamProfile = profile }
        .onChange(of: mouseStick, initial: true) { _, stick in model.mouseStick = stick }
        .sheet(isPresented: $addingPC, onDismiss: {
            if let address = pendingAddress {
                pendingAddress = nil
                model.select(address: address)
            }
        }, content: { AddPCView { pendingAddress = $0 } })
        .sheet(item: Binding(get: { model.pairing }, set: {
            if $0 == nil { model.dismissPairing() }
        })) { prompt in
            PairingView(prompt: prompt, cancel: model.dismissPairing)
        }
        .fullScreenCover(item: $model.stream, onDismiss: model.streamClosed) { session in
            StreamView(model: session) { model.stream = nil }
                .modifier(RunningGameConfirmation(model: model, duringStream: true))
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .top)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controllers.update(active: phase == .active, streaming: model.hasActiveStream)
            updateAvailability()
        }
        .onChange(of: model.hasActiveStream) { _, streaming in
            controllers.update(active: scenePhase == .active, streaming: streaming)
        }
        .onAppear { controllers.update(active: scenePhase == .active, streaming: model.hasActiveStream) }
        .onDisappear { controllers.stop() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            model.availabilityChanged(active: false, background: false, protectedDataAvailable: false)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in updateAvailability() }
    }

    private var pcHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            HStack {
                Image(systemName: Self.pcSymbol)
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 30) : .largeTitle)
                    .foregroundStyle(Color("AccentColor"))
                    .accessibilityHidden(true)
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    controllerBadge
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    if let running = model.runningAppOutsideGallery {
                        RunningGameMenu(model: model, app: running)
                    }
                    ForEach(model.savedPCs) { pc in
                        Button(pc.name, systemImage: Self.pcSymbol) { model.select(pc) }
                            .accessibilityIdentifier("pc-picker-\(pc.id)")
                    }
                    Button("PC settings", systemImage: "gearshape") { showingSettings = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.selectedName ?? "Choose a PC").font(.title2).bold()
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.down")
                            .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 13) : .caption)
                    }
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Color.primary)
                }
                .disabled(model.busy)
                if model.selectedName != nil {
                    Text(profile.summary(adaptive: adaptiveBandwidth)).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Pair with a PC running Sunshine in Settings.").foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                controllerBadge
            }
        }
    }

    @ViewBuilder private var controllerBadge: some View {
        if controllers.controllers.contains(where: \.hasExtendedGamepad) {
            Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                .accessibilityLabel("Controller connected")
        }
    }

    private func finishSettings() {
        if pendingAddPC {
            pendingAddPC = false
            addingPC = true
        } else if let pc = pendingPC {
            pendingPC = nil
            model.select(pc)
        }
    }

    private func updateAvailability() {
        model.availabilityChanged(active: scenePhase == .active, background: scenePhase == .background,
                                  protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
        model.selectInitialPCIfNeeded()
    }
}

extension StreamSessionModel: Identifiable {
    nonisolated var id: UUID { launch.id }
}
