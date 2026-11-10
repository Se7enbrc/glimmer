// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  MiniPlayerTests.swift
//
//  The mini player's pure parts: its opening size and corner, the aspect
//  floor, and the default chord's place in the family.
//

import GlimmerEngine
import CoreGraphics
import AppKit
import Testing
@testable import Glimmer

struct MiniPlayerTests {

    @Test func opensAQuarterOfTheScreenWideAtTheStreamAspect() {
        let size = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 3840, height: 2160), visible: CGSize(width: 2056, height: 1300))
        #expect(size == CGSize(width: 514, height: 289))
    }

    @Test func widthIsClampedBetweenTheMinimumAndSixFortyPoints() {
        let narrow = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 16, height: 9), visible: CGSize(width: 1000, height: 700))
        #expect(narrow.width == StreamWindowGeometry.miniPlayerMinimumContentWidth)
        let wide = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 16, height: 9), visible: CGSize(width: 5120, height: 2880))
        #expect(wide == CGSize(width: 640, height: 360))
    }

    @Test func minimumSitsOnTheAspectLineAndFallsBackToSixteenNine() {
        let ultrawide = StreamWindowGeometry.miniPlayerMinimumContentSize(aspect: CGSize(width: 21, height: 9))
        #expect(ultrawide.width == 320)
        #expect(abs(ultrawide.height - 320 * 9 / 21) < 0.001)
        let bad = StreamWindowGeometry.miniPlayerMinimumContentSize(aspect: .zero)
        #expect(bad == CGSize(width: 320, height: 180))
    }

    @Test func parksInTheBottomRightOfTheVisibleArea() {
        let visible = CGRect(x: 0, y: 80, width: 2056, height: 1220)
        let origin = StreamWindowGeometry.miniPlayerOrigin(
            frame: CGSize(width: 514, height: 289), visible: visible)
        #expect(origin == CGPoint(x: 2056 - 16 - 514, y: 80 + 16))
    }

    @Test func defaultChordIsTwoKeysAndCollidesWithNothing() {
        let chord = HotkeyChord.defaultMiniPlayer
        #expect(chord.ctrl && !chord.alt && !chord.shift && !chord.cmd)
        #expect(chord.keyChar == "m")
        let others = [HotkeyChord.defaultQuit, .defaultStats, .defaultBookmark, .defaultReleasePointer]
        #expect(!others.contains(chord))
    }

    @MainActor
    @Test(arguments: [false, true], [false, true])
    func topEdgeDragsStayLocalAndTheNextPictureClickStillWorks(released: Bool, receivesMouseUp: Bool) throws {
        let window = MiniPlayerDragTestWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                                             styleMask: .borderless, backing: .buffered, defer: true)
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.attach(to: window)
        defer { forwarder.detach() }
        forwarder.isReady = true
        forwarder.setWindowMode(true)
        forwarder.setMiniPlayer(true)
        forwarder.setInputReleased(released)
        let view = try #require(forwarder.inputView)
        let top = CGPoint(x: 320, y: 344)
        view.mouseDown(with: try mouse(.leftMouseDown, at: top))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 230, y: 284)))
        if receivesMouseUp { view.mouseUp(with: try mouse(.leftMouseUp, at: top)) }
        #expect(window.drags.count == 1)
        #expect(forwarder.isMouseCaptured == false)
        #expect(forwarder.isInputReleased == released)
        #expect(backend.pointer.isEmpty && backend.mouseMoves.isEmpty)

        let picture = CGPoint(x: 320, y: 180)
        view.mouseDown(with: try mouse(.leftMouseDown, at: picture))
        view.mouseUp(with: try mouse(.leftMouseUp, at: picture))
        #expect(forwarder.isMouseCaptured)
        #expect(forwarder.isInputReleased == false)
        #expect(view.windowDragEnabled == false)
        #expect(window.drags.count == 1)
        forwarder.setInputReleased(true)
        #expect(view.windowDragEnabled)
        forwarder.setMiniPlayer(false)
        #expect(view.windowDragEnabled)
        forwarder.setWindowMode(false)
        #expect(view.windowDragEnabled == false)
    }

    @MainActor
    @Test(arguments: [CGSize(width: 320, height: 180), CGSize(width: 1280, height: 720)])
    func dragAreaTracksOnlyTheTopThirtyTwoPoints(size: CGSize) {
        let view = StreamInputView(frame: CGRect(origin: .zero, size: size))
        let top = CGPoint(x: size.width / 2, y: size.height - 1)
        #expect(view.isWindowDragPoint(top) == false)
        view.windowDragEnabled = true
        #expect(view.pictureTrackingRect.maxY == size.height - 32)
        #expect(view.isWindowDragPoint(top))
        #expect(view.isWindowDragPoint(CGPoint(x: size.width / 2, y: size.height - 32)))
        #expect(view.isWindowDragPoint(CGPoint(x: size.width / 2, y: size.height - 33)) == false)
        #expect(view.isWindowDragPoint(CGPoint(x: -1, y: top.y)) == false)
        #expect(view.isWindowDragPoint(CGPoint(x: size.width + 1, y: top.y)) == false)
        view.setFrameSize(CGSize(width: size.width, height: size.height + 64))
        #expect(view.isWindowDragPoint(top) == false)
        #expect(view.isWindowDragPoint(CGPoint(x: top.x, y: top.y + 64)))
    }

    @MainActor
    @Test(arguments: [false, true])
    func bothWindowPresentationsHaveTransparentChromeAndNativeButtons(miniPlayer: Bool) throws {
        let stream = StreamWindow(displayMode: .window)
        defer { stream.close() }
        stream.isMiniPlayer = miniPlayer
        stream.configureTransparentWindowChrome()
        #expect(stream.window.styleMask.contains(.fullSizeContentView))
        #expect(stream.window.titlebarAppearsTransparent)
        #expect(stream.window.titleVisibility == .hidden)
        #expect(try #require(stream.window.standardWindowButton(.closeButton)).isHidden == false)
        #expect(try #require(stream.window.standardWindowButton(.miniaturizeButton)).isHidden == miniPlayer)
        #expect(try #require(stream.window.standardWindowButton(.zoomButton)).isHidden == miniPlayer)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class MiniPlayerDragTestWindow: NSWindow {
    var drags: [NSEvent] = []
    override var isKeyWindow: Bool { true }
    override func performDrag(with event: NSEvent) { drags.append(event) }
}
