//
//  BitrateDownshiftController.swift
//  Bitrate is set in SDP; 0x5502 collides with IDX_SET_RGB_LED, so recovery needs reconnect.

import Foundation

/// Policy + budget for walking the session bitrate down when a remote path
/// demonstrably cannot carry the negotiated rate. Pure: `evaluate` decides,
/// `recordDownshift` books it. Wiring lives in StreamSession+Watchdog.
struct BitrateDownshiftController: Sendable {

    // MARK: - Policy

    /// Two `stepFactor` steps reach ~36% of the ask, from a slightly tight tunnel to one carrying a fifth;
    /// more steps would only churn reconnects. No automatic upshift: unused headroom can't be measured,
    /// and guessing risks repeated reconnects.
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
    /// IDRs can resolve a paused encoder, but cannot repair an overloaded path:
    /// repeated requests only send more frames into the same bottleneck.
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
        /// LAN overload points to a local fault; downshifting would mask it.
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
