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
        controller.stopPresentation()
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
    private(set) var keyboardMouseCapture: IOSKeyboardMouseCapture?
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
    override var prefersPointerLocked: Bool {
        model.inputFocused && viewIfLoaded?.window?.isKeyWindow == true
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
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: nil)
        }
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
        becomeFirstResponder()
        updateHardwareCapture()
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
        model.windowChanged(surface: surface)
    }

    func stopPresentation() {
        presentationActive = false
        model.stop()
        outputs.end(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        presentationActive = false
        // A full-screen editor covers this controller without removing the stream.
        model.showControls()
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
           revealControls: { [weak model] in model?.showControls() },
           revealMenu: { [weak model] in model?.menuVisibility.reveal() }))
        model.inputCaptureChanged = { [weak self] focused in
            self?.touchCapture?.setEnabled(focused, mouseEnabled: self?.model.launch.touchMouseEnabled ?? true)
            self?.controllerUserInteractionEnabled = !focused
            self?.updateHardwareCapture()
        }
        surface.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show controls") { [weak model] _ in
            model?.showControls()
            return true
        }]
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        guard notification.object as? UIWindow === viewIfLoaded?.window else { return }
        updateHardwareCapture()
    }

    private func updateHardwareCapture() {
        if model.phase.isEnded || model.phase == .stopping {
            keyboardMouseCapture?.stop()
            keyboardMouseCapture = nil
        } else if keyboardMouseCapture == nil, let input = model.streamInput {
            let capture = IOSKeyboardMouseCapture(input: input, quit: model.shortcuts.quit,
                                                  stats: model.shortcuts.stats)
            keyboardMouseCapture = capture
            capture.connected = { [weak model] in model?.hardwareConnectionChanged($0) }
            capture.resetShortcuts = { [weak model] in model?.shortcuts.reset() }
            capture.start()
        }
        keyboardMouseCapture?.setFocused(model.inputFocused && viewIfLoaded?.window?.isKeyWindow == true)
        setNeedsUpdateOfPrefersPointerLocked()
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
        Self.requestLandscape(in: scene)
    }

    static func requestLandscape(in scene: UIWindowScene) {
        // UIKit can deliver geometry failures from a background queue.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { @Sendable error in
            Logger(subsystem: "io.ugfugl.Glimmer", category: "Display")
                .error("Display rotation failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

extension StreamSessionModel.Phase {
    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}
