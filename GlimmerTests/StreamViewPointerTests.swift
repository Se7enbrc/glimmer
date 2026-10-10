// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Mouse motion, buttons and scroll from StreamInputView to the backend.

import AppKit
import CoreGraphics
import Testing
@testable import Glimmer

@MainActor
struct StreamViewPointerTests {
    private let press = Int8(StreamProtocol.BUTTON_ACTION_PRESS)
    private let release = Int8(StreamProtocol.BUTTON_ACTION_RELEASE)

    /// A ready forwarder in a key 64x64 window, mirroring a 640x640 stream.
    private func rig(
        tuning: CruiseTraversal.Tuning = .init(enabled: false, vKnee: 1100, vFull: 1800, dragDeltaScale: 1.35)
    ) -> (InputForwarder, InputRecordingBackend, PointerFocusTestWindow) {
        let forwarder = InputForwarder(cruiseTuning: tuning)
        let backend = InputRecordingBackend()
        let window = PointerFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                                            styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.setBackend(backend)
        forwarder.attach(to: window)
        forwarder.isReady = true
        forwarder.streamPixelSize = CGSize(width: 640, height: 640)
        return (forwarder, backend, window)
    }

    private func motion(_ type: CGEventType = .mouseMoved, at timestamp: TimeInterval = 1,
                        dx: Int64, dy: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: .zero, mouseButton: .left))
        cg.timestamp = UInt64(timestamp * 1_000_000_000)
        cg.setIntegerValueField(.mouseEventDeltaX, value: dx)
        cg.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return try #require(NSEvent(cgEvent: cg))
    }

    private func click(_ type: NSEvent.EventType, at point: CGPoint = CGPoint(x: 16, y: 48)) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: 1))
    }

    private func otherButton(_ type: CGEventType, number: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: .zero, mouseButton: .center))
        cg.setIntegerValueField(.mouseEventButtonNumber, value: number)
        return try #require(NSEvent(cgEvent: cg))
    }

    private func scroll(_ units: CGScrollEventUnit, dy: Int32, dx: Int32 = 0,
                        phase: CGScrollPhase? = nil) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                      wheel1: dy, wheel2: dx, wheel3: 0))
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        return try #require(NSEvent(cgEvent: cg))
    }

    // MARK: Relative motion (full screen, captured)

    @Test func capturedMotionSendsTheRawDelta() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.mouseMoved(with: try motion(dx: 7, dy: -3))
        view.mouseDragged(with: try motion(.leftMouseDragged, dx: -2, dy: 5))
        #expect(backend.mouseMoves == [.init(dx: 7, dy: -3), .init(dx: -2, dy: 5)])
        #expect(backend.pointer.isEmpty)
    }

    /// The wire carries Int16; a larger coalesced batch keeps its overflow for the next send.
    @Test func oversizedBatchKeepsTheOverflowInTheResidual() throws {
        let (forwarder, backend, window) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        window.motionQueue = [try motion(.leftMouseDragged, dx: 20_000, dy: -20_000)]
        view.mouseMoved(with: try motion(dx: 20_000, dy: -20_000))
        #expect(window.motionQueue.isEmpty)
        view.mouseMoved(with: try motion(dx: 0, dy: 0))
        view.mouseMoved(with: try motion(dx: 0, dy: 0))
        #expect(backend.mouseMoves == [.init(dx: 32_767, dy: -32_768), .init(dx: 7_233, dy: -7_232)])
    }

    @Test func rawAimScalesDragsButNotMoves() throws {
        let (forwarder, backend, _) = rig()
        defer {
            forwarder.savedLinearScaling = nil
            forwarder.detach()
        }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        forwarder.savedLinearScaling = false
        view.mouseMoved(with: try motion(dx: 20, dy: 20))
        view.rightMouseDragged(with: try motion(.rightMouseDragged, dx: 20, dy: -20))
        view.otherMouseDragged(with: try motion(.otherMouseDragged, dx: 20, dy: 0))
        #expect(backend.mouseMoves == [.init(dx: 20, dy: 20), .init(dx: 27, dy: -27), .init(dx: 27, dy: 0)])
    }

    @Test func dragsAreUnscaledWithAccelerationUntouched() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.mouseDragged(with: try motion(.leftMouseDragged, dx: 20, dy: 20))
        #expect(backend.mouseMoves == [.init(dx: 20, dy: 20)])
    }

    /// Above the knee a 4K stream doubles the flick; the first batch after a gap never boosts.
    @Test func cruiseBoostsOnlyFastFlicks() throws {
        let (forwarder, backend, _) = rig(
            tuning: .init(enabled: true, vKnee: 1100, vFull: 1800, dragDeltaScale: 1.0))
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        CruiseTraversal.configure(forwarder, streamWidth: 3840)
        #expect(forwarder.cruiseGMax == 2.0)
        forwarder.isMouseCaptured = true
        view.mouseMoved(with: try motion(at: 10, dx: 100, dy: 0))
        view.mouseMoved(with: try motion(at: 10.010, dx: 100, dy: 0))
        #expect(backend.mouseMoves == [.init(dx: 100, dy: 0), .init(dx: 200, dy: 0)])
    }

    @Test func cruiseLeavesAimSpeedsAlone() throws {
        let (forwarder, backend, _) = rig(
            tuning: .init(enabled: true, vKnee: 1100, vFull: 1800, dragDeltaScale: 1.0))
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        CruiseTraversal.configure(forwarder, streamWidth: 3840)
        forwarder.isMouseCaptured = true
        view.mouseMoved(with: try motion(at: 10, dx: 1, dy: 0))
        view.mouseMoved(with: try motion(at: 10.010, dx: 5, dy: 0))
        #expect(backend.mouseMoves == [.init(dx: 1, dy: 0), .init(dx: 5, dy: 0)])
    }

    // MARK: Nothing leaves without capture

    @Test func fullScreenWithoutCaptureSendsNothing() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        view.mouseMoved(with: try motion(dx: 5, dy: 5))
        view.mouseDown(with: try click(.leftMouseDown))
        view.mouseUp(with: try click(.leftMouseUp))
        view.scrollWheel(with: try scroll(.line, dy: 1))
        #expect(backend.mouseMoves.isEmpty)
        #expect(backend.pointer.isEmpty)
        #expect(forwarder.heldMouseButtons.isEmpty)
    }

    @Test func aBackgroundOrNotReadyStreamSendsNothing() throws {
        let (forwarder, backend, window) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        window.focused = false
        view.mouseMoved(with: try motion(dx: 5, dy: 5))
        view.rightMouseDown(with: try click(.rightMouseDown))
        window.focused = true
        forwarder.isReady = false
        view.mouseMoved(with: try motion(dx: 5, dy: 5))
        view.otherMouseDown(with: try otherButton(.otherMouseDown, number: 2))
        view.scrollWheel(with: try scroll(.line, dy: 1))
        #expect(backend.mouseMoves.isEmpty)
        #expect(backend.pointer.isEmpty)
    }

    // MARK: Buttons

    @Test func buttonsMapToTheHostButtons() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.mouseDown(with: try click(.leftMouseDown))
        view.rightMouseDown(with: try click(.rightMouseDown))
        for number: Int64 in [2, 3, 4, 7] {
            view.otherMouseDown(with: try otherButton(.otherMouseDown, number: number))
        }
        #expect(backend.pointer == [
            .button(action: press, button: StreamProtocol.BUTTON_LEFT),
            .button(action: press, button: StreamProtocol.BUTTON_RIGHT),
            .button(action: press, button: StreamProtocol.BUTTON_MIDDLE),
            .button(action: press, button: StreamProtocol.BUTTON_X1),
            .button(action: press, button: StreamProtocol.BUTTON_X2),
            .button(action: press, button: StreamProtocol.BUTTON_MIDDLE)
        ])
        #expect(forwarder.heldMouseButtons == [1, 2, 3, 4, 5])
    }

    @Test func releasesClearWhatTheHostHolds() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.rightMouseDown(with: try click(.rightMouseDown))
        view.otherMouseDown(with: try otherButton(.otherMouseDown, number: 4))
        view.rightMouseUp(with: try click(.rightMouseUp))
        view.otherMouseUp(with: try otherButton(.otherMouseUp, number: 4))
        #expect(backend.pointer.suffix(2) == [
            .button(action: release, button: StreamProtocol.BUTTON_RIGHT),
            .button(action: release, button: StreamProtocol.BUTTON_X2)
        ])
        #expect(forwarder.heldMouseButtons.isEmpty)
    }

    /// Focus loss lets the physical up land elsewhere, so the PC is told now.
    @Test func focusLossReleasesHeldButtonsAndKeys() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.mouseDown(with: try click(.leftMouseDown))
        forwarder.windowResignedKey()
        #expect(backend.pointer.last == .button(action: release, button: StreamProtocol.BUTTON_LEFT))
        #expect(forwarder.heldMouseButtons.isEmpty)
        #expect(!forwarder.isMouseCaptured)
        view.mouseUp(with: try click(.leftMouseUp))
        #expect(backend.pointer.count == 2)
    }

    // MARK: Window mode, pointer free: absolute positions

    @Test func aFreeWindowPointerSendsWhereItIs() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.setWindowMode(true)
        view.mouseMoved(with: try click(.mouseMoved))
        view.mouseDown(with: try click(.leftMouseDown))
        view.mouseUp(with: try click(.leftMouseUp, at: CGPoint(x: 48, y: 16)))
        #expect(backend.mouseMoves.isEmpty)
        #expect(backend.pointer == [
            .position(x: 160, y: 160, refW: 640, refH: 640),
            .position(x: 160, y: 160, refW: 640, refH: 640),
            .button(action: press, button: StreamProtocol.BUTTON_LEFT),
            .position(x: 480, y: 480, refW: 640, refH: 640),
            .button(action: release, button: StreamProtocol.BUTTON_LEFT)
        ])
    }

    /// No stream size yet: there is no pixel to name, so the click goes without a position.
    @Test func noStreamSizeSendsNoPosition() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.setWindowMode(true)
        forwarder.streamPixelSize = .zero
        view.mouseMoved(with: try click(.mouseMoved))
        view.mouseDown(with: try click(.leftMouseDown))
        #expect(backend.pointer == [.button(action: press, button: StreamProtocol.BUTTON_LEFT)])
    }

    @Test func aWindowReleaseWithoutAPressIsNotSent() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.setWindowMode(true)
        view.mouseUp(with: try click(.leftMouseUp))
        #expect(backend.pointer.isEmpty)
    }

    // MARK: Scroll

    @Test func wheelNotchesPassThroughUnchanged() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.scrollWheel(with: try scroll(.line, dy: 1))
        view.scrollWheel(with: try scroll(.line, dy: -2, dx: 1))
        #expect(backend.pointer == [.scroll(120), .scroll(-240), .hScroll(120)])
    }

    /// Precise slices bank into whole notches; a finished gesture drops the remainder.
    @Test func preciseScrollSendsWholeNotchesAndResetsOnEnd() throws {
        let (forwarder, backend, _) = rig()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.isMouseCaptured = true
        view.scrollWheel(with: try scroll(.pixel, dy: 6, phase: .began))
        #expect(backend.pointer.isEmpty)
        view.scrollWheel(with: try scroll(.pixel, dy: 6, phase: .ended))
        #expect(backend.pointer == [.scroll(120)])
        view.scrollWheel(with: try scroll(.pixel, dy: 6, phase: .began))
        #expect(backend.pointer == [.scroll(120)])
    }
}
