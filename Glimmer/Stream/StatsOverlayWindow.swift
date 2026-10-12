// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import QuartzCore

/// A separate, tightly bounded surface keeps stats out of the video's layer tree.
@MainActor
final class StatsOverlayWindow: NSObject {
    let window: NSPanel
    private weak var streamWindow: NSWindow?
    private weak var displayView: NSView?
    private let overlay: StatsOverlayLayer
    private let root = CALayer()
    private(set) var isClosed = false
    var isSuspended = false {
        didSet { synchronize() }
    }

    init(parent: NSWindow, overlay: StatsOverlayLayer, displayView: NSView) {
        self.streamWindow = parent
        self.overlay = overlay
        self.displayView = displayView
        window = StatsOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.animationBehavior = .none
        window.sharingType = parent.sharingType
        let view = NSView(frame: .zero)
        root.actions = StatsOverlayLayer.disabledActions
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        overlay.onLayout = { [weak self] in self?.place(in: $0) }
        overlay.onVisibilityChanged = { [weak self] in self?.synchronize() }
        overlay.attach(to: root)
        let notifications: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        for name in notifications {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshLayout), name: name, object: parent)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(close),
                                               name: NSWindow.willCloseNotification, object: parent)
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshLayout), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refreshLayout() {
        guard !isClosed else { return }
        overlay.layoutInHost(root)
    }

    private func place(in frame: CGRect) {
        guard !isClosed, let parent = streamWindow, let view = displayView else { return }
        let screenFrame = parent.convertToScreen(view.convert(frame, to: nil))
        // Round outward: AppKit rounds window geometry, which could otherwise clip a scaled row.
        let windowFrame = screenFrame.integral
        if window.frame != windowFrame { window.setFrame(windowFrame, display: false) }
        overlay.layer.position = CGPoint(x: screenFrame.midX - windowFrame.minX,
                                         y: screenFrame.midY - windowFrame.minY)
        synchronize()
    }

    func synchronize() {
        guard !isClosed, let parent = streamWindow else { return }
        if window.level != parent.level { window.level = parent.level }
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        if parent.collectionBehavior.contains(.canJoinAllSpaces) { behavior.insert(.canJoinAllSpaces) }
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        let visible = !isSuspended && !overlay.layer.isHidden && !overlay.frameInDisplay.isEmpty
            && parent.isVisible && !parent.isMiniaturized && parent.alphaValue == 1 && !NSApp.isHidden
        guard visible else {
            if window.parent != nil { parent.removeChildWindow(window) }
            if window.isVisible { window.orderOut(nil) }
            return
        }
        if window.parent !== parent { parent.addChildWindow(window, ordered: .above) }
        if !window.isVisible { window.order(.above, relativeTo: parent.windowNumber) }
    }

    @objc func close() {
        guard !isClosed else { return }
        isClosed = true
        overlay.onLayout = nil
        overlay.onVisibilityChanged = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
        overlay.layer.removeFromSuperlayer()
    }
}

private final class StatsOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
