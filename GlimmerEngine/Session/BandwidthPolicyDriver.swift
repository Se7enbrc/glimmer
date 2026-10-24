// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// The integration seam serializes requests and rejects completions from retired attempts or paths.
public actor BandwidthPolicyDriver {
    public private(set) var policy: BandwidthPolicy
    private let actuator: any BandwidthActuator
    private var epoch: UInt64 = 0
    private var inFlight = false
    private var lastSubmittedSequence: UInt64?
    private var lastRequestAt: Double = -.infinity

    public init(policy: BandwidthPolicy, actuator: any BandwidthActuator) {
        self.policy = policy
        self.actuator = actuator
    }

    public func replacePath(_ path: BandwidthPath) {
        guard path.generation >= policy.path.generation else { return }
        if path.generation != policy.path.generation || path.constrained != policy.path.constrained {
            epoch &+= 1
        }
        policy.replacePath(path)
    }

    public func stop() { epoch &+= 1; policy.stop() }
    public func setEnvironment(_ environment: BandwidthEnvironment) { policy.setEnvironment(environment) }

    public func evaluate(_ health: BandwidthHealth) async -> BandwidthDecision {
        let decision = policy.evaluate(health)
        guard let request = decision.request, !inFlight, policy.outcome != .accepted,
              maySubmit(request) else { return decision }
        let capturedEpoch = epoch
        inFlight = true
        lastRequestAt = policy.activeSeconds
        lastSubmittedSequence = request.sequence
        let result = await actuator.request(rate: request.rateKbps, reason: request.reason)
        inFlight = false
        guard epoch == capturedEpoch else { return policy.decision(.missingEvidence, health: health) }
        policy.recordOutcome(result, for: request)
        return policy.decision(decision.reason, health: health)
    }

    private func maySubmit(_ request: BandwidthRequest) -> Bool {
        let urgent = request.reason == .rollback || request.reason == .pathChanged || request.reason == .lowData
        return policy.activeSeconds - lastRequestAt >= 90
            || (urgent && request.sequence != lastSubmittedSequence)
    }

    /// A queued transition that later fails must release acceptance so finite retries remain possible.
    public func recordOutcome(_ outcome: BandwidthActuatorOutcome, for request: BandwidthRequest) {
        policy.recordOutcome(outcome, for: request)
    }

    @discardableResult public func confirmApplied(_ request: BandwidthRequest) -> Bool {
        policy.confirmApplied(request)
    }
}
