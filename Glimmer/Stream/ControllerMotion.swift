//
//  ControllerMotion.swift
//
//  Host-solicited controller motion (gyro/accel) uplink: the host's
//  SET_MOTION_EVENT (0x5501) enables per-pad sensor reporting at a requested
//  rate, and we answer with SS_CONTROLLER_MOTION input packets - the
//  LiSendControllerMotionEvent path the LI_CCAP_ACCEL/GYRO caps promise.
//
//  PROTOCOL (verified against moonlight-common-c + Sunshine master):
//   * Enable: Sunshine's control_set_motion_event_t (stream.cpp) writes
//     [u16 LE controllerNumber][u16 LE reportRateHz][u8 motionType]; moonlight
//     ControlStream.c parses the identical order (BbGet16/BbGet16/BbGet8,
//     BYTE_ORDER_LITTLE). reportRateHz == 0 means STOP
//     (ConnListenerSetMotionEventState, Limelight.h).
//   * Uplink: SS_CONTROLLER_MOTION_PACKET (Input.h) - see
//     InputEncoder.controllerMotion for the byte layout. Units per
//     Limelight.h: ACCEL in m/s^2 INCLUSIVE of gravity, GYRO in deg/s; axes
//     follow SDL's sensor convention (+X right, +Y up, +Z toward the player).
//   * GCMotion → wire mapping mirrors moonlight-ios ControllerSupport.m (the
//     only upstream client on this exact API):
//       accel = motion.acceleration * -9.80665 on ALL axes - GameController
//         reports gravity-inclusive acceleration in G with gravity DOWN at
//         rest, SDL wants the reaction-force convention (+Y ≈ +9.81 at rest),
//         so one global sign flip doubles as the G → m/s^2 scale;
//       gyro  = (rot.x, rot.z, -rot.y) * 57.2957795 - rad/s → deg/s with the
//         y/z swap moonlight-ios ships.
//
//  SAMPLING: GCMotion.valueChangedHandler sends each new reading as the pad
//  reports it, duplicate-suppressed and capped at the host rate (MotionRateGate).
//  Every sample rides the InputBatcher's 1ms latest-wins merge like all input.
//
//  ZERO WORK WHEN OFF: registration stores only a weak pad ref - no handler
//  and no sensorsActive flip until the host's first nonzero 0x5501.
//  Disable is host rate=0, pad detach, or stream teardown; each drops the
//  handler, and halting an ACTIVE gyro also sends one (0,0,0) null sample -
//  the special value ControlStream.c blesses for exactly this client-side
//  halt, so the host's virtual pad can't hold a stale rotation forever.
//
//  THREADING: all mutable state is MainActor-confined (GameController's home
//  isolation in this codebase - the forwarder treats the framework as
//  main-domain). setMotionEventState/streamActivated/stopAll arrive on the
//  enet receive thread / pipeline executor and hop to main first.
//

import Foundation
import GameController

/// Singleton sampler: ControllerForwarder registers slot→pad on attach (main
/// thread), EnetControlChannel→NativeConnectionEvents feeds it 0x5501 enables
/// (enet receive thread), and NativeBackend+Pipeline arms/clears the uplink
/// per stream session. `@unchecked Sendable`: every entry point either is
/// @MainActor or hops to main before touching state.
final class ControllerMotion: @unchecked Sendable {
    static let shared = ControllerMotion()
    static let logCategory = "Controller"

    /// Ceiling on the host-requested report rate. Sunshine asks for 100Hz per
    /// sensor today; the cap bounds the reliable-uplink budget (our wire has
    /// no unreliable sends, so every sample is an ACK-tracked ENet command)
    /// at ≤400 pkt/s worst case for a both-sensors pad.
    private static let maxReportRateHz: UInt16 = 200

    /// G → m/s^2 (SDL_STANDARD_GRAVITY; the moonlight-ios constant).
    private static let gravity: Float = 9.80665
    /// rad/s → deg/s (the moonlight-ios constant).
    private static let degPerRad: Float = 57.2957795

    /// LI_MOTION_TYPE_* narrowed once to the wire's u8.
    private static let accelType = UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL)
    private static let gyroType = UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO)

    // MARK: - MainActor-confined state

    /// slot (the forwarder's 0..15 controllerNumber) → sampling state.
    @MainActor private var pads: [UInt8: Pad] = [:]
    /// The live stream's input uplink; nil = no stream (the quiesce gate - a
    /// reading with no uplink sends nothing, mirroring the haptics
    /// actuator's quiesced flag). Weak: the backend's lifetime belongs to
    /// StreamSession, not to this singleton.
    @MainActor private weak var uplink: (any StreamingBackend)?

    private init() {}

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Probe the pad's IMU and map `slot` for host motion enables. Returns
    /// the LI_CCAP_ACCEL/GYRO bits to ADVERTISE - gated per sensor (the
    /// moonlight-ios timer gates: hasGravityAndUserAcceleration for accel,
    /// hasRotationRate for gyro), not a blanket "motion != nil", so the caps
    /// we promise are caps we can deliver. Registration alone starts no
    /// sensors and installs no handlers.
    @MainActor
    func register(slot: UInt8, controller: GCController) -> UInt16 {
        // A re-attach can reuse a slot before detach bookkeeping settles;
        // halt the stale pad's sampling so the swap can't strand a live handler.
        if let stale = pads.removeValue(forKey: slot) {
            halt(pad: stale, slot: slot, why: "slot reassigned")
        }
        guard let motion = controller.motion else { return 0 }
        var caps: UInt16 = 0
        if motion.hasGravityAndUserAcceleration {
            caps |= UInt16(StreamProtocol.LI_CCAP_ACCEL)
        }
        if motion.hasRotationRate {
            caps |= UInt16(StreamProtocol.LI_CCAP_GYRO)
        }
        guard caps != 0 else { return 0 }
        pads[slot] = Pad(controller: controller)
        return caps
    }

    /// Drop a slot's mapping and halt its sampling (controller detach).
    @MainActor
    func unregister(slot: UInt8) {
        guard let pad = pads.removeValue(forKey: slot) else { return }
        halt(pad: pad, slot: slot, why: "controller detached")
    }

    // MARK: - Stream lifecycle (NativeBackend+Pipeline)

    /// Arm the uplink for a new stream session. Wired in startVideoStage
    /// alongside enet.onSetMotionEvent, so samples become possible exactly
    /// when host enables can start arriving.
    func streamActivated(backend: any StreamingBackend) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.uplink = backend }
        }
    }

    /// Stream over: halt all sampling and drop the uplink. Fired by
    /// EnetControlChannel.onTeardown on EVERY stream-end path (user stop,
    /// watchdog, host TERMINATION) - the ControllerHaptics.stopAll
    /// discipline. The gyro nulls halt() attempts are best-effort here: by
    /// teardown the batcher is usually gone and sendControllerMotion returns
    /// -2, which is fine - so is the host. Pads stay registered (the
    /// forwarder owns that lifetime); only the sampling state resets.
    func stopAll(reason: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (slot, pad) in self.pads {
                    self.halt(pad: pad, slot: slot, why: reason)
                }
                self.uplink = nil
            }
        }
    }

    // MARK: - Host enable intake (enet receive thread)

    /// Apply a host SET_MOTION_EVENT (0x5501). Called on the enet receive
    /// thread; hops to main, where GameController lives. This is a rare
    /// state change (a per-sensor open/close when a game grabs or releases
    /// the IMU), not a per-frame flood, so the hop costs nothing.
    func setMotionEventState(controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        // The host echoes the controllerNumber WE assigned (the forwarder's
        // 0..15 slot); anything else can't be ours. Unknown motion types
        // have no sensor behind them (LI_MOTION_TYPE_* is 1-based, two types).
        guard controllerNumber < UInt16(Enet.maxGamepads),
              motionType == Self.accelType || motionType == Self.gyroType else { return }
        let slot = UInt8(controllerNumber)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.apply(slot: slot, motionType: motionType, reportRateHz: reportRateHz)
            }
        }
    }

    // MARK: - Sampling state machine (main)

    /// Start/retune/stop one sensor's reporting per the host's request.
    @MainActor
    private func apply(slot: UInt8, motionType: UInt8, reportRateHz: UInt16) {
        guard let pad = pads[slot] else { return }
        let idx = Int(motionType) - 1
        let rate = min(reportRateHz, Self.maxReportRateHz)
        // The host may re-announce an unchanged state; only act on change
        // (the handleHdrInfo transition-gating discipline).
        guard pad.rates[idx] != rate else { return }
        let wasActive = pad.rates[idx] != 0
        pad.rates[idx] = rate
        pad.lastSample[idx] = nil
        pad.gates[idx] = MotionRateGate()

        if rate == 0 {
            // Host-requested stop. Null an active gyro (see halt()'s WHY) and
            // power the IMU down if both sensors are now idle.
            if motionType == Self.gyroType { sendGyroNull(slot: slot) }
            let anyActive = pad.rates.contains { $0 != 0 }
            if !anyActive { pad.controller?.motion?.valueChangedHandler = nil }
            setSensorsActive(pad, anyActive)
            Diag.info("controller \(slot) \(Self.name(motionType)) reporting stopped (host request)",
                      Self.logCategory)
            return
        }

        // The caps gate means the host only asks for sensors we advertised,
        // but a pad detaching mid-flight reads nil here - then don't start.
        guard let motion = pad.controller?.motion else { return }
        setSensorsActive(pad, true)
        // GameController calls this on its handler queue, main by default.
        motion.valueChangedHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(slot: slot) }
        }
        let detail = wasActive ? "retuned to" : "started at"
        Diag.info("controller \(slot) \(Self.name(motionType)) reporting \(detail) \(rate)Hz "
            + "(host requested \(reportRateHz))", Self.logCategory)
    }

    /// One GCMotion change: convert each active sensor to the wire's SDL
    /// convention, skip unchanged readings, and send what the rate gate admits.
    @MainActor
    private func sample(slot: UInt8) {
        guard let pad = pads[slot], let motion = pad.controller?.motion,
              let backend = uplink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for motionType in [Self.accelType, Self.gyroType] {
            let idx = Int(motionType) - 1
            guard pad.rates[idx] != 0 else { continue }
            let value = Self.reading(motion, motionType)
            // Duplicate suppression (the moonlight-ios memcmp skip): a resting
            // pad would otherwise stream constants.
            if let last = pad.lastSample[idx], last == value { continue }
            guard pad.gates[idx].admit(at: now, rateHz: pad.rates[idx]) else { continue }
            pad.lastSample[idx] = value
            _ = backend.sendControllerMotion(num: slot, motionType: motionType,
                                             x: value.x, y: value.y, z: value.z)
        }
    }

    @MainActor
    private static func reading(_ motion: GCMotion, _ motionType: UInt8) -> (x: Float, y: Float, z: Float) {
        if motionType == accelType {
            // G (gravity DOWN at rest) → m/s^2 reaction-force convention
            // (+Y up at rest): one global -9.80665 (moonlight-ios mapping).
            let a = motion.acceleration
            return (Float(a.x) * -gravity, Float(a.y) * -gravity, Float(a.z) * -gravity)
        }
        // rad/s → deg/s with moonlight-ios's axis fix-up:
        // wire (x, y, z) = (rot.x, rot.z, -rot.y).
        let r = motion.rotationRate
        return (Float(r.x) * degPerRad, Float(r.z) * degPerRad, Float(r.y) * -degPerRad)
    }

    // MARK: - Halt helpers (main)

    /// Stop both sensors' reporting for `pad`. An ACTIVE gyro also emits one
    /// (0,0,0) null sample if the uplink is still alive - ControlStream.c
    /// reserves exactly that value so clients can "reliably set the gyro to
    /// a null state when sensor events are halted due to ... client-side
    /// constraints" (and our reliable-only wire guarantees its delivery).
    /// Accel needs no null: a stale gravity vector just reads as a pad at
    /// rest.
    @MainActor
    private func halt(pad: Pad, slot: UInt8, why: String) {
        guard pad.rates.contains(where: { $0 != 0 }) else { return }
        if pad.rates[Int(Self.gyroType) - 1] != 0 { sendGyroNull(slot: slot) }
        pad.controller?.motion?.valueChangedHandler = nil
        for idx in pad.rates.indices {
            pad.rates[idx] = 0
            pad.lastSample[idx] = nil
            pad.gates[idx] = MotionRateGate()
        }
        setSensorsActive(pad, false)
        Diag.info("controller \(slot) motion sampling stopped (\(why))", Self.logCategory)
    }

    /// The reliable gyro null-state sample (see halt()).
    @MainActor
    private func sendGyroNull(slot: UInt8) {
        guard let backend = uplink else { return }
        _ = backend.sendControllerMotion(num: slot, motionType: Self.gyroType,
                                         x: 0, y: 0, z: 0)
    }

    /// Some pads gate their IMU behind explicit power-up; flip it with sensor
    /// liveness (the moonlight-ios sensorsRequireManualActivation discipline)
    /// so a motion-idle pad burns no sensor power.
    @MainActor
    private func setSensorsActive(_ pad: Pad, _ active: Bool) {
        guard let motion = pad.controller?.motion,
              motion.sensorsRequireManualActivation else { return }
        motion.sensorsActive = active
    }

    /// Human label for a motion type in breadcrumbs.
    private static func name(_ motionType: UInt8) -> String {
        motionType == accelType ? "accel" : "gyro"
    }

    // MARK: - Per-pad state

    /// Per-pad sampling state. Constructed and mutated exclusively on the
    /// main actor - unlike ControllerHaptics' queue-owned box, motion never
    /// leaves GameController's main-domain, so no Sendable box is needed.
    @MainActor
    private final class Pad {
        /// Weak: GameController owns the pad's lifetime; a disconnect must
        /// deallocate it even if our unregister is still in flight.
        weak var controller: GCController?
        /// Granted report rate per sensor (index = LI_MOTION_TYPE_* - 1,
        /// post-cap); 0 = off.
        var rates: [UInt16] = [0, 0]
        /// Last forwarded sample per sensor, for duplicate suppression.
        var lastSample: [(x: Float, y: Float, z: Float)?] = [nil, nil]
        var gates = [MotionRateGate(), MotionRateGate()]

        init(controller: GCController) { self.controller = controller }
    }
}

/// Caps forwarded samples at the host's rate without dropping a slower
/// pad's jittered ones: a two-sample token bucket refilled at `rateHz`.
struct MotionRateGate: Equatable, Sendable {
    private var tokens = 2.0
    private var lastAt: TimeInterval?

    mutating func admit(at now: TimeInterval, rateHz: UInt16) -> Bool {
        if let lastAt { tokens = min(2, tokens + (now - lastAt) * Double(rateHz)) }
        lastAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

// MARK: - NativeBackend motion uplink

extension NativeBackend {
    /// = LiSendControllerMotionEvent (InputStream.c). Hands the sample to the
    /// InputBatcher's latest-wins merge on the pad's sensor channel -
    /// moonlight's currentGamepadSensorState batching, where a superseded
    /// sample is replaced, never queued. Gated on the same Sunshine feature
    /// flag as controller touch: LiSendControllerMotionEvent checks
    /// LI_FF_CONTROLLER_TOUCH_EVENTS for BOTH (InputStream.c). Lives here,
    /// not NativeBackend+Input.swift, so the motion uplink reads end-to-end
    /// in this file.
    public func sendControllerMotion(num: UInt8, motionType: UInt8,
                                     x: Float, y: Float, z: Float) -> Int32 {
        guard let batcher = readyBatcher() else { return Self.inputNotReady }
        guard withState({ featureFlags }) & Self.ffControllerTouchEvents != 0 else {
            return StreamProtocol.LI_ERR_UNSUPPORTED
        }
        return batcher.updateMotion(num: num, motionType: motionType, x: x, y: y, z: z)
    }
}
