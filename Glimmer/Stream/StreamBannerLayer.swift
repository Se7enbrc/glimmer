//
//  StreamBannerLayer.swift
//
//  A CALayer text pill floating over the video (sibling to StatsOverlayLayer)
//  for transient signals the user must see while the launcher is occluded:
//  reconnect/hold, network-health, and the leave-hint toast. Separate
//  from the stats panel because these fire on engine edges and must show
//  regardless of the stats-HUD toggle.
//

import Accessibility
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
    private var baseText = ""
    /// True once the pill has stayed up `lingerDelay` and earned `lingerHint`.
    private var lingered = false
    /// Bumped on every show and hide so a stale linger timer can't fire.
    private var showGeneration: UInt64 = 0

    /// Appended after the pill has been up `lingerDelay` seconds, so a stuck
    /// stream says how to leave it. Nil for pills that never linger.
    var lingerHint: (@MainActor () -> String)?
    var lingerDelay: TimeInterval = 5
    /// VoiceOver can't focus a CALayer, so shown and changed text is announced.
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

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
        text.truncationMode = .end
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
        if string == baseText { return }
        baseText = string
        render()
    }

    /// The text the pill shows right now, linger hint included.
    var displayedText: String { (textLayer.string as? String) ?? "" }

    /// Fade the pill in (true) or out (false) over 200ms.
    public func setVisible(_ show: Bool) {
        if show == visible { return }
        visible = show
        showGeneration &+= 1
        if show {
            // A fresh show starts without the hint and re-flows against the
            // host's current size (the window may have resized while hidden).
            lingered = false
            render()
            scheduleLinger()
        }
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

    /// Push the text (plus the linger hint once earned) into the layer,
    /// re-flow, and announce it while the pill is up.
    private func render() {
        var shown = baseText
        if lingered, let hint = lingerHint?() { shown += " · \(hint)" }
        textLayer.string = shown
        if let host = layer.superlayer { layoutInHost(host) }
        if visible { announce(shown) }
    }

    private func scheduleLinger() {
        guard lingerHint != nil else { return }
        let generation = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + lingerDelay) { [weak self] in
            guard let self, self.visible, self.showGeneration == generation else { return }
            self.lingered = true
            self.render()
        }
    }

    /// Sustained-degradation gate for the network pill: an ASYMMETRIC leaky
    /// integrator over the caller's ticks (the 4Hz overlay timer). Attack +1.0,
    /// decay −0.7 over a 0..16 band so a borderline link needs a degraded fraction
    /// > ~0.41 to latch - isolated trips can't random-walk the pill up - while a
    /// clean link still self-drains in ~2.5s.
    private var degradeLevel = 0.0          // range 0..16
    public func setSustained(_ degraded: Bool, text: String) {
        degradeLevel = max(0, min(16, degradeLevel + (degraded ? 1.0 : -0.7)))
        if degradeLevel >= 10 { setText(text); setVisible(true) }   // ~2.5s sustained @4Hz
        else if degradeLevel <= 3 { setVisible(false) }             // self-drains in ~2.5s
    }

    /// Position the pill against the host's bounds, sizing width to the text
    /// but never wider than the host less a 16pt margin each side (the text
    /// truncates with an ellipsis in a narrow mini player).
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
        let hostW = host.bounds.width
        let hostH = host.bounds.height
        let chrome = padH + dotW + dotGap + padH
        let width = min(chrome + ceil(textW), max(chrome, hostW - 32))
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
            width: width - chrome + 2, height: 16)
    }
}
