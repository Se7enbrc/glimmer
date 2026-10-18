// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Shared feedback policy with prepared native actuators. Registration revokes stale work synchronously;
/// the serial queue owns channels and pending actuation.
package final class ControllerHaptics: @unchecked Sendable {
    package typealias Rumble = (low: UInt16, high: UInt16)
    package typealias TriggerRumble = (left: UInt16, right: UInt16)
    package typealias LightColor = (red: UInt8, green: UInt8, blue: UInt8)

    package struct PendingDrain {
        var rumble: [UInt8: Rumble]
        var submittedAt: [UInt8: UInt64]
        var triggers: [UInt8: TriggerRumble]
        var lights: [UInt8: LightColor]
        var playerLEDs: [UInt8: UInt8]
        var gameControllerSlots: Set<UInt8>
        var suspended: Bool
        var quiesced: Bool
    }

    package struct DrainActions {
        var light: (UInt8, LightColor) -> Void
        var playerLEDs: (UInt8, UInt8) -> Void
        var hidRumble: ([UInt8: Rumble], [UInt8: UInt64]) -> Void
        var rumble: (UInt8, Rumble) -> Void
        var triggers: (UInt8, TriggerRumble) -> Void
    }

    package struct ActivationGate {
        var appActive = true
        var backgroundPlayers: Set<UUID> = []
        var shouldSuspend: Bool { !appActive && backgroundPlayers.isEmpty }
    }

    package static let logCategory = "Controller"

    /// Failed native creation backs off for one second per pad; later nonzero feedback retries instead
    /// of disabling rumble permanently.
    package static let engineRetryNanos: UInt64 = 1_000_000_000

    /// The trigger-motor locality keys: body and trigger rumble share
    /// pad.engines, so each side's zero/idle path must only touch its own.
    /// (Internal for the +Actuation split.)
    package static let triggerLocalityKeys: Set<String> =
        [ControllerFeedbackOutput.Locality.leftTrigger.rawValue, ControllerFeedbackOutput.Locality.rightTrigger.rawValue]

    /// Feedback uses a user-initiated serial queue; it does not compete with the user-interactive
    /// video/receive path.
    package let queue = DispatchQueue(label: "io.ugfugl.Glimmer.haptics", qos: .userInitiated)

    /// Latest-wins inbox. Lock-guarded (NOT queue-confined) because the writer
    /// is the enet receive thread, which deposits and leaves - one dictionary
    /// write + one flag read under a lock is the entire cost it ever pays.
    let lock = NSLock()
    private var pendingBySlot: [UInt8: (low: UInt16, high: UInt16)] = [:]
    private var pendingHIDRumbleTimes: [UInt8: UInt64] = [:]
    /// Latest-wins trigger-motor inbox (SS_RUMBLE_TRIGGERS) - the
    /// pendingBySlot contract, for the independent trigger wire channel.
    private var pendingTriggersBySlot: [UInt8: (left: UInt16, right: UInt16)] = [:]
    /// Latest-wins light-bar inbox (SET_RGB_LED), coalesced because games can
    /// re-color the bar at frame rate and only the newest color matters.
    private var pendingLightBySlot: [UInt8: (red: UInt8, green: UInt8, blue: UInt8)] = [:]
    private var pendingPlayerLedsBySlot: [UInt8: UInt8] = [:]
    /// True while a drain is queued; coalesces bursts so the queue holds at
    /// most ONE drain at a time (the drain takes all three inboxes).
    private var drainScheduled = false

    // Queue-confined state from here down.

    /// slot (the forwarder's 0..15 controllerNumber) → actuation state.
    /// (Internal for the +Actuation split, which owns all mutation of the
    /// PadHaptics boxes; this file only inserts/removes mappings.)
    package var pads: [UInt8: PadHaptics] = [:]
    /// Ordinary background playback parks motors; Mini Player retains feedback while another app is active.
    private var suspended = false
    private var activationGate = ActivationGate()
    /// Preserve the existing four-second resign-active grace for transient Mac focus changes. Explicit
    /// input ownership loss revokes motor adoption immediately.
    package static let suspendGraceSeconds: TimeInterval = 4.0
    /// The pending debounced-suspend work item (queue-confined). Non-nil ==
    /// a resign is waiting out its grace; a fresh edge (resume OR another resign)
    /// cancels and supersedes it.
    private var pendingSuspend: DispatchWorkItem?
    /// The lifecycle gate starts closed and closes synchronously on stop, rejecting feedback from old
    /// control callbacks.
    package var quiesced = true
    /// Seams for tests: nil runs the real CoreHaptics motor / GCDeviceLight path.
    package var motorSink: ((UInt8, ControllerFeedbackOutput.Locality, Float) -> Void)?
    package var lightSink: ((UInt8, LightColor) -> Void)?

    package struct Platform: Sendable {
        package var appActive: @MainActor @Sendable () -> Bool = { true }
        package var stopHID: @Sendable () -> Void = {}
        package var rumbleHID: @Sendable ([UInt8: Rumble], [UInt8: UInt64]) -> Void = { _, _ in }
        package init() {}
    }
    private let platform: Platform
    var generation: UInt64 = 0
    var feedbackEnabled = false
    var ownershipGeneration: UInt64 = 0
    var ownsInput = true
    var registrationTokens: [UInt8: UUID] = [:]
    struct ActuationEpoch {
        let stream: UInt64
        let ownership: UInt64
    }
    // Queue-confined: every native step in one drain must still belong to its original ownership interval.
    var drainEpoch: ActuationEpoch?

    package init(platform: Platform = Platform()) { self.platform = platform }

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Map a forwarder slot to its pad. Registration alone never spins a
    /// motor - engines are created lazily on the first nonzero rumble - so
    /// it is safe to register pads that turn out to have no haptics at all.
    package func register(slot: UInt8, output: ControllerFeedbackOutput) {
        // The queue owns this prepared output box after registration.
        let pad = PadHaptics(output: output)
        lock.withLock { clearPending(slot: slot); registrationTokens[slot] = pad.token }
        queue.async { [weak self] in
            guard let self else { return }
            // A re-attach can reuse a slot before the old unregister hop
            // lands; park the stale pad's motors so the swap can't strand
            // them running.
            if let stale = self.pads[slot] {
                self.teardown(pad: stale, slot: slot, why: "slot reassigned")
            }
            self.pads[slot] = pad
        }
    }

    /// Drop a slot's mapping and stop its motors (controller detach).
    package func unregister(slot: UInt8) {
        lock.withLock { clearPending(slot: slot); registrationTokens[slot] = nil }
        queue.async { [weak self] in
            guard let self, let pad = self.pads.removeValue(forKey: slot) else { return }
            self.teardown(pad: pad, slot: slot, why: "controller detached")
        }
    }

    // MARK: - Stream lifecycle (NativeBackend+Pipeline)

    /// Activate a new stream generation. The Mac adapter supplies current app activity; public input
    /// supplies its known foreground ownership without a main-actor lookup.
    package func streamActivated(appActive: Bool? = nil) {
        let generation = lock.withLock { self.generation }
        if let appActive {
            activate(appActive: appActive, generation: generation)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let active = MainActor.assumeIsolated { self.platform.appActive() }
                self.activate(appActive: active, generation: generation)
            }
        }
    }

    private func activate(appActive: Bool, generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({
                guard self.generation == generation else { return false }
                self.feedbackEnabled = true
                return true
            }) else { return }
            self.pendingSuspend?.cancel()
            self.pendingSuspend = nil
            self.quiesced = false
            self.activationGate.appActive = appActive
            self.applySuspended(self.activationGate.shouldSuspend, why: "stream start")
        }
    }

    /// Stream over: park every pad at (0,0), tear the engines down, and
    /// re-arm the quiesce gate. Fired by EnetControlChannel.onTeardown on
    /// EVERY stream-end path (user stop, watchdog, host TERMINATION).
    package func stopAll(reason: String) {
        lock.withLock { generation &+= 1; feedbackEnabled = false; clearPending() }
        queue.async { [weak self] in
            guard let self else { return }
            // Drop any debounced suspend in flight - the session is ending, so its
            // teardown is moot and must not fire into the next session.
            self.pendingSuspend?.cancel()
            self.pendingSuspend = nil
            self.quiesced = true
            self.platform.stopHID()
            for (slot, pad) in self.pads {
                self.teardown(pad: pad, slot: slot, why: reason)
            }
        }
    }

    package func setOwnership(_ owned: Bool) {
        lock.withLock {
            ownsInput = owned
            if !owned { ownershipGeneration &+= 1; clearPending() }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSuspend?.cancel()
            self.pendingSuspend = nil
            self.activationGate.appActive = owned
            self.applySuspended(!owned, why: "input ownership")
        }
    }

    // MARK: - Event intake (enet receive thread)

    /// Coalesce the newest motor pair per slot under the existing lock, then drain on the serial
    /// feedback queue.
    package func setRumble(controllerNumber: UInt16, lowFreq: UInt16, highFreq: UInt16) {
        // Controller numbers are assigned by the client; reject unsupported values before indexing the
        // sixteen-slot state.
        guard controllerNumber < UInt16(Enet.maxGamepads) else {
            TelemetryCounters.shared.rumbleDroppedInvalidTotal.increment()
            return
        }
        let slot = UInt8(controllerNumber)
        lock.lock()
        guard feedbackEnabled else { lock.unlock(); return }
        pendingBySlot[slot] = (low: lowFreq, high: highFreq)
        pendingHIDRumbleTimes[slot] = DispatchTime.now().uptimeNanoseconds
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule {
            queue.async { [weak self] in self?.drainPending() }
        }
    }

    /// Deposit the newest trigger-motor pair for a pad (SS_RUMBLE_TRIGGERS) -
    /// the setRumble contract, for the trigger localities. (0,0) is a real
    /// event (triggers off) and flows like any other value.
    package func setTriggerRumble(controllerNumber: UInt16, left: UInt16, right: UInt16) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
        guard feedbackEnabled else { lock.unlock(); return }
        pendingTriggersBySlot[slot] = (left: left, right: right)
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule {
            queue.async { [weak self] in self?.drainPending() }
        }
    }

    /// Deposit the newest light-bar color for a pad (SET_RGB_LED). Latest
    /// wins, like rumble - a stale color is strictly worse than the newest.
    package func setLight(controllerNumber: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
        guard feedbackEnabled else { lock.unlock(); return }
        pendingLightBySlot[slot] = (red: red, green: green, blue: blue)
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule {
            queue.async { [weak self] in self?.drainPending() }
        }
    }

    /// Host player indicator LEDs (SET_PLAYER_LEDS). Latest-wins per slot, like
    /// the light bar; only the solid mask maps onto GameController's player index.
    package func setPlayerLEDs(controllerNumber: UInt16, solid: UInt8, flashing: UInt8) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
        guard feedbackEnabled else { lock.unlock(); return }
        pendingPlayerLedsBySlot[slot] = solid
        let schedule = !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule {
            queue.async { [weak self] in self?.drainPending() }
        }
    }

    // MARK: - Actuation (haptics queue)

    private func drainPending() {
        // Empty every inbox before either gate so stale updates cannot replay
        // after resume or teardown.
        lock.lock()
        let epoch = ActuationEpoch(stream: generation, ownership: ownershipGeneration)
        let pending = pendingBySlot
        let submittedAt = pendingHIDRumbleTimes
        pendingHIDRumbleTimes.removeAll(keepingCapacity: true)
        pendingBySlot.removeAll(keepingCapacity: true)
        let pendingTriggers = pendingTriggersBySlot
        pendingTriggersBySlot.removeAll(keepingCapacity: true)
        let pendingLight = pendingLightBySlot
        pendingLightBySlot.removeAll(keepingCapacity: true)
        let pendingPlayerLeds = pendingPlayerLedsBySlot
        pendingPlayerLedsBySlot.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
        drainEpoch = epoch
        defer { drainEpoch = nil }
        let drain = PendingDrain(rumble: pending, submittedAt: submittedAt, triggers: pendingTriggers,
                                 lights: pendingLight, playerLEDs: pendingPlayerLeds,
                                 gameControllerSlots: Set(pads.keys), suspended: suspended || lock.withLock { !ownsInput },
                                 quiesced: quiesced || lock.withLock { !feedbackEnabled })
        let actions = DrainActions(
            light: { self.applyLight(slot: $0, red: $1.red, green: $1.green, blue: $1.blue) },
            playerLEDs: { self.applyPlayerLEDs(slot: $0, solidMask: $1) },
            hidRumble: { rumble, times in
                guard self.acceptsActuation(requiresOwnership: true) else { return }
                self.platform.rumbleHID(rumble, times)
            },
            rumble: { self.apply(slot: $0, lowFreq: $1.low, highFreq: $1.high) },
            triggers: { self.applyTriggers(slot: $0, left: $1.left, right: $1.right) })
        Self.processDrain(drain, actions: actions)
    }

    // Caller holds the inbox lock; keep its scheduled drain so fresh feedback still coalesces normally.
    private func clearPending(slot: UInt8? = nil) {
        if let slot {
            pendingBySlot[slot] = nil
            pendingHIDRumbleTimes[slot] = nil
            pendingTriggersBySlot[slot] = nil
            pendingLightBySlot[slot] = nil
            pendingPlayerLedsBySlot[slot] = nil
        } else {
            pendingBySlot.removeAll(keepingCapacity: true)
            pendingHIDRumbleTimes.removeAll(keepingCapacity: true)
            pendingTriggersBySlot.removeAll(keepingCapacity: true)
            pendingLightBySlot.removeAll(keepingCapacity: true)
            pendingPlayerLedsBySlot.removeAll(keepingCapacity: true)
        }
    }

    func acceptsActuation(pad: PadHaptics? = nil, slot: UInt8? = nil, requiresOwnership: Bool = false) -> Bool {
        lock.withLock {
            guard feedbackEnabled, !requiresOwnership || ownsInput else { return false }
            if let epoch = drainEpoch,
               epoch.stream != generation || epoch.ownership != ownershipGeneration { return false }
            if let pad, let slot, registrationTokens[slot] != pad.token { return false }
            return true
        }
    }

    package static func processDrain(_ drain: PendingDrain, actions: DrainActions) {
        guard !drain.quiesced else { return }
        for (slot, color) in drain.lights { actions.light(slot, color) }
        for (slot, mask) in drain.playerLEDs { actions.playerLEDs(slot, mask) }
        guard !drain.suspended else { return }
        let hidRumble = drain.rumble.filter { !drain.gameControllerSlots.contains($0.key) }
        if !hidRumble.isEmpty {
            let hidTimes = drain.submittedAt.filter { hidRumble[$0.key] != nil }
            actions.hidRumble(hidRumble, hidTimes)
        }
        for (slot, motors) in drain.rumble { actions.rumble(slot, motors) }
        for (slot, motors) in drain.triggers { actions.triggers(slot, motors) }
    }

    // (apply / applyTriggers / applyLight, the locality plans, the engine
    // channel machinery, and the per-pad state types live in
    // ControllerHaptics+Actuation.swift - the topic split.)

    @MainActor
    package func setBackgroundPlayEnabled(_ enabled: Bool, for owner: UUID) {
        let active = platform.appActive()
        queue.async { [weak self] in
            guard let self else { return }
            let changed = enabled ? self.activationGate.backgroundPlayers.insert(owner).inserted
                : self.activationGate.backgroundPlayers.remove(owner) != nil
            guard changed else { return }
            self.activationGate.appActive = active
            self.reconcileSuspension()
        }
    }

    package func setSuspended(_ suspended: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activationGate.appActive = !suspended
            self.reconcileSuspension()
        }
    }

    private func reconcileSuspension() {
        pendingSuspend?.cancel()
        pendingSuspend = nil
        guard activationGate.shouldSuspend else {
            applySuspended(false, why: "controller playback active")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activationGate.shouldSuspend, !self.quiesced else { return }
            self.pendingSuspend = nil
            self.applySuspended(true, why: "app inactive \(Int(Self.suspendGraceSeconds))s")
        }
        pendingSuspend = work
        queue.asyncAfter(deadline: .now() + Self.suspendGraceSeconds, execute: work)
    }

    /// Apply the queue-owned suspension state after its native or explicit ownership transition.
    private func applySuspended(_ suspended: Bool, why: String) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended {
            self.platform.stopHID()
        }
        Diag.info("rumble gate \(suspended ? "ON" : "off") (\(why))", Self.logCategory)
        // The next host event re-actuates after resume; retain the existing debounce grace for transient
        // native focus changes.
        guard suspended else { return }
        for (slot, pad) in pads {
            teardown(pad: pad, slot: slot, why: "app inactive")
        }
    }
}

// (The NativeConnectionEvents feedback slots that route into this actuator
// live with the rest of the event wiring in NativeBackend+Pipeline.swift.)
