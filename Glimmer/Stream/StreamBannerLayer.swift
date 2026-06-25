//
//  StreamBannerLayer.swift
//
//  A CALayer text pill floating over the video (sibling to StatsOverlayLayer)
//  for transient signals the user must see while the launcher is occluded:
//  reconnect/hold, network-health, and the one-time leave-hint toast. Separate
//  from the stats panel because these fire on engine edges and must show
//  regardless of the stats-HUD toggle.
//

import AppKit
import QuartzCore

/// Screen anchor for a banner pill.
public enum StreamBannerAnchor {
    case topCenter
    case bottomCenter
}

/// A single rounded translucent text pill with a leading accent dot, fading in
/// and out over the frozen/live frame. One instance per signal; attach as a
/// sublayer of the display layer.
@MainActor
public final class StreamBannerLayer {
    public let layer: CALayer
    private let textLayer: CATextLayer
    private let dotLayer: CALayer
    private let anchor: StreamBannerAnchor
    /// Distance from the anchored screen edge. Configurable so co-anchored pills
    /// (e.g. network + leave-hint, both bottomCenter) can stack without overlap.
    private let inset: CGFloat
    private var visible = false

    public init(anchor: StreamBannerAnchor, accent: CGColor, inset: CGFloat = 28) {
        self.anchor = anchor
        self.inset = inset
        let bg = CALayer()
        bg.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        bg.cornerRadius = 13
        bg.borderColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
        bg.borderWidth = 1
        bg.zPosition = 1_100  // above the stats panel (zPosition 1000).
        bg.opacity = 0
        bg.isHidden = true
        bg.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        bg.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]

        let dot = CALayer()
        dot.backgroundColor = accent
        dot.cornerRadius = 4
        dot.frame = CGRect(x: 14, y: 0, width: 8, height: 8)
        bg.addSublayer(dot)

        let text = CATextLayer()
        text.contentsScale = bg.contentsScale
        text.isWrapped = false
        text.alignmentMode = .left
        text.foregroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        text.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        text.fontSize = 13
        bg.addSublayer(text)

        self.layer = bg
        self.textLayer = text
        self.dotLayer = dot
    }

    /// Attach as a sublayer of the host video layer.
    public func attach(to host: CALayer) {
        host.addSublayer(layer)
        if let s = layer.superlayer { layoutInHost(s) }
    }

    /// Set the pill's text and re-flow. No-op if unchanged so a per-tick caller
    /// doesn't re-flow layout every frame.
    public func setText(_ string: String) {
        if (textLayer.string as? String) == string { return }
        textLayer.string = string
        if let host = layer.superlayer { layoutInHost(host) }
    }

    /// Fade the pill in (true) or out (false) over 200ms.
    public func setVisible(_ show: Bool) {
        if show == visible { return }
        visible = show
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        if show {
            layer.isHidden = false
            layer.opacity = 1
        } else {
            // Gate the final hide on the LATEST intent (not opacity): a re-show that
            // raced in during the fade sets visible=true, so a stale completion can't
            // un-hide a shown pill - and a real hide always lands.
            CATransaction.setCompletionBlock { [weak self] in
                if self?.visible == false { self?.layer.isHidden = true }
            }
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// Sustained-degradation gate for the network pill: a leaky integrator over the
    /// caller's ticks (the 4Hz overlay timer) so a brief co-gap FLAP never flashes the
    /// pill - only mostly-sustained caution shows it, and clearing drains it back out.
    private var degradeLevel = 0
    public func setSustained(_ degraded: Bool, text: String) {
        degradeLevel = max(0, min(12, degradeLevel + (degraded ? 1 : -1)))
        if degradeLevel >= 8 { setText(text); setVisible(true) }   // ~2s sustained
        else if degradeLevel <= 2 { setVisible(false) }            // hysteresis floor
    }

    /// Position the pill against the host's bounds, sizing width to the text.
    public func layoutInHost(_ host: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dotW: CGFloat = 8
        let dotGap: CGFloat = 8
        let padH: CGFloat = 16
        let height: CGFloat = 34
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let str = (textLayer.string as? String) ?? ""
        let textW = (str as NSString).size(withAttributes: [.font: font]).width
        let width = padH + dotW + dotGap + ceil(textW) + padH

        let hostW = host.bounds.width
        let hostH = host.bounds.height
        let x = (hostW - width) / 2
        let y: CGFloat
        switch anchor {
        case .topCenter:
            let notchTop = NSScreen.main?.safeAreaInsets.top ?? 0
            y = hostH - max(inset, notchTop + 8) - height
        case .bottomCenter:
            y = inset
        }
        layer.frame = CGRect(x: x, y: y, width: width, height: height)
        dotLayer.frame = CGRect(
            x: padH, y: (height - dotW) / 2, width: dotW, height: dotW)
        textLayer.frame = CGRect(
            x: padH + dotW + dotGap, y: (height - 16) / 2 - 1,
            width: ceil(textW) + 2, height: 16)
    }
}
