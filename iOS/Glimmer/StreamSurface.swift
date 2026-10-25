// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
import UIKit

@MainActor
final class StreamSurface: UIView {
    private(set) var displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        configureDisplayLayer()
        isAccessibilityElement = true
        accessibilityLabel = "Video from the PC"
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
    }

    func replaceDisplayLayer(attach: (AVSampleBufferDisplayLayer) -> Void) -> AVSampleBufferDisplayLayer {
        displayLayer.removeFromSuperlayer()
        displayLayer = AVSampleBufferDisplayLayer()
        configureDisplayLayer()
        setNeedsLayout()
        attach(displayLayer)
        return displayLayer
    }

    // iPhone and iPad share one rule: fill the window, cropping edges after an aspect change.
    private let presentationGravity = AVLayerVideoGravity.resizeAspectFill

    private func configureDisplayLayer() {
        displayLayer.videoGravity = presentationGravity
        displayLayer.frame = bounds
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    var pacerDisplay: PacerDisplay {
        PacerDisplay(makeLink: { [weak self] target, selector in
            guard let self, self.window != nil else { return nil }
            return CADisplayLink(target: target, selector: selector)
        }, screen: { [weak self] in
            guard let screen = self?.window?.windowScene?.screen else {
                return PacerScreen(identity: "detached", maximumHz: 0, minimumHz: nil, scale: 1)
            }
            return PacerScreen(identity: String(describing: ObjectIdentifier(screen)),
                maximumHz: Double(screen.maximumFramesPerSecond), minimumHz: nil, scale: Double(screen.scale))
        }, tickOffMain: { true }, prepareTickThread: {})
    }
}
