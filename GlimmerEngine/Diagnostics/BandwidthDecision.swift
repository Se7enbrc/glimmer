// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// One privacy-safe ledger schema serves both shells; missing probes encode as absent values.
public struct BandwidthDecision: Sendable, Equatable, Codable {
    public let policyVersion: Int
    public let path: BandwidthPath
    public let demand: BandwidthDemand
    public let environment: BandwidthEnvironment
    public let window: BandwidthHealth?
    public enum State: String, Sendable, Codable { case observing, trial, recovering, stopped }
    public let displayDemandKbps: Int
    public let baseKbps: Int
    public let earnedRung: Double
    public let state: State
    public let ceilingKbps: Int
    public let proposedKbps: Int
    public let appliedKbps: Int
    public let provenKbps: Int
    public let baselineMs: Double?
    public let activeSeconds: Double
    public let cleanSeconds: Double
    public let nextEligibleActiveSeconds: Double
    public let reason: BandwidthReason
    public let confidence: BandwidthConfidence
    public let request: BandwidthRequest?
    public let actuatorOutcome: BandwidthActuatorOutcome?
    public let flap: BandwidthFlapGuard
}

public struct BandwidthConnectRTT: Sendable, Codable {
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let steadyMs: Double
}

public struct BandwidthLedgerContext: Sendable, Codable {
    public let session: UUID
    public let attempt: UUID
    public var appRevision: String?
    public var engineRevision: String?
    public var sunshineVersion: String?
    public var encoder: String?
    public var connectStart: Double?
    public var mediaStart: Double?
    public var connectRTT: BandwidthConnectRTT?
    public var lastOldToFirstNewFrameMs: Double?
    public var audioInterruptionMs: Double?
    public var inputDisabledMs: Double?
    public var receivedBytes: UInt64?
    public var encodedBytes: UInt64?
    public var resumeCount: Int?
    public var cancelCount: Int?

    public init(session: UUID, attempt: UUID, connectRTT: BandwidthConnectRTT? = nil) {
        self.session = session
        self.attempt = attempt
        self.connectRTT = connectRTT
    }
}

public struct BandwidthLedger: Sendable, Codable {
    public var schemaVersion = 1
    public let context: BandwidthLedgerContext
    public let decision: BandwidthDecision
    public init(context: BandwidthLedgerContext, decision: BandwidthDecision) {
        self.context = context
        self.decision = decision
    }
}
