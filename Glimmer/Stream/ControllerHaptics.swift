//
//  ControllerHaptics.swift
//
//  PC feedback through GameController only: rumble (0x010b), trigger rumble (0x5500) and the
//  DualSense light bar (0x5502), one lazy engine per motor, latest-wins, parked on every teardown.
//  THREADING: GameController haptics and light calls are thread-safe, so the work runs on `queue`.
//

import AppKit
import Foundation
import GameController

// (CoreHaptics is imported by ControllerHaptics+Actuation.swift, where the
// engine/player machinery lives.)

/// Singleton actuator: ControllerForwarder registers slot→pad mappings on
/// attach (main thread), EnetControlChannel→NativeConnectionEvents feeds it
/// rumble events (enet receive thread), and everything meets on the private
/// serial queue. `@unchecked Sendable`: the pending map is NSLock-guarded and
/// all other mutable state is confined to `queue`.
final class ControllerHaptics: @unchecked Sendable {
    typealias Rumble = (low: UInt16, high: UInt16)
    typealias TriggerRumble = (left: UInt16, right: UInt16)
    typealias LightColor = (red: UInt8, green: UInt8, blue: UInt8)

    struct PendingDrain {
        var rumble: [UInt8: Rumble]
        var submittedAt: [UInt8: UInt64]
        var triggers: [UInt8: TriggerRumble]
        var lights: [UInt8: LightColor]
        var playerLEDs: [UInt8: UInt8]
        var gameControllerSlots: Set<UInt8>
        var suspended: Bool
        var quiesced: Bool
    }

    struct DrainActions {
        var light: (UInt8, LightColor) -> Void
        var playerLEDs: (UInt8, UInt8) -> Void
        var hidRumble: ([UInt8: Rumble], [UInt8: UInt64]) -> Void
        var rumble: (UInt8, Rumble) -> Void
        var triggers: (UInt8, TriggerRumble) -> Void
    }

    static let shared = ControllerHaptics()
    static let logCategory = "Controller"

    /// One engine-creation attempt per second per pad while failing: at the
    /// wire's ~135 events/s an unguarded retry would hammer the haptics server
    /// every ~7ms (controller asleep, resource exhaustion) - but the retry
    /// never stops entirely, so a recovered pad resumes rumbling by itself.
    /// (Internal, not private: the +Actuation split reads it.)
    static let engineRetryNanos: UInt64 = 1_000_000_000

    /// The trigger-motor locality keys: body and trigger rumble share
    /// pad.engines, so each side's zero/idle path must only touch its own.
    /// (Internal for the +Actuation split.)
    static let triggerLocalityKeys: Set<String> =
        [GCHapticsLocality.leftTrigger.rawValue, GCHapticsLocality.rightTrigger.rawValue]

    /// The actuation queue. .userInitiated, not .userInteractive: rumble is
    /// feedback, not input - it must feel immediate but may never compete with
    /// the enet ACK path or the render loop for scheduling. (Internal for the
    /// +Actuation split's engine stop/reset handler hops.)
    let queue = DispatchQueue(label: "io.ugfugl.Glimmer.haptics", qos: .userInitiated)

    /// Latest-wins inbox. Lock-guarded (NOT queue-confined) because the writer
    /// is the enet receive thread, which deposits and leaves - one dictionary
    /// write + one flag read under a lock is the entire cost it ever pays.
    private let lock = NSLock()
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
    var pads: [UInt8: PadHaptics] = [:]
    /// App-background gate: motors must not buzz while the user is in another
    /// app. Engines are torn down on deactivation; events that arrive while
    /// suspended are dropped (the next post-resume host event re-establishes
    /// the true level within one game frame).
    private var suspended = false
    /// DEBOUNCE grace before a resign-active actually suspends. macOS resigns
    /// active for plenty of TRANSIENT reasons (a notification banner, Spotlight,
    /// an OS dialog, a fat-fingered Cmd-Tab) - and a controller player is still
    /// playing THROUGH all of those, since they drive the game with the pad, not
    /// the Mac. Tearing the engines down on a sub-second focus blip just killed
    /// rumble mid-combat. So we wait this long after a resign before suspending; a
    /// didBecomeActive within the window cancels it. A REAL walk-away (sustained
    /// background) still suspends and frees haptics resources - only the blips are
    /// spared. Resume is never debounced (restore rumble at once).
    static let suspendGraceSeconds: TimeInterval = 4.0
    /// The pending debounced-suspend work item (queue-confined). Non-nil ==
    /// a resign is waiting out its grace; a fresh edge (resume OR another resign)
    /// cancels and supersedes it.
    private var pendingSuspend: DispatchWorkItem?
    /// Stream-lifecycle gate, armed at init and on every stopAll(). A late
    /// event from a dying session must not re-spin motors AFTER the teardown
    /// (0,0) - once the channel is dead nobody can deliver the next "off".
    /// startVideoStage lifts it via streamActivated() when it wires onRumble.
    private var quiesced = true

    /// Block-based observer tokens, retained for the singleton's (infinite)
    /// lifetime so the registrations stay alive.
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?

    private init() {
        // App-deactivation safety net. The notifications post on the main
        // thread; the closures only hop to the haptics queue, so no main-time
        // is spent beyond the dispatch itself.
        let nc = NotificationCenter.default
        resignObserver = nc.addObserver(forName: NSApplication.willResignActiveNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            self?.setSuspended(true)
        }
        becomeObserver = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            self?.setSuspended(false)
        }
    }

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Map a forwarder slot to its pad. Registration alone never spins a
    /// motor - engines are created lazily on the first nonzero rumble - so
    /// it is safe to register pads that turn out to have no haptics at all.
    func register(slot: UInt8, controller: GCController) {
        // The box is built HERE, on the caller's thread, so the non-Sendable
        // GCController itself never crosses into the @Sendable closure - only
        // the @unchecked Sendable box does (see PadHaptics for why that's ok).
        let pad = PadHaptics(controller: controller)
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
    func unregister(slot: UInt8) {
        queue.async { [weak self] in
            guard let self, let pad = self.pads.removeValue(forKey: slot) else { return }
            self.teardown(pad: pad, slot: slot, why: "controller detached")
        }
    }

    // MARK: - Stream lifecycle (NativeBackend+Pipeline)

    /// Lift the quiesce gate for a new stream session. Wired in
    /// startVideoStage alongside enet.onRumble, so the gate opens exactly when
    /// rumble events become possible.
    ///
    /// The app-inactive gate is SEEDED here from the app's MEASURED activation
    /// state, not inherited: the suspend flag is otherwise edge-driven
    /// (resign/become notifications), so a stream started while the app was
    /// ALREADY inactive at singleton init would inherit a stale "active" and
    /// buzz a pad the user isn't holding - and the mirror-image stale would
    /// gate a stream started active. The next notification keeps it
    /// self-correcting either way (dynamic, recovering - never a latched
    /// give-up). The main hop is for NSApplication (MainActor); a rumble
    /// event landing during the hop drains against the still-armed quiesce
    /// gate and is superseded by the next host event within a game frame -
    /// the file's standing latest-wins discipline.
    func streamActivated() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = MainActor.assumeIsolated { NSApplication.shared.isActive }
            self.queue.async { [weak self] in
                guard let self else { return }
                // The measured-state seed is authoritative - drop any debounced
                // suspend still waiting out its grace so it can't fire a stale
                // teardown into this fresh session.
                self.pendingSuspend?.cancel()
                self.pendingSuspend = nil
                self.quiesced = false
                self.applySuspended(!active, why: active ? "app active at stream start"
                                                         : "app inactive at stream start")
            }
        }
    }

    /// Stream over: park every pad at (0,0), tear the engines down, and
    /// re-arm the quiesce gate. Fired by EnetControlChannel.onTeardown on
    /// EVERY stream-end path (user stop, watchdog, host TERMINATION).
    func stopAll(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // Drop any debounced suspend in flight - the session is ending, so its
            // teardown is moot and must not fire into the next session.
            self.pendingSuspend?.cancel()
            self.pendingSuspend = nil
            self.quiesced = true
            DispatchQueue.main.async {
                HIDGamepadManager.shared.stopRumble()
            }
            for (slot, pad) in self.pads {
                self.teardown(pad: pad, slot: slot, why: reason)
            }
        }
    }

    // MARK: - Event intake (enet receive thread)

    /// Deposit the newest motor pair for a pad and return immediately.
    /// (0,0) is a real event (motors off) and flows like any other value.
    /// (`rumble_events_total` is counted upstream at protocol dispatch -
    /// EnetControlChannel.handleRumbleData, BEFORE any validity guard - so a
    /// zero there proves the host sent nothing; it used to increment behind
    /// the slot guard below, which weakened that proof.)
    func setRumble(controllerNumber: UInt16, lowFreq: UInt16, highFreq: UInt16) {
        // The host echoes back the controllerNumber WE assigned (the
        // forwarder's 0..15 slot; Sunshine clamps to Enet.maxGamepads pads).
        // Anything outside that range cannot be ours - drop it rather than
        // truncate into some other pad's motors, and COUNT the drop so the
        // receipt arithmetic stays provable postmortem:
        // deposited = rumble_events_total − rumble_dropped_invalid_total.
        guard controllerNumber < UInt16(Enet.maxGamepads) else {
            TelemetryCounters.shared.rumbleDroppedInvalidTotal.increment()
            return
        }
        let slot = UInt8(controllerNumber)
        lock.lock()
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
    func setTriggerRumble(controllerNumber: UInt16, left: UInt16, right: UInt16) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
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
    func setLight(controllerNumber: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
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
    func setPlayerLEDs(controllerNumber: UInt16, solid: UInt8, flashing: UInt8) {
        guard controllerNumber < UInt16(Enet.maxGamepads) else { return }
        let slot = UInt8(controllerNumber)
        lock.lock()
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
        let drain = PendingDrain(rumble: pending, submittedAt: submittedAt, triggers: pendingTriggers,
                                 lights: pendingLight, playerLEDs: pendingPlayerLeds,
                                 gameControllerSlots: Set(pads.keys), suspended: suspended, quiesced: quiesced)
        let actions = DrainActions(
            light: { self.applyLight(slot: $0, red: $1.red, green: $1.green, blue: $1.blue) },
            playerLEDs: { self.applyPlayerLEDs(slot: $0, solidMask: $1) },
            hidRumble: { rumble, times in
                DispatchQueue.main.async {
                    HIDGamepadManager.shared.enqueueRumble(rumble, submittedAt: times)
                }
            },
            rumble: { self.apply(slot: $0, lowFreq: $1.low, highFreq: $1.high) },
            triggers: { self.applyTriggers(slot: $0, left: $1.left, right: $1.right) })
        Self.processDrain(drain, actions: actions)
    }

    static func processDrain(_ drain: PendingDrain, actions: DrainActions) {
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

    private func setSuspended(_ suspended: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            // Any fresh activation edge supersedes a still-pending debounced
            // suspend - cancel it first so a quick resign→become can't strand a
            // teardown that fires AFTER the user is already back.
            self.pendingSuspend?.cancel()
            self.pendingSuspend = nil
            guard suspended else {
                // Resume is immediate: becoming active restores rumble at once
                // (the next host event re-actuates and lazily rebuilds engines).
                self.applySuspended(false, why: "app became active")
                return
            }
            // DEBOUNCE the suspend - only tear down if the app stays inactive past
            // the grace window (a transient focus loss never reaches here).
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSuspend = nil
                self.applySuspended(true,
                                    why: "app inactive \(Int(Self.suspendGraceSeconds))s")
            }
            self.pendingSuspend = work
            self.queue.asyncAfter(deadline: .now() + Self.suspendGraceSeconds, execute: work)
        }
    }

    /// Queue-confined gate write, shared by the notification edges and the
    /// stream-start seed. Every TRANSITION leaves a Diag breadcrumb (bounded
    /// by app-switch frequency): the gate used to be invisible postmortem, so
    /// "rumble dead because the app was backgrounded" and "rumble dead because
    /// the host sent nothing" were indistinguishable in a session log.
    private func applySuspended(_ suspended: Bool, why: String) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended {
            DispatchQueue.main.async {
                HIDGamepadManager.shared.stopRumble()
            }
        }
        Diag.info("rumble gate \(suspended ? "ON" : "off") (\(why))", Self.logCategory)
        // Resuming needs no action: the next host event re-actuates (and
        // lazily rebuilds engines). Suspending tears engines down - not
        // just idles them - so a backgrounded stream holds no haptics
        // server resources and cannot buzz a pad the user set down.
        guard suspended else { return }
        for (slot, pad) in pads {
            teardown(pad: pad, slot: slot, why: "app inactive")
        }
    }
}

// (The NativeConnectionEvents feedback slots that route into this actuator
// live with the rest of the event wiring in NativeBackend+Pipeline.swift.)
