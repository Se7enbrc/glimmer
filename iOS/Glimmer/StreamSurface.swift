// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
import UIKit

@MainActor
final class StreamSurface: UIView {
    private(set) var displayLayer = AVSampleBufferDisplayLayer()
    weak var stats: StreamStats?
    let overlayAppearance = StreamOverlayAppearance()
    var displayChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        configureDisplayLayer()
        isAccessibilityElement = true
        accessibilityLabel = "Video from the PC"
        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged),
                                               name: UIScreen.modeDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = presentationGravity
        displayLayer.frame = bounds
        CATransaction.commit()
        stats?.layout()
        if window != nil { displayChanged?() }
    }

    @objc private func displayModeChanged(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen, screen === window?.windowScene?.screen else { return }
        setNeedsLayout()
    }

    var streamPixels: CGSize {
        guard let scene = window?.windowScene else { return .zero }
        let screen = scene.screen
        let native = screen.currentMode?.size ?? screen.nativeBounds.size
        let landscape = screen.bounds.width > screen.bounds.height
        let pixels = CGSize(width: landscape ? max(native.width, native.height) : min(native.width, native.height),
                            height: landscape ? min(native.width, native.height) : max(native.width, native.height))
        if scene.session.role == .windowExternalDisplayNonInteractive { return pixels }
        // Clamp against the panel in the window's own orientation; rotation must not shrink the request.
        let panel = (bounds.width > bounds.height) == (pixels.width > pixels.height)
            ? pixels : CGSize(width: pixels.height, height: pixels.width)
        return StreamDisplayGeometry.pixels(viewSize: bounds.size, scale: screen.nativeScale, screenPixels: panel)
    }

    func replaceDisplayLayer(attach: (AVSampleBufferDisplayLayer) -> Void) -> AVSampleBufferDisplayLayer {
        displayLayer.removeFromSuperlayer()
        displayLayer = AVSampleBufferDisplayLayer()
        configureDisplayLayer()
        setNeedsLayout()
        attach(displayLayer)
        return displayLayer
    }

    // One rule on iPhone, iPad and external displays: fill the whole window, cropping edges if shapes differ.
    private let presentationGravity = AVLayerVideoGravity.resizeAspectFill

    private func configureDisplayLayer() {
        displayLayer.videoGravity = presentationGravity
        displayLayer.frame = bounds
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    var pacerDisplay: PacerDisplay {
        PacerDisplay(makeLink: { [weak self] target, selector in
            guard let scene = self?.window?.windowScene else { return nil }
            #if compiler(>=6.4)
            if #available(iOS 27, *) {
                return scene.displayLink(target: target, selector: selector)
            } else {
                return scene.screen.displayLink(withTarget: target, selector: selector)
            }
            #else
            return scene.screen.displayLink(withTarget: target, selector: selector)
            #endif
        }, screen: { [weak self] in
            guard let screen = self?.window?.windowScene?.screen else {
                return PacerScreen(identity: "detached", maximumHz: 0, minimumHz: nil, scale: 1)
            }
            return PacerScreen(identity: String(describing: ObjectIdentifier(screen)),
                maximumHz: Double(screen.maximumFramesPerSecond), minimumHz: nil, scale: Double(screen.scale))
        }, tickOffMain: { true }, prepareTickThread: {})
    }
}
