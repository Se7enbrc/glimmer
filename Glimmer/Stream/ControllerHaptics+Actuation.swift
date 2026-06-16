//
//  ControllerHaptics+Actuation.swift
//
//  The actuation layer of ControllerHaptics: wire motor values → haptic
//  localities → CHHapticEngine/player channels, plus the per-pad state types.
//  Topic split from ControllerHaptics.swift (file-length budget) — the core
//  file keeps the inboxes, gates, and registration; everything here runs on
//  the actuator's serial `queue` (see the core file's THREADING note).
//

import CoreHaptics
import Foundation
import GameController

extension ControllerHaptics {

    // MARK: - Actuation (haptics queue)

    func apply(slot: UInt8, lowFreq: UInt16, highFreq: UInt16) {
        guard let pad = pads[slot] else { return }
        // Keep DualSenseHID's merged OUTPUT state current so an adaptive-trigger
        // write re-emits the live rumble instead of zeroing it. Merge-only — the
        // motors themselves still ride GameController haptics below; this just
        // mirrors the latest value (16-bit wire → 8-bit report) for the merge.
        mirrorRumbleToHID(pad: pad, lowFreq: lowFreq, highFreq: highFreq)
        if lowFreq == 0 && highFreq == 0 {
            // (0,0) idles whatever BODY players exist — the trigger localities
            // are a separate wire channel, so zeroing them here would cut live
            // trigger rumble every time the body motors idle. It must never
            // CREATE an engine — priming hardware to play silence — so it
            // bypasses the plan entirely.
            for (key, channel) in pad.engines where !Self.triggerLocalityKeys.contains(key) {
                sendIntensity(0, to: channel, pad: pad, slot: slot, localityKey: key)
            }
            return
        }
        if pad.plan == nil { pad.plan = resolvePlan(for: pad, slot: slot) }
        guard let plan = pad.plan else { return }
        switch plan {
        case .splitHandles:
            announceIfFirst(pad, slot: slot)
            setMotor(pad: pad, slot: slot, locality: .leftHandle, intensity: Float(lowFreq) / 65535.0)
            setMotor(pad: pad, slot: slot, locality: .rightHandle, intensity: Float(highFreq) / 65535.0)
        case .single(let locality):
            announceIfFirst(pad, slot: slot)
            setMotor(pad: pad, slot: slot, locality: locality,
                     intensity: Float(max(lowFreq, highFreq)) / 65535.0)
        case .unavailable:
            break
        }
    }

    /// Decide once, on the first nonzero rumble, how this pad's motors map to
    /// haptic localities.
    private func resolvePlan(for pad: PadHaptics, slot: UInt8) -> ActuationPlan? {
        // nil controller = the pad is mid-detach (the weak ref cleared before
        // the unregister hop landed). Return nil WITHOUT caching so a racing
        // re-attach of the slot resolves fresh.
        guard let controller = pad.controller else { return nil }
        guard let haptics = controller.haptics else {
            // Permanent for THIS pad object — haptics support is a hardware
            // property, not a transient fault, so caching "unavailable" is
            // honest (a re-attach builds a new PadHaptics and re-probes).
            Diag.info("controller \(slot) exposes no haptics — host rumble ignored", Self.logCategory)
            return .unavailable
        }
        let localities = haptics.supportedLocalities
        if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
            // The wire's dual-motor model maps 1:1 onto per-handle engines:
            // low-frequency (heavy) motor → left handle, high-frequency motor
            // → right handle — the physical layout of Xbox/DualSense pads.
            return .splitHandles
        }
        // No per-handle engines: merge both motors onto the best whole-pad
        // locality. max() keeps the stronger motor's energy rather than
        // averaging it away.
        let merged: GCHapticsLocality = localities.contains(.handles) ? .handles : .all
        Diag.info("controller \(slot) haptics lack per-handle localities — merging motors onto "
            + "'\(merged.rawValue)'", Self.logCategory)
        return .single(merged)
    }

    /// Trigger rumble (SS_RUMBLE_TRIGGERS): each wire motor drives its own
    /// trigger locality through the same lazy engine/player machinery as the
    /// body motors — setMotor handles zero (idle existing, never create) and
    /// nonzero (lazy build) per locality.
    func applyTriggers(slot: UInt8, left: UInt16, right: UInt16) {
        guard let pad = pads[slot] else { return }
        if left == 0 && right == 0 {
            // Idle existing trigger players only — never probe hardware or
            // build an engine to play silence (the body-(0,0) discipline).
            for key in Self.triggerLocalityKeys {
                if let channel = pad.engines[key] {
                    sendIntensity(0, to: channel, pad: pad, slot: slot, localityKey: key)
                }
            }
            return
        }
        // Resolve trigger support once per pad on the first nonzero event (a
        // hardware property, the ActuationPlan discipline): we only ADVERTISE
        // LI_CCAP_TRIGGER_RUMBLE for pads whose haptics expose both trigger
        // localities, but a host could send anyway — degrade quietly instead
        // of hammering createEngine retries for a locality that cannot exist.
        if pad.triggersSupported == nil {
            // nil controller = mid-detach; bail WITHOUT caching (resolvePlan's
            // rule) so a racing re-attach of the slot resolves fresh.
            guard let controller = pad.controller else { return }
            let localities = controller.haptics?.supportedLocalities ?? []
            pad.triggersSupported = localities.contains(.leftTrigger)
                && localities.contains(.rightTrigger)
            if pad.triggersSupported == false {
                Diag.info("controller \(slot) haptics lack trigger localities — "
                    + "host trigger rumble ignored", Self.logCategory)
            }
        }
        guard pad.triggersSupported == true else { return }
        if !pad.announcedTriggersActive {
            pad.announcedTriggersActive = true
            // Once-per-pad-per-stream breadcrumb (the "rumble active"
            // pattern): proves host trigger rumble reached actuation.
            Diag.info("trigger rumble active: controller \(slot)", Self.logCategory)
        }
        setMotor(pad: pad, slot: slot, locality: .leftTrigger, intensity: Float(left) / 65535.0)
        setMotor(pad: pad, slot: slot, locality: .rightTrigger, intensity: Float(right) / 65535.0)
    }

    /// Light bar (SET_RGB_LED) → GCDeviceLight. GCDeviceLight, like
    /// GCDeviceHaptics, carries no documented main-thread requirement (only
    /// the GCController.controllers() registry does — the core file's
    /// threading note), so the write stays on the haptics queue: no main-time,
    /// and the non-Sendable GCColor never crosses a thread hop. Failable-quiet
    /// by construction — a pad without a light (the cap is only advertised
    /// when gamepad.light != nil) just drops the event.
    func applyLight(slot: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        guard let pad = pads[slot], let light = pad.controller?.light else { return }
        // Mirror to DualSenseHID's merge (see apply()): so an adaptive-trigger
        // OUTPUT report re-emits this color rather than blanking the light bar.
        mirrorLightToHID(pad: pad, red: red, green: green, blue: blue)
        light.color = GCColor(red: Float(red) / 255.0,
                              green: Float(green) / 255.0,
                              blue: Float(blue) / 255.0)
        if !pad.announcedLightActive {
            pad.announcedLightActive = true
            Diag.info("light bar set: controller \(slot) rgb(\(red),\(green),\(blue))",
                      Self.logCategory)
        }
    }

    private func announceIfFirst(_ pad: PadHaptics, slot: UInt8) {
        guard !pad.announcedActive else { return }
        pad.announcedActive = true
        // The one always-on HUMAN breadcrumb for this feature (the volume
        // signal rides `rumbleEventTotal`, counted at protocol dispatch):
        // proves host rumble reached actuation, once per pad per stream.
        Diag.info("rumble active: controller \(slot)", Self.logCategory)
    }

    private func setMotor(pad: PadHaptics, slot: UInt8, locality: GCHapticsLocality, intensity: Float) {
        let key = locality.rawValue
        if let channel = pad.engines[key] {
            sendIntensity(intensity, to: channel, pad: pad, slot: slot, localityKey: key)
            return
        }
        // No live channel: a zero needs no engine — never create hardware
        // state just to keep it idle. Nonzero → lazy build (first rumble, or
        // rebuild after a stop/reset/teardown), seeded with the target
        // intensity so there is no window at the wrong level.
        guard intensity > 0 else { return }
        if let channel = makeChannel(pad: pad, slot: slot, locality: locality,
                                     initialIntensity: intensity) {
            pad.engines[key] = channel
        }
    }

    private func sendIntensity(_ intensity: Float, to channel: HapticChannel, pad: PadHaptics,
                               slot: UInt8, localityKey: String) {
        do {
            try channel.player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                          value: intensity, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        } catch {
            // Recoverable hiccup, not a fault: drop the channel so the next
            // nonzero event lazily rebuilds it. INFO on purpose — haptics
            // self-heal and a warning would cry wolf in the diagnostics ring.
            Diag.info("controller \(slot) haptics update failed (\(error)) — rebuilding on next event",
                      Self.logCategory)
            pad.engines[localityKey] = nil
            channel.engine.stop(completionHandler: nil)
        }
    }

    /// Per-locality CHHapticEvent sharpness — the spectral half of the wire's
    /// dual-motor model (intensity is the temporal half, and the ONLY
    /// parameter the upstream clients set: moonlight-ios HapticContext.m and
    /// SDL's SDL_mfijoystick.m both build their continuous event with
    /// intensity alone, verified against both sources — so this is a
    /// deliberate step beyond upstream, not a port).
    ///
    /// WHY: the wire's two motors are FREQUENCY classes — lowFreqRumble is the
    /// heavy slow motor (left handle), highFreqRumble the light fast one
    /// (right handle). On pads with real ERM motors (Xbox) the OS routes each
    /// locality to its physical motor, so sharpness costs nothing. On a
    /// DualSense there are no rumble ERMs at all: the grips hold broadband
    /// VOICE-COIL actuators that SYNTHESIZE whatever band Core Haptics asks
    /// for — and an event with no sharpness renders both wire motors at the
    /// same default band, collapsing the wire's heavy-thump/light-buzz split
    /// into one homogeneous mid-band buzz (the "weak rumble" feel on a
    /// DualSense). Explicit per-locality sharpness restores the split along
    /// Apple's documented axis: 0.0 = round/organic, 1.0 = crisp/precise.
    static func sharpness(for locality: GCHapticsLocality) -> Float {
        switch locality {
        case .leftHandle:
            // The wire's low-frequency (heavy) motor: deep, round thump. Not
            // 0.0 — the very bottom of the band rolls off on small grip
            // actuators, trading punch for inaudible sub-band excursion.
            return 0.25
        case .rightHandle, .leftTrigger, .rightTrigger:
            // The high-frequency body motor and the (small, fast) trigger
            // motors: crisp buzz, clearly separated from the left thump.
            return 0.75
        default:
            // Merged single-locality plan (.handles / .all) carries
            // max(low, high) of BOTH motors — stay spectrally neutral.
            return 0.5
        }
    }

    /// Build engine + infinite continuous player for one motor locality.
    private func makeChannel(pad: PadHaptics, slot: UInt8, locality: GCHapticsLocality,
                             initialIntensity: Float) -> HapticChannel? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= pad.nextEngineAttemptNanos else { return nil }
        guard let haptics = pad.controller?.haptics,
              let engine = haptics.createEngine(withLocality: locality) else {
            pad.nextEngineAttemptNanos = now + Self.engineRetryNanos
            Diag.info("controller \(slot) haptic engine create failed for '\(locality.rawValue)'; "
                + "retrying in ~1s", Self.logCategory)
            return nil
        }
        // Self-healing: Core Haptics stops engines on its own (controller
        // power management, system reclaim) and resets them after a haptics
        // server hiccup. Either way this channel is dead — both handlers just
        // drop it on the haptics queue (latest engine instance only, via the
        // identity check) and the NEXT nonzero rumble rebuilds lazily. The
        // handlers fire on a Core Haptics internal thread, so they capture
        // only Sendable values (the locality's raw string, never the engine).
        let key = locality.rawValue
        let engineID = ObjectIdentifier(engine)
        engine.stoppedHandler = { [weak self] reason in
            let why = "engine stopped (reason \(reason.rawValue))"
            self?.queue.async {
                self?.dropChannel(slot: slot, localityKey: key, engineID: engineID, why: why)
            }
        }
        engine.resetHandler = { [weak self] in
            self?.queue.async {
                self?.dropChannel(slot: slot, localityKey: key, engineID: engineID, why: "engine reset")
            }
        }
        do {
            try engine.start()
            // ONE infinite continuous event at full base intensity, with the
            // motor's per-locality sharpness (see `sharpness(for:)`); every
            // level change rides .hapticIntensityControl (a multiplier on the
            // event's intensity), so a 135/s rumble stream is parameter
            // updates on a long-lived player, never player churn.
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness,
                                           value: Self.sharpness(for: locality))
                ],
                relativeTime: 0,
                duration: TimeInterval(GCHapticDurationInfinite))
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            // Seed the gain BEFORE starting playback: the event's base
            // intensity is 1.0, so starting un-seeded would flash the motor
            // at full strength until the first update landed.
            try player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                          value: initialIntensity, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            return HapticChannel(engine: engine, player: player)
        } catch {
            pad.nextEngineAttemptNanos = now + Self.engineRetryNanos
            Diag.info("controller \(slot) haptic engine start failed (\(error)); retrying in ~1s",
                      Self.logCategory)
            engine.stop(completionHandler: nil)
            return nil
        }
    }

    /// Drop a dead channel IF it is still the current one for its locality —
    /// a stop/reset notification for an engine we already replaced must not
    /// kill its successor.
    private func dropChannel(slot: UInt8, localityKey: String, engineID: ObjectIdentifier, why: String) {
        guard let pad = pads[slot], let channel = pad.engines[localityKey],
              ObjectIdentifier(channel.engine) == engineID else { return }
        pad.engines[localityKey] = nil
        Diag.info("controller \(slot) haptic \(why) — rebuilding on next rumble", Self.logCategory)
    }

    /// Park a pad's motors at zero and stop its engines. Idempotent and quiet
    /// when there is nothing to stop.
    func teardown(pad: PadHaptics, slot: UInt8, why: String) {
        pad.announcedActive = false
        pad.announcedTriggersActive = false
        pad.announcedLightActive = false
        guard !pad.engines.isEmpty else { return }
        for channel in pad.engines.values {
            // Park the motor at zero THEN stop: the explicit (0,0) is the
            // belt-and-braces guarantee that a stream ending mid-rumble can't
            // leave a motor running even if the engine stop defers
            // internally. try? — an already-gone pad throws here, and that is
            // exactly the case where the motor is already dead.
            try? channel.player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                          value: 0, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
            try? channel.player.stop(atTime: CHHapticTimeImmediate)
            channel.engine.stop(completionHandler: nil)
        }
        pad.engines.removeAll()
        Diag.info("controller \(slot) rumble engines stopped (\(why))", Self.logCategory)
    }

    // MARK: - DualSense raw-HID merge mirror

    /// True when this pad is a DualSense whose raw-HID reader is live — the only
    /// case where DualSenseHID owns an OUTPUT report and therefore needs the
    /// merged lightbar + rumble kept current. GameController's `.haptics` /
    /// `.light` access is thread-safe (the file's threading note), and the
    /// extendedGamepad profile read is too.
    private func hidMergeActive(pad: PadHaptics) -> Bool {
        DualSenseHID.shared.isActive
            && pad.controller?.extendedGamepad is GCDualSenseGamepad
    }

    func mirrorRumbleToHID(pad: PadHaptics, lowFreq: UInt16, highFreq: UInt16) {
        guard hidMergeActive(pad: pad) else { return }
        // 16-bit wire → 8-bit report byte (the DS5EffectsState motor field).
        DualSenseHID.shared.setRumbleState(left: UInt8(lowFreq >> 8),
                                           right: UInt8(highFreq >> 8))
    }

    func mirrorLightToHID(pad: PadHaptics, red: UInt8, green: UInt8, blue: UInt8) {
        guard hidMergeActive(pad: pad) else { return }
        DualSenseHID.shared.setLightbarState(red: red, green: green, blue: blue)
    }

    // MARK: - Per-pad state

    /// How a pad's two wire motors map onto its haptic localities. Resolved
    /// once per pad (on first nonzero rumble) because supportedLocalities is
    /// a hardware property. (Internal, not private: the core file's `pads`
    /// map and registration construct these — the topic-split cost.)
    enum ActuationPlan {
        /// lowFreq → .leftHandle, highFreq → .rightHandle (two engines).
        case splitHandles
        /// max(lowFreq, highFreq) → one whole-pad engine.
        case single(GCHapticsLocality)
        /// Pad exposes no haptics at all.
        case unavailable
    }

    /// One locality's live engine + its infinite continuous player.
    final class HapticChannel {
        let engine: CHHapticEngine
        let player: CHHapticPatternPlayer
        init(engine: CHHapticEngine, player: CHHapticPatternPlayer) {
            self.engine = engine
            self.player = player
        }
    }

    /// Per-pad actuation state. `@unchecked Sendable` because the box is
    /// constructed on the registering thread (main) and from then on owned
    /// and mutated EXCLUSIVELY on the haptics queue; the weak GCController
    /// inside is only used for `.haptics` access, which GameController does
    /// not restrict to the main thread (unlike its controllers() registry).
    final class PadHaptics: @unchecked Sendable {
        /// Weak: GameController owns the pad's lifetime; a disconnect must
        /// deallocate it even if our unregister hop is still in flight.
        weak var controller: GCController?
        /// Live channels keyed by GCHapticsLocality.rawValue. String keys so
        /// the engine stop/reset handlers (which run on Core Haptics threads
        /// and hop through @Sendable closures) never capture the framework
        /// struct itself.
        var engines: [String: HapticChannel] = [:]
        /// Resolved lazily on the first nonzero rumble; see ActuationPlan.
        var plan: ActuationPlan?
        /// Trigger-locality support, resolved once per pad on the first
        /// nonzero trigger event (a hardware property, like `plan`).
        var triggersSupported: Bool?
        /// First-rumble breadcrumb latch; reset by teardown so each stream
        /// session announces once.
        var announcedActive = false
        /// First-event breadcrumb latches for the trigger and light-bar
        /// channels; reset by teardown, the announcedActive discipline.
        var announcedTriggersActive = false
        var announcedLightActive = false
        /// Earliest uptime (ns) for the next engine-creation attempt after a
        /// failure — the 1s backoff that keeps a failing pad cheap without
        /// ever giving up on it.
        var nextEngineAttemptNanos: UInt64 = 0

        init(controller: GCController) {
            self.controller = controller
        }
    }
}
