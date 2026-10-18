// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  InputBatcher.swift
//
//  Merges high-rate input between sends at least 1 ms apart and passes edge events through
//  in order, as moonlight-common-c's InputStream.c does: one send per event once overran
//  Sunshine's ENet peer. Ported from moonlight-common-c (GPLv3); see CREDITS.md.
//

import Foundation
import Synchronization

/// Return codes mirroring the NativeBackend.dispatchInput contract
/// (Li* convention): 0 = accepted (edges) or merged (motion), -1 = seal/send failed, -2 = input not ready.
enum InputBatcherResult {
    static let ok: Int32 = 0
    static let sendFailed: Int32 = -1
    static let notReady: Int32 = -2
}

/// `@unchecked Sendable`: merge state, the timer and `enet` are touched only on `queue`;
/// `stopped` is the one field producers read from other threads.
final class InputBatcher: @unchecked Sendable {
    private static let logCategory = "NativeConnection"

    /// MOUSE_BATCHING_INTERVAL_MS (InputStream.c:43): the minimum gap between merged sends.
    private static let batchInterval: DispatchTimeInterval = .milliseconds(1)

    private weak var enet: EnetControlChannel?
    private let stopped = Atomic<Bool>(false)

    // The owned sender requests a bounded realtime budget and falls back to userInteractive.
    private let queue: InputSendThread
    /// The one-shot flush is armed only while state is dirty, so an idle stream costs no
    /// wakeups; deadlines stay 1 ms apart, as the old repeating tick's did.
    private var flushArmed = false
    private var flushDeadline: DispatchTime
    private var backpressureSince: DispatchTime?

    // MARK: Merge state (only ever touched on `queue`)

    /// currentRelativeMouseState (InputStream.c:88). Accumulated deltas held as
    /// Int so repeated moves never overflow before the per-tick Int16 split.
    private var relMouseDX: Int = 0
    private var relMouseDY: Int = 0
    private var relMouseDirty = false
    private var relTimings: [InputEventTiming] = []
    /// Queue→wire latency stamp: the OLDEST unflushed entry per slot (set on the
    /// clean→dirty edge, kept across accumulation/supersession, reset at flush) so
    /// the flush observes the worst-case age, not the freshest survivor.
    private var relMouseStamp = DispatchTime.now()

    /// currentAbsoluteMouseState (InputStream.c:93) - latest-only.
    private var absMouseX: Int16 = 0
    private var absMouseY: Int16 = 0
    private var absMouseRefW: Int16 = 0
    private var absMouseRefH: Int16 = 0
    private var absMouseDirty = false
    private var absTimings: [InputEventTiming] = []
    private var absMouseStamp = DispatchTime.now()

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
        /// Oldest-unflushed stamp - set on the clean→dirty edge, kept on
        /// supersession, reset at flush. See relMouseStamp.
        var stamp = DispatchTime.now()
        /// Deliver→enqueue leg (ms) of that oldest state; 0 when not measured.
        var deliverMs = 0.0
        var timings: [InputEventTiming] = []
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
        /// Oldest-unflushed stamp (set on clean→dirty, reset at flush).
        var stamp = DispatchTime.now()
        /// Uptime of this sensor's last input_motion trace line (0 = never).
        var lastTraceNanos: UInt64 = 0
    }
    /// MAX_MOTION_EVENTS (InputStream.c) - accel + gyro.
    private static let motionTypeCount = 2
    /// input_motion trace lines per (slot, sensor) are capped at 20 Hz: at the
    /// host's sensor rate they filled a third of the frame trace.
    static let motionTraceIntervalNanos: UInt64 = 50_000_000
    private var motionStates = [MotionSlot](repeating: MotionSlot(),
                                            count: Enet.maxGamepads * motionTypeCount)
    /// Dirty-slot count, so the 1ms flush pays ONE integer compare - not a
    /// 32-slot scan - when the host never enabled motion (zero-overhead-off).
    private var motionDirtyCount = 0

    /// Queue-to-wire stamps and the latency tracker, injectable so tests can script both.
    private let now: @Sendable () -> DispatchTime
    private let tracker: @Sendable () -> FrameTimingTracker?
    private let backpressure: @Sendable (EnetControlChannel) -> Bool
    // The scheduler must deliver callbacks on the owned sender thread.
    private let scheduleFlush: @Sendable (InputSendThread, DispatchTime, @escaping @Sendable () -> Void) -> Void

    init(enet: EnetControlChannel, configureThread: @escaping @Sendable () -> Void = {},
         now: @escaping @Sendable () -> DispatchTime = { .now() },
         tracker: @escaping @Sendable () -> FrameTimingTracker? = { FrameTimingTracker.shared },
         backpressure: @escaping @Sendable (EnetControlChannel) -> Bool = { $0.inputBacklogged },
         scheduleFlush: @escaping @Sendable (InputSendThread, DispatchTime, @escaping @Sendable () -> Void) -> Void
            = { $0.schedule(deadline: $1, action: $2) }) {
        queue = InputSendThread(configureThread: configureThread)
        self.enet = enet
        self.now = now
        self.tracker = tracker
        self.backpressure = backpressure
        self.scheduleFlush = scheduleFlush
        self.flushDeadline = now()
        Diag.notice("input batcher started (1ms merge/flush)", Self.logCategory)
    }

    /// Stop the flush timer and release the channel reference. Idempotent.
    func stop() {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        queue.sync {
            queue.cancelTimer()
            for slot in controllers.indices where controllers[slot].dirty {
                _ = flushController(slot, tracker: tracker())
            }
            enet = nil
            return InputBatcherResult.ok
        }
        Diag.notice("input batcher stopped", Self.logCategory)
    }

    deinit { queue.stop() }

    private func appendTimings(_ capture: InputTimingContext.Capture?, to samples: inout [InputEventTiming]) {
        guard let capture else { return }
        for sample in capture.samples() {
            if samples.count < 4096 { samples.append(sample) } else { tracker()?.inputTimingDropped.increment() }
        }
    }

    // MARK: - High-rate merged producers

    /// LiSendMouseMoveEvent (InputStream.c:707-771): ADD into the running delta
    /// and mark dirty; a timer flush or ordering barrier sends the total.
    func accumulateMouseMove(dx: Int16, dy: Int16) -> Int32 {
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        let timing = InputTimingContext.take()
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            // Send the earlier absolute position before relative motion can move from it.
            if self.absMouseDirty { self.flushAbsoluteMouse(tracker: self.tracker()) }
            if !self.relMouseDirty { self.relMouseStamp = self.now() }
            self.appendTimings(timing, to: &self.relTimings)
            self.relMouseDX += Int(dx)
            self.relMouseDY += Int(dy)
            self.relMouseDirty = true
            self.armFlush()
            return InputBatcherResult.ok
        }
    }

    /// LiSendMousePositionEvent (InputStream.c:437-467) - latest-only.
    func setAbsMouse(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32 {
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        let timing = InputTimingContext.take()
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            // Send the earlier relative motion before an absolute grab overwrites it.
            if self.relMouseDirty { self.flushRelativeMouse(tracker: self.tracker()) }
            // Latest-only: keep the oldest stamp (set on the clean→dirty edge);
            // a superseding sample discards its own newer stamp.
            if !self.absMouseDirty { self.absMouseStamp = self.now() }
            self.appendTimings(timing, to: &self.absTimings)
            self.absMouseX = x
            self.absMouseY = y
            self.absMouseRefW = refW
            self.absMouseRefH = refH
            self.absMouseDirty = true
            self.armFlush()
            return InputBatcherResult.ok
        }
    }

    /// Only axes merge. Button and trigger edges return the reliable channel's acceptance,
    /// so a release cannot disappear behind a successful asynchronous enqueue.
    func updateController(num: Int16, mask: Int16, buttons: Int32,
                          analog: GamepadAnalog) -> Int32 {
        let timing = InputTimingContext.take()
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            let slot = Int(UInt16(bitPattern: num)) % Enet.maxGamepads
            let safeButtons = buttons < 0 ? (buttons & 0xFFFF) : buttons
            let previous = controllers[slot]
            let edge = previous.buttons != safeButtons || (previous.mask != mask && mask & (1 << slot) == 0)
                || (previous.analog.leftTrigger == 0) != (analog.leftTrigger == 0)
                || (previous.analog.rightTrigger == 0) != (analog.rightTrigger == 0)
                || (safeButtons == 0 && analog.leftTrigger == 0 && analog.rightTrigger == 0
                    && analog.leftStickX == 0 && analog.leftStickY == 0
                    && analog.rightStickX == 0 && analog.rightStickY == 0)
            if edge, previous.dirty {
                // Obsolete axes cannot prevent a button edge from reaching the reliable channel.
                _ = flushController(slot, tracker: tracker())
                controllers[slot].dirty = false
                controllers[slot].timings.removeAll(keepingCapacity: true)
            }
            let stampNow = now()
            let deliverMs = observeInputDeliverAge(slot: slot, enqueued: stampNow)
            if !controllers[slot].dirty {
                controllers[slot].stamp = stampNow
                controllers[slot].deliverMs = deliverMs
            }
            appendTimings(timing, to: &controllers[slot].timings)
            controllers[slot].num = num
            controllers[slot].mask = mask
            controllers[slot].buttons = safeButtons
            controllers[slot].analog = analog
            controllers[slot].dirty = true
            if edge {
                let sent = flushController(slot, tracker: tracker())
                // The caller retains failed edges. Never replay an obsolete down at stop.
                if !sent { controllers[slot] = previous; controllers[slot].dirty = false }
                return sent ? InputBatcherResult.ok : InputBatcherResult.sendFailed
            }
            armFlush()
            return InputBatcherResult.ok
        }
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
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        // LI_MOTION_TYPE_* is 1-based (ACCEL=1, GYRO=2); anything else has no
        // state slot (the LC_ASSERT in LiSendControllerMotionEvent, folded
        // into -1 - no caller distinguishes the C's -3 here).
        let typeIndex = Int(motionType) - 1
        guard typeIndex >= 0, typeIndex < Self.motionTypeCount else {
            return InputBatcherResult.sendFailed
        }
        TelemetryCounters.shared.inputMotionTotal.increment()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            let idx = (Int(num) % Enet.maxGamepads) * Self.motionTypeCount + typeIndex
            if !self.motionStates[idx].dirty {
                self.motionStates[idx].dirty = true
                self.motionDirtyCount += 1
                self.motionStates[idx].stamp = self.now()  // oldest-unflushed
            }
            self.motionStates[idx].x = x
            self.motionStates[idx].y = y
            self.motionStates[idx].z = z
            self.armFlush()
            return InputBatcherResult.ok
        }
    }

    // MARK: - Low-rate pass-through producers

    /// Drain earlier motion, then hand the edge to ENet before reporting success.
    /// This waits for local acceptance only, never for a network round trip or ACK.
    func passThrough(_ plaintext: @autoclosure () -> [UInt8], channel: UInt8) -> Int32 {
        let timing = InputTimingContext.take()
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            flushLocked()
            let batch = InputTimingBatch(timing?.samples() ?? [], tracker: tracker())
            return enet?.sendInputPacket(plaintext(), channel: channel, timing: batch) == true
                ? InputBatcherResult.ok : InputBatcherResult.sendFailed
        }
    }

    /// Pass-through for host-facing device REPORTS that are not user input
    /// (controller battery). Same ordering contract as passThrough - drain the
    /// pending merged state, then send - but deliberately does NOT bump
    /// inputEventsTotal/noteInputEvent: a battery report on its ~30s cadence
    /// would otherwise mark an idle-hands stream input-active and break the
    /// idle/active counters' honesty (the updateMotion rule).
    func passThroughReport(_ plaintext: [UInt8], channel: UInt8) -> Int32 {
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            self.flushLocked()
            _ = self.enet?.sendInputPacket(plaintext, channel: channel)
            return InputBatcherResult.ok
        }
    }

    /// Pass-through that sends TWO packets atomically in order (controller arrival
    /// + its mandatory fallback multiController, InputStream.c:1471). Both ride
    /// the same gamepad channel; ordering vs. pending merged state is preserved.
    func passThroughPair(_ first: [UInt8], _ second: [UInt8], channel: UInt8) -> Int32 {
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        TelemetryCounters.shared.inputEventsTotal.increment()
        TelemetryCounters.shared.noteInputEvent()
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            self.flushLocked()
            _ = self.enet?.sendInputPacket(first, channel: channel)
            _ = self.enet?.sendInputPacket(second, channel: channel)
            return InputBatcherResult.ok
        }
    }

    func passThroughText(_ text: String) -> Int32 {
        guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
        return queue.sync {
            guard !stopped.load(ordering: .relaxed) else { return InputBatcherResult.notReady }
            for packet in InputEncoder.utf8TextPackets(text) {
                _ = passThrough(packet, channel: Enet.ctrlChannelUtf8)
            }
            return InputBatcherResult.ok
        }
    }

    // MARK: - Flush (timer tick) - runs on `queue`

    private var hasPendingState: Bool {
        relMouseDirty || absMouseDirty || motionDirtyCount > 0 || controllers.contains { $0.dirty }
    }

    /// An owned-thread deadline keeps merged sends at least 1 ms apart without a GCD timer hop.
    private func armFlush() {
        guard !flushArmed else { return }
        flushArmed = true
        flushDeadline = max(flushDeadline + Self.batchInterval, now())
        scheduleFlush(queue, flushDeadline) { [weak self] in self?.flushTimerFired() }
    }

    /// Re-arms while state is still dirty, as when backpressure held it back.
    private func flushTimerFired() {
        flushArmed = false
        guard !stopped.load(ordering: .relaxed) else { return }
        flush()
        if hasPendingState { armFlush() }
    }

    /// Bound ACK-only waiting to ENet's 10 ms allowance; a full submission queue still waits for space.
    private func flush() {
        guard hasPendingState, let enet else { backpressureSince = nil; return }
        if backpressure(enet) {
            let time = now()
            let since = backpressureSince ?? time
            backpressureSince = since
            if enet.sendBacklogged || time < since + .milliseconds(10) {
                countBackpressureSkip(enet)
                return
            }
        }
        flushLocked()
    }

    /// Drain dirty merged state without a gate so an edge cannot overtake earlier state,
    /// even under backpressure. MUST run on `queue`.
    private func flushLocked() {
        backpressureSince = nil
        guard hasPendingState, let enet else { return }
        TelemetryCounters.shared.inputBatchFlushTotal.increment()

        // Client queue→wire age: observe the OLDEST unflushed entry per drained
        // slot. Tracker is nil when telemetry is off (gate), so it's one optional
        // load + (when on) two local DispatchTime reads + a subtract - no behavior
        // change. Both clocks local (host/present-clock independent).
        let latencyTracker = tracker()
        let drainNow = latencyTracker != nil ? now() : nil

        // (1)+(2) Mouse: relative and absolute are never dirty together, because a
        //     switch between them drains the other kind first.
        if relMouseDirty { flushRelativeMouse(tracker: latencyTracker) }
        if absMouseDirty { flushAbsoluteMouse(tracker: latencyTracker) }

        // (3) Controllers: latest state per dirty slot.
        for slot in controllers.indices where controllers[slot].dirty {
            flushController(slot, tracker: latencyTracker)
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
                    // Keep the final stop sample until accepted or superseded by newer motion.
                    guard enet.sendInputPacket(plaintext, channel: channel) else { continue }
                } else {
                    _ = enet.sendInputPacketUnreliable(plaintext, channel: channel)
                }
                traceMotion(idx, isGyroNull: isGyroNull, tracker: latencyTracker, now: drainNow)
                // Motion is not user input: its age feeds the histogram but never
                // stands in for the last input's legs (deliverMs nil).
                observeInputAge(from: motionStates[idx].stamp, to: drainNow, tracker: latencyTracker,
                                deliverMs: nil)
                motionStates[idx].dirty = false
                motionDirtyCount -= 1
            }
        }
    }

    /// Observe one merged slot's queue→wire age (no-op with telemetry off). With a
    /// `deliverMs`, deliver + queue also become the latest input's client legs for
    /// the input-to-photon estimate; motion passes nil.
    private func observeInputAge(from stamp: DispatchTime, to drainNow: DispatchTime?,
                                 tracker: FrameTimingTracker?, deliverMs: Double?) {
        guard let drainNow, let tracker, drainNow >= stamp else { return }
        let ageMs = Double(drainNow.uptimeNanoseconds &- stamp.uptimeNanoseconds) / 1_000_000.0
        tracker.inputLocalLatency.observe(ageMs)
        if let deliverMs { tracker.noteInputLegs(deliverMs + ageMs) }
    }

    /// Trace motion slot `idx` (slot * motionTypeCount + sensor) if it is due; no-op
    /// with telemetry off. MUST be called on `queue`.
    private func traceMotion(_ idx: Int, isGyroNull: Bool, tracker: FrameTimingTracker?, now: DispatchTime?) {
        guard let tracker, let now,
              Self.motionTraceDue(lastNanos: motionStates[idx].lastTraceNanos,
                                  nowNanos: now.uptimeNanoseconds, isGyroNull: isGyroNull) else { return }
        motionStates[idx].lastTraceNanos = now.uptimeNanoseconds
        let sample = motionStates[idx]
        trace(tracker, "\"event\":\"input_motion\",\"slot\":\(idx / Self.motionTypeCount),"
            + "\"type\":\(idx % Self.motionTypeCount + 1),\"x\":\(TelemetryRenderer.jsonNumber(Double(sample.x))),"
            + "\"y\":\(TelemetryRenderer.jsonNumber(Double(sample.y)))"
            + ",\"z\":\(TelemetryRenderer.jsonNumber(Double(sample.z)))")
    }

    /// Whether this sensor's sample gets an input_motion trace line: at most one
    /// per `motionTraceIntervalNanos`, but always the gyro null that stops sensors.
    static func motionTraceDue(lastNanos: UInt64, nowNanos: UInt64, isGyroNull: Bool) -> Bool {
        isGyroNull || nowNanos &- lastNanos >= motionTraceIntervalNanos
    }

    /// Count a backpressure flush-skip, split by which signal fired (both when
    /// both asserted). Counter-only telemetry; no behavior change.
    private func countBackpressureSkip(_ enet: EnetControlChannel) {
        if enet.sendBacklogged {
            TelemetryCounters.shared.inputFlushSendBackloggedSkipTotal.increment()
        }
        if enet.reliableBacklogged {
            TelemetryCounters.shared.inputFlushReliableBackloggedSkipTotal.increment()
        }
    }

    /// Observe one slot's deliver→enqueue age (controller handler entry → here) and
    /// return it, 0 when unmeasured. Always takes the handler stamp so it can't go
    /// stale with telemetry off; off the GameController path the take returns 0.
    private func observeInputDeliverAge(slot: Int, enqueued: DispatchTime) -> Double {
        let entry = InputDeliverStamp.shared.take(slot: slot)
        guard let tracker = self.tracker(),
              entry != 0, enqueued.uptimeNanoseconds >= entry else { return 0 }
        let deliverMs = Double(enqueued.uptimeNanoseconds &- entry) / 1_000_000.0
        tracker.inputDeliverLatency.observe(deliverMs)
        return deliverMs
    }

    /// One trace line per merged input the wire carried, on the per-frame trace's
    /// clock. `fields` is only built when telemetry is on (the tracker is nil off).
    private func trace(_ tracker: FrameTimingTracker?, _ fields: @autoclosure () -> String) {
        guard let tracker else { return }
        let nowMs = Double(now().uptimeNanoseconds) / 1_000_000.0
        tracker.traceWriter.append(
            "{\"session\":\"\(tracker.sessionId)\",\(fields()),\"t_ms\":\(TelemetryRenderer.jsonNumber(nowMs))}")
    }

    /// Send the accumulated delta in Int16 chunks (InputStream.c:379-422) and clear it.
    /// MUST run on `queue`: the timer drain and the mode-change drain both land here.
    private func flushRelativeMouse(tracker: FrameTimingTracker?) {
        guard let enet else { return }
        var timing = InputTimingBatch(relTimings, tracker: tracker)
        relTimings.removeAll(keepingCapacity: true)
        let dx = relMouseDX
        let dy = relMouseDY
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
                channel: Enet.ctrlChannelMouse, timing: timing)
            timing = nil
        }
        relMouseDirty = false
        observeInputAge(from: relMouseStamp, to: tracker != nil ? now() : nil,
                        tracker: tracker, deliverMs: 0)
        trace(tracker, "\"event\":\"input_mouse\",\"dx\":\(dx),\"dy\":\(dy)")
    }

    /// Send the latest absolute position and clear it. MUST run on `queue`: the
    /// timer drain and the mode-change drain both land here.
    private func flushAbsoluteMouse(tracker: FrameTimingTracker?) {
        guard let enet else { return }
        let timing = InputTimingBatch(absTimings, tracker: tracker)
        _ = enet.sendInputPacket(
            InputEncoder.mousePosition(x: absMouseX, y: absMouseY,
                                       refW: absMouseRefW, refH: absMouseRefH),
            channel: Enet.ctrlChannelMouse, timing: timing)
        absTimings.removeAll(keepingCapacity: true)
        absMouseDirty = false
        observeInputAge(from: absMouseStamp, to: tracker != nil ? now() : nil,
                        tracker: tracker, deliverMs: 0)
        trace(tracker, "\"event\":\"input_mouse_abs\",\"x\":\(absMouseX),\"y\":\(absMouseY)")
    }

    /// Send the latest pending multiController for `slot` and clear its dirty flag.
    /// MUST be called on `queue`: the drain point for both the timer flush and the
    /// button-change flush, so it resolves its own queue→wire age.
    @discardableResult
    private func flushController(_ slot: Int, tracker: FrameTimingTracker?) -> Bool {
        guard let enet else { return false }
        let pending = controllers[slot]
        let analog = pending.analog
        let timing = InputTimingBatch(pending.timings, tracker: tracker)
        guard enet.sendInputPacket(
            InputEncoder.multiController(num: pending.num, mask: pending.mask,
                                        buttons: pending.buttons, analog: pending.analog),
            channel: Enet.ctrlChannelGamepadBase &+ UInt8(slot),
            timing: timing) else { return false }
        observeInputAge(from: pending.stamp, to: tracker != nil ? now() : nil,
                        tracker: tracker, deliverMs: pending.deliverMs)
        trace(tracker, "\"event\":\"input_pad\",\"slot\":\(slot),\"buttons\":\(pending.buttons),"
            + "\"lx\":\(analog.leftStickX),\"ly\":\(analog.leftStickY),\"rx\":\(analog.rightStickX),"
            + "\"ry\":\(analog.rightStickY),\"lt\":\(analog.leftTrigger),\"rt\":\(analog.rightTrigger)")
        controllers[slot].dirty = false
        controllers[slot].timings.removeAll(keepingCapacity: true)
        return true
    }
}
