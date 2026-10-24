// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Optional facts stay unknown; a default route is never evidence of the media socket's underlay.
public struct BandwidthPath: Sendable, Equatable, Codable {
    public enum Interface: String, Sendable, Codable { case wired, wifi, cellular, other, unknown }
    public enum Source: String, Sendable, Codable { case destination, defaultPath, unavailable }
    public enum LinkQuality: String, Sendable, Codable { case unknown, minimal, moderate, good }
    public enum Radio: String, Sendable, Codable { case lte, nr, nrNSA, other }
    public var generation: UInt64
    public var observedAt: Double
    public var interface: Interface
    public var interfaces: [Interface] = []
    public var source: Source
    public var satisfied: Bool?
    public var expensive: Bool?
    public var constrained: Bool?
    public var ultraConstrained: Bool?
    public var tunnel: Bool?
    public var mtu: Int?
    public var linkQuality: LinkQuality = .unknown
    public var radio: Radio?
    public var phyMbps: Double?
    public var phyObservedAt: Double?
    public var phyMatchesInterface = false

    public var needsConservativePacketSize: Bool {
        satisfied != true || source == .unavailable || (interface != .wifi && interface != .wired)
    }

    public init(generation: UInt64 = 0, observedAt: Double, interface: Interface = .unknown,
                source: Source = .unavailable, satisfied: Bool? = nil,
                expensive: Bool? = nil, constrained: Bool? = nil) {
        self.generation = generation
        self.observedAt = observedAt
        self.interface = interface
        self.source = source
        self.satisfied = satisfied
        self.expensive = expensive
        self.constrained = constrained
    }
}

public struct BandwidthEnvironment: Sendable, Equatable, Codable {
    public enum Thermal: String, Sendable, Codable { case unknown, nominal, fair, serious, critical }
    public var thermal: Thermal = .unknown
    public var lowPower: Bool?
    public var foreground = true
    public init() {}

    var allowsPromotion: Bool {
        foreground && lowPower == false && (thermal == .nominal || thermal == .fair)
    }
}

public struct BandwidthDemand: Sendable, Equatable, Codable {
    public enum Codec: String, Sendable, Codable { case h264, hevc, av1 }
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: Codec
    public var hdr: Bool
    public var customKbps: Int?
    public var saver = false
    public var deviceCeilingKbps: Int?
    public var encoderCeilingKbps: Int?
    public var dataCeilingKbps: Int?

    public init(width: Int, height: Int, fps: Int, codec: Codec, hdr: Bool = false) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.hdr = hdr
    }

    /// The phone curve is normalized to 1080p60; desktop harness anchors are not phone measurements.
    public var baseKbps: Int {
        let curve = StreamQuality.bitrateKbps(width: min(max(width, 2), 16_384),
            height: min(max(height, 2), 16_384), fps: min(max(fps, 1), 1_000), preset: .matchDisplay)
        return customKbps.map { max(1, min($0, 500_000)) }
            ?? Int((Double(curve) * (codec == .h264 ? 1 : 0.8)).rounded())
    }
}

/// Each window owns interval counts, not differences of percentiles or repeated two-second gauges.
public struct BandwidthHealth: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var generation: UInt64
    public var coverage: Double = 1
    public var missingSamples = 0
    public enum MissingReason: String, Sendable, Codable { case producerUnavailable, invalidClock, counterReset }
    public var missingReason: MissingReason?
    public var rttSamplesMs: [Double] = []
    public var expectedPackets: Int?
    public var lostPackets: Int?
    public var recoveredFrames: Int?
    public var totalFrames: Int?
    public var unrecoverableFrames: Int?
    public var gapMs: Double?
    public var localQueueMs: Double?
    public var decoderBacklog: Bool?
    public var encodedKbps: Double?
    public var receivedIPKbps: Double?
    public var jitterP95Ms: Double?
    public var parityMargin: Double?
    public var risingQueue: Bool?
    public var counterReset = false
    public var reorderedPackets = 0
    public var train: BandwidthTrainEvidence?

    public init(start: Double, end: Double, generation: UInt64) {
        self.start = start
        self.end = end
        self.generation = generation
    }

    var valid: Bool {
        start.isFinite && end.isFinite && (0.5...1.5).contains(end - start)
            && coverage.isFinite && coverage >= 0.9 && coverage <= 1 && !counterReset
            && rttSamplesMs.count <= 256 && missingSamples >= 0
    }

    var ledgerValue: Self? {
        let values = [start, end, coverage] + rttSamplesMs
            + [gapMs, localQueueMs, encodedKbps, receivedIPKbps, jitterP95Ms, parityMargin].compactMap { $0 }
        guard values.allSatisfy(\.isFinite) else { return nil }
        var value = self
        value.rttSamplesMs = Array(rttSamplesMs.suffix(256))
        if train?.budgetIPKbps(at: end) == nil { value.train = nil }
        return value
    }

    var loss: Double? { fraction(lostPackets, expectedPackets) }
    var recovered: Double? { fraction(recoveredFrames, totalFrames) }

    private func fraction(_ numerator: Int?, _ denominator: Int?) -> Double? {
        guard let numerator, let denominator, numerator >= 0, denominator > 0,
              numerator <= denominator else { return nil }
        return Double(numerator) / Double(denominator)
    }
}

public enum BandwidthReason: String, Sendable, Codable {
    case startup, hold, missingEvidence, localOverload, transportDistress, rollback, recovery, promotion
    case pathChanged, lowData, dataCeiling, background, unsupportedPath, stopped
}

public enum BandwidthConfidence: String, Sendable, Codable { case unknown, provisional, measured }

public struct BandwidthRequest: Sendable, Equatable, Codable {
    public let rateKbps: Int
    public let reason: BandwidthReason
    public let generation: UInt64
    public let sequence: UInt64
}

public enum BandwidthActuatorOutcome: String, Sendable, Codable { case accepted, deferred, rejected }

/// Acceptance queues a request; only confirmation of a successful ANNOUNCE changes the applied rate.
public protocol BandwidthActuator: Sendable {
    func request(rate: Int, reason: BandwidthReason) async -> BandwidthActuatorOutcome
}
