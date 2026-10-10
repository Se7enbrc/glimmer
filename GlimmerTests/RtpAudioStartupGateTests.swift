//
//  RtpAudioStartupGateTests.swift
//
//  The backlog-aware startup gate, driven through the datagram path with the pacing clock's
//  zero moved instead of waiting: paced, burst-then-drain, and the quiet-socket resolution.
//

import Foundation
import Testing
@testable import Glimmer

struct RtpAudioStartupGateTests {

    /// Every field is read or written while holding the lock.
    private final class RecordingSink: NativeAudioSink, @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: UnsafeRawBufferPointer) { lock.lock(); packets.append(Array(opus)); lock.unlock() }
        func decodeAndPlayPLC() {}
        func cleanup() {}
        func firstBytes() -> [UInt8] { lock.lock(); defer { lock.unlock() }; return packets.compactMap(\.first) }
    }

    private static func receiver(_ sink: NativeAudioSink, encrypted: Bool = false) -> RtpAudioReceiver {
        RtpAudioReceiver(host: .ipv4(.loopback), audioPort: 0, pingPayload: [], audioPacketDuration: 5,
                         opusConfig: RtspHandshakeResult.defaultOpusConfig, audioConfig: 0,
                         audioEncryption: encrypted, aesKey: EnetFixture.key,
                         aesIvId: [UInt8](repeating: 0, count: 16), sink: sink)
    }

    private static func feed(_ receiver: RtpAudioReceiver, _ sequences: some Sequence<UInt16>) {
        for seq in sequences {
            let packet: [UInt8] = [0x80, RtpAudioQueue.payloadTypeAudio, UInt8(seq >> 8), UInt8(truncatingIfNeeded: seq),
                                   0, 0, 0, UInt8(truncatingIfNeeded: seq &* 5), 0, 0, 0, 1,
                                   UInt8(truncatingIfNeeded: seq), 0xAA, 0xBB]
            receiver.handleDatagram(packet, count: packet.count)
        }
    }

    /// The queue withholds the first FEC block while it synchronises, so decodes start here.
    private static let firstSyncedSeq = UInt8(RtpAudioQueue.dataShards)

    /// Move the pacing zero back so the window reads as having taken `ms` of wall clock.
    private static func age(_ receiver: RtpAudioReceiver, byMs ms: UInt64) {
        receiver.startupFirstDataNanos &-= ms * 1_000_000
    }

    @Test func liveFlowLatchesPacedAndDecodesEverything() {
        let sink = RecordingSink()
        let receiver = Self.receiver(sink)
        Self.feed(receiver, [0])
        Self.age(receiver, byMs: 1000)
        Self.feed(receiver, 1...20)
        #expect(receiver.startupPacing == .decided)
        #expect(!receiver.startupVerdictBurst)
        #expect(receiver.startupDroppedPackets == 0)
        #expect(sink.firstBytes() == Array(Self.firstSyncedSeq...20))
    }

    @Test func backlogFlushDrainsToTheLiveEdgeAndReportsIt() throws {
        let sink = RecordingSink()
        let receiver = Self.receiver(sink)
        receiver.pingsSent.store(7_301)
        receiver.pingStartTimeUs.store(DispatchTime.now().uptimeNanoseconds / 1000 - 250_000)
        Self.feed(receiver, 0...20) // a whole window lands at once: the decision packet is stale
        #expect(receiver.startupPacing == .draining)
        Self.feed(receiver, [21])
        Self.age(receiver, byMs: 500) // arrivals fall back to real time
        Self.feed(receiver, [22])
        #expect(receiver.startupPacing == .decided)
        #expect(receiver.startupVerdictBurst)
        #expect(receiver.startupDroppedPackets == 2)
        #expect(sink.firstBytes() == Array(Self.firstSyncedSeq...19) + [22])
        let row = try #require(LogStore.shared.snapshot().last { $0.message.contains("\"pings\":7301") })
        #expect(row.message.hasPrefix("EVENT {\"event\":\"audio_ttf\",\"ping_to_rtp_ms\":"))
        #expect(row.message.contains("\"startup\":\"burst\",\"dropped_ms\":10,"))
    }

    @Test func quietSocketResolvesOnlyOnceAudioHasStarted() {
        let receiver = Self.receiver(RecordingSink())
        receiver.resolveStartupPacingOnIdle()
        #expect(receiver.startupPacing == .measuring)
        Self.feed(receiver, [0, 1])
        receiver.resolveStartupPacingOnIdle()
        #expect(receiver.startupPacing == .decided)
        #expect(!receiver.startupVerdictBurst)
    }

    @Test func quietSocketEndsADrainAsABurst() {
        let receiver = Self.receiver(RecordingSink())
        Self.feed(receiver, 0...20)
        #expect(receiver.startupPacing == .draining)
        receiver.resolveStartupPacingOnIdle()
        #expect(receiver.startupPacing == .decided)
        #expect(receiver.startupVerdictBurst)
    }

    /// Parity carries no audio-ms: never counted while measuring, stale while draining.
    @Test func parityFollowsTheGatePhase() {
        let receiver = Self.receiver(RecordingSink())
        Self.feed(receiver, [0])
        #expect(!receiver.updateStartupPacing(isData: false))
        #expect(receiver.startupDataPackets == 0)
        receiver.startupPacing = .draining
        #expect(receiver.updateStartupPacing(isData: false))
        receiver.startupPacing = .decided
        #expect(!receiver.updateStartupPacing(isData: true))
    }

    @Test func undecryptableAudioNeverReachesTheSink() {
        let sink = RecordingSink()
        let receiver = Self.receiver(sink, encrypted: true)
        let packet: [UInt8] = [0x80, RtpAudioQueue.payloadTypeAudio, 0, 1, 0, 0, 0, 5, 0, 0, 0, 1]
            + [UInt8](repeating: 0x5A, count: 16)
        receiver.decodePacket(packet)
        receiver.decodePacket(packet)
        #expect(sink.firstBytes().isEmpty)
        #expect(receiver.loggedDecryptFailure)
    }
}
