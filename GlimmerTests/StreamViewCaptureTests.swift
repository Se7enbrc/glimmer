// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Window mode's grab and release as the forwarder walks them, and the diagnostic
// event sampler. No key event reaches the diagnostic log.

import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct StreamViewCaptureTests {
    @MainActor
    private final class Edges { var seen: [Bool] = [] }

    private let press = Int8(StreamProtocol.BUTTON_ACTION_PRESS)
    private let release = Int8(StreamProtocol.BUTTON_ACTION_RELEASE)

    private static func keyWindow() -> PointerFocusTestWindow {
        PointerFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                               styleMask: .borderless, backing: .buffered, defer: true)
    }

    private func windowed(in window: PointerFocusTestWindow = keyWindow())
        -> (InputForwarder, InputRecordingBackend, Edges) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.attach(to: window)
        forwarder.isReady = true
        forwarder.streamPixelSize = CGSize(width: 640, height: 640)
        forwarder.setWindowMode(true)
        let edges = Edges()
        forwarder.onPointerCaptureChanged = { edges.seen.append($0) }
        return (forwarder, backend, edges)
    }

    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 16, y: 48), modifierFlags: [],
                                        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: CGPoint(x: 16, y: 48), modifierFlags: [],
                                            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
                                            trackingNumber: 0, userData: nil))
    }

    private func pointerChord() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 1, windowNumber: 0,
            context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_P)))
    }

    /// Capture sync reads the live mouse location, so its position is left out.
    private func buttons(_ backend: InputRecordingBackend) -> [PointerSend] {
        backend.pointer.filter { if case .button = $0 { true } else { false } }
    }

    @Test(arguments: ["Desktop", "desktop", "Hades"])
    func everyAppBuildsWithRelativeFullscreenCapture(name: String) throws {
        let model = AppModel()
        let app = LibraryApp(id: 1, name: name, hdr: false, hidden: false)
        let host = Host(id: "pointer-pc", name: "Tower", customName: nil, localAddress: nil,
                        manualAddress: nil, apps: [app], lastConnected: nil, serverCertPEM: nil,
                        appVersion: nil, macAddress: nil)
        var config = model.nativeStreamConfig(for: host, app: app)
        config.displayMode = .fullScreen
        let session = StreamSession(backend: InputRecordingBackend())
        let setup = session.buildStreamSubsystems(.init(
            config: config, negotiatedBitrateKbps: config.bitrateKbps,
            initialStatsOverlay: false, initialStatsCorner: .topLeft,
            quitHotkeyProvider: { .defaultQuit }, statsHotkeyProvider: { .defaultStats },
            bookmarkHotkeyProvider: { .defaultQuit }, releasePointerHotkeyProvider: { .defaultQuit },
            miniPlayerHotkeyProvider: { .defaultQuit }, controllerQuitChordProvider: { .none },
            customControllerChordProvider: { [] }, onBackgroundedChanged: nil, onMiniPlayerChanged: nil,
            onCancelConnect: nil))
        defer { setup.1.detach(); setup.2.teardown(); setup.0.close() }
        #expect(setup.1.fullscreenRelativePointer)
        #expect(setup.0.fullscreenRelativePointer)
        #expect(!setup.1.isWindowMode)
    }

    @Test func hoverGrabsAndAHeldEscLatchHoldsItOffUntilThePointerLeaves() throws {
        let (forwarder, _, edges) = windowed()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        view.mouseEntered(with: try crossing(.mouseEntered))
        #expect(forwarder.isMouseCaptured)
        #expect(!forwarder.sendsAbsolutePointer)

        forwarder.releasePointer(reason: "test")
        #expect(!forwarder.isMouseCaptured)
        #expect(forwarder.isHoverCaptureSuppressed)
        view.mouseEntered(with: try crossing(.mouseEntered))
        #expect(!forwarder.isMouseCaptured)

        view.mouseExited(with: try crossing(.mouseExited))
        #expect(!forwarder.isHoverCaptureSuppressed)
        view.mouseEntered(with: try crossing(.mouseEntered))
        #expect(forwarder.isMouseCaptured)
        #expect(edges.seen == [true, false, true])
    }

    /// Under associate-false a captured pointer cannot leave, so an exit then is bookkeeping.
    @Test func anExitWhileCapturedKeepsTheLatch() throws {
        let (forwarder, _, _) = windowed()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        view.mouseEntered(with: try crossing(.mouseEntered))
        forwarder.isHoverCaptureSuppressed = true
        view.mouseExited(with: try crossing(.mouseExited))
        #expect(forwarder.isHoverCaptureSuppressed)
    }

    @Test func aBackgroundWindowNeverGrabs() throws {
        let window = Self.keyWindow()
        let (forwarder, backend, edges) = windowed(in: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        window.focused = false
        view.mouseEntered(with: try crossing(.mouseEntered))
        forwarder.togglePointerCapture(reason: "test")
        #expect(!forwarder.isMouseCaptured)
        #expect(edges.seen.isEmpty)
        #expect(backend.pointer.isEmpty)
    }

    /// The chord toggles, and freeing the pointer lets go of a button held through it.
    @Test func pointerChordTogglesAndReleasesHeldButtons() throws {
        let (forwarder, backend, edges) = windowed()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.keyDown(with: try pointerChord())
        #expect(forwarder.isMouseCaptured)
        view.keyDown(with: try pointerChord())
        #expect(!forwarder.isMouseCaptured)
        #expect(forwarder.isHoverCaptureSuppressed)
        #expect(forwarder.heldMouseButtons.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(buttons(backend) == [
            .button(action: press, button: StreamProtocol.BUTTON_LEFT),
            .button(action: release, button: StreamProtocol.BUTTON_LEFT)
        ])
        #expect(edges.seen == [true, false])
        #expect(backend.keyboard.isEmpty)
    }

    /// The mini player never grabs on hover; its click both grabs and presses.
    @Test func miniPlayerGrabsOnClickNotHover() throws {
        let (forwarder, backend, _) = windowed()
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        let hovering = Edges()
        forwarder.onMiniPlayerHoverChanged = { hovering.seen.append($0) }
        forwarder.setMiniPlayer(true)
        view.mouseEntered(with: try crossing(.mouseEntered))
        #expect(!forwarder.isMouseCaptured)
        view.mouseExited(with: try crossing(.mouseExited))
        #expect(hovering.seen == [true, false])
        view.mouseDown(with: try mouse(.leftMouseDown))
        #expect(forwarder.isMouseCaptured)
        #expect(buttons(backend) == [.button(action: press, button: StreamProtocol.BUTTON_LEFT)])
    }

    /// Back to full screen: the latch retires with the rule it belongs to.
    @Test func leavingWindowModeClearsTheLatch() throws {
        let (forwarder, _, _) = windowed()
        defer { forwarder.detach() }
        forwarder.isHoverCaptureSuppressed = true
        forwarder.setWindowMode(false)
        #expect(!forwarder.isHoverCaptureSuppressed)
        #expect(!forwarder.sendsAbsolutePointer)
    }

    @Test func fullscreenDesktopMapsClicksAndTogglesToRelativeAndBack() throws {
        let (forwarder, backend, edges) = windowed()
        defer { forwarder.detach() }
        forwarder.fullscreenRelativePointer = false
        forwarder.setWindowMode(false)
        let view = try #require(forwarder.inputView)
        #expect(forwarder.sendsAbsolutePointer)
        view.mouseEntered(with: try crossing(.mouseEntered))
        #expect(!forwarder.isMouseCaptured)
        view.mouseDown(with: try mouse(.leftMouseDown))
        #expect(backend.pointer.first == .position(x: 160, y: 160, refW: 640, refH: 640))
        view.keyDown(with: try pointerChord())
        #expect(forwarder.isMouseCaptured)
        #expect(forwarder.fullscreenRelativePointer)
        #expect(!forwarder.sendsAbsolutePointer)
        view.keyDown(with: try pointerChord())
        #expect(forwarder.sendsAbsolutePointer)
        #expect(!forwarder.fullscreenRelativePointer)
        #expect(forwarder.heldMouseButtons.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(buttons(backend).count == 2)
        #expect(edges.seen == [true, false])
        #expect(backend.keyboard.isEmpty)
        forwarder.windowResignedKey()
        #expect(forwarder.sendsAbsolutePointer)
    }

    @Test func returningFromAWindowRestoresTheFullscreenPointerChoice() {
        let (forwarder, _, _) = windowed()
        defer { forwarder.detach() }
        forwarder.fullscreenRelativePointer = false
        forwarder.capturePointer(reason: "test")
        #expect(forwarder.isMouseCaptured)
        forwarder.setWindowMode(false)
        #expect(!forwarder.isMouseCaptured)
        #expect(forwarder.sendsAbsolutePointer)
        forwarder.setWindowMode(true)
        forwarder.fullscreenRelativePointer = true
        forwarder.setWindowMode(false)
        #expect(forwarder.isMouseCaptured)
        #expect(!forwarder.sendsAbsolutePointer)
    }

    // MARK: Diagnostic sampler

    @Test func diagnosticEventNamesFallBackToTheRawType() {
        let forwarder = InputForwarder()
        #expect(forwarder.diagnosticEventTypeName(.scrollWheel) == "scrollWheel")
        #expect(forwarder.diagnosticEventTypeName(.otherMouseDown) == "otherMouseDown")
        #expect(forwarder.diagnosticEventTypeName(.mouseCancelled)
            == "type(\(NSEvent.EventType.mouseCancelled.rawValue))")
    }

    /// Past 100 events in a second the log samples one in N.
    @Test func diagnosticSamplerThrottlesFloods() throws {
        let forwarder = InputForwarder()
        let event = try mouse(.leftMouseDown)
        for _ in 0..<250 { forwarder.logDiagnosticEvent(event) }
        #expect(forwarder.diagSampleCount == 250)
        #expect(forwarder.diagSampleDivisor == 2)
        forwarder.removeDiagnosticMonitors()
        #expect(forwarder.diagSampleCount == 0)
        #expect(forwarder.diagSampleDivisor == 1)
    }
}
