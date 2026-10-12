// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import AVFoundation
import Testing
@testable import Glimmer

@MainActor
struct StatsOverlayWindowTests {
    private func populatedStream() -> StreamWindow {
        let stream = StreamWindow(displayMode: .window)
        stream.window.setFrame(CGRect(x: 100, y: 100, width: 800, height: 600), display: false)
        stream.statsOverlay.videoSize = CGSize(width: 1_920, height: 1_080)
        stream.statsOverlay.update(snapshot: StreamStatsSnapshot(),
                                   enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        stream.statsOverlay.setVisible(true)
        return stream
    }

    @Test func separateSurfaceCannotTakeInputOrEnterWindowLists() {
        let stream = populatedStream()
        defer { stream.window.close() }
        let child = stream.statsOverlayWindow.window
        #expect(!child.canBecomeKey)
        #expect(!child.canBecomeMain)
        #expect(!child.acceptsFirstResponder)
        #expect(child.styleMask.contains(.nonactivatingPanel))
        #expect(child.ignoresMouseEvents)
        #expect(!child.acceptsMouseMovedEvents)
        #expect(!child.isOpaque)
        #expect(child.backgroundColor == .clear)
        #expect(!child.hasShadow)
        #expect(child.isExcludedFromWindowsMenu)
        #expect(child.collectionBehavior == [.fullScreenAuxiliary, .ignoresCycle, .stationary])
        #expect(stream.statsOverlay.layer.superlayer === child.contentView?.layer)
        #expect(!(stream.displayLayer.sublayers ?? []).contains(stream.statsOverlay.layer))
        let parent = stream.statsOverlay.layer.superlayer
        stream.rebuildDisplayLayer()
        #expect(stream.statsOverlay.layer.superlayer === parent)
        #expect(stream.reconnectBanner.layer.superlayer === stream.displayLayer)
    }

    @Test func geometryFollowsMovesResizesCornersAndMiniPlayerBounds() {
        let stream = populatedStream()
        defer { stream.window.close() }
        let overlay = stream.statsOverlay
        let child = stream.statsOverlayWindow.window
        for size in [CGSize(width: 800, height: 600), CGSize(width: 320, height: 180)] {
            stream.window.setContentSize(size)
            for corner in StatsOverlayCorner.allCases {
                overlay.corner = corner
                stream.statsOverlayWindow.refreshLayout()
                let windowFrame = stream.displayView.convert(overlay.frameInDisplay, to: nil)
                let expected = stream.window.convertToScreen(windowFrame)
                #expect(child.frame == expected.integral)
                #expect(child.frame.width - overlay.layer.frame.width < 2)
                #expect(child.frame.height - overlay.layer.frame.height < 2)
                #expect(abs(child.frame.minX + overlay.layer.frame.minX - expected.minX) < 0.001)
                #expect(abs(child.frame.minY + overlay.layer.frame.minY - expected.minY) < 0.001)
                #expect(child.frame.width < size.width)
                #expect(child.frame.height < size.height)
                #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(overlay.backdropSampleRect))
            }
        }
        let before = child.frame
        let origin = stream.window.frame.origin
        stream.window.setFrameOrigin(CGPoint(x: origin.x + 30, y: origin.y + 20))
        #expect(abs(child.frame.minX - before.minX - 30) < 0.001)
        #expect(abs(child.frame.minY - before.minY - 20) < 0.001)
        NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: stream.window)
        #expect(overlay.layer.contentsScale == stream.window.backingScaleFactor)
    }

    @Test func ordersAboveParentAndTracksVisibilityLevelAndTeardown() throws {
        let stream = populatedStream()
        defer { stream.window.close() }
        let parent = stream.window
        let controller = stream.statsOverlayWindow
        let child = controller.window
        #expect(!child.isVisible)
        parent.orderFront(nil)
        #expect(child.parent === parent)
        #expect(child.isVisible)
        let ordered = try #require(NSWindow.windowNumbers(options: []))
        let childIndex = try #require(ordered.firstIndex { $0.intValue == child.windowNumber })
        let parentIndex = try #require(ordered.firstIndex { $0.intValue == parent.windowNumber })
        #expect(childIndex < parentIndex)
        #expect(parent.childWindows?.filter { $0 === child }.count == 1)
        parent.level = .floating
        #expect(child.level == .floating)
        parent.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: parent)
        #expect(child.collectionBehavior.contains(.canJoinAllSpaces))
        parent.collectionBehavior = [.fullScreenPrimary]
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: parent)
        #expect(!child.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(child.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!child.isKeyWindow && !child.isMainWindow)
        parent.alphaValue = 0.5
        #expect(!child.isVisible)
        parent.alphaValue = 0
        #expect(!child.isVisible)
        parent.alphaValue = 1
        #expect(child.isVisible)
        parent.orderOut(nil)
        #expect(!child.isVisible)
        #expect(child.parent == nil)
        parent.orderFront(nil)
        #expect(child.isVisible)
        controller.isSuspended = true
        #expect(!child.isVisible)
        controller.isSuspended = false
        #expect(child.isVisible)
        parent.close()
        #expect(controller.isClosed)
        #expect(!child.isVisible)
        #expect(child.parent == nil)
        #expect(stream.statsOverlay.layer.superlayer == nil)
        controller.refreshLayout()
        stream.statsOverlay.setVisible(false)
        stream.statsOverlay.setVisible(true)
        #expect(!child.isVisible)
    }

    @Test func coverSlidesSuspendTheChildAndClosePreventsAnyReturn() {
        let stream = populatedStream()
        defer { stream.window.close() }
        stream.window.orderFront(nil)
        let child = stream.statsOverlayWindow.window
        #expect(child.isVisible)
        let responder = stream.window.firstResponder
        let keyWindow = NSApp.keyWindow
        stream.slideCover(entering: true) {}
        #expect(!child.isVisible)
        stream.resetCoverSlide()
        #expect(child.isVisible)
        #expect(stream.window.firstResponder === responder)
        #expect(NSApp.keyWindow === keyWindow)
        stream.statsOverlayWindow.close()
        stream.resetCoverSlide()
        #expect(!child.isVisible)
    }

    @Test func pictureSamplingUsesDisplayCoordinatesAcrossTheSeparateSurface() {
        let stream = populatedStream()
        defer { stream.window.close() }
        let overlay = stream.statsOverlay
        let picture = AVMakeRect(aspectRatio: overlay.videoSize, insideRect: stream.displayView.bounds)
        for corner in StatsOverlayCorner.allCases {
            overlay.corner = corner
            let frame = overlay.frameInDisplay
            let expected = CGRect(x: (frame.minX - picture.minX) / picture.width,
                                  y: (picture.maxY - frame.maxY) / picture.height,
                                  width: frame.width / picture.width, height: frame.height / picture.height)
            #expect(overlay.backdropSampleRect == expected)
        }
    }

    @Test func hideCompletionDetachesOnlyTheCurrentGenerationAndSnapshotListsChild() {
        let stream = populatedStream()
        defer { stream.window.close() }
        stream.window.orderFront(nil)
        let overlay = stream.statsOverlay
        let child = stream.statsOverlayWindow.window
        overlay.setVisible(false)
        let stale = overlay.visibilityGeneration
        #expect(child.parent === stream.window)
        overlay.setVisible(true)
        overlay.finishHide(generation: stale)
        #expect(child.isVisible)
        let snapshot = stream.rendererDiagnosticSnapshot(hdrInput: false)
        #expect(snapshot.contains("statsWindow={attached=true,visible=true,size="))
        #expect(snapshot.contains("level=\(child.level.rawValue)}"))
        #expect(!stream.rendererVisibleOverlays().contains { $0.contains(":stats/") })
        overlay.setVisible(false)
        overlay.finishHide(generation: overlay.visibilityGeneration)
        #expect(child.parent == nil)
        #expect(!child.isVisible)
    }
}
