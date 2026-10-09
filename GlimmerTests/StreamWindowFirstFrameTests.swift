//
//  StreamWindowFirstFrameTests.swift
//
//  The stream window's hand-off: nothing is taken from the user before the
//  first frame, after a close or Cmd-Tab away; cover options stay valid; a
//  warp's jump never reaches the PC.
//

import AppKit
import Testing
@testable import Glimmer

@MainActor
struct StreamWindowFirstFrameTests {

    @Test(arguments: [false, true])
    func eachDisplayTypeRetainsItsFullScreenChoice(usesSpace: Bool) {
        #expect(AppModel.streamCoversNotch(displayHasNotch: false, coversNotch: false,
                                         usesFullScreenSpace: usesSpace) == !usesSpace)
        #expect(AppModel.streamCoversNotch(displayHasNotch: false, coversNotch: true,
                                         usesFullScreenSpace: usesSpace) == !usesSpace)
        #expect(AppModel.streamCoversNotch(displayHasNotch: true, coversNotch: false,
                                         usesFullScreenSpace: usesSpace) == false)
        #expect(AppModel.streamCoversNotch(displayHasNotch: true, coversNotch: true,
                                         usesFullScreenSpace: usesSpace) == true)
    }

    @Test func onlyHiddenPresentationIsSuppressed() {
        #expect(!StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: false, occlusionVisible: true))
        #expect(StreamWindow.suppressesPresentation(isVisible: false, isMiniaturized: false, occlusionVisible: true))
        #expect(StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: true, occlusionVisible: true))
        #expect(StreamWindow.suppressesPresentation(isVisible: true, isMiniaturized: false, occlusionVisible: false))
    }

    @Test func aFirstFrameDuringTheFocusDebounceCannotTakeThePointer() {
        let stream = StreamWindow()
        var installs = 0
        stream.onDidBecomeReadyForInput = { installs += 1 }
        defer { stream.setCursorHidden(false) }
        #expect(!stream.window.isKeyWindow)
        #expect(!stream.userBackgrounded)

        stream.takePointerOnFirstFrame()

        #expect(stream.cursorHideCount == 0)
        #expect(installs == 0)
    }

    @Test func aWindowSpaceExitForMiniPlayerRetiresItsVisibilityObservers() {
        let stream = StreamWindow(displayMode: .window)
        let center = NotificationCenter.default
        stream.installDisplayObservers(nc: center)
        stream.installSpaceExitObservers()
        defer { for token in stream.spaceExitObservers { center.removeObserver(token) } }
        stream.miniPlayerPending = true
        #expect(!stream.keyObservers.isEmpty)

        center.post(name: NSWindow.willExitFullScreenNotification, object: stream.window)

        #expect(stream.keyObservers.isEmpty)
        #expect(stream.workspaceObservers.isEmpty)
        #expect(stream.miniPlayerPending)
        #expect(stream.displayMode == .window)
    }

    @Test func repeatedSpaceExitRegistrationKeepsOneOwnedObserverPair() {
        let stream = StreamWindow()
        stream.installSpaceExitObservers()
        stream.installSpaceExitObservers()
        defer { for token in stream.spaceExitObservers { NotificationCenter.default.removeObserver(token) } }
        #expect(stream.spaceExitObservers.count == 2)
    }

    @Test func repeatedMiniPlayerRequestDuringSpaceExitKeepsItsOriginalReturnMode() {
        let stream = StreamWindow(displayMode: .window)
        stream.miniPlayerPending = true
        stream.miniPlayerReturnMode = .fullScreen
        stream.miniPlayerReturnUsesSpace = true

        stream.enterMiniPlayer()

        #expect(!stream.isMiniPlayer)
        #expect(stream.miniPlayerPending)
        #expect(stream.miniPlayerReturnMode == .fullScreen)
        #expect(stream.miniPlayerReturnUsesSpace)
    }

    @Test func spaceFocusLossReportsTheLauncherWithoutBlockingTheFirstFrame() {
        let stream = StreamWindow()
        stream.coversNotch = false
        stream.awaitingFirstFrameFadeIn = true
        var backgrounded: [Bool] = []
        var suppressed: [Bool] = []
        stream.onBackgroundedChanged = { backgrounded.append($0) }
        stream.onPresentationSuppressedChanged = { suppressed.append($0) }

        stream.backgroundStreamWindow()

        #expect(stream.userBackgrounded)
        #expect(backgrounded == [true])
        #expect(suppressed.isEmpty)
        #expect(stream.cursorHideCount == 0)
    }

    @Test func occlusionReportsVisibilityIndependentlyAndStopsAfterClose() {
        let stream = StreamWindow()
        let center = NotificationCenter()
        var backgrounded: [Bool] = []
        var suppressed: [Bool] = []
        stream.onBackgroundedChanged = { backgrounded.append($0) }
        stream.onPresentationSuppressedChanged = { suppressed.append($0) }
        stream.installPresentationVisibilityObserver(nc: center)
        defer { for token in stream.keyObservers { center.removeObserver(token) } }

        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: stream.window)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: stream.window)
        #expect(suppressed == [true])
        #expect(backgrounded.isEmpty)

        stream.didClose = true
        stream.presentationSuppressed = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: stream.window)
        #expect(!stream.presentationSuppressed)
        #expect(suppressed == [true])
    }

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
    /// the pointer while they are in another app.
    @Test func aFirstFrameWhileTheUserIsAwayTakesNothing() {
        let stream = StreamWindow()
        stream.awaitingFirstFrameFadeIn = true
        stream.userBackgrounded = true
        stream.fadeInOnFirstFrame()
        #expect(!stream.window.ignoresMouseEvents)
        #expect(stream.cursorHideCount == 0)
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
                #expect(options.contains(NSApplication.PresentationOptions(rawValue: 1 << 15)))
                #if compiler(>=6.4)
                #expect(options.contains(.disableScreenCornerInteractions))
                #endif
            }
        }
    }

    @Test func displayWakeUsesDedicatedCallbackAndCloseRemovesObserver() {
        let stream = StreamWindow()
        var wakeCount = 0
        var screenChangeCount = 0
        stream.onDisplaysWoke = { wakeCount += 1 }
        stream.onScreenChanged = { screenChangeCount += 1 }
        stream.installDisplayObservers(nc: NotificationCenter())
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(wakeCount == 1)
        #expect(screenChangeCount == 0)

        stream.close()
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(wakeCount == 1)
        #expect(screenChangeCount == 0)
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

    @Test func aWarpDropsOldMotionThenExactlyOneFreshMotionEvent() throws {
        let view = StreamInputView()
        let recorder = MotionRecorder()
        view.delegate = recorder
        let oldMove = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 3,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.resetMotion(after: 2)
        view.mouseMoved(with: oldMove)
        view.mouseDragged(with: oldMove)
        view.mouseMoved(with: move)
        #expect(recorder.moves == 0)
        view.mouseMoved(with: move)
        view.mouseMoved(with: move)
        #expect(recorder.moves == 2)
    }

    @Test(arguments: [StreamDisplayMode.fullScreen, .window])
    func closeRestoresArrowBeforeFadeAndLateCursorUpdates(mode: StreamDisplayMode) throws {
        let stream = StreamWindow(displayMode: mode)
        let forwarder = InputForwarder()
        forwarder.attach(to: stream.window)
        defer { forwarder.detach(); NSCursor.arrow.set() }
        let view = try #require(forwarder.inputView)
        view.updateTrackingAreas()
        stream.window.ignoresMouseEvents = false
        stream.setCursorHidden(true)
        #expect(NSCursor.current !== NSCursor.arrow)

        stream.close()

        #expect(stream.didClose)
        #expect(stream.window.ignoresMouseEvents)
        #expect(stream.cursorHideCount == 0)
        #expect(NSCursor.current === NSCursor.arrow)
        view.cursorUpdate(with: try cursorEvent())
        view.refreshCursor()
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func repeatedDisplayHidesReleaseTheirImageAndCountTogether() throws {
        let stream = StreamWindow()
        let view = StreamInputView()
        stream.window.contentView = view
        defer { stream.setCursorHidden(false) }
        stream.setCursorHidden(true)
        stream.setCursorHidden(true)
        #expect(stream.cursorHideCount == 2)

        stream.setCursorHidden(false)
        stream.setCursorHidden(false)
        view.cursorUpdate(with: try cursorEvent())
        stream.reassertCursorHiddenIfNeeded()

        #expect(stream.cursorHideCount == 0)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func newlyAttachedViewLeavesCursorVisibleUntilCaptureStarts() throws {
        let stream = StreamWindow()
        let forwarder = InputForwarder()
        forwarder.attach(to: stream.window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        NSCursor.arrow.set()

        view.cursorUpdate(with: try cursorEvent())
        view.refreshCursor()

        #expect(stream.cursorHideCount == 0)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func fullscreenDetachRetiresTransparentImageWithoutWaitingForClose() throws {
        let stream = StreamWindow()
        let forwarder = InputForwarder()
        forwarder.attach(to: stream.window)
        defer { NSCursor.arrow.set() }
        let view = try #require(forwarder.inputView)
        view.setTransparentCursorEnabled(true)
        #expect(NSCursor.current !== NSCursor.arrow)

        forwarder.detach()

        #expect(view.delegate == nil)
        #expect(NSCursor.current === NSCursor.arrow)
        view.cursorUpdate(with: try cursorEvent())
        view.refreshCursor()
        #expect(NSCursor.current === NSCursor.arrow)
    }

    private func cursorEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }
}

/// Counts the motion the view passes on; every other edge is ignored.
@MainActor
private final class MotionRecorder: StreamInputViewDelegate {
    var moves = 0
    func streamView(_ view: StreamInputView, handleMouseMoved event: NSEvent) { moves += 1 }
    func streamView(_ view: StreamInputView, handleKeyDown event: NSEvent) {}
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
