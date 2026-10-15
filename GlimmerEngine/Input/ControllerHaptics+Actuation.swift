// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension ControllerHaptics {

    // MARK: - Actuation (haptics queue)

    package func apply(slot: UInt8, lowFreq: UInt16, highFreq: UInt16) {
        guard let pad = pads[slot], acceptsActuation(pad: pad, slot: slot, requiresOwnership: true) else { return }
        // Update the prepared side-channel mirror before native motors, preserving merged output when
        // the Mac sends another HID report.
        mirrorRumbleToHID(pad: pad, lowFreq: lowFreq, highFreq: highFreq)
        if lowFreq == 0 && highFreq == 0 {
            // A zero body-rumble event idles existing body players without affecting trigger localities,
            // which have separate wire events.
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
        // Capabilities belong to this prepared registration; a replacement resolves its own plan.
        let localities = pad.output.localities
        guard !localities.isEmpty else {
            Diag.info("controller \(slot) exposes no haptics - host rumble ignored", Self.logCategory)
            return .unavailable
        }
        if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
            // The wire's dual-motor model maps 1:1 onto per-handle engines:
            // low-frequency (heavy) motor → left handle, high-frequency motor
            // → right handle - the physical layout of Xbox/DualSense pads.
            return .splitHandles
        }
        // No per-handle engines: merge both motors onto the best whole-pad
        // locality. max() keeps the stronger motor's energy rather than
        // averaging it away.
        let merged: ControllerFeedbackOutput.Locality = localities.contains(.handles) ? .handles : .all
        Diag.info("controller \(slot) haptics lack per-handle localities - merging motors onto "
            + "'\(merged.rawValue)'", Self.logCategory)
        return .single(merged)
    }

    /// Each trigger wire motor drives its corresponding locality. Both trigger localities are required
    /// before advertising support.
    package func applyTriggers(slot: UInt8, left: UInt16, right: UInt16) {
        guard let pad = pads[slot], acceptsActuation(pad: pad, slot: slot, requiresOwnership: true) else { return }
        if left == 0 && right == 0 {
            // Idle existing trigger players only - never probe hardware or
            // build an engine to play silence (the body-(0,0) discipline).
            for key in Self.triggerLocalityKeys {
                if let channel = pad.engines[key] {
                    sendIntensity(0, to: channel, pad: pad, slot: slot, localityKey: key)
                }
            }
            return
        }
        // Resolve both trigger localities once, on first nonzero demand; unsupported pads allocate no
        // trigger motors.
        if pad.triggersSupported == nil {
            // Prepared capabilities stay fixed for this registration, including after native detach.
            let localities = pad.output.localities
            pad.triggersSupported = localities.contains(.leftTrigger)
                && localities.contains(.rightTrigger)
            if pad.triggersSupported == false {
                Diag.info("controller \(slot) haptics lack trigger localities - "
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

    /// Apply the newest RGB value through the prepared native light function on the serial feedback
    /// queue.
    package func applyLight(slot: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        guard let pad = pads[slot], acceptsActuation(pad: pad, slot: slot) else { return }
        guard pad.output.setLight != nil || lightSink != nil else { return }
        // Mirror to DualSenseHID's merge (see apply()) so a trigger report keeps this color.
        mirrorLightToHID(pad: pad, red: red, green: green, blue: blue)
        guard acceptsActuation(pad: pad, slot: slot) else { return }
        if let lightSink {
            lightSink(slot, (red, green, blue))
        } else {
            pad.output.setLight?(red, green, blue)
        }
        if !pad.announcedLightActive {
            pad.announcedLightActive = true
            Diag.info("light bar set: controller \(slot) rgb(\(red),\(green),\(blue))",
                      Self.logCategory)
        }
    }

    /// Player LEDs (SET_PLAYER_LEDS) → GCController.playerIndex, which drives the
    /// player indicators on pads that have them. Same queue as the light bar.
    package func applyPlayerLEDs(slot: UInt8, solidMask: UInt8) {
        guard let pad = pads[slot], acceptsActuation(pad: pad, slot: slot) else { return }
        let index = ControllerPlayerIndicator.index(solidMask: solidMask)
        guard pad.output.setPlayerIndex?(index) == true else { return }
        Diag.info("player LEDs set: controller \(slot) mask=0x\(String(solidMask, radix: 16))",
                  Self.logCategory)
    }

    private func announceIfFirst(_ pad: PadHaptics, slot: UInt8) {
        guard !pad.announcedActive else { return }
        pad.announcedActive = true
        // The one always-on HUMAN breadcrumb for this feature (the volume
        // signal rides `rumbleEventTotal`, counted at protocol dispatch):
        // proves host rumble reached actuation, once per pad per stream.
        Diag.info("rumble active: controller \(slot)", Self.logCategory)
    }

    private func setMotor(pad: PadHaptics, slot: UInt8, locality: ControllerFeedbackOutput.Locality, intensity: Float) {
        guard acceptsActuation(pad: pad, slot: slot, requiresOwnership: true) else { return }
        if let motorSink { motorSink(slot, locality, intensity); return }
        let key = locality.rawValue
        if let channel = pad.engines[key] {
            sendIntensity(intensity, to: channel, pad: pad, slot: slot, localityKey: key)
            return
        }
        // Zero intensity does not create hardware. Nonzero demand lazily creates a channel subject to
        // the existing retry backoff.
        guard intensity > 0 else { return }
        if let channel = makeChannel(pad: pad, slot: slot, locality: locality,
                                     initialIntensity: intensity) {
            pad.engines[key] = channel
        }
    }

    private func sendIntensity(_ intensity: Float, to channel: HapticChannel, pad: PadHaptics,
                               slot: UInt8, localityKey: String) {
        guard acceptsActuation(pad: pad, slot: slot, requiresOwnership: true) else { return }
        do {
            try channel.motor.setIntensity(intensity)
        } catch {
            // Recoverable hiccup, not a fault: drop the channel so the next
            // nonzero event lazily rebuilds it. INFO on purpose - haptics
            // self-heal and a warning would cry wolf in the diagnostics ring.
            Diag.info("controller \(slot) haptics update failed (\(error, privacy: .private)) - rebuilding on next event",
                      Self.logCategory)
            pad.engines[localityKey] = nil
            channel.motor.stop()
        }
    }

    /// Wire motors preserve spectral identity: low-frequency left handle uses sharpness 0.25; right
    /// handle and trigger motors use 0.75. A merged whole-pad motor uses 0.5.
    package static func sharpness(for locality: ControllerFeedbackOutput.Locality) -> Float {
        switch locality {
        case .leftHandle:
            // The wire's low-frequency (heavy) motor: deep, round thump. Not
            // 0.0 - the very bottom of the band rolls off on small grip
            // actuators, trading punch for inaudible sub-band excursion.
            return 0.25
        case .rightHandle, .leftTrigger, .rightTrigger:
            // The high-frequency body motor and the (small, fast) trigger
            // motors: crisp buzz, clearly separated from the left thump.
            return 0.75
        default:
            // Merged single-locality plan (.handles / .all) carries
            // max(low, high) of BOTH motors - stay spectrally neutral.
            return 0.5
        }
    }

    /// Build engine + infinite continuous player for one motor locality.
    private func makeChannel(pad: PadHaptics, slot: UInt8, locality: ControllerFeedbackOutput.Locality,
                             initialIntensity: Float) -> HapticChannel? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= pad.nextEngineAttemptNanos else { return nil }
        let generation = lock.withLock { (self.generation, self.ownershipGeneration) }
        let key = locality.rawValue
        let channelID = UUID()
        do {
            guard let motor = try pad.output.makeMotor(locality, Self.sharpness(for: locality), initialIntensity,
                { [weak self] why in
                    guard let self else { return }
                    self.queue.async {
                        self.dropChannel(slot: slot, localityKey: key, channelID: channelID, why: why)
                    }
                }) else {
                pad.nextEngineAttemptNanos = now + Self.engineRetryNanos
                return nil
            }
            let current = lock.withLock {
                self.generation == generation.0 && self.ownershipGeneration == generation.1
                    && self.ownsInput && self.registrationTokens[slot] == pad.token
            }
            guard current else { motor.stop(); return nil }
            return HapticChannel(id: channelID, motor: motor)
        } catch {
            pad.nextEngineAttemptNanos = now + Self.engineRetryNanos
            Diag.info("controller \(slot) haptic engine start failed (\(error, privacy: .private)); retrying in ~1s",
                      Self.logCategory)
            return nil
        }
    }

    /// Drop a dead channel IF it is still the current one for its locality -
    /// a stop/reset notification for an engine we already replaced must not
    /// kill its successor.
    private func dropChannel(slot: UInt8, localityKey: String, channelID: UUID, why: String) {
        guard let pad = pads[slot], let channel = pad.engines[localityKey],
              channel.id == channelID else { return }
        pad.engines[localityKey] = nil
        Diag.info("controller \(slot) haptic \(why) - rebuilding on next rumble", Self.logCategory)
    }

    /// Park a pad's motors at zero and stop its engines. Idempotent and quiet
    /// when there is nothing to stop.
    package func teardown(pad: PadHaptics, slot: UInt8, why: String) {
        // A later trigger or close-time write must not replay the last rumble.
        mirrorRumbleToHID(pad: pad, lowFreq: 0, highFreq: 0)
        pad.announcedActive = false
        pad.announcedTriggersActive = false
        pad.announcedLightActive = false
        guard !pad.engines.isEmpty else { return }
        for channel in pad.engines.values {
            // Set intensity to zero before stopping so delayed native shutdown cannot leave a motor
            // running. An already disconnected motor may reject the update.
            try? channel.motor.setIntensity(0)
            channel.motor.stop()
        }
        pad.engines.removeAll()
        Diag.info("controller \(slot) rumble engines stopped (\(why))", Self.logCategory)
    }

    // MARK: - DualSense raw-HID merge mirror

    /// Optional prepared mirrors keep native side-channel output synchronized without giving the engine
    /// device ownership.
    package func mirrorRumbleToHID(pad: PadHaptics, lowFreq: UInt16, highFreq: UInt16) {
        pad.output.mirrorRumble?(lowFreq, highFreq)
    }

    package func mirrorLightToHID(pad: PadHaptics, red: UInt8, green: UInt8, blue: UInt8) {
        pad.output.mirrorLight?(red, green, blue)
    }

    // MARK: - Per-pad state

    /// Resolve the two wire motors onto prepared hardware localities once per pad, on first nonzero
    /// demand.
    package enum ActuationPlan {
        /// lowFreq → .leftHandle, highFreq → .rightHandle (two engines).
        case splitHandles
        /// max(lowFreq, highFreq) → one whole-pad engine.
        case single(ControllerFeedbackOutput.Locality)
        /// Pad exposes no haptics at all.
        case unavailable
    }

    /// One locality's live engine + its infinite continuous player.
    package final class HapticChannel {
        let id: UUID
        let motor: ControllerMotor
        init(id: UUID, motor: ControllerMotor) { self.id = id; self.motor = motor }
    }

    /// Constructed during registration, then owned exclusively by the feedback queue. Prepared closures
    /// retain only their adapter-defined native lifetime.
    package final class PadHaptics: @unchecked Sendable {
        /// Prepared closures own the native lease until registration teardown.
        let output: ControllerFeedbackOutput
        let token = UUID()
        /// Channels use scalar locality keys; stop/reset callbacks identify the exact channel they
        /// invalidated.
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
        /// failure - the 1s backoff that keeps a failing pad cheap without
        /// ever giving up on it.
        var nextEngineAttemptNanos: UInt64 = 0

        init(output: ControllerFeedbackOutput) { self.output = output }
    }
}

/// Pure mapping from Sunshine's four-bit player mask to a zero-based indicator; -1 clears it.
package enum ControllerPlayerIndicator {
    package static func index(solidMask: UInt8) -> Int {
        switch solidMask & 0x0F {
        case 0: return -1
        case let mask where mask & 0x1 != 0: return 0
        case let mask where mask & 0x2 != 0: return 1
        case let mask where mask & 0x4 != 0: return 2
        default: return 3
        }
    }
}
