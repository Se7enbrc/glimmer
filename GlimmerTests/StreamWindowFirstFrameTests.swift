//
//  StreamWindowFirstFrameTests.swift
//
//  The stream window's hand-off: nothing is taken from the user before the
//  first frame, or after a close or a Cmd-Tab away; the cover's presentation
//  options stay a set AppKit accepts; a warp's jump never reaches the PC.
//

import AppKit
import Testing
@testable import Glimmer

@MainActor
struct StreamWindowFirstFrameTests {

    /// A failing connect leaves the pointer free for the launcher's Cancel: the
    /// invisible window cannot capture it before the first frame.
    @Test func waitingForTheFirstFrameLeavesThePointerFree() {
        let stream = StreamWindow()
        stream.awaitingFirstFrameFadeIn = true
        let forwarder = InputForwarder()
        forwarder.attach(to: stream.window)
        defer { forwarder.exitCapturedMode() }
        forwarder.enterCapturedMode()
        #expect(!forwarder.isMouseCaptured)
    }

    /// A Cmd-Tab away belongs to the full-screen cover. Leaving the cover for
    /// the mini player forgets it, so the way back arms the key backstop again.
    @Test func leavingTheCoverForgetsACmdTabAway() {
        let stream = StreamWindow()
        stream.userBackgrounded = true
        stream.retireFullScreenCover()
        #expect(!stream.userBackgrounded)
    }

    @Test func aFirstFrameAfterCloseTakesNothing() {
        let stream = StreamWindow()
        stream.awaitingFirstFrameFadeIn = true
        stream.didClose = true
        stream.fadeInOnFirstFrame()
        #expect(stream.awaitingFirstFrameFadeIn)
        #expect(stream.cursorHideCount == 0)
    }

    /// The window goes visible for the user's return, but keeps its hands off
    /// the pointer and the menu bar while they are in another app.
    @Test func aFirstFrameWhileTheUserIsAwayTakesNothing() {
        let stream = StreamWindow()
        stream.awaitingFirstFrameFadeIn = true
        stream.userBackgrounded = true
        let options = NSApp.presentationOptions
        stream.fadeInOnFirstFrame()
        #expect(!stream.window.ignoresMouseEvents)
        #expect(stream.cursorHideCount == 0)
        #expect(NSApp.presentationOptions == options)
    }

    @Test func coverOptionsPairEachMenuBarChoiceWithItsDock() {
        let covering = StreamWindow.streamingPresentationOptions(coversNotch: true)
        #expect(covering.isSuperset(of: [.hideMenuBar, .hideDock]))
        #expect(covering.isDisjoint(with: [.autoHideMenuBar, .autoHideDock]))
        let spaced = StreamWindow.streamingPresentationOptions(coversNotch: false)
        #expect(spaced.isSuperset(of: [.autoHideMenuBar, .autoHideDock]))
        #expect(spaced.isDisjoint(with: [.hideMenuBar, .hideDock]))
    }

    @Test func coverOptionsTurnOffShakeToFindAndHotCorners() {
        for coversNotch in [true, false] {
            let options = StreamWindow.streamingPresentationOptions(coversNotch: coversNotch)
            #expect(options.contains(.disableCursorLocationAssistance))
            if #available(macOS 27, *) {
                #expect(options.contains(.disableScreenCornerInteractions))
            }
        }
    }

    /// AppKit mouse rows run from minY + 1 to maxY: the top row belongs to
    /// this screen, the row at minY to the display below.
    @Test func pointerOnScreenFollowsAppKitMouseRows() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(StreamCursor.isOnScreen(CGPoint(x: 960, y: 540), frame: screen))
        #expect(StreamCursor.isOnScreen(CGPoint(x: 0, y: 1080), frame: screen))
        #expect(!StreamCursor.isOnScreen(CGPoint(x: 500, y: 0), frame: screen))
        #expect(!StreamCursor.isOnScreen(CGPoint(x: 1920, y: 540), frame: screen))
        #expect(!StreamCursor.isOnScreen(CGPoint(x: -300, y: 400), frame: screen))
    }

    @Test func aWarpDropsExactlyOneMotionEvent() throws {
        let view = StreamInputView()
        let recorder = MotionRecorder()
        view.delegate = recorder
        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.discardsNextMotion = true
        view.mouseMoved(with: move)
        #expect(recorder.moves == 0)
        view.mouseMoved(with: move)
        view.mouseMoved(with: move)
        #expect(recorder.moves == 2)
    }
}

/// Counts the motion the view passes on; every other edge is ignored.
@MainActor
private final class MotionRecorder: StreamInputViewDelegate {
    var moves = 0
    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent) { moves += 1 }
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent) -> Bool { true }
    func streamView(_ view: StreamInputView, handleKeyUp event: NSEvent) {}
    func streamView(_ view: StreamInputView, handleFlagsChanged event: NSEvent) {}
    func streamView(_ view: StreamInputView, handleMouseDown event: NSEvent) {}
    func streamView(_ view: StreamInputView, handleMouseUp event: NSEvent) {}
    func streamView(_ view: StreamInputView, handleScroll event: NSEvent) {}
    func streamViewPointerDidEnter(_ view: StreamInputView) {}
    func streamViewPointerDidExit(_ view: StreamInputView) {}
    func streamView(_ view: StreamInputView, handleKeyEquivalent event: NSEvent) -> Bool { false }
    func streamViewPaste(_ view: StreamInputView) {}
}
