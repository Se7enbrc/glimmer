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
    private let overlay: UIHostingController<StreamControls>
    private var touchCapture: StreamTouchCapture?
    private var screenIdentity: ObjectIdentifier?

    init(model: StreamSessionModel, close: @escaping () -> Void) {
        self.model = model
        overlay = UIHostingController(rootView: StreamControls(model: model, close: close))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = true
        view.backgroundColor = .black
        view.addSubview(surface)
        overlay.overrideUserInterfaceStyle = .dark
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        installInputCapture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateOrientation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateOrientation()
        startWhenReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface.frame = view.bounds
        overlay.view.frame = view.bounds
        if let screen = view.window?.windowScene?.screen {
            let identity = ObjectIdentifier(screen)
            if screenIdentity != identity {
                screenIdentity = identity
                model.screenChanged()
            }
        }
        startWhenReady()
    }

    func startWhenReady() {
        guard isViewLoaded, view.window != nil, view.bounds.width > view.bounds.height else { return }
        model.start(surface: surface)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.stop()
    }

    private func installInputCapture() {
        touchCapture = StreamTouchCapture(view: view, actions: .init(move: { [weak self] delta, time in
            guard let self else { return }
            let scale = surface.window?.windowScene?.screen.scale ?? 1
            model.streamInput?.movePointer(dx: Double(delta.x * scale), dy: Double(delta.y * scale), capturedAt: time)
        }, scroll: { [weak self] delta, time in
            guard let self else { return }
            let scale = surface.window?.windowScene?.screen.scale ?? 1
            model.streamInput?.scroll(x: Double(-delta.x * scale), y: Double(delta.y * scale),
                                     precise: true, capturedAt: time)
        }, click: { [weak model] secondary, time in
            model?.streamInput?.setPointerButton(secondary ? .right : .left, pressed: true, capturedAt: time)
            model?.streamInput?.setPointerButton(secondary ? .right : .left, pressed: false, capturedAt: time)
        }, endScroll: { [weak model] in model?.streamInput?.endScroll() },
           revealControls: { [weak model] in model?.showControls() }))
        model.inputCaptureChanged = { [weak self] focused in
            self?.touchCapture?.setEnabled(focused)
            self?.controllerUserInteractionEnabled = !focused
        }
        surface.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show controls") { [weak model] _ in
            model?.showControls()
            return true
        }]
    }

    private func updateOrientation() {
        guard let scene = view.window?.windowScene else { return }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
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

    var body: some View {
        ZStack {
            status
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top, alignment: .trailing) {
            if model.controlsVisible || model.phase != .streaming {
                VStack(alignment: .trailing, spacing: 0) {
                    controls
                    if let format = model.requestedFormat {
                        Text("Requested: \(format.summary)")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let message = model.controllerModeMessage, model.inputFocused {
                    Text(message).font(.callout).padding(8).glassEffect().allowsHitTesting(false)
                        .transition(.opacity)
                }
                if model.waitingForVideo, model.phase == .streaming {
                    Label("Waiting for video…", systemImage: "clock")
                        .font(.callout).padding().glassEffect()
                }
            }
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.controllerModeMessage)
        }
        .opacity(model.dismissWhenStopped ? 0 : 1)
        .allowsHitTesting(!model.dismissWhenStopped)
        .accessibilityHidden(model.dismissWhenStopped)
        .onChange(of: model.phase.isEnded && model.dismissWhenStopped, initial: true) { _, finished in
            if finished { close() }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { controlActions }
            VStack(alignment: .trailing) { controlActions }
        }.padding()
    }

    @ViewBuilder private var controlActions: some View {
        if model.phase == .streaming {
            Button("Resume", systemImage: "play.fill", action: model.resumeInput)
                .buttonStyle(.glass)
                .accessibilityHint("Returns controller and touch input to the PC.")
        }
        Button(model.phase.isEnded ? "Done" : "Disconnect", systemImage: "xmark") {
            if model.phase.isEnded { close() } else { model.disconnect() }
        }
        .buttonStyle(.glass)
        .disabled(model.phase == .stopping)
        .accessibilityHint("Disconnects without quitting the game on the PC.")
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
            if model.controlsVisible {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Hold Menu for a second and release to switch between gamepad and mouse.")
                        Text(model.launch.mouseStick.controls)
                        Text("Hold Menu, Options, and both shoulder buttons to disconnect.")
                        Text("Drag to move the pointer. Tap to click.")
                        Text("Use two fingers to scroll or tap for a secondary click.")
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
