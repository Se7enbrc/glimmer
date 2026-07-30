//
//  BitrateDownshiftController.swift
//
//  MID-SESSION BITRATE DOWNSHIFT: the only rate adaptation this protocol
//  profile permits.
//
//  WHY A RECONNECT AND NOT A MESSAGE: bitrate is fixed for the life of a
//  session. There is no client→host bitrate request wired for this Sunshine
//  profile - FEC% is host-driven per frame, and the per-frame FEC-status
//  feedback moonlight uses collides on the wire with IDX_SET_RGB_LED and is
//  deliberately never sent (see FecHeadroomController). The rate is set once, in
//  the SDP, at ANNOUNCE. So the ONLY way to change it is to build a new SDP -
//  i.e. reconnect. That is not a workaround for a missing message; it is the
//  mechanism the protocol actually offers.
//
//  THE HOLE THIS FILLS: the frame watchdog's HOLD-IF-ALIVE branch is correct for
//  the case it was written for - the host paused its encoder (Windows sign-in →
//  secure desktop) while its control loop keeps ACKing, so tearing down would
//  kill the session just as the desktop returns. It holds and re-requests an IDR
//  every tick. But that hold is UNBOUNDED, and for a different failure it is
//  unproductive forever: when the path cannot carry the negotiated bitrate,
//  frames arrive and none survive FEC, so every IDR we ask for is itself shredded
//  on the way in. A captured tunnel session sat in exactly this state for 15
//  straight minutes - bits arriving at 13-32 fps, ZERO decoded frames, ~2500
//  RFI/min - because nothing in the loop could lower the rate that was the
//  actual problem. This controller is the escalation tier that ends that hold.
//
//  SIGNATURE IT KEYS ON (deliberately narrow): reception healthy + decode silent.
//  That is `receiveIdle` small (bits ARE arriving, so the link is not dead - a
//  dead link is ENet dead-peer detection's job) AND `decodeIdle` large (none of
//  them are usable). The watchdog already computes both, and already folds the
//  decode GATE into decodeIdle via
//  `min(secondsSinceLastDecodedFrame, secondsSinceDecodeGateLifted)` - so a
//  hidden window, which legitimately decodes nothing, can never trip this.
//
//  SAFETY CONTRACT:
//   1. REMOTE ONLY. A LAN that cannot carry its own negotiated rate is a
//      different fault (bad cable, duplex mismatch, a host that is overcommitted)
//      and lowering the ask would mask it. Gated on the resolved remoteness from
//      StreamPathMTU, not a guess.
//   2. BOUNDED. `maxDownshifts` per session, hard stop. It can walk the rate
//      down, never into a hole - and never below `floorKbps`.
//   3. CANNOT OSCILLATE. There is no automatic UPshift. Recovering the original
//      quality needs a new session, which is the honest contract: we cannot
//      measure headroom we are not using, so "try higher again" would be a guess
//      that costs another reconnect to walk back. One-way, by construction.
//   4. COOLDOWN. After a downshift, `cooldownSeconds` must pass before another
//      is considered - long enough for the reconnect to complete and the new
//      rate to actually be exercised, so we never stack two downshifts on one
//      episode's evidence.
//   5. NO-OP WHEN CLEAN. A session that never stalls never touches this; the
//      controller holds its initial state and costs one comparison per watchdog
//      tick.
//
//  THREADING: owned by StreamSession and touched only from the session actor
//  (the watchdog's per-tick hop). A value type with no shared state.
//

import Foundation

/// Policy + budget for walking the session bitrate down when a remote path
/// demonstrably cannot carry the negotiated rate. Pure: `evaluate` decides,
/// `recordDownshift` books it. Wiring lives in StreamSession+Watchdog.
struct BitrateDownshiftController: Sendable {

    // MARK: - Policy

    /// How many downshifts one session may perform. Two steps at `stepFactor`
    /// walk a rate to ~36% of the original, which spans the gap between "a
    /// tunnel that is a bit tight" and "a tunnel carrying a fifth of the ask".
    /// Past that the link is not a bitrate problem and another reconnect is just
    /// churn the user pays for.
    static let maxDownshifts = 2

    /// Multiplier per step. 0.6 is a decisive cut, not a nibble - a 10-15% trim
    /// would cost a reconnect and still leave the path overrun, which is the
    /// worst of both. Two steps: 1.0 → 0.6 → 0.36.
    static let stepFactor = 0.6

    /// Never advertise below this. Under it the stream is not worth resuming and
    /// the honest outcome is the existing teardown path, not an unwatchable
    /// trickle.
    static let floorKbps = 10_000

    /// How long the decode-only stall must persist before the FIRST downshift.
    /// Comfortably past `decodeStallRecoveryThreshold` (2s) so the cheap fix -
    /// the IDR nudge, which resolves the host-paused-encoder case - gets a full
    /// chance first. Only once IDRs have plainly failed is the rate implicated.
    static let stallSecondsBeforeDownshift: Double = 20.0

    /// Quiet window after a downshift before another may be considered. Covers
    /// the reconnect episode itself plus enough streaming at the new rate to
    /// judge it, so two downshifts can never fire on one episode's evidence.
    static let cooldownSeconds: Double = 90.0

    // MARK: - State

    /// Downshifts performed this session.
    private(set) var downshiftCount = 0

    /// Monotonic seconds of the last downshift; nil until the first.
    private var lastDownshiftUptime: Double?

    // MARK: - Decision

    /// Why a downshift was declined - carried so the caller can log the honest
    /// reason once per episode instead of a bare "no".
    enum Decision: Equatable, Sendable {
        /// Downshift now, to this advertised bitrate (kbps).
        case downshift(toKbps: Int)
        /// Not a remote path - a LAN that cannot carry its rate is a different fault.
        case notRemote
        /// The stall has not persisted long enough to implicate the bitrate.
        case tooEarly
        /// Bits are not arriving either - a dead link, owned by dead-peer detection.
        case receptionAlsoDead
        /// Still inside the post-downshift cooldown.
        case coolingDown
        /// Session budget spent, or the next step would breach the floor.
        case budgetExhausted
    }

    /// Decide whether to downshift. `nowUptime` is a monotonic clock
    /// (ProcessInfo.systemUptime); `decodeIdle`/`receiveIdle` come straight from
    /// the frame watchdog, where decodeIdle already folds in the decode gate.
    func evaluate(
        isRemote: Bool,
        decodeIdle: Double,
        receiveIdle: Double,
        currentKbps: Int,
        nowUptime: Double
    ) -> Decision {
        guard isRemote else { return .notRemote }
        // Bits must be ARRIVING. Reception dead means the link is gone, which is
        // ENet dead-peer detection's call, not a bitrate decision.
        guard receiveIdle.isFinite,
              receiveIdle < Self.stallSecondsBeforeDownshift else {
            return .receptionAlsoDead
        }
        guard decodeIdle >= Self.stallSecondsBeforeDownshift else { return .tooEarly }
        if let last = lastDownshiftUptime,
           nowUptime - last < Self.cooldownSeconds {
            return .coolingDown
        }
        guard downshiftCount < Self.maxDownshifts else { return .budgetExhausted }
        let next = Int((Double(currentKbps) * Self.stepFactor).rounded())
        guard next >= Self.floorKbps, next < currentKbps else { return .budgetExhausted }
        return .downshift(toKbps: next)
    }

    /// Book a downshift that actually happened. Only the caller knows whether the
    /// reconnect was really initiated, so the budget is spent here, not in
    /// `evaluate`.
    ///
    /// There is deliberately no `reset`: the budget is per-session by
    /// CONSTRUCTION, because `StreamSession` is built fresh for every stream
    /// launch (AppModel+Streaming) and this is one of its stored properties. A
    /// reconnect - including a downshift's own - reuses the same session, which
    /// is exactly right: the budget must survive it, or a link that keeps
    /// failing would downshift forever.
    mutating func recordDownshift(atUptime: Double) {
        downshiftCount += 1
        lastDownshiftUptime = atUptime
    }
}
