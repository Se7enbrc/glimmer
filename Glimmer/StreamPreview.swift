// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import OSLog
import SwiftUI

@MainActor
struct StreamPreview: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> StreamPreviewController {
        StreamPreviewController { dismiss() }
    }

    func updateUIViewController(_ controller: StreamPreviewController, context: Context) {}
}

@MainActor
final class StreamPreviewController: UIHostingController<StreamPreviewContent> {
    init(close: @escaping () -> Void) {
        super.init(rootView: StreamPreviewContent(close: close))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateOrientation(.landscape)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateOrientation(.landscape)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
struct StreamPreviewContent: View {
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Display preview").font(.title2)
                Text("Video from the PC will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top, alignment: .trailing) {
            Button("Done", action: close)
                .buttonStyle(.glass)
                .padding()
        }
    }
}
