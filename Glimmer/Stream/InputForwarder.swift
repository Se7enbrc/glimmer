// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  InputForwarder.swift
//
//  Forwards keyboard, mouse, and gamepad input from the local Mac to the
//  remote host via the native backend's input-uplink methods (the LiSend*
//  family the GameStream protocol defines). Hosts the user's configurable
//  in-stream quit hotkey.
//
//  Implementation notes - read before editing:
//
//   * Input goes through a custom NSView (`StreamInputView`) installed as the
//     window's contentView's responder. Earlier revisions used
//     `NSEvent.addLocalMonitorForEvents`, but on macOS 26 the responder chain
//     consumes mouseMoved/keyDown events for content views that accept first
//     responder *before* the local monitor block fires. Routing through
//     NSResponder overrides is the only thing that's reliably ordered.
//
//   * The native backend's input queue is gated on the input stream being
//     started, which happens only after the control stream's RTSP handshake
//     completes. Any send call made before that returns -2 and does NOT
//     enqueue. We expose `setReady(_:)` so StreamSession can flip the gate
//     when the `connectionStarted` listener callback fires; until then we
//     drop events on the floor instead of generating a flood of -2 log lines.
//
//   * Keyboard codes are sent as positional scancodes via
//     `LiSendKeyboardEvent2(Int16(bitPattern: 0x8000 | UInt16(bitPattern: vk)), ...)`. The high bit asks the host to
//     skip its layout-correction pass (GFE tries to "fix" AZERTY → QWERTY by
//     remapping VK_*; we want the position to win because the user is looking
//     at their physical keyboard). This is the same convention moonlight-qt
//     uses in its Mac build.
//
//   * NKRO: each physical key transition sends exactly one event, with no coalescing; `raiseAllHeldInputs()`
//     runs only on focus loss, a paste, `detach()` and a reconnect. `heldModifierVKs` (one entry per side) is
//     diffed in `flagsChanged`, so releasing one of two held Shifts releases exactly that one on the PC.
//
//   * Mouse motion is *relative* via the SDL associate-false model
//     (P0 mouse-snap fix). When relative aim is engaged we call
//     `CGAssociateMouseAndMouseCursorPosition(false)` (enterCapturedMode) so the
//     OS STOPS physically moving the on-screen cursor - exactly
//     SDL_SetRelativeMouseMode(true) on macOS. This is the airtight fix for the
//     in-game aim snapping to a screen edge/corner: the prior model kept the
//     cursor associated and warped it back to centre near an edge, but an
//     associate-TRUE warp posts a reconciling mouse-moved event carrying the
//     full edge→centre delta (~1500px), which (with no suppression anywhere) was
//     read as pure HID motion and sent to the host. Under associate-false the
//     cursor never moves, so there is no edge, no warp, and no reconciliation
//     delta to leak - the bug class is structurally gone. Ownership:
//       1. Visibility: owned ENTIRELY by StreamWindow, which hides the cursor
//          with `CGDisplayHideCursor` (single source of truth =
//          `StreamWindow.didHideCursor`). CGDisplayHideCursor (unlike
//          NSCursor.hide) does not require the cursor to be over our window, so
//          the hide can't no-op. With the cursor hidden there is no visible
//          pointer to "freeze" - the two reasons associate-false was previously
//          abandoned (visible freeze + dead deltas) both no longer apply.
//       2. Relative deltas: read off the CGEvent backing each mouseMoved
//          NSEvent via `CGEventGetIntegerValueField(_, kCGMouseEventDeltaX/Y)`.
//          These raw, accel-free HID deltas stay valid AND become pure HID under
//          associate-false (the exact field SDL reads in relative mode). Only
//          NSEvent.deltaX/Y goes silent under associate-false - and we don't use
//          it. The previous Glimmer revision read NSEvent.deltaX/Y and wrongly
//          concluded associate-false killed deltas; the right field is the
//          CGEvent layer underneath.
//       3. Association: every associate-false (enterCapturedMode) is paired with
//          a guaranteed associate-true (exitCapturedMode, run on resign-key and
//          detach) so Cmd-Tab / teardown restores a normal OS-controlled pointer.
//          Hot corners are a non-issue: the OS doesn't move the cursor, so it
//          can never reach a corner - warpCursorIfNearEdge was deleted.
//     This is the SDL relative-mouse recipe on macOS: hide (CGDisplayHideCursor)
//     + associate-false + read kCGMouseEventDeltaX/Y.
//     A local NSEvent monitor for the gesture family
//     (`.magnify`/`.smartMagnify`/`.swipe`/`.rotate`) swallows the high-
//     level gesture events while the stream window is key so a trackpad
//     pinch can't reach macOS's window scaler. The narrower mask is
//     intentional: a broader set (`.gesture`/`.beginGesture`/`.endGesture`/
//     `.pressure`) swallows raw trackpad pan/scroll data on laptops with
//     no external mouse, killing cursor + scroll because the OS
//     synthesises mouseMoved from the same gesture stream we're eating.
//     (Ctrl+scroll Accessibility Zoom is the one trigger the freeze used to
//     gate that a monitor cannot - its non-freezing replacement is the
//     kCGAnnotatedSessionEventTap escalation, not yet installed; see
//     InputForwarder+Capture.swift.)
//
//   * Diagnostic event tap: while a stream is live (isReady == true) we
//     install two NSEvent monitors (local + global) that log every input
//     event AppKit delivers to the process at .info level. Reproducing the
//     mid-game macOS-zoom bug once and grepping for "DiagEvent"
//     in the log shows exactly which event type fires immediately
//     before the zoom - that drives whether we need to escalate to a
//     CGEventTap (see TODO(eventtap) in installDiagnosticMonitors). Rate-
//     limited to ~100 events/sec via a 1-second windowed sampler.
//
//   * Gamepad arrival is announced via `LiSendControllerArrivalEvent`. Some
//     host versions register a controller slot only after seeing this; without
//     it `LiSendMultiControllerEvent` events appear to be silently dropped on
//     newer Sunshine builds.

import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GameController
import os.log

@MainActor
public final class InputForwarder {
    // Internal (default) so the ControllerForwarder extension in
    // ControllerForwarder.swift can log with the same subsystem/category.
    let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Input")

    weak var window: NSWindow?
    weak var inputView: StreamInputView?
    var controllerLayouts: MacControllerLayouts?

    /// Called when the user presses the configured quit hotkey. The session
    /// owner wires this to stop streaming.
    public var onQuitHotkey: (@MainActor () -> Void)?
    /// Leaving before the first connection is live cancels the connect, as the
    /// launcher's Cancel does. Falls back to `onQuitHotkey` when unset.
    public var onCancelConnect: (@MainActor () -> Void)?

    /// Provider for the quit hotkey. Called on every keyDown so changes the
    /// user makes in Settings while a stream is live take effect immediately
    /// - capturing the chord once at attach time meant the live edit silently
    /// did nothing until the next stream restart, which is a real UX trap.
    package var quitHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultQuit }

    /// Called when the user presses the configured stats-overlay hotkey.
    /// The session owner wires this to toggle the in-stream stats overlay.
    /// Like `onQuitHotkey`, the chord fires BEFORE the sys-key-capture gate
    /// so a non-Cmd default keeps working regardless of `captureSysKeys`.
    public var onStatsHotkey: (@MainActor () -> Void)?

    /// Provider for the stats-overlay hotkey. See `quitHotkeyProvider` for
    /// why this is a closure rather than a stored chord value.
    package var statsHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultStats }

    /// Called when the user presses the telemetry-bookmark chord (signal 4 -
    /// "that felt bad"). CLIENT-ONLY: the chord is consumed in the input path and
    /// NEVER forwarded to the host (mirrors the quit/stats intercept). The session
    /// owner wires this to `TelemetryExporter.recordBookmark()`. Like the quit
    /// hotkey, the match fires BEFORE the sys-key-capture gate so the non-Cmd
    /// default works regardless of `captureSysKeys`.
    ///
    /// GATED: the chord is only intercepted when this handler is wired AND
    /// `TelemetryGate.isEnabled` (see `streamView(_:handleKeyDown:)`). With
    /// telemetry OFF - the default - there is no live telemetry to bookmark
    /// into, so ⌃B is NOT swallowed and passes straight through to the host
    /// like any other key.
    public var onBookmarkHotkey: (@MainActor () -> Void)?

    /// Provider for the bookmark chord. See `quitHotkeyProvider` for why this is
    /// a closure rather than a stored chord value.
    package var bookmarkEnabled: @MainActor () -> Bool = { TelemetryGate.isEnabled }
    package var bookmarkHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultBookmark }

    /// Read live like the quit/stats chords; toggles capture in every presentation.
    package var releasePointerHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultReleasePointer }

    /// Precise scroll slices summed into whole wheel notches (ScrollQuantizer.swift).

    /// The mini player chord: a client-only toggle, never forwarded.
    package var miniPlayerHotkeyProvider: (@MainActor () -> HotkeyChord) = { .defaultMiniPlayer }
    public var onMiniPlayerHotkey: (@MainActor () -> Void)?

    /// Mini player: no hover grab, a click takes the pointer. Set live by
    /// `setMiniPlayer` (InputForwarder+WindowPointer.swift).
    var isMiniPlayer = false
    var controllerOwnershipSuspended = false
    let controllerBackgroundEventsID = UUID()
    /// The pointer entered or left the mini player; the window shows its
    /// close button off this edge.
    var onMiniPlayerHoverChanged: (@MainActor (Bool) -> Void)?

    /// Window mode grabs on hover; fullscreen follows the app's initial policy
    /// and the user's live capture toggle across focus changes.
    var isWindowMode: Bool = false
    var fullscreenRelativePointer = true
    var onPointerModeToggled: (@MainActor (Bool) -> Void)?

    /// The stream's pixel dimensions, the reference frame absolute pointer
    /// positions are measured in. Set by the session at start and re-set on a
    /// reconnect that changes resolution; `.zero` (full screen, or before the
    /// session sets it) makes the absolute path a no-op rather than sending a
    /// position against a frame that does not exist.
    var streamPixelSize: CGSize = .zero

    /// In-flight "hold Esc to free the pointer" dwell (window mode, captured
    /// only). Stored here because extensions can't add stored properties; the
    /// decision table and the timer live in InputForwarder+EscapeHold.swift.
    var escapeHoldTask: Task<Void, Never>?

    /// Window mode: block the hover grab until the pointer LEAVES the stream
    /// view or the window loses key status.
    ///
    /// Armed by every explicit release (a held Esc, the pointer chord), which
    /// all happen with the pointer still physically over the picture - without
    /// this the grab-on-hover rule would take the pointer straight back and
    /// there would be no way out of capture at all. Stored here because
    /// extensions can't add stored properties; the transitions are a pure
    /// table in InputForwarder+HoverCapture.swift and this is its only writer.
    var isHoverCaptureSuppressed = false

    /// StreamWindow owns cursor visibility in every presentation.
    var onPointerCaptureChanged: (@MainActor (Bool) -> Void)?

    /// Controller-side quit chord. The ControllerForwarder extension
    /// consults this on every gamepad update and fires `onQuitHotkey`
    /// when all chord buttons are held simultaneously. Closure so live
    /// edits in Settings take effect on the next gamepad event.
    package var controllerQuitChordProvider: (@MainActor () -> ControllerQuitChord) = { .none } {
        didSet { observeControllerConfiguration() }
    }

    /// The user-recorded button set for the `.custom` quit chord.
    /// Consulted only when `controllerQuitChordProvider()` returns `.custom`.
    package var customControllerChordProvider: (@MainActor () -> Set<ControllerButton>) = { [] } {
        didSet { observeControllerConfiguration() }
    }

    /// In-flight hold-to-quit dwell for the controller quit chord. Armed by
    /// the ControllerForwarder extension when the chord first reads fully
    /// held; cancelled when it releases, when the arming pad detaches, or at
    /// session teardown (`detach()`). Stored here because extensions can't
    /// add stored properties - the dwell logic lives with the chord matcher
    /// in ControllerForwarder+QuitChord.swift.
    let controllerChordDwell = ControllerChordDwell()
    var quitChordDwellTask: Task<Void, Never>? { controllerChordDwell.task }

    /// Slot that armed the in-flight dwell. Only that pad's value-changed
    /// frames may cancel the count - a second pad's frames (which won't
    /// match the chord) say nothing about whether the holder is still
    /// holding.
    var quitChordDwellSlot: UInt8? { controllerChordDwell.slot }

    /// Rate-limit state for the quit-chord Diag breadcrumbs (arm / cancel /
    /// expiry / partial hold). Same stored-property-in-extension constraint as
    /// the dwell fields above; the logic is in ControllerForwarder+QuitChord.
    var quitChordCrumbs = QuitChordBreadcrumbState()

    /// Opted-in Command chords become Win-key chords in fullscreen or a captured window.
    /// Otherwise key-downs, modifier transitions and the meta byte stay local to avoid phantom Win keys.
    /// Client quit/stats chords run before this gate so they work in either mode.
    public var captureSysKeys: Bool = false

    /// Delayed input belongs to one ready connection and one uninterrupted focus interval.
    var inputGeneration: UInt64 = 0

    /// Keyboard events wait behind text until cross-channel modifier releases settle.
    var pendingTextTask: Task<Void, Never>?
    var pendingKeyboardEvents: [(InputForwarder) -> Void] = []

    /// Opens when the backend can accept input; reconnects invalidate delayed work.
    public internal(set) var isReady: Bool = false {
        didSet {
            if isReady != oldValue { inputGeneration &+= 1 }
            publishInputSnapshot()
        }
    }

    /// Supplied by the session; replacing it invalidates text queued for the old connection.
    var backend: StreamingBackend? {
        didSet {
            inputCore.lock.lock(); defer { inputCore.lock.unlock() }
            inputGeneration &+= 1
            publishInputSnapshot(focused: false)
            if oldValue != nil {
                isReady = false
                inputOwnershipLost(reason: "connection replaced")
                releases.releaseAll(connectionLost: true)
                updateReconciliationTimer()
            }
        }
    }

    /// Set the backend the forwarder uses. Called by StreamSession right after
    /// `attach(to:)`.
    func setBackend(_ backend: StreamingBackend) {
        self.backend = backend
    }

    /// Track of which controllers have had their arrival event sent so we
    /// only do it once per connect. Keyed by GCController's hashable identity.
    /// Internal so the ControllerForwarder extension can read/write.
    var attachedHIDControllers: [UInt64: AttachedHIDController] = [:]
    let dualSenseRouting = DualSenseRouting.shared
    var attachedControllers: [ObjectIdentifier: AttachedController] = [:]

    /// Bitmask of slots currently in use; bit N == 1 means slot N is occupied.
    /// Sent to the host as `activeGamepadMask` on every controller event.
    var gamepadMask: UInt16 {
        get { inputCore.withLock { inputCore.snapshot.mask } }
        set { inputCore.withLock { inputCore.snapshot.mask = newValue }; publishInputSnapshot() }
    }

    var onControllerMouseChanged: (@MainActor (String) -> Void)?
    var nintendoLayoutProvider: @MainActor () -> Bool = { ControllerButtonLayout.usesLabels() }
    var useNintendoLabels = false { didSet { publishInputSnapshot() } }
    var nintendoLayoutObserver: NSObjectProtocol?
    var nintendoControllerTypes: [UInt8: NintendoControllerType] = [:] { didSet { publishInputSnapshot() } }

    /// What the PC may still hold in each slot. Only a stream start retires an entry,
    /// since a removal sent into a link that is already dead never arrives.
    var announcedControllers: [UInt8: ControllerArrival] {
        _read { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield inputCore.announcedControllers }
        _modify { inputCore.lock.lock(); defer { inputCore.lock.unlock() }; yield &inputCore.announcedControllers }
    }

    /// Cached connection observers so we can deregister on `detach()`.
    var connectObserver: NSObjectProtocol?
    var disconnectObserver: NSObjectProtocol?

    /// Sub-pixel mouse-move residual so motion under 1px per event isn't
    /// rounded to zero. macOS coalesces mouseMoved at ~120Hz on ProMotion;
    /// with a slow-moving trackpad we routinely see 0.3px/event. The
    /// accumulator carries the fraction forward until it crosses a
    /// whole-pixel boundary, which is what the host expects.

    /// Cruise traversal-boost state (see InputForwarder+Cruise.swift). Stored on
    /// the class because extensions can't add stored properties.
    /// `lastMoveTimestamp` is the previous batch's NSEvent.timestamp, for the
    /// inter-batch dt that gates the velocity; `cruiseGMax` is the resolution-
    /// derived ceiling, set at start and re-set on a reconnect resolution change.
    var lastMoveTimestamp: TimeInterval = 0
    var cruiseGMax: Double = 1.0
    let cruiseTuning: CruiseTraversal.Tuning
    /// WINDOWED velocity estimator feeding the Cruise gate: exponentially
    /// weighted Σdistance/Σtime over a ~30ms window. Robust BY CONSTRUCTION to
    /// variable event-delivery cadence - a device-rate 1ms batch contributes
    /// tiny distance AND tiny time, so the ratio can never spike (the 07-19
    /// "crazy sensitive" incident) nor understate under a dt floor (the
    /// follow-up chop: per-batch distance/dt flapped 4x as macOS alternated
    /// coalesced and per-event delivery). Both accums decay by exp(-dt/30ms).
    var cruiseDistAccum: Double = 0
    var cruiseTimeAccum: Double = 0

    /// Pull the relative delta out of a mouseMoved NSEvent. Reads the CGEvent
    /// integer fields `kCGMouseEventDeltaX/Y` (valid whether or not the cursor is
    /// associated; NSEvent.deltaX/Y goes silent under associate-false), falling
    /// back to NSEvent.deltaX/Y only for a synthetic event with no CGEvent
    /// backing. NOTE: these deltas carry macOS's pointer-acceleration curve -
    /// no accel-free path was adopted for the mouse (CGEventTap is also
    /// accelerated; the system accel-disable is intrusive and was
    /// deliberately not adopted).
    /// Returned in the same down-positive Y convention macOS uses so the
    /// LiSendMouseMoveEvent call site needs no sign flip.
    func mouseDelta(from event: NSEvent) -> (dx: Double, dy: Double) {
        if let cg = event.cgEvent {
            return (
                Double(cg.getIntegerValueField(.mouseEventDeltaX)),
                Double(cg.getIntegerValueField(.mouseEventDeltaY))
            )
        }
        return (event.deltaX, event.deltaY)
    }

    /// True when relative-aim mode is engaged. Flipped by `enterCapturedMode()`
    /// / `exitCapturedMode()` from the window's becomeKey/resignKey hooks.
    /// Re-entrant: enter while already-captured is a no-op.
    ///
    /// Under the SDL associate-false model (P0 mouse-snap fix) this
    /// flag ALSO gates the cursor-association latch:
    /// `enterCapturedMode` calls `CGAssociateMouseAndMouseCursorPosition(false)`
    /// when flipping it true, and `exitCapturedMode` re-associates (true) when
    /// flipping it false. It's the in-memory record of whether the disassociate
    /// is currently in effect, so the re-associate on resign/teardown is paired
    /// exactly once. The CGEvent-delta read in `mouseDelta(from:)` does not
    /// branch on it - the deltas are pure HID under associate-false regardless.
    var isMouseCaptured: Bool = false

    /// Saved `NSEvent.isMouseCoalescingEnabled` from BEFORE we engaged relative
    /// aim, restored on disengage so the rest of the system keeps its default.
    /// nil while we have not overridden coalescing (no save to restore). See
    /// `enterCapturedMode()` for why we turn coalescing OFF in relative aim.
    var savedMouseCoalescing: Bool?

    /// The user's linear-scaling flag from before raw aim switched it on, restored
    /// on disengage; nil while we have not overridden it. Also persisted while
    /// engaged so a crash can't strand it; see `MouseAccelerationControl`.
    var savedLinearScaling: Bool?

    /// NSEvent local-monitor token for gesture suppression. While the stream
    /// window is key, we swallow gesture-family events so macOS's pinch-to-
    /// zoom, smart-zoom, swipe-to-Mission-Control, and rotate don't reach
    /// default handlers under the stream layer. We do NOT swallow
    /// `.scrollWheel` here - scrolls need to reach our StreamInputView so we
    /// can forward them as host scroll events. This monitor alone is
    /// sufficient for the trackpad gesture family now that the freeze is gone;
    /// the one trigger it can't reach is Ctrl+scroll Accessibility Zoom (a
    /// WindowServer-level interlock), whose non-freezing replacement is the
    /// kCGAnnotatedSessionEventTap escalation described in
    /// InputForwarder+Capture.swift - not the old associate-false freeze.
    var gestureSuppressionMonitor: Any?

    /// NSEvent local-monitor token for ⌘-held key-ups, which AppKit otherwise
    /// never delivers to the first responder. See InputForwarder+CommandKeyUp.
    var commandKeyUpMonitor: Any?

    /// Last key-up seen, so a key-up delivered by both the responder chain and
    /// the ⌘ monitor is forwarded once.
    var lastKeyUpStamp: KeyUpStamp?

    /// NSEvent local-monitor token for the diagnostic event tap. While
    /// streaming (i.e. `isReady == true`) and the stream window is key, this
    /// monitor logs every event AppKit delivers to our process so we can
    /// identify exactly which event type triggers macOS Accessibility Zoom
    /// during gameplay. Pass-through (returns `event` unchanged) - this is
    /// observation only, suppression is the other monitor's job. Rate-limited
    /// to 100 events/sec to keep the log manageable.
    var diagnosticLocalMonitor: Any?

    /// NSEvent global-monitor token. Sees events delivered to OTHER apps and
    /// system-level chords WindowServer intercepts before they reach us
    /// (e.g. ⌥⌘8 toggling Accessibility Zoom). Global monitors are
    /// observation-only by API contract - they can't consume - which is
    /// exactly what we want for diagnostics. Same rate-limit as the local
    /// monitor.
    var diagnosticGlobalMonitor: Any?

    /// Rolling 1-second window of event counts for the diagnostic sampler.
    /// When the rate crosses 100/sec we sample down to one in N to bound
    /// the log volume during gestural floods (e.g. a long .scrollWheel
    /// burst with phase data on every frame).
    var diagSampleWindowStart: TimeInterval = 0
    var diagSampleCount: Int = 0
    var diagSampleDivisor: Int = 1

    /// becomeKey/resignKey observers, kept so we can flip captured mode on
    /// focus transitions and tear down cleanly in `detach()`.
    var didBecomeKeyObserver: NSObjectProtocol?
    var didResignKeyObserver: NSObjectProtocol?

    public convenience init() {
        self.init(cruiseTuning: CruiseTraversal.Tuning.current())
    }

    init(cruiseTuning: CruiseTraversal.Tuning) {
        self.cruiseTuning = cruiseTuning
        connectInputCore()
        setupGamepadObservers()
    }

    isolated deinit {
        // `isolated` so the MainActor observer tokens are readable here: the backstop for a
        // forwarder freed without detach().
        removeGamepadObservers()
        removeInputRecoveryObservers()
        reconciliationTimer?.invalidate()
    }

    // MARK: - LiSend wrappers with diagnostic logging

    // Native sends return 0, -2 before the input stream starts, or
    // LI_ERR_UNSUPPORTED when the host lacks the entry point.
    // Log the first non-zero return per code so transient failures stay quiet.

    func record(_ name: StaticString, _ rc: Int32) {
        guard rc != 0 else { return }
        inputCore.withLock { inputCore.record(name, rc) }
    }

    // MARK: - Modifier mapping

    /// Physical modifier sides owned by this view; failed ups live in the release ledger.
    var heldModifierVKs: Set<Int16> = []
    /// Set when the PC may not match `heldModifierVKs` (attach, raise-all). Only
    /// then does a key-down resync: a tool-posted ⌃C carries ⌃ with no
    /// flagsChanged, and syncing it would leave Ctrl held on the PC.
    var modifiersNeedResync = true
    /// The Mac's Caps Lock state last seen, so a toggle is sent exactly once.
    var lastCapsLock = false

    /// Physical ownership ends on an up or focus loss. The separate release ledger
    /// remembers what the PC may still hold until the reliable channel accepts the up.
    var heldKeys: Set<VKScanCode> = []
    var keyMapping: (Int) -> VKScanCode? = { vkScanCode(forCarbonKeyCode: $0) }
    var physicalKeys: [UInt16: VKScanCode] = [:]
    var missingPhysicalKeys: Set<UInt16> = []
    var missingModifierVKs: Set<Int16> = []
    var physicalMouseButtons: [Int: Int32] = [:]
    nonisolated let inputCore = InputCore()
    nonisolated let controllerCaptureQueue = DispatchQueue(
        label: "io.ugfugl.Glimmer.controllerCapture", qos: .userInteractive)
    var controllersNeedAnnouncement = false { didSet { publishInputSnapshot() } }
    var reconciliationTimer: Timer?
    var lastInputEventTime: TimeInterval?
    var keyboardMonitoringGranted: () -> Bool = { HIDGamepadManager.accessGranted }
    var physicalKeyState: (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }
    var currentModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var currentMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var inputRecoveryObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// True from attach until the first connection goes live: Esc cancels the
    /// connect then, and is game input from then on (reconnects included).
    var initialConnectPending = false

    /// Mac keyCodes with no PC mapping already logged this session.
    var loggedUnmappedKeyCodes: Set<UInt16> = []

    func modifierByte(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var b: Int32 = 0
        if flags.contains(.control) { b |= StreamProtocol.MODIFIER_CTRL }
        if flags.contains(.shift) { b |= StreamProtocol.MODIFIER_SHIFT }
        if flags.contains(.option) { b |= StreamProtocol.MODIFIER_ALT }
        // Only fold Cmd into MODIFIER_META while ⌘ is forwarded. Otherwise
        // the user expects Cmd to be a macOS-only key - sending
        // MODIFIER_META alongside an unrelated keypress would make the host
        // see e.g. "Win+T" for a stray ⌘-T the user pressed to open a tab in
        // a backgrounded mac app.
        if flags.contains(.command), forwardsCommand { b |= StreamProtocol.MODIFIER_META }
        return UInt8(truncatingIfNeeded: b)
    }

    // Gamepad path (GameController framework integration, slot allocation,
    // arrival announcements, per-frame value-changed handlers) lives in
    // ControllerForwarder.swift; the attach/detach/ready-gate lifecycle lives in
    // InputForwarder+Lifecycle.swift.
}
