// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
final class StreamViewController: UIViewController {
    let model: StreamSessionModel
    let surface = StreamSurface()
    private let overlay: UIHostingController<StreamControls>
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
        view.backgroundColor = .black
        view.addSubview(surface)
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateOrientation(.landscape)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateOrientation(.landscape)
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
        updateOrientation(.allButUpsideDown)
    }

    private func updateOrientation(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = view.window?.windowScene else { return }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Logger(subsystem: "io.ugfugl.Glimmer", category: "Display")
                .error("Display rotation failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

@MainActor
struct StreamControls: View {
    let model: StreamSessionModel
    let close: () -> Void
    @State private var controlsVisible = true

    var body: some View {
        ZStack {
            if model.phase == .streaming {
                Button {
                    controlsVisible.toggle()
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controlsVisible ? "Hide stream controls" : "Show stream controls")
                .ignoresSafeArea()
            }
            status
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top, alignment: .trailing) {
            if controlsVisible || model.phase != .streaming {
                Button(model.phase.isEnded ? "Done" : "Disconnect", systemImage: "xmark") {
                    model.stop()
                    Task { await model.waitUntilStopped(); close() }
                }
                .buttonStyle(.glass)
                .disabled(model.phase == .stopping)
                .padding()
                .accessibilityHint("Disconnects without quitting the game on the PC.")
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .streaming { controlsVisible = false }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(model.launch.pcName)…")
                Text(model.launch.appName).font(.footnote).foregroundStyle(.secondary)
            }
        case .stopping:
            ProgressView("Disconnecting…")
        case .ended(let message):
            Text(message).multilineTextAlignment(.center).padding(32)
        case .streaming:
            if controlsVisible && (model.audioUnavailable || model.connectionPoor) {
                VStack(spacing: 8) {
                    if model.audioUnavailable { Label("Audio is unavailable", systemImage: "speaker.slash") }
                    if model.connectionPoor { Label("Connection is unstable", systemImage: "wifi.exclamationmark") }
                }
                .padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
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
