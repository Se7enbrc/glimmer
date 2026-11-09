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
    private let settings = IsolatedDefaults()

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
        let model = AppModel(defaults: settings.defaults)
        let app = LibraryApp(id: 1, name: name, hdr: false, hidden: false)
        let host = Host(id: "pointer-pc", name: "Tower", customName: nil, localAddress: nil,
                        manualAddress: nil, apps: [app], lastConnected: nil, serverCertPEM: nil,
                        appVersion: nil, macAddress: nil)
        var config = model.nativeStreamConfig(for: host, app: app)
        config.displayMode = .fullScreen
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
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

    private func inputKey(_ code: Int, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown,
                          repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: code == kVK_ANSI_P ? "p" : "w", charactersIgnoringModifiers: code == kVK_ANSI_P ? "p" : "w",
            isARepeat: repeatKey, keyCode: UInt16(code)))
    }

    @Test(arguments: [false, true], [false, true])
    func releaseHandsKeyboardMouseAndSystemShortcutsBackToMac(windowed: Bool, relative: Bool) throws {
        let window = Self.keyWindow()
        let (forwarder, backend, _) = self.windowed(in: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        window.makeFirstResponder(view)
        forwarder.fullscreenRelativePointer = relative
        forwarder.setWindowMode(windowed)
        forwarder.captureSysKeys = true
        forwarder.currentMouseButtons = { 0 }
        view.keyDown(with: try inputKey(kVK_ANSI_W))
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.flagsChanged(with: try inputKey(kVK_Control, flags: .control, type: .flagsChanged))
        view.keyDown(with: try inputKey(kVK_ANSI_P, flags: [.control, .shift]))
        #expect(forwarder.isInputReleased)
        #expect(!forwarder.isMouseCaptured && !forwarder.ownsKeyboard && !forwarder.forwardsMouseEvents)
        #expect(!forwarder.sendsAbsolutePointer && !forwarder.forwardsCommand)
        #expect(forwarder.heldKeys.isEmpty && forwarder.heldModifierVKs.isEmpty && forwarder.heldMouseButtons.isEmpty)
        #expect(backend.keyboard.contains { $0.keyCode == VKScanCode(vk: 0x57).wireCode
            && $0.action == Int8(StreamProtocol.KEY_ACTION_UP) })
        let keyCount = backend.keyboard.count
        let pointerCount = backend.pointer.count
        view.keyDown(with: try inputKey(kVK_ANSI_W))
        view.mouseDown(with: try mouse(.rightMouseDown))
        view.mouseMoved(with: try mouse(.mouseMoved))
        view.insertText("not sent", replacementRange: NSRange(location: NSNotFound, length: 0))
        var clipboardRead = false
        #expect(forwarder.pasteClipboardAsText(read: { clipboardRead = true; return "not sent" }) == nil)
        #expect(!clipboardRead)
        #expect(!view.performKeyEquivalent(with: try inputKey(kVK_ANSI_4, flags: [.command, .shift])))
        #expect(backend.keyboard.count == keyCount && backend.pointer.count == pointerCount && backend.texts.isEmpty)
        forwarder.updateSystemKeyCapture { #expect(!$0) }
        forwarder.windowResignedKey()
        forwarder.enterCapturedMode()
        view.mouseEntered(with: try crossing(.mouseEntered))
        forwarder.setWindowMode(!windowed)
        #expect(forwarder.isInputReleased && !forwarder.isMouseCaptured)
    }

    @Test func recaptureConsumesItsClickAndShortcutUntilTheModifiersAreReleased() throws {
        let window = Self.keyWindow()
        let (forwarder, backend, _) = windowed(in: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        window.makeFirstResponder(view)
        forwarder.currentMouseButtons = { 0 }
        forwarder.setInputReleased(true)
        view.mouseDown(with: try mouse(.leftMouseDown))
        #expect(!forwarder.isInputReleased && forwarder.inputRearming)
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(!forwarder.inputRearming && buttons(backend).isEmpty)
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(buttons(backend).count == 2)
        forwarder.setInputReleased(true)
        let chord = try inputKey(kVK_ANSI_P, flags: [.control, .shift])
        #expect(view.performKeyEquivalent(with: chord))
        #expect(!forwarder.isInputReleased && forwarder.inputRearming)
        view.keyDown(with: try inputKey(kVK_ANSI_P, flags: [.control, .shift], repeatKey: true))
        #expect(!forwarder.isInputReleased)
        view.flagsChanged(with: try inputKey(kVK_Shift, flags: .control, type: .flagsChanged))
        #expect(forwarder.inputRearming && backend.keyboard.isEmpty)
        view.flagsChanged(with: try inputKey(kVK_Control, type: .flagsChanged))
        #expect(!forwarder.inputRearming && backend.keyboard.isEmpty)
        view.keyDown(with: try inputKey(kVK_ANSI_W))
        #expect(backend.keyboard.last?.keyCode == VKScanCode(vk: 0x57).wireCode)
    }

    @Test func releasePreemptsPendingPasteAndRetainsFailedReleaseObligations() async throws {
        let window = Self.keyWindow()
        let (forwarder, backend, _) = windowed(in: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        window.makeFirstResponder(view)
        view.keyDown(with: try inputKey(kVK_ANSI_W))
        backend.inputResult = -2
        let task = try #require(forwarder.queuePasteText("must not arrive"))
        view.keyDown(with: try inputKey(kVK_ANSI_W))
        #expect(!forwarder.pendingKeyboardEvents.isEmpty)
        view.keyDown(with: try inputKey(kVK_ANSI_P, flags: [.control, .shift]))
        #expect(forwarder.isInputReleased && !forwarder.releases.pending.isEmpty)
        await task.value
        #expect(backend.texts.isEmpty && forwarder.pendingKeyboardEvents.isEmpty)
        backend.inputResult = 0
        #expect(forwarder.flushPendingReleases())
        #expect(forwarder.releases.pending.isEmpty)
    }

    @Test func releaseSurvivesReconnectAndMiniPlayerButEndsWithTheSession() throws {
        let window = Self.keyWindow()
        let (forwarder, _, _) = windowed(in: window)
        let view = try #require(forwarder.inputView)
        defer { forwarder.detach() }
        forwarder.setInputReleased(true)
        forwarder.setReady(false)
        forwarder.setMiniPlayer(true)
        forwarder.setReady(true)
        forwarder.setMiniPlayer(false)
        forwarder.captureIfPointerIsOverTheStreamView(reason: "test")
        #expect(forwarder.isInputReleased && !forwarder.isMouseCaptured && !forwarder.forwardsCommand)
        #expect(view.acceptsFirstMouse(for: nil))
        window.focused = false
        forwarder.setInputReleased(false)
        #expect(forwarder.isInputReleased)
        forwarder.detach()
        #expect(!forwarder.isInputReleased && !forwarder.inputRearming)
    }

    @Test(arguments: [false, true])
    func recaptureHidesTheCursorInWindowsAndMiniPlayers(miniPlayer: Bool) {
        let (forwarder, _, _) = windowed()
        let stream = StreamWindow(displayMode: .window)
        defer { forwarder.detach(); stream.close() }
        forwarder.setMiniPlayer(miniPlayer)
        stream.isMiniPlayer = miniPlayer
        forwarder.onInputReleaseChanged = { stream.setInputReleased($0, shortcut: "⌃⇧P") }
        forwarder.onPointerCaptureChanged = { stream.setPointerCaptured($0) }
        forwarder.capturePointer(reason: "test")
        #expect(forwarder.isMouseCaptured && stream.didHideCursor)

        for _ in 0..<2 {
            forwarder.setInputReleased(true)
            #expect(stream.isInputReleased && !stream.didHideCursor)
            forwarder.setInputReleased(false)
            #expect(!stream.isInputReleased && forwarder.isMouseCaptured)
            #expect(stream.didHideCursor)
        }
    }

    @Test func releasedFullscreenNeverRehidesTheCursorOrRaisesTheCoverOnRefocus() {
        let prior = NSApp.presentationOptions
        let stream = StreamWindow(displayMode: .fullScreen)
        defer { stream.close(); NSApp.presentationOptions = prior }
        stream.previousPresentationOptions = prior
        stream.awaitingFirstFrameFadeIn = false
        stream.streamingWindowLevel = NSWindow.Level(rawValue: 25)
        stream.window.level = NSWindow.Level(rawValue: 25)
        stream.setInputReleased(true, shortcut: "⌃⇧P")
        stream.setCursorHidden(true)
        stream.setPointerCaptured(true, isKeyWindow: true)
        stream.reengageForeground()
        stream.takePointerOnFirstFrame()
        #expect(!stream.didHideCursor)
        #expect(stream.window.level == .normal)
        #expect(NSApp.presentationOptions == prior)
        stream.setInputReleased(false, shortcut: "⌃⇧P")
        #expect(stream.window.level == NSWindow.Level(rawValue: 25))
    }

    // MARK: Diagnostic sampler

    @Test func diagnosticEventNamesFallBackToTheRawType() throws {
        let forwarder = InputForwarder()
        #expect(forwarder.diagnosticEventTypeName(.scrollWheel) == "scrollWheel")
        #expect(forwarder.diagnosticEventTypeName(.otherMouseDown) == "otherMouseDown")
        if #available(macOS 26, *) {
            #expect(forwarder.diagnosticEventTypeName(.mouseCancelled)
                == "type(\(NSEvent.EventType.mouseCancelled.rawValue))")
        }
        let unmapped = try #require(NSEvent.EventType(rawValue: 999))
        #expect(forwarder.diagnosticEventTypeName(unmapped) == "type(999)")
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
