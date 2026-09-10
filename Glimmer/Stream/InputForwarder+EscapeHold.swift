//
//  InputForwarder+EscapeHold.swift
//
//  "Hold Esc to free the pointer" - the universal escape from window-mode
//  capture, and the one that needs no teaching because every browser's pointer
//  lock works this way.
//
//  The constraint that shapes it: Esc is a GAME input. A tap must open the
//  game's menu exactly as it does today, so the key is never consumed - it
//  forwards on the way past and a ~1s HOLD is what releases the pointer. The
//  decision of whether a given key event arms, cancels, or means nothing is a
//  pure table (`EscapeHold`) so it can be tested without a window, a stream,
//  or a clock; this file's InputForwarder extension is just the timer that
//  drives it.
//
//  Window mode only, and only while captured: in full screen there is no
//  released state to return to, so nothing here ever arms.
//

import AppKit
import Carbon.HIToolbox

/// Pure decision table for the hold-Esc gesture.
enum EscapeHold {
    /// How long Esc must stay down before the pointer comes back. Long enough
    /// that a menu tap (and even a deliberate double-tap) never trips it,
    /// short enough that a user who is trying to get out does not give up.
    static let holdSeconds: TimeInterval = 1.0

    /// Carbon's virtual key for Esc. Positional, so it is right on every
    /// keyboard layout - unlike `charactersIgnoringModifiers`.
    static let keyCode = UInt16(kVK_Escape)

    /// What a key event means for an in-flight hold.
    enum Action: Equatable {
        /// Nothing to do; the event is somebody else's business.
        case none
        /// Start the dwell. The key still forwards to the host.
        case arm
        /// Abandon the dwell - the key came up first, so this was a tap.
        case cancel
    }

    /// A key going down. Arms only for a first (non-repeat) Esc while a
    /// windowed session holds the pointer and nothing is already counting.
    /// macOS auto-repeat fires further key-downs while Esc is held; those say
    /// nothing the timer does not already know, so they are ignored rather
    /// than re-arming.
    static func onKeyDown(
        keyCode: UInt16, isRepeat: Bool, windowMode: Bool, captured: Bool, armed: Bool
    ) -> Action {
        guard keyCode == Self.keyCode, windowMode, captured, !isRepeat, !armed else { return .none }
        return .arm
    }

    /// A key coming up. Cancels only the key we are actually counting, and
    /// only while counting - deliberately NOT gated on window mode or capture,
    /// so an in-flight dwell is always cancellable even if the pointer was
    /// freed by some other path (the chord, a resign) mid-hold.
    static func onKeyUp(keyCode: UInt16, armed: Bool) -> Action {
        guard keyCode == Self.keyCode, armed else { return .none }
        return .cancel
    }
}

extension InputForwarder {

    /// Called on every key-down, BEFORE the key forwards. Never consumes:
    /// whatever this decides, the Esc still reaches the host on the same
    /// event, so a tap opens the game's menu with no added latency.
    func noteEscapeKeyDown(_ event: NSEvent) {
        let action = EscapeHold.onKeyDown(
            keyCode: event.keyCode, isRepeat: event.isARepeat,
            windowMode: isWindowMode, captured: isMouseCaptured,
            armed: escapeHoldTask != nil)
        if action == .arm { armEscapeHold() }
    }

    /// Called on every key-up, before any readiness gate: a tap must behave
    /// exactly as it did before this feature existed even when the stream is
    /// mid-handshake and forwarding nothing.
    func noteEscapeKeyUp(_ event: NSEvent) {
        if EscapeHold.onKeyUp(keyCode: event.keyCode, armed: escapeHoldTask != nil) == .cancel {
            cancelEscapeHold()
        }
    }

    /// Drop an in-flight dwell. Safe to call with none pending; called from
    /// every release path so a hold that is overtaken by the chord, a
    /// resign-key, or teardown cannot fire against a freed pointer.
    func cancelEscapeHold() {
        escapeHoldTask?.cancel()
        escapeHoldTask = nil
    }

    /// Start the dwell. The Task inherits MainActor isolation from this
    /// context, so touching the forwarder's stored state after the sleep is
    /// sound. State is re-read at expiry rather than trusted from the arming
    /// event: the pointer may have been freed some other way in the meantime,
    /// and a key-up that raced the wakeup is caught by `Task.isCancelled`.
    private func armEscapeHold() {
        escapeHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(EscapeHold.holdSeconds))
            guard !Task.isCancelled, let self else { return }
            // Clear the slot before any early return, or the arm guard above
            // stays wedged for the rest of the session.
            self.escapeHoldTask = nil
            guard self.isWindowMode, self.isMouseCaptured else { return }
            Diag.notice("input: Esc held - freeing the pointer (window mode)", "Stream")
            self.releasePointer(reason: "held Esc")
        }
    }
}
