// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Transient in-stream notices (reconnect, network health, leave and pointer hints, mouse mode).
// Each shows in its own borderless child window only while visible, so the video layer tree
// stays untouched and the picture keeps its direct path whenever no notice is up.

import Accessibility
import AppKit
import SwiftUI

/// Screen anchor for a banner pill.
public enum StreamBannerAnchor {
    case topCenter
    case bottomCenter
    /// A corner chosen by `StreamModeBadgeLayout`, clear of `StreamBanner.avoiding`.
    case corner
}

@MainActor
public final class StreamBanner {
    private let anchor: StreamBannerAnchor
    private let accent: Color
    /// Distance from the anchored edge, so co-anchored notices stack without overlap.
    private let inset: CGFloat
    private var symbol: String?
    private var visible = false
    private var baseText = ""
    private var lingered = false
    /// Bumped on every show and hide so a stale linger timer or fade can't land.
    private var showGeneration: UInt64 = 0
    private weak var parent: NSWindow?
    private var panel: NSPanel?
    private var resizeObservation: NSObjectProtocol?
    private var cornerPlaced = true

    /// Appended after the notice has been up `lingerDelay` seconds, so a stuck stream says how to leave it.
    var lingerHint: (@MainActor () -> String)?
    var lingerDelay: TimeInterval = 5
    var scheduleLingerDelay: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    /// The notice never takes focus, so shown and changed text is announced.
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    /// Liquid Glass on macOS 26; tests and captures force the macOS 15 material path.
    var glassAvailable = StreamNoticeView.glassAvailable
    /// Overlays a corner badge must clear, in top-left-origin content coordinates.
    var avoiding: @MainActor () -> [CGRect] = { [] }
    var accessibilityName: String?
    /// Runs after this notice appears or finishes leaving, so a corner badge can move clear of it.
    var presenceChanged: (@MainActor () -> Void)?

    public init(anchor: StreamBannerAnchor, accent: NSColor, inset: CGFloat = 28) {
        self.anchor = anchor
        self.accent = Color(nsColor: accent)
        self.inset = inset
    }

    /// The stream window the notice floats over; it moves into its Space and follows its frame.
    public func attach(to window: NSWindow) {
        parent = window
        if visible { present() }
    }

    public var isVisible: Bool { visible }

    /// The text the notice shows right now, linger hint included.
    var displayedText: String {
        guard lingered, let hint = lingerHint?() else { return baseText }
        return baseText + " · " + hint
    }

    /// The SwiftUI content the notice shows, the same view iPhone and iPad use.
    var content: StreamNoticeView {
        StreamNoticeView(text: displayedText, symbol: symbol, accent: symbol == nil ? accent : nil,
                         glass: glassAvailable, accessibilityName: accessibilityName)
    }

    /// No-op if unchanged so a per-tick caller doesn't re-flow every frame.
    public func setText(_ string: String) {
        guard string != baseText else { return }
        baseText = string
        render(changed: true)
    }

    /// A leading SF Symbol in place of the accent dot; nil restores the dot.
    func setSymbol(_ name: String?) {
        guard name != symbol else { return }
        symbol = name
        render(changed: false)
    }

    public func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        showGeneration &+= 1
        if show {
            lingered = false
            present()
            if !baseText.isEmpty { announce(displayedText) }
            scheduleLinger()
        } else {
            dismiss()
        }
    }

    private func render(changed: Bool) {
        guard visible else { return }
        if let host = panel?.contentView as? NSHostingView<StreamNoticeView> { host.rootView = content }
        layout()
        if changed { announce(displayedText) }
    }

    private func present() {
        guard let parent else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? NSHostingView<StreamNoticeView>)?.rootView = content
        layout()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.short
            panel.animator().alphaValue = 1
        }
        presenceChanged?()
        resizeObservation = resizeObservation ?? NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
    }

    // The window exists only while the notice is up; a re-show during the fade keeps it.
    private func dismiss() {
        if let resizeObservation { NotificationCenter.default.removeObserver(resizeObservation) }
        resizeObservation = nil
        guard let panel else { return }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.short
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible, self.showGeneration == generation, let panel = self.panel else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                self.panel = nil
                self.presenceChanged?()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    /// Moves a visible notice clear of overlays that appeared since it was laid out.
    func relayout() { if visible { layout() } }

    var isOnScreenWithStream: Bool { panel?.parent != nil }

    /// Centres the notice on the anchored edge, never wider than the window less 16pt each side.
    private func layout() {
        guard let parent, let panel, let host = panel.contentView as? NSHostingView<StreamNoticeView> else { return }
        let frame = parent.contentLayoutRect.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY)
        let margin = Self.shadowMargin
        let fitting = host.fittingSize
        if anchor == .corner { return layoutCorner(size: fitting, content: frame) }
        let width = min(fitting.width + margin * 2, max(0, frame.width - 32 + margin * 2))
        let height = fitting.height + margin * 2
        let x = frame.midX - width / 2
        let y: CGFloat
        switch anchor {
        case .topCenter:
            let notch = parent.screen?.safeAreaInsets.top ?? 0
            y = frame.maxY - max(inset, notch + 8) - height + margin
        case .bottomCenter, .corner:
            y = frame.minY + inset - margin
        }
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        // A window ordered out (Cmd-Tab, tests) defers joining until it is back and relays the notice out.
        if parent.isVisible, panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
    }

    // A badge with no clear corner stays hidden rather than cover another overlay.
    private func layoutCorner(size: CGSize, content: CGRect) {
        guard let parent, let panel, let host = panel.contentView as? NSHostingView<StreamNoticeView> else { return }
        let notch = parent.screen.map { content.maxY >= $0.frame.maxY ? $0.safeAreaInsets.top : 0 } ?? 0
        let area = CGRect(x: 0, y: notch, width: content.width, height: max(0, content.height - notch))
        guard let badge = StreamModeBadgeLayout.frame(size: size, in: area, avoiding: avoiding()) else {
            cornerPlaced = false
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            return
        }
        cornerPlaced = true
        let margin = Self.shadowMargin
        let screen = CGRect(x: content.minX + badge.minX, y: content.maxY - badge.maxY, width: badge.width,
                            height: badge.height).insetBy(dx: -margin, dy: -margin)
        host.frame = CGRect(origin: .zero, size: screen.size)
        panel.setFrame(screen, display: true)
        if parent.isVisible, panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
    }

    /// Room for the notice's shadow inside its transparent window.
    static let shadowMargin: CGFloat = 12

    /// The capsule's frame in the stream window's content coordinates, while a notice window exists.
    var noticeFrame: CGRect? {
        guard let panel, let parent, cornerPlaced else { return nil }
        let content = parent.contentLayoutRect.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY)
        return panel.frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
            .offsetBy(dx: -content.minX, dy: -content.minY)
    }

    private func scheduleLinger() {
        guard lingerHint != nil else { return }
        let generation = showGeneration
        scheduleLingerDelay(lingerDelay) { [weak self] in
            guard let self, self.visible, self.showGeneration == generation else { return }
            self.lingered = true
            self.render(changed: true)
        }
    }

    /// Sustained-degradation gate for the network notice: an asymmetric leaky integrator over 4 Hz ticks.
    /// Attack +1.0, decay −0.7 in a 0...16 band, so isolated trips can't random-walk it up.
    private var degradeLevel = 0.0
    public func setSustained(_ degraded: Bool, text: String) {
        degradeLevel = max(0, min(16, degradeLevel + (degraded ? 1.0 : -0.7)))
        if degradeLevel >= 10 { setText(text); setVisible(true) } else if degradeLevel <= 3 { setVisible(false) }
    }
}
