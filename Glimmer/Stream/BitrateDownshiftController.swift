//
//  BitrateDownshiftController.swift
//  Bitrate is set in SDP; 0x5502 collides with IDX_SET_RGB_LED, so recovery needs reconnect.

import Foundation

/// Policy + budget for walking the session bitrate down when a remote path demonstrably cannot carry
/// the negotiated rate, and one step back up once it has run clean. Pure: `evaluate` and `stepUp`
/// decide, the `record` calls book. Wiring lives in StreamSession+Downshift.
struct BitrateDownshiftController: Sendable {

    // MARK: - Policy

    /// Downshifts allowed inside one budget window: two steps reach ~36% of the ask, and more at a
    /// time would only churn reconnects. A downshift stops counting after `budgetWindowSeconds`.
    static let maxDownshifts = 2
    static let budgetWindowSeconds: Double = 1800

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

    /// Clean streaming at a lowered rate before one step back up. A step-up that stalls again inside
    /// its own window doubles the next one, up to the cap, so a failing link is probed less and less.
    static let stepUpCleanSeconds: Double = 300
    static let stepUpCleanCapSeconds: Double = 2400

    // MARK: - State

    private var downshiftUptimes: [Double] = []
    private var lastDownshiftUptime: Double?
    private var lastStallUptime: Double?
    private var lastStepUpUptime: Double?
    private var cleanSecondsRequired = BitrateDownshiftController.stepUpCleanSeconds
    /// Steps the ask sits below the route's; 0 means no downshift is in force.
    private(set) var stepsDown = 0
    /// The route the downshift was judged on (HostRouteMonitor's class); another route starts fresh.
    /// The session sets it after booking, since learning the route takes a main-actor hop.
    var route: String?

    var isDownshifted: Bool { stepsDown > 0 }

    /// Downshifts still counted against the budget.
    func downshiftCount(nowUptime: Double) -> Int {
        downshiftUptimes.count { nowUptime - $0 < Self.budgetWindowSeconds }
    }

    /// Whether the downshift in force was judged on `route`; one judged elsewhere says nothing here.
    func covers(route: String) -> Bool { isDownshifted && self.route == route }

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
        guard downshiftCount(nowUptime: nowUptime) < Self.maxDownshifts else { return .budgetExhausted }
        let next = Int((Double(currentKbps) * Self.stepFactor).rounded())
        guard next >= Self.floorKbps, next < currentKbps else { return .budgetExhausted }
        return .downshift(toKbps: next)
    }

    /// Book a downshift that actually happened, judged on `route`. Only the caller knows whether the
    /// reconnect was really initiated, so the budget is spent here, not in `evaluate`.
    mutating func recordDownshift(atUptime now: Double, route: String? = nil) {
        downshiftUptimes.append(now)
        lastDownshiftUptime = now
        stepsDown += 1
        self.route = route
        // A stall inside a step-up's own clean window means the step-up failed; one that outlived it
        // proved the link, and the backoff starts over.
        if let stepUp = lastStepUpUptime {
            let failed = now - stepUp < cleanSecondsRequired
            cleanSecondsRequired = failed
                ? min(cleanSecondsRequired * 2, Self.stepUpCleanCapSeconds) : Self.stepUpCleanSeconds
            lastStepUpUptime = nil
        }
    }

    /// Decode stalled past the nudge threshold: the clean window starts over.
    mutating func noteStall(atUptime now: Double) { lastStallUptime = now }

    /// Seconds the lowered rate has run clean: since the latest of the downshift, the last stall and
    /// the last step-up. Nil while nothing is downshifted.
    func cleanSeconds(nowUptime: Double) -> Double? {
        guard isDownshifted,
              let since = [lastDownshiftUptime, lastStallUptime, lastStepUpUptime].compactMap({ $0 }).max()
        else { return nil }
        return nowUptime - since
    }

    /// The ask to step back up to once the clean window has passed: one `stepFactor` toward
    /// `routeKbps`, capped there. Nil while not downshifted, not yet clean enough, or already there.
    func stepUp(currentKbps: Int, routeKbps: Int, nowUptime: Double) -> Int? {
        guard let clean = cleanSeconds(nowUptime: nowUptime), clean >= cleanSecondsRequired,
              currentKbps < routeKbps else { return nil }
        return min(routeKbps, Int((Double(currentKbps) / Self.stepFactor).rounded()))
    }

    /// Book a step-up; `reachedRoute` means the ask is back at the route's and nothing is downshifted.
    mutating func recordStepUp(atUptime now: Double, reachedRoute: Bool) {
        lastStepUpUptime = now
        stepsDown = reachedRoute ? 0 : max(0, stepsDown - 1)
    }
}
