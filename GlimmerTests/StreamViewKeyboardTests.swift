// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Client chords, Caps Lock and modifier bytes on the way to the backend.

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct StreamViewKeyboardTests {
    @MainActor
    private final class Tally { var calls = 0 }

    private let down = Int8(StreamProtocol.KEY_ACTION_DOWN)
    private let up = Int8(StreamProtocol.KEY_ACTION_UP)
    private func wire(_ vk: Int16) -> Int16 { VKScanCode(vk: vk).wireCode }

    private func key(_ type: NSEvent.EventType, _ keyCode: Int, mods: NSEvent.ModifierFlags = [],
                     chars: String = "", isRepeat: Bool = false, at timestamp: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: mods, timestamp: timestamp,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: isRepeat, keyCode: UInt16(keyCode)))
    }

    private func ready() -> (InputForwarder, InputRecordingBackend, StreamInputView) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let view = StreamInputView()
        view.delegate = forwarder
        return (forwarder, backend, view)
    }

    @Test func aKeyGoesOutWithItsModifiersAfterTheModifierItself() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_A, mods: [.shift, .option], chars: "a"))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_A, mods: [.shift, .option], chars: "a", at: 2))
        let mods = Int8(StreamProtocol.MODIFIER_SHIFT | StreamProtocol.MODIFIER_ALT)
        #expect(backend.keyboard == [
            .init(keyCode: wire(0xA0), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0xA4), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0x41), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0x41), action: up, modifiers: mods, flags: 0)
        ])
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func repeatsAndAClosedGateSendNothing() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_W, chars: "w", isRepeat: true))
        forwarder.isReady = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_W, chars: "w"))
        view.flagsChanged(with: try key(.flagsChanged, kVK_Shift, mods: [.shift]))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_W, chars: "w"))
        #expect(backend.keyboard.isEmpty)
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func modifierByteFoldsCommandOnlyWhileItIsForwarded() {
        let forwarder = InputForwarder()
        #expect(forwarder.modifierByte(from: [.control, .shift, .option, .command]) == 0x07)
        forwarder.captureSysKeys = true
        forwarder.isMouseCaptured = true
        #expect(forwarder.modifierByte(from: [.control, .shift, .option, .command]) == 0x0F)
        #expect(forwarder.modifierByte(from: [.capsLock, .function]) == 0)
    }

    /// Windows toggles on each press, so one Mac toggle is a full press and release.
    @Test func capsLockToggleIsOneTapEachWay() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        view.flagsChanged(with: try key(.flagsChanged, kVK_CapsLock, mods: [.capsLock]))
        view.flagsChanged(with: try key(.flagsChanged, kVK_CapsLock))
        #expect(backend.keyboard.map(\.keyCode) == Array(repeating: wire(0x14), count: 4))
        #expect(backend.keyboard.map(\.action) == [down, up, down, up])
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func shiftWhileCapsLockIsOnSendsOnlyShift() throws {
        let (forwarder, backend, view) = ready()
        forwarder.lastCapsLock = true
        view.flagsChanged(with: try key(.flagsChanged, kVK_Shift, mods: [.capsLock, .shift]))
        #expect(backend.keyboard.map(\.keyCode) == [wire(0xA0)])
        #expect(forwarder.heldModifierVKs == [0xA0])
    }

    // MARK: Client chords are consumed, never forwarded

    @Test func quitAndStatsChordsStayOnTheMac() throws {
        let (forwarder, backend, view) = ready()
        let quits = Tally()
        let stats = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onStatsHotkey = { stats.calls += 1 }
        view.keyDown(with: try key(.keyDown, kVK_ANSI_Q, mods: [.control], chars: "q"))
        view.keyDown(with: try key(.keyDown, kVK_ANSI_I, mods: [.control], chars: "i"))
        view.keyDown(with: try key(.keyDown, kVK_ANSI_I, mods: [.control], chars: "i", isRepeat: true))
        #expect(quits.calls == 1)
        #expect(stats.calls == 1)
        #expect(!backend.keyboard.contains { $0.keyCode == wire(0x51) || $0.keyCode == wire(0x49) })
    }

    @Test func bookmarkChordWithoutAHandlerIsAKey() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_B, mods: [.control], chars: "b"))
        #expect(forwarder.heldKeys == [0x42])
        #expect(backend.keyboard.last == .init(keyCode: wire(0x42), action: down,
                                               modifiers: Int8(StreamProtocol.MODIFIER_CTRL), flags: 0))
    }

    @Test func pointerChordIsAKeyInFullScreen() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_P, mods: [.control], chars: "p"))
        #expect(forwarder.heldKeys == [0x50])
        #expect(backend.keyboard.last?.keyCode == wire(0x50))
    }

    @Test func miniPlayerChordToggles() throws {
        let (forwarder, backend, view) = ready()
        let toggles = Tally()
        forwarder.onMiniPlayerHotkey = { toggles.calls += 1 }
        forwarder.modifiersNeedResync = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_M, mods: [.control], chars: "m"))
        #expect(toggles.calls == 1)
        #expect(backend.keyboard.isEmpty)
    }

    // MARK: The view's own routing

    @Test func viewClaimsCommandEquivalentsOnlyWhenTheyAreTheGames() throws {
        let (forwarder, backend, view) = ready()
        let commandW = try key(.keyDown, kVK_ANSI_W, mods: [.command], chars: "w")
        #expect(!view.performKeyEquivalent(with: commandW))
        forwarder.captureSysKeys = true
        forwarder.isMouseCaptured = true
        #expect(view.performKeyEquivalent(with: commandW))
        #expect(backend.keyboard.last?.keyCode == wire(0x57))
        #expect(backend.keyboard.last?.modifiers == Int8(StreamProtocol.MODIFIER_META))
    }

    /// Without a live tracking area AppKit never delivers mouseMoved; a resize replaces it.
    @Test func trackingAreaIsReplacedNotStacked() {
        let view = StreamInputView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        let options = view.trackingAreas.first?.options ?? []
        #expect(options.isSuperset(of: [.mouseMoved, .activeAlways, .mouseEnteredAndExited]))
    }

    @Test func viewAcceptsTheActivatingClickOnlyForTheMiniPlayer() {
        let forwarder = InputForwarder()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.attach(to: window)
        defer { forwarder.detach() }
        let view = forwarder.inputView
        #expect(view?.acceptsFirstMouse(for: nil) == false)
        #expect(view?.acceptsFirstResponder == true)
        forwarder.setMiniPlayer(true)
        #expect(view?.acceptsFirstMouse(for: nil) == true)
        forwarder.setMiniPlayer(false)
        #expect(view?.acceptsFirstMouse(for: nil) == false)
    }
}

/// ⌃B is a bookmark only while telemetry runs; otherwise it is the game's.
/// Serialized because both tests pin the shared telemetry preference.
@MainActor
@Suite(.serialized)
struct BookmarkChordTelemetryTests {
    @MainActor
    private final class Tally { var calls = 0 }

    /// Runs `body` with TelemetryGate's preference pinned, restoring the prior value.
    private func withTelemetry(_ enabled: Bool, _ body: () throws -> Void) throws {
        try #require(getenv("GLIMMER_TELEMETRY").map { String(cString: $0) } != "1")
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "telemetryEnabled")
        defer { defaults.set(prior, forKey: "telemetryEnabled") }
        defaults.set(enabled, forKey: "telemetryEnabled")
        try #require(TelemetryGate.isEnabled == enabled)
        try body()
    }

    /// One ⌃B with a handler wired: the bookmark count and the keys sent.
    private func pressBookmark() throws -> (marks: Int, sent: [KeyboardSend]) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let marks = Tally()
        forwarder.onBookmarkHotkey = { marks.calls += 1 }
        let view = StreamInputView()
        view.delegate = forwarder
        view.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 1, windowNumber: 0,
            context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_B))))
        return (marks.calls, backend.keyboard)
    }

    @Test func withTelemetryOnTheChordIsABookmark() throws {
        try withTelemetry(true) {
            let result = try pressBookmark()
            #expect(result.marks == 1)
            #expect(result.sent.isEmpty)
        }
    }

    @Test func withTelemetryOffTheChordReachesThePC() throws {
        try withTelemetry(false) {
            let result = try pressBookmark()
            #expect(result.marks == 0)
            #expect(result.sent.last == .init(keyCode: VKScanCode(vk: 0x42).wireCode,
                                              action: Int8(StreamProtocol.KEY_ACTION_DOWN),
                                              modifiers: Int8(StreamProtocol.MODIFIER_CTRL), flags: 0))
        }
    }
}
