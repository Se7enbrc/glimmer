// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import OSLog
import SwiftUI

@MainActor
struct StreamView: UIViewControllerRepresentable {
    let model: StreamSessionModel
    let close: () -> Void

    func makeUIViewController(context: Context) -> StreamViewController {
        StreamViewController(model: model, close: close)
    }

    func updateUIViewController(_ controller: StreamViewController, context: Context) {
        controller.startWhenReady()
    }

    static func dismantleUIViewController(_ controller: StreamViewController, coordinator: ()) {
        controller.model.stop()
    }
}

@MainActor
final class StreamViewController: GCEventViewController {
    let model: StreamSessionModel
    let surface = StreamSurface()
    private(set) var presentationActive = false
    private let overlay: UIHostingController<StreamControls>
    private let outputs: StreamOutputCoordinator
    private(set) var touchCapture: StreamTouchCapture?
    private weak var presentationWindow: UIWindow?

    init(model: StreamSessionModel, close: @escaping () -> Void, outputs: StreamOutputCoordinator = .shared) {
        self.model = model
        self.outputs = outputs
        overlay = UIHostingController(rootView: StreamControls(model: model, close: close))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppDelegate.streamOrientations(for: traitCollection.userInterfaceIdiom)
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = true
        view.backgroundColor = .black
        view.addSubview(surface)
        surface.displayChanged = { [weak self] in
            self?.model.screenChanged()
            self?.startWhenReady()
        }
        model.presentationEnded = { [weak self] in
            guard let self else { return }
            outputs.end(self)
        }
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        installInputCapture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationActive = true
        updateOrientation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateOrientation()
        startWhenReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if surface.superview === view { surface.frame = view.bounds }
        overlay.view.frame = view.bounds
        startWhenReady()
    }

    func startWhenReady() {
        guard isViewLoaded, view.window != nil else { return }
        guard !model.phase.isEnded, model.phase != .stopping else { outputs.end(self); return }
        outputs.update(self)
        guard surface.window != nil, surface.bounds.width > 0, surface.bounds.height > 0,
              traitCollection.userInterfaceIdiom == .pad || model.externalDisplayActive
                || view.bounds.width > view.bounds.height else { return }
        model.start(surface: surface)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        presentationActive = false
        model.stop()
        outputs.end(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Re-evaluate after SwiftUI removes its presentation; a replacement stream keeps its own lock.
        Task { @MainActor [weak window = presentationWindow] in
            guard let window, window.isKeyWindow, let scene = window.windowScene else { return }
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: AppDelegate.orientationMask(for: window)))
        }
    }

    private func installInputCapture() {
        touchCapture = StreamTouchCapture(view: view, actions: .init(move: { [weak self] delta, time in
            guard let self else { return }
            let motion = pointerMotion(delta)
            model.streamInput?.movePointer(dx: Double(motion.x), dy: Double(motion.y), capturedAt: time)
        }, scroll: { [weak self] delta, time in
            guard let self else { return }
            let scale = view.traitCollection.displayScale
            model.streamInput?.scroll(x: Double(-delta.x * scale), y: Double(delta.y * scale),
                                     precise: true, capturedAt: time)
        }, click: { [weak model] secondary, time in
            model?.streamInput?.setPointerButton(secondary ? .right : .left, pressed: true, capturedAt: time)
            model?.streamInput?.setPointerButton(secondary ? .right : .left, pressed: false, capturedAt: time)
        }, endScroll: { [weak model] in model?.streamInput?.endScroll() },
           revealControls: { [weak model] in model?.showControls() }))
        model.inputCaptureChanged = { [weak self] focused in
            self?.touchCapture?.setEnabled(focused, mouseEnabled: self?.model.launch.touchMouseEnabled ?? true)
            self?.controllerUserInteractionEnabled = !focused
        }
        surface.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show controls") { [weak model] _ in
            model?.showControls()
            return true
        }]
    }

    private func pointerMotion(_ delta: CGPoint) -> CGPoint {
        guard let format = model.requestedFormat else { return .zero }
        return StreamDisplayGeometry.relativeMotion(delta, viewSize: view.bounds.size,
            streamSize: CGSize(width: format.width, height: format.height))
    }

    private func updateOrientation() {
        guard let window = view.window, window.isKeyWindow, window.traitCollection.userInterfaceIdiom != .pad,
              let scene = window.windowScene else { return }
        presentationWindow = window
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        var owner: UIViewController = self
        while let parent = owner.parent { owner = parent }
        owner.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard traitCollection.userInterfaceIdiom != .pad else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            Logger(subsystem: "io.ugfugl.Glimmer", category: "Display")
                .error("Display rotation failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

@MainActor
struct StreamControls: View {
    let model: StreamSessionModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingQuit = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            statusPane
            TouchOverlay(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: model.touchControlsVisible ? .center : .bottom) {
            if model.inputFocused { notices.offset(y: model.touchControlsVisible ? -24 : 0) }
        }
        .opacity(model.dismissWhenStopped ? 0 : 1)
        .allowsHitTesting(!model.dismissWhenStopped)
        .accessibilityHidden(model.dismissWhenStopped)
        .modifier(IOSControllerLayoutStreamControls(model: model))
        .onChange(of: model.phase.isEnded && model.dismissWhenStopped, initial: true) { _, finished in
            if finished { close() }
        }
        .confirmationDialog("Quit \(model.launch.appName) on \(model.launch.pcName)?",
                            isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit \(model.launch.appName)", role: .destructive, action: model.quitGame)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unsaved progress may be lost. Other streams from \(model.launch.pcName) will stop.")
        }
    }

    private var statusPane: some View {
        ZStack {
            if !model.editingTouchControls {
                if model.phase == .streaming, !model.controllerConnected, !model.touchGeometryUsable {
                    ScrollView {
                        Text("Make this window larger to use touch controls.")
                            .multilineTextAlignment(.center).padding()
                    }
                } else if model.phase == .streaming {
                    status
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            status.fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, alignment: .trailing) {
            if !model.editingTouchControls && (model.controlsVisible || model.phase != .streaming) {
                VStack(alignment: .trailing, spacing: 0) {
                    controls
                    if model.pictureNeedsReview {
                        VStack(alignment: .trailing, spacing: 8) {
                            Text("Does \(model.launch.appName) look right?")
                            Button("Keep this size") { model.keepSize?() }
                            Button("Use the previous size") { model.restoreSize?() }
                        }.buttonStyle(.glass).padding()
                    }
                    if let format = model.requestedFormat {
                        Text("Requested: \(format.summary)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal).padding(.bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if !model.inputFocused { notices } }
        .background {
            if colorScheme == .light, !model.editingTouchControls,
               model.controlsVisible || model.phase != .streaming
                || (!model.controllerConnected && !model.touchGeometryUsable) {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
    }

    private var notices: some View {
        VStack(spacing: 8) {
            if let message = model.controllerModeMessage, model.inputFocused {
                Text(message).font(.callout).padding(8).glassEffect().transition(.opacity)
            }
            if model.waitingForVideo, model.phase == .streaming {
                Label("Waiting for video…", systemImage: "clock").font(.callout).padding().glassEffect()
            }
        }
        .padding(.bottom, 8).allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.controllerModeMessage)
    }

    @ViewBuilder private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            controlLayout.labelStyle(.titleOnly)
        } else {
            controlLayout
        }
    }

    private var controlLayout: some View {
        VStack(alignment: .trailing) {
            ViewThatFits(in: .horizontal) {
                HStack { controlActions }
                HStack { controlActions }.labelStyle(.iconOnly)
                VStack(alignment: .trailing) { controlActions }
            }
            if model.phase == .streaming, model.controllerConnected {
                Button(model.touchControlsRequested ? "Hide touch controls" : "Show touch controls",
                       systemImage: "gamecontroller", action: model.toggleTouchControls)
                    .buttonStyle(.glass)
            }
        }.padding()
    }

    @ViewBuilder private var controlActions: some View {
        if model.phase == .streaming {
            IOSControllerLayoutStreamButton(model: model)
            Button("Edit controls…", systemImage: "hand.draw") {
                model.showControls()
                model.editingTouchControls = true
            }.buttonStyle(.glass)
            Button("Resume", systemImage: "play.fill", action: model.resumeInput)
                .buttonStyle(.glass)
                .disabled(!model.controllerConnected && !model.touchGeometryUsable)
                .accessibilityHint("Returns controller and touch input to the PC.")
        }
        Button {
            if model.phase.isEnded { close() } else { model.disconnect() }
        } label: {
            Label {
                Text(model.phase.isEnded ? "Done" : "Disconnect")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark")
            }
        }
        .buttonStyle(.glass)
        .disabled(model.phase == .stopping)
        .accessibilityHint(model.phase.isEnded ? "Returns to your apps."
            : model.launch.leaveGamesRunning ? "Ends this stream and leaves the game running on the PC."
            : "Ends this stream and quits the game on the PC.")
        if !model.phase.isEnded {
            Button("Quit \(model.launch.appName)…", role: .destructive) { confirmingQuit = true }
                .buttonStyle(.glass).disabled(model.phase == .stopping)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text(model.waitingForVideo ? "Waiting for video…" : "Connecting to \(model.launch.pcName)…")
                Text(model.launch.appName).font(.footnote).foregroundStyle(.secondary)
            }
        case .stopping:
            ProgressView("Disconnecting…")
        case .reconnecting:
            ProgressView("Reconnecting to \(model.launch.pcName)…")
        case .ended(let message):
            Text(message).multilineTextAlignment(.center).padding(32)
        case .streaming:
            if model.externalDisplayActive, !model.controlsVisible {
                Label("Playing on the connected display", systemImage: "display")
                    .foregroundStyle(.secondary)
                    .accessibilityAction(named: "Show controls", model.showControls)
            }
            if model.controlsVisible {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Hold Menu for a second and release to switch between gamepad and mouse.")
                        Text(model.launch.mouseStick.controls)
                        Text("Hold Menu, Options, and both shoulder buttons to disconnect.")
                        if model.launch.touchMouseEnabled {
                            Text("Drag to move the pointer. Tap to click.")
                            Text("Use two fingers to scroll or tap for a secondary click.")
                        }
                        Text("Tap with three fingers to show these controls.")
                            .accessibilityHint("VoiceOver users can choose Show controls on the video.")
                        if model.audioUnavailable { Label("Audio is unavailable", systemImage: "speaker.slash") }
                        if model.connectionPoor { Label("Connection is unstable", systemImage: "wifi.exclamationmark") }
                    }.padding(32).multilineTextAlignment(.center)
                }
            }
        }
    }
}

extension StreamSessionModel.Phase {
    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}
