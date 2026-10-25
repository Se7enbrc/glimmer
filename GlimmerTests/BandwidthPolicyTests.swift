// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
@testable import GlimmerEngine
import Testing

struct BandwidthReplay {
    enum Client: CaseIterable { case mac, ios }
    var policy: BandwidthPolicy
    var now: Double = 0
    var decisions: [BandwidthDecision] = []

    init(client: Client = .ios, interface: BandwidthPath.Interface = .wifi, constrained: Bool = false) {
        let path = BandwidthPath(generation: 1, observedAt: 0, interface: interface, source: .destination,
                                 satisfied: true, expensive: interface == .cellular, constrained: constrained)
        var verified = path
        verified.tunnel = false
        var environment = BandwidthEnvironment()
        environment.thermal = .nominal
        environment.lowPower = false
        // Both shells enter through public immutable facts, with no platform-derived multipliers.
        policy = BandwidthPolicy(demand: BandwidthDemand(width: 1920, height: 1080, fps: 60, codec: .h264),
                                 path: verified, environment: environment)
    }

    mutating func tick(_ edit: (inout BandwidthHealth) -> Void = { _ in }) -> BandwidthDecision {
        var window = BandwidthHealth(start: now, end: now + 1, generation: policy.path.generation)
        now += 1
        window.rttSamplesMs = [1, 1, 1, 1, 1]
        window.expectedPackets = 1_000
        window.lostPackets = 0
        window.recoveredFrames = 0
        window.totalFrames = 60
        window.unrecoverableFrames = 0
        window.gapMs = 16
        window.localQueueMs = 0
        window.decoderBacklog = false
        window.encodedKbps = Double(policy.appliedKbps)
        window.receivedIPKbps = Double(policy.appliedKbps) * 1.1
        window.jitterP95Ms = 0.5
        window.risingQueue = false
        edit(&window)
        let result = policy.evaluate(window)
        decisions.append(result)
        return result
    }

    mutating func run(_ seconds: Int, edit: (inout BandwidthHealth) -> Void = { _ in }) {
        for _ in 0..<seconds { _ = tick(edit) }
    }

    mutating func apply() throws {
        let request = try #require(policy.pending)
        policy.recordOutcome(.accepted, for: request)
        let confirmed = policy.confirmApplied(request)
        #expect(confirmed)
    }

    mutating func distress() {
        run(3) { $0.lostPackets = 20; $0.gapMs = 80 }
    }
}

struct BandwidthPolicyTests {
    @Test(arguments: BandwidthReplay.Client.allCases)
    func startRatesAndLowData(client: BandwidthReplay.Client) {
        #expect(BandwidthReplay(client: client).policy.baseKbps == 40_000)
        #expect(BandwidthReplay(client: client, interface: .cellular).policy.baseKbps == 20_000)
        #expect(BandwidthReplay(client: client, constrained: true).policy.baseKbps == 9_000)
        #expect(BandwidthReplay(client: client, interface: .cellular, constrained: true).policy.baseKbps == 9_000)
    }

    @Test func demandUsesAcceptedCodecAndBoundsRatherThanRememberedRates() {
        let path = BandwidthReplay().policy.path
        var demand = BandwidthDemand(width: 1920, height: 1080, fps: 120, codec: .hevc, hdr: true)
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) > 40_000)
        demand.fps = 60
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) == 32_000)
        demand.codec = .h264
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) == 40_000)
        demand.encoderCeilingKbps = 25_000
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) == 25_000)
        demand.customKbps = 10_000
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) == 10_000)
        demand.dataCeilingKbps = 2_000
        #expect(BandwidthPolicy.startRate(demand: demand, path: path) == 2_000)
    }

    @Test func identicalPublicClientReplays() {
        var mac = BandwidthReplay(client: .mac)
        var ios = BandwidthReplay(client: .ios)
        for _ in 0..<120 {
            let macDecision = mac.tick()
            #expect(ios.tick() == macDecision)
            if let request = mac.policy.pending { mac.policy.recordOutcome(.deferred, for: request) }
            if let request = ios.policy.pending { ios.policy.recordOutcome(.deferred, for: request) }
        }
        #expect(mac.policy.pending?.rateKbps == 44_000)
        #expect(mac.policy.appliedKbps == 40_000)
    }

    @Test func noPHYStillEarnsDoubleStartThroughBoundedTrials() throws {
        var replay = BandwidthReplay()
        for _ in 0..<8 {
            replay.run(120)
            if replay.policy.pending != nil { try replay.apply() }
        }
        #expect(replay.policy.appliedKbps == 80_000)
    }

    @Test func staticMissingNaNAndReorderedObservations() {
        var replay = BandwidthReplay()
        replay.run(300) { $0.encodedKbps = 100 }
        #expect(replay.policy.pending == nil)
        replay.run(300) { $0.rttSamplesMs = [] }
        #expect(replay.policy.pending == nil)
        replay.run(300) { $0.rttSamplesMs = [.nan] }
        #expect(replay.policy.pending == nil)
        replay.run(120) { $0.reorderedPackets = 3 }
        #expect(replay.policy.pending?.rateKbps == 44_000)
    }

    @Test func thresholdEqualityAndSparseCoverage() {
        var replay = BandwidthReplay()
        replay.run(120) { $0.coverage = 0.89 }
        #expect(replay.policy.cleanSeconds == 0)
        replay.run(119) { $0.coverage = 0.9 }
        #expect(replay.policy.pending == nil)
        _ = replay.tick { $0.coverage = 0.9 }
        #expect(replay.policy.pending?.rateKbps == 44_000)
        var loss = BandwidthReplay()
        loss.run(120) { $0.lostPackets = 1 }
        #expect(loss.policy.pending == nil)
    }

    @Test func distressCutsWithinThreeSecondsAndFreezesBaseline() throws {
        var replay = BandwidthReplay()
        replay.run(10)
        let baseline = replay.policy.baselineMs
        replay.run(2) { $0.rttSamplesMs = [12, 12, 12]; $0.gapMs = 80 }
        #expect(replay.policy.pending == nil)
        _ = replay.tick { $0.rttSamplesMs = [12, 12, 12]; $0.gapMs = 80 }
        #expect(replay.policy.pending?.rateKbps == 24_000)
        #expect(replay.policy.baselineMs == baseline)
        try replay.apply()
        replay.run(299)
        #expect(replay.policy.pending == nil)
        _ = replay.tick()
        #expect(replay.policy.pending?.rateKbps == 26_400)
    }

    @Test func localDecoderTroubleAndIsolatedGapDoNotCut() {
        var replay = BandwidthReplay()
        replay.run(20) { $0.decoderBacklog = true; $0.localQueueMs = 12; $0.gapMs = 150 }
        #expect(replay.policy.pending == nil)
        replay.run(20)
        _ = replay.tick { $0.gapMs = 150; $0.lostPackets = 20 }
        replay.run(20)
        #expect(replay.policy.pending == nil)
    }

    @Test func failedTrialsRollbackImmediatelyWithFiniteCappedRetry() throws {
        var replay = BandwidthReplay()
        replay.distress()
        try replay.apply()
        for _ in 0..<5 {
            replay.run(Int(replay.policy.retrySeconds))
            try replay.apply()
            replay.distress()
            #expect(replay.policy.pending == nil)
            replay.run(Int(BandwidthFlapGuard.minDwellSeconds) - 3) { $0.lostPackets = 20; $0.gapMs = 80 }
            #expect(replay.policy.pending?.reason == .rollback)
            try replay.apply()
        }
        #expect(replay.policy.retrySeconds == 2_400)
        replay.run(2_400)
        #expect(replay.policy.pending?.reason == .recovery)
    }

    @Test func handoffAndSameInterfaceReplacementDiscardOldEvidence() throws {
        var replay = BandwidthReplay()
        replay.run(120)
        let old = try #require(replay.policy.pending)
        var path = replay.policy.path
        path.generation += 1
        path.interface = .cellular
        replay.policy.replacePath(path)
        #expect(replay.policy.baselineMs == nil)
        let handoff = replay.tick()
        #expect(handoff.request?.rateKbps == 20_000)
        let staleApplied = replay.policy.confirmApplied(old)
        #expect(staleApplied == false)
        try replay.apply()
        path.generation += 1
        path.constrained = true
        replay.policy.replacePath(path)
        let constrained = replay.tick()
        #expect(constrained.request?.rateKbps == 9_000)
    }

    @Test func thermalAndForegroundRecoveryUseOnlyCleanActiveTime() {
        var replay = BandwidthReplay()
        var environment = BandwidthEnvironment()
        environment.thermal = .serious
        environment.lowPower = false
        replay.policy.setEnvironment(environment)
        replay.run(120)
        #expect(replay.policy.pending == nil)
        environment.thermal = .nominal
        replay.policy.setEnvironment(environment)
        replay.run(299)
        #expect(replay.policy.pending == nil)
        _ = replay.tick()
        #expect(replay.policy.pending != nil)
        replay.policy.stop()
        replay.run(500)
        #expect(replay.policy.pending == nil)
    }

    @Test func highPropagationDelayAndCellularDoNotEarnUnprovenHeadroom() {
        var distant = BandwidthReplay()
        distant.run(300) { $0.rttSamplesMs = [60, 60, 61, 61] }
        #expect(distant.policy.pending == nil)
        #expect(distant.policy.appliedKbps == 40_000)
        var cellular = BandwidthReplay(interface: .cellular)
        cellular.run(300)
        #expect(cellular.policy.pending == nil)
    }

    @Test func staleResetAndBackwardClockCannotAccrueCleanTime() throws {
        var replay = BandwidthReplay()
        replay.run(10)
        let old = try #require(replay.decisions[0].window)
        let stale = replay.policy.evaluate(old)
        #expect(stale.reason == .missingEvidence)
        #expect(replay.policy.cleanSeconds == 0)
        replay.run(119)
        _ = replay.tick { $0.counterReset = true }
        #expect(replay.policy.cleanSeconds == 0)
        _ = replay.tick { $0.end = .nan }
        #expect(replay.policy.pending == nil)
    }

    @Test func deferredAndRejectedNeverChangeAppliedRate() throws {
        var replay = BandwidthReplay()
        replay.distress()
        let request = try #require(replay.policy.pending)
        for outcome in [BandwidthActuatorOutcome.deferred, .rejected] {
            replay.policy.recordOutcome(outcome, for: request)
            let confirmed = replay.policy.confirmApplied(request)
            #expect(confirmed == false)
            #expect(replay.policy.appliedKbps == 40_000)
        }
    }

    @Test func ledgerRoundTripPreservesUnknownProbes() throws {
        var replay = BandwidthReplay()
        let decision = replay.tick { $0.receivedIPKbps = nil; $0.parityMargin = nil }
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(BandwidthDecision.self, from: data)
        #expect(decoded == decision)
        #expect(decoded.path.phyMbps == nil)
        #expect(decoded.window?.receivedIPKbps == nil)
    }
}

struct BandwidthBoundaryTests {
    @Test func serializationCannotChangeDecisions() throws {
        var exporting = BandwidthReplay()
        var disabled = BandwidthReplay()
        for _ in 0..<120 {
            let recorded = exporting.tick()
            _ = try JSONEncoder().encode(recorded)
            let unrecorded = disabled.tick()
            #expect(recorded == unrecorded)
        }
    }

    @Test func macCompatibilityRetainsConfiguredRouteBoostsAndRadioGate() {
        let settings = RouteBitratePolicy.Settings(wiredBoost: 2, wifiBoost: 1.5,
                                                   wiredCapKbps: 500_000, capKbps: 300_000)
        let launch = BitrateDecision(mode: .highestQuality, dialKbps: 100_000,
                                     codecMultiplier: 0.8, boost: 2, radioGatePhyMbps: nil)
        let wired = RouteBitratePolicy.ask(launch, route: .wired, settings: settings)
        #expect(wired.kbps == 160_000 && wired.boost == 2)
        let wifi = RouteBitratePolicy.onRoute(launch, route: .wifi, phyRateMbps: 200, settings: settings)
        #expect(RouteBitratePolicy.ask(wifi, route: .wifi, settings: settings).kbps == 70_000)
    }

    @Test func constrainedRecoveryAndSaverNeverExceedTheirCeiling() throws {
        var replay = BandwidthReplay(constrained: true)
        replay.distress()
        #expect(replay.policy.pending?.rateKbps == 5_400)
        try replay.apply()
        replay.run(300)
        #expect(replay.policy.pending?.rateKbps == 5_940)
        let path = replay.policy.path
        var demand = BandwidthDemand(width: 1920, height: 1080, fps: 60, codec: .h264)
        demand.saver = true
        var ordinary = path
        ordinary.constrained = false
        #expect(BandwidthPolicy.startRate(demand: demand, path: ordinary) == 20_000)
    }

    @Test func backgroundNeverLearnsAndReturnRequalifies() {
        var replay = BandwidthReplay()
        replay.run(119)
        var environment = BandwidthEnvironment()
        environment.thermal = .nominal
        environment.lowPower = false
        environment.foreground = false
        replay.policy.setEnvironment(environment)
        replay.run(600)
        #expect(replay.policy.activeSeconds == 119)
        #expect(replay.policy.pending == nil)
        environment.foreground = true
        replay.policy.setEnvironment(environment)
        replay.run(119)
        #expect(replay.policy.pending == nil)
        _ = replay.tick()
        #expect(replay.policy.pending?.rateKbps == 44_000)
    }

    @Test func staleTrainCannotShortenQualificationAndGoodTrainIsOnlyARung() {
        var replay = BandwidthReplay()
        replay.run(119) {
            $0.train = BandwidthTrainEvidence(distinctFrames: 3, firstAt: 0, lastAt: 1,
                                             p20IPKbps: 500_000, maximumToMinimumRatio: 1.2)
        }
        #expect(replay.policy.pending == nil)
        var corroborated = BandwidthReplay()
        corroborated.run(60) {
            $0.train = BandwidthTrainEvidence(distinctFrames: 3, firstAt: $0.end - 1, lastAt: $0.end,
                                             p20IPKbps: 500_000, maximumToMinimumRatio: 1.2)
        }
        #expect(corroborated.policy.pending?.rateKbps == 48_000)
    }

    @Test func counterRolloverResetAndReorderCreditCannotBecomeLoss() {
        let first = BandwidthCounterSample(expected: 100, lost: 2, generation: 1, at: 0)
        let second = BandwidthCounterSample(expected: 1_100, lost: 3, generation: 1, at: 1)
        #expect(second.delta(since: first)?.expected == 1_000)
        #expect(second.delta(since: first)?.lost == 1)
        let reordered = BandwidthCounterSample(expected: 1_100, lost: 1, generation: 1, at: 1)
        #expect(reordered.delta(since: first) == nil)
        let rolled = BandwidthCounterSample(expected: .max, lost: .max, generation: 1, at: 0)
        #expect(second.delta(since: rolled) == nil)
        let replaced = BandwidthCounterSample(expected: 1_100, lost: 3, generation: 2, at: 1)
        #expect(replaced.delta(since: first) == nil)
    }

    @Test func invalidNumbersStayAbsentInLedger() throws {
        var replay = BandwidthReplay()
        let invalid = replay.tick { $0.rttSamplesMs = [.nan] }
        #expect(invalid.window == nil)
        #expect(throws: Never.self) { _ = try JSONEncoder().encode(invalid) }
    }

    @Test func defaultPathAndUnknownCostCannotAuthorizePromotion() {
        var replay = BandwidthReplay()
        var path = replay.policy.path
        path.source = .defaultPath
        replay.policy.replacePath(path)
        replay.run(240)
        #expect(replay.policy.pending == nil)
        path.source = .destination
        path.expensive = nil
        replay.policy.replacePath(path)
        replay.run(240)
        #expect(replay.policy.pending == nil)
    }

    @Test func repeatedSevereEpisodesCutButFECDoesNotHideDamage() {
        var replay = BandwidthReplay()
        _ = replay.tick { $0.unrecoverableFrames = 1; $0.lostPackets = 20 }
        replay.run(5)
        _ = replay.tick { $0.unrecoverableFrames = 1; $0.lostPackets = 20 }
        #expect(replay.policy.pending?.rateKbps == 24_000)
        var fec = BandwidthReplay()
        fec.run(240) { $0.recoveredFrames = 1 }
        #expect(fec.policy.pending == nil)
    }

    @Test func lowPowerChangesNothingAndPoorRadioHintsNeverGiveUp() throws {
        var replay = BandwidthReplay()
        var environment = BandwidthEnvironment()
        environment.thermal = .nominal
        environment.lowPower = true
        replay.policy.setEnvironment(environment)
        replay.run(120)
        #expect(replay.policy.pending?.rateKbps == 44_000)
        replay = BandwidthReplay()
        var path = replay.policy.path
        path.linkQuality = .minimal
        path.radio = .lte
        replay.policy.replacePath(path)
        replay.run(120)
        #expect(replay.policy.pending?.rateKbps == 44_000)
    }
}

struct BandwidthNegotiationTests {
    @Test func unknownAndCellularPathsNeverMasqueradeAsLocal() {
        #expect(BandwidthPath(observedAt: 0).needsConservativePacketSize)
        let cellular = BandwidthReplay(interface: .cellular).policy.path
        #expect(cellular.needsConservativePacketSize)
        #expect(BandwidthReplay().policy.path.needsConservativePacketSize == false)
    }

    @Test(arguments: [9_000, 20_000, 40_000])
    func intendedRequestPreservesPacketAndFECBounds(rate: Int) throws {
        let packet = StreamPathMTU.advertisedPacketSize(configured: 1392, isRemote: true, mtu: 1280)
        let config = BackendStreamConfig(width: 1920, height: 1080, fps: 60, bitrate: Int32(rate),
            packetSize: Int32(packet), streamingRemotely: 1, audioConfiguration: 0x00010002,
            supportedVideoFormats: StreamProtocol.VIDEO_FORMAT_H264, clientRefreshRateX100: 6000,
            colorSpace: 1, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16), remoteInputAesIv: [UInt8](repeating: 0, count: 16))
        let builder = SdpBuilder(config: config, videoPort: 47998, urlSafeAddr: "192.0.2.1",
            addrFamilyToken: "IPv4", negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H264,
            encryptionFeaturesEnabled: 0)
        let sdp = try #require(String(data: builder.build(), encoding: .utf8))
        #expect(sdp.contains("a=x-ml-video.configuredBitrateKbps:\(rate) "))
        #expect(sdp.contains("a=x-nv-video[0].packetSize:1024 "))
        #expect(sdp.contains("a=x-nv-vqos[0].fec.enable:1 "))
        #expect(sdp.contains("a=x-nv-vqos[0].fec.minRequiredFecPackets:2 "))
    }
}
