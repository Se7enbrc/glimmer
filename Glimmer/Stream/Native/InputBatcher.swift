//
//  InputBatcher.swift
//
//  Input queue + merge + bounded-flush for the native input uplink, ported from
//  moonlight-common-c's InputStream.c (inputSendThreadProc + the per-type merge
//  state). The native path previously sent ONE reliable ENet command per raw
//  input event (~150-250/s across the mouse + controller channels). That flood
//  saturated the single serial NWConnection send path and delayed our outbound
//  ACKs for the host's reliable rumble/LED/adaptive-trigger control messages past
//  Sunshine ENet's ~5-7s un-ACKed deadline, so the host silently reset our peer
//  (no DISCONNECT/TERMINATION) and the stream died at ~16-18s.
//
//  This batcher collapses high-rate input into ~1 packet per ~1ms tick, exactly
//  the way moonlight does:
//    - relative mouse: ACCUMULATE deltas, send the running total once per tick,
//      splitting only when the accumulated delta exceeds Int16 range
//      (InputStream.c:366-435).
//    - absolute mouse: latest-only per tick (InputStream.c:437-467).
//    - multiController: latest state per gamepad slot; a buttonFlags CHANGE ends
//      the batch (flush the slot first) so the host sees the exact axes present
//      at the press edge (InputStream.c:1048-1059).
//    - controller motion: latest sample per (slot, sensor) - moonlight's
//      currentGamepadSensorState. A superseded sample is replaced, never
//      queued; see updateMotion for the reliability deviation note.
//    - keyboard / mouse button / scroll / hscroll / controller arrival /
//      controller touch: low-rate edge events, passed straight through, but still
//      serialized on the batcher queue and flushed AFTER any pending merged state
//      so ordering vs. a queued mouse/controller packet is preserved (mirrors how
//      a buttonFlags change flushes the controller slot before the new state).
//    - controller battery: same pass-through ordering, but via the REPORT
//      variant that skips the input-activity stamp (a device report, not input).
//
//  Mouse / sticks / triggers / buttons / keyboard / scroll stay RELIABLE -
//  moonlight ships those reliable (the "TODO: send unreliable once we have
//  delayed retransmit" comments at InputStream.c:740-741, 805, 1075 confirm
//  reliable is the shipping behavior); the cure for their flood is the RATE,
//  not the reliability flag. Controller MOTION (gyro/accel), however, ships
//  UNRELIABLE to match current upstream (InputStream.c:525-534) - a superseded
//  sensor sample is worthless, so a lost one is harmless and must never
//  HOL-block the reliable stream - EXCEPT a gyro null (0,0,0), which stays
//  RELIABLE so the "sensors stopped" state survives loss. See updateMotion /
//  flushLocked for the gyro-null special case.
//
//  Threading: a single serial DispatchQueue owns ALL merge state and a single
//  1ms repeating DispatchSourceTimer drives flush(). Every public method hops
//  onto that queue, so no extra locking is needed. The EnetControlChannel is
//  held weakly - when the connection tears down (stop/interrupt) the batcher is
//  released and the timer cancelled.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

import Foundation

/// Return codes mirroring the NativeBackend.dispatchInput contract
/// (Li* convention): 0 = queued OK, -1 = seal/send failed, -2 = input not ready.
enum InputBatcherResult {
    static let ok: Int32 = 0
    static let sendFailed: Int32 = -1
    static let notReady: Int32 = -2
}

/// MOUSE_BATCHING_INTERVAL_MS (InputStream.c:43) - flush cadence.
final class InputBatcher: @unchecked Sendable {
    private static let logCategory = "NativeConnection"

    /// Flush cadence - MOUSE_BATCHING_INTERVAL_MS = 1ms (InputStream.c:43).
    private static let batchIntervalNs: UInt64 = 1_000_000

    private weak var enet: EnetControlChannel?

    // QoS .userInteractive so the merge/flush context isn't a default-QoS queue
    // starved behind high-QoS main-thread UI/input - it carries latency-sensitive
    // input toward the wire.
    private let queue = DispatchQueue(label: "io.ugfugl.Glimmer.inputBatcher", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // MARK: Merge state (only ever touched on `queue`)

    /// currentRelativeMouseState (InputStream.c:88). Accumulated deltas held as
    /// Int so repeated moves never overflow before the per-tick Int16 split.
    private var relMouseDX: Int = 0
    private var relMouseDY: Int = 0
    private var relMouseDirty = false

    /// currentAbsoluteMouseState (InputStream.c:93) - latest-only.
    private var absMouseX: Int16 = 0
    private var absMouseY: Int16 = 0
    private var absMouseRefW: Int16 = 0
    private var absMouseRefH: Int16 = 0
    private var absMouseDirty = false

    /// currentQueuedControllerPacket[MAX_GAMEPADS] (InputStream.c:80). Per-slot
    /// latest multiController fields + the buttonFlags that batch is built on.
    private struct ControllerSlot {
        var num: Int16 = 0
        var mask: Int16 = 0
        var buttons: Int32 = 0
        var analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                                   leftStickX: 0, leftStickY: 0,
                                   rightStickX: 0, rightStickY: 0)
        var dirty = false
    }
    private var controllers = [ControllerSlot](repeating: ControllerSlot(),
                                               count: Enet.maxGamepads)

    /// currentGamepadSensorState[MAX_GAMEPADS][MAX_MOTION_EVENTS]
    /// (InputStream.c) - latest motion sample per (slot, sensor), flattened to
    /// slot * motionTypeCount + (LI_MOTION_TYPE_* - 1).
    private struct MotionSlot {
        var x: Float = 0
        var y: Float = 0
        var z: Float = 0
        var dirty = false
    }
    /// MAX_MOTION_EVENTS (InputStream.c) - accel + gyro.
    private static let motionTypeCount = 2
    private var motionStates = [MotionSlot](repeating: MotionSlot(),
                                            count: Enet.maxGamepads * motionTypeCount)
    /// Dirty-slot count, so the 1ms flush pays ONE integer compare - not a
    /// 32-slot scan - when the host never enabled motion (zero-overhead-off).
    private var motionDirtyCount = 0

    init(enet: EnetControlChannel) {
        self.enet = enet
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Repeating 1ms tick; small leeway lets the OS coalesce timer fires.
        timer.schedule(deadline: .now() + .nanoseconds(Int(Self.batchIntervalNs)),
                       repeating: .nanoseconds(Int(Self.batchIntervalNs)),
                       leeway: .nanoseconds(Int(Self.batchIntervalNs)))
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
        Diag.notice("input batcher started (1ms merge/flush)", Self.logCategory)
    }

    /// Stop the flush timer and release the channel reference. Idempotent.
    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            enet = nil
        }
        Diag.notice("input batcher stopped", Self.logCategory)
    }

    // MARK: - High-rate merged producers

    /// LiSendMouseMoveEvent (InputStream.c:707-771): ADD into the running delta
    /// and mark dirty; do NOT send. The next flush() sends the accumulated total.
    func accumulateMouseMove(dx: Int16, dy: Int16) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        queue.async { [weak self] in
            guard let self else { return }
            self.relMouseDX += Int(dx)
            self.relMouseDY += Int(dy)
            self.relMouseDirty = true
        }
        return InputBatcherResult.ok
    }

    /// LiSendMousePositionEvent (InputStream.c:437-467) - latest-only.
    func setAbsMouse(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        queue.async { [weak self] in
            guard let self else { return }
            self.absMouseX = x
            self.absMouseY = y
            self.absMouseRefW = refW
            self.absMouseRefH = refH
            self.absMouseDirty = true
        }
        return InputBatcherResult.ok
    }

    /// sendControllerEventInternal (InputStream.c:998-1162): overwrite the slot's
    /// latest state in place. On a buttonFlags CHANGE while a batch is pending,
    /// flush that slot FIRST so the host receives the exact axis values present at
    /// the time of the button press (InputStream.c:1048-1059), then start a fresh
    /// batch with the new state.
    func updateController(num: Int16, mask: Int16, buttons: Int32,
                          analog: GamepadAnalog) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        queue.async { [weak self] in
            guard let self else { return }
            let slot = Int(num) % Enet.maxGamepads
            // Sign-extend guard mirrors InputStream.c:1017 (and InputEncoder's
            // own guard) so the buttonFlags comparison is on the canonical value.
            let safeButtons = buttons < 0 ? (buttons & 0xFFFF) : buttons
            if self.controllers[slot].dirty,
               self.controllers[slot].buttons != safeButtons {
                // Button-flag change ends the batch: emit the pending slot first.
                self.flushController(slot)
            }
            self.controllers[slot].num = num
            self.controllers[slot].mask = mask
            self.controllers[slot].buttons = safeButtons
            self.controllers[slot].analog = analog
            self.controllers[slot].dirty = true
        }
        return InputBatcherResult.ok
    }

    /// LiSendControllerMotionEvent (InputStream.c): overwrite the
    /// (slot, sensor) latest sample in place - moonlight's
    /// currentGamepadSensorState batching. The host-rate sampler
    /// (ControllerMotion) bounds the CALL rate; this merge plus the
    /// sendBacklogged skip bound the WIRE rate, so motion can never starve
    /// the receive/ACK chain (the 1ms-coalescing lesson).
    ///
    /// Deliberately does NOT bump the input-activity telemetry the other
    /// producers feed: motion is host-solicited sensor flow, not user input -
    /// counting it would make an idle-hands stream look input-active and
    /// break the idle/active counters' honesty.
    ///
    /// RELIABILITY (matches current upstream): motion ships UNRELIABLE
    /// (enetPacketFlags = 0, InputStream.c:525-534) - a superseded sensor
    /// sample is worthless, so dropping a lost one is correct and it must
    /// never HOL-block or back up the reliable stream. The one EXCEPTION is a
    /// GYRO null (0,0,0), which ships RELIABLE so the "sensors stopped" state
    /// can't be lost (moonlight's inputSendThreadProc special case). The
    /// reliable-vs-unreliable choice is made in flushLocked at drain time
    /// (where the sample's values are known); this merge just keeps the
    /// latest sample per (slot, sensor).
    func updateMotion(num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        // LI_MOTION_TYPE_* is 1-based (ACCEL=1, GYRO=2); anything else has no
        // state slot (the LC_ASSERT in LiSendControllerMotionEvent, folded
        // into -1 - no caller distinguishes the C's -3 here).
        let typeIndex = Int(motionType) - 1
        guard typeIndex >= 0, typeIndex < Self.motionTypeCount else {
            return InputBatcherResult.sendFailed
        }
        queue.async { [weak self] in
            guard let self else { return }
            let idx = (Int(num) % Enet.maxGamepads) * Self.motionTypeCount + typeIndex
            if !self.motionStates[idx].dirty {
                self.motionStates[idx].dirty = true
                self.motionDirtyCount += 1
            }
            self.motionStates[idx].x = x
            self.motionStates[idx].y = y
            self.motionStates[idx].z = z
        }
        return InputBatcherResult.ok
    }

    // MARK: - Low-rate pass-through producers

    /// Edge events that must NOT be merged (keyboard, mouse button, scroll,
    /// hscroll, controller arrival, controller touch). Sent straight through, but
    /// only AFTER flushing any pending merged mouse/controller state so the host
    /// sees them in the correct order relative to the merged stream (mirrors the
    /// buttonFlags-change flush + the C's flushInputOnControlStream before
    /// keyboard/UTF-8 events). Bytes are the InputEncoder plaintext; channel is
    /// the input class's ENet channel.
    func passThrough(_ plaintext: [UInt8], channel: UInt8) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        queue.async { [weak self] in
            guard let self else { return }
            // Preserve ordering: drain merged state before the edge event.
            self.flushLocked()
            _ = self.enet?.sendInputPacket(plaintext, channel: channel)
        }
        return InputBatcherResult.ok
    }

    /// Pass-through for host-facing device REPORTS that are not user input
    /// (controller battery). Same ordering contract as passThrough - drain the
    /// pending merged state, then send - but deliberately does NOT bump
    /// inputEventsTotal/noteInputEvent: a battery report on its ~30s cadence
    /// would otherwise mark an idle-hands stream input-active and break the
    /// idle/active counters' honesty (the updateMotion rule).
    func passThroughReport(_ plaintext: [UInt8], channel: UInt8) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        queue.async { [weak self] in
            guard let self else { return }
            self.flushLocked()
            _ = self.enet?.sendInputPacket(plaintext, channel: channel)
        }
        return InputBatcherResult.ok
    }

    /// Pass-through that sends TWO packets atomically in order (controller arrival
    /// + its mandatory fallback multiController, InputStream.c:1471). Both ride
    /// the same gamepad channel; ordering vs. pending merged state is preserved.
    func passThroughPair(_ first: [UInt8], _ second: [UInt8], channel: UInt8) -> Int32 {
        guard enet != nil else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        queue.async { [weak self] in
            guard let self else { return }
            self.flushLocked()
            _ = self.enet?.sendInputPacket(first, channel: channel)
            _ = self.enet?.sendInputPacket(second, channel: channel)
        }
        return InputBatcherResult.ok
    }

    // MARK: - Flush (timer tick) - runs on `queue`

    /// Timer entry point. Identical body to flushLocked(); kept separate so the
    /// pass-through path can flush inline without re-entering the timer handler.
    private func flush() {
        flushLocked()
    }

    /// Drain all dirty merged state to the wire, in a stable order. MUST be called
    /// on `queue`.
    ///
    /// BACKPRESSURE: skip the merged-state drains this tick and leave them dirty
    /// whenever EITHER backpressure signal is asserted:
    ///   - `sendBacklogged`: the LOCAL outbound send count is over the cap (the
    ///     radio is draining slowly) - keys on NWConnection send-completion.
    ///   - `reliableBacklogged`: the count of un-ACKed reliable commands is over
    ///     the cap, i.e. the HOST has stopped draining our reliable backlog. This
    ///     is the mouse-spin fix: `sendBacklogged` alone drains fast even under
    ///     loss (it's local send-completion, not host ACK), so it never reflects
    ///     the host falling behind. Without this gate, reliable mouse-move commands
    ///     pile into a HOL-blocked reliable stream that the host later burst-applies
    ///     - the "view spins until it recovers" failure. This mirrors moonlight's
    ///     10ms ack-wait (sendMessageEnet, ControlStream.c:787-789).
    /// The state is latest-only - the running mouse delta keeps accumulating and
    /// the controller/abs-mouse/motion slots keep their newest values - so the next
    /// tick sends the freshest merged state instead of backing up the wire ahead of
    /// inbound ACK processing. Edge pass-through events (keyboard/buttons/scroll/
    /// arrival/touch) are NOT gated by either signal - they are discrete, not
    /// latest-state, so they must not drop.
    private func flushLocked() {
        guard let enet else { return }
        if enet.sendBacklogged || enet.reliableBacklogged { return }

        // Telemetry: count a flush only when this tick actually drains dirty
        // merged state to the wire (not the no-op ticks that dominate an idle
        // stream). One cheap check off the per-packet path.
        let drainedSomething = relMouseDirty || absMouseDirty
            || motionDirtyCount > 0 || controllers.contains { $0.dirty }
        if drainedSomething {
            TelemetryCounters.shared.inputBatchFlushTotal.increment()
        }

        // (1) Relative mouse: send the accumulated delta, splitting into Int16
        //     chunks exactly like InputStream.c:379-422.
        if relMouseDirty {
            while relMouseDX != 0 || relMouseDY != 0 {
                let chunkX: Int16
                if relMouseDX < Int(Int16.min) {
                    chunkX = Int16.min; relMouseDX -= Int(Int16.min)
                } else if relMouseDX > Int(Int16.max) {
                    chunkX = Int16.max; relMouseDX -= Int(Int16.max)
                } else {
                    chunkX = Int16(relMouseDX); relMouseDX = 0
                }

                let chunkY: Int16
                if relMouseDY < Int(Int16.min) {
                    chunkY = Int16.min; relMouseDY -= Int(Int16.min)
                } else if relMouseDY > Int(Int16.max) {
                    chunkY = Int16.max; relMouseDY -= Int(Int16.max)
                } else {
                    chunkY = Int16(relMouseDY); relMouseDY = 0
                }

                _ = enet.sendInputPacket(
                    InputEncoder.mouseMove(dx: chunkX, dy: chunkY),
                    channel: Enet.ctrlChannelMouse)
            }
            relMouseDirty = false
        }

        // (2) Absolute mouse: latest-only.
        if absMouseDirty {
            _ = enet.sendInputPacket(
                InputEncoder.mousePosition(x: absMouseX, y: absMouseY,
                                           refW: absMouseRefW, refH: absMouseRefH),
                channel: Enet.ctrlChannelMouse)
            absMouseDirty = false
        }

        // (3) Controllers: latest state per dirty slot.
        for slot in controllers.indices where controllers[slot].dirty {
            flushController(slot)
        }

        // (4) Motion: latest sample per dirty (slot, sensor) - moonlight's
        //     currentGamepadSensorState drain. The integer guard keeps a
        //     motion-less session at zero cost here.
        //
        //     Sent UNRELIABLE (current upstream InputStream.c:525-534) - a
        //     superseded sensor sample is worthless, so losing one is harmless and
        //     must never HOL-block or back up the reliable stream. EXCEPTION: a
        //     GYRO null (0,0,0) ships RELIABLE so the "sensors stopped" state can't
        //     be lost (moonlight's special case).
        if motionDirtyCount > 0 {
            for idx in motionStates.indices where motionStates[idx].dirty {
                let slot = idx / Self.motionTypeCount
                let motionType = UInt8(idx % Self.motionTypeCount + 1)
                let s = motionStates[idx]
                let plaintext = InputEncoder.controllerMotion(
                    num: UInt8(slot), motionType: motionType,
                    x: s.x, y: s.y, z: s.z)
                let channel = Enet.ctrlChannelSensorBase &+ UInt8(slot)
                // GYRO null (0,0,0) → RELIABLE (state can't be lost); everything
                // else → UNRELIABLE.
                let isGyroNull = motionType == UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO)
                    && s.x == 0 && s.y == 0 && s.z == 0
                if isGyroNull {
                    _ = enet.sendInputPacket(plaintext, channel: channel)
                } else {
                    _ = enet.sendInputPacketUnreliable(plaintext, channel: channel)
                }
                motionStates[idx].dirty = false
            }
            motionDirtyCount = 0
        }
    }

    /// Send the latest pending multiController for `slot` and clear its dirty
    /// flag. MUST be called on `queue`.
    private func flushController(_ slot: Int) {
        guard let enet else { return }
        let pending = controllers[slot]
        _ = enet.sendInputPacket(
            InputEncoder.multiController(num: pending.num, mask: pending.mask,
                                        buttons: pending.buttons, analog: pending.analog),
            channel: Enet.ctrlChannelGamepadBase &+ UInt8(slot))
        controllers[slot].dirty = false
    }
}
