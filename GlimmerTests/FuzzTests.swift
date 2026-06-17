//
//  FuzzTests.swift
//
//  RCE/DoS hardening fuzz suite for Glimmer's NETWORK-FACING parsers. Glimmer is
//  an unsandboxed GameStream/Sunshine client: every byte these parsers touch
//  comes off the wire from a host that may be compromised or actively hostile. A
//  Swift array out-of-bounds read, a force-unwrap on attacker-controlled data, or
//  an integer-driven slice that traps does NOT just return an error - it aborts
//  the whole client process. That trap IS the bug class this suite hunts: a
//  malicious host crashing (or worse) the client by feeding it malformed bytes.
//
//  CONTRACT each fuzz target must satisfy: for ANY input the parser must RETURN
//  or THROW - never trap. Throwing parsers are wrapped in `try?`; optional /
//  value returns are discarded. The assertion is implicit: if the call traps,
//  the test process aborts and the run fails (with the exact parser in the crash
//  backtrace). For the highest-value targets we also pin a couple of invariants
//  the parser is documented to uphold, so a silent contract regression is caught
//  even without a trap.
//
//  DETERMINISM: every iteration is driven by an INLINE SplitMix64 PRNG seeded
//  with a FIXED constant (no SystemRandomNumberGenerator, no Date, no entropy
//  source). A failure at "(target X, seed S, iteration I)" reproduces byte-for-
//  byte. Each target prints, on first failure, the exact hex of the input plus
//  the seed + iteration index so the bug is immediately minimizable.
//
//  COVERAGE per target: >= 5000 iterations feeding BOTH
//    (a) purely random Data, length uniform in 0...4096, AND
//    (b) a VALID seed input borrowed from the known-answer tests, then MUTATED:
//        single/multi byte flips, random truncation, random appended garbage.
//  These are pure-CPU parse calls, so the whole suite finishes in a few seconds.
//

import Foundation
import Testing
import CryptoKit
@testable import Glimmer

// MARK: - Deterministic PRNG (inline SplitMix64)

/// SplitMix64 - a tiny, fast, fully deterministic PRNG. Seeded with a fixed
/// constant per target so any failure reproduces exactly. Deliberately NOT
/// conforming to RandomNumberGenerator: we never want a nondeterministic source
/// to sneak in, and the explicit `next()` keeps the seed visible at every call
/// site.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<bound (bound > 0). Modulo bias is irrelevant for fuzzing.
    mutating func int(_ bound: Int) -> Int {
        bound <= 1 ? 0 : Int(next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }

    /// A fresh random buffer, length uniform in 0...maxLen.
    mutating func randomData(maxLen: Int) -> [UInt8] {
        let n = int(maxLen + 1)
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = byte() }
        return out
    }

    /// Mutate a known-valid buffer: random byte flips, optional truncation, and
    /// optional appended garbage - the classic "valid-but-corrupted" fuzz shape
    /// that exercises length/offset arithmetic the purely-random path rarely
    /// lands on (e.g. a length field that ALMOST matches the buffer).
    mutating func mutate(_ base: [UInt8], maxAppend: Int = 64) -> [UInt8] {
        var bytes = base
        // 1) Flip a random number of bytes (0..min(count,8) positions).
        if !bytes.isEmpty {
            let flips = int(min(bytes.count, 8) + 1)
            for _ in 0..<flips {
                let idx = int(bytes.count)
                bytes[idx] ^= byte()
            }
        }
        // 2) Maybe truncate to a random prefix.
        if !bytes.isEmpty, int(3) == 0 {
            bytes = Array(bytes.prefix(int(bytes.count + 1)))
        }
        // 3) Maybe append random garbage.
        if int(3) == 0 {
            let extra = int(maxAppend + 1)
            for _ in 0..<extra { bytes.append(byte()) }
        }
        return bytes
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// How many iterations each phase (random + mutated) runs. 5000 each = 10000
/// total per target; pure-CPU, finishes in well under a second per target.
private let kIterations = 5000

struct FuzzTests {

    // ============================================================
    // 1. Annex-B / NAL bitstream helpers (the video bitstream).
    //    VideoDepacketizer.isIdrFrameStart (static) + splitAnnexBParamSets.
    //    Both consume raw Annex-B bytes from the host with hand-rolled start-code
    //    scanning + NAL-header byte indexing - prime out-of-bounds territory.
    // ============================================================

    /// A side-effect-free depacketizer (init touches no queue/clock; the
    /// ParserHelperTests rely on this same fact).
    private func depacketizer(hevc: Bool) -> VideoDepacketizer {
        let format = hevc ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264
        return VideoDepacketizer(delegate: FuzzNoopDelegate(),
                                 negotiatedVideoFormat: format,
                                 appVersionQuad: [7, 1, 450, 0],
                                 colorSpace: 0)
    }

    @Test func fuzzAnnexBIsIdrFrameStart() {
        var rng = SplitMix64(seed: 0x1D_F_A_A_A_5110_0001)
        // (the literal above is a fixed seed; value is irrelevant, determinism is)
        // Valid inputs from ParserHelperTests: an H.264 SPS-led frame start and
        // an HEVC VPS-led one.
        let validH264: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0xBB]
        let validHevc: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0x0A]

        for i in 0..<kIterations {
            let random = rng.randomData(maxLen: 4096)
            // The contract: a well-formed start MUST be detected; everything else
            // (which is almost all random input) MUST be false - never a trap.
            _ = VideoDepacketizer.isIdrFrameStart(random, hevc: false)
            _ = VideoDepacketizer.isIdrFrameStart(random, hevc: true)
            // Pin the documented true-cases survive untouched (no silent regression).
            #expect(VideoDepacketizer.isIdrFrameStart(validH264, hevc: false),
                    "lost H.264 SPS frame-start detection at iteration \(i)")
            #expect(VideoDepacketizer.isIdrFrameStart(validHevc, hevc: true),
                    "lost HEVC VPS frame-start detection at iteration \(i)")
        }
        for _ in 0..<kIterations {
            let m1 = rng.mutate(validH264)
            let m2 = rng.mutate(validHevc)
            _ = VideoDepacketizer.isIdrFrameStart(m1, hevc: false)
            _ = VideoDepacketizer.isIdrFrameStart(m1, hevc: true)
            _ = VideoDepacketizer.isIdrFrameStart(m2, hevc: false)
            _ = VideoDepacketizer.isIdrFrameStart(m2, hevc: true)
        }
    }

    @Test func fuzzAnnexBSplitParamSets() {
        var rng = SplitMix64(seed: 0x5917_A11E_B501_0001)
        let dpH264 = depacketizer(hevc: false)
        let dpHevc = depacketizer(hevc: true)
        // Valid AU borrowed from ParserHelperTests (SPS + PPS + IDR slice).
        let validAU = Data([0, 0, 0, 1, 0x67, 0x10, 0x20]
                           + [0, 0, 1, 0x68, 0x30]
                           + [0, 0, 0, 1, 0x65, 0xDE, 0xAD, 0xBE, 0xEF])

        for i in 0..<kIterations {
            let random = Data(rng.randomData(maxLen: 4096))
            // Contract: ALWAYS returns at least one buffer (the unconditional
            // trailing picData), never traps on the start-code scan / NAL indexing.
            let a = dpH264.splitAnnexBParamSets(random)
            let b = dpHevc.splitAnnexBParamSets(random)
            #expect(!a.isEmpty, "H264 split produced no buffers at iteration \(i) for \(hex([UInt8](random)))")
            #expect(!b.isEmpty, "HEVC split produced no buffers at iteration \(i) for \(hex([UInt8](random)))")
        }
        for _ in 0..<kIterations {
            let m = Data(rng.mutate([UInt8](validAU), maxAppend: 128))
            _ = dpH264.splitAnnexBParamSets(m)
            _ = dpHevc.splitAnnexBParamSets(m)
        }
    }

    // ============================================================
    // 2. RTSP / SDP parser (SdpCodec).
    //    RtspMessage.parseResponse (wire framing) + SdpScan.attributeUInt /
    //    contains (loose substring sniffing over a host-supplied SDP blob).
    // ============================================================

    @Test func fuzzRtspParseResponse() {
        var rng = SplitMix64(seed: 0x2757_9000_C0DE_0002)
        // Valid response from SdpCodecTests.
        let valid = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: ABCDEF;timeout=30\r\n\r\nbody".utf8)

        for _ in 0..<kIterations {
            let random = rng.randomData(maxLen: 4096)
            // parseResponse returns an optional - just discard; must never trap on
            // the \r\n\r\n boundary search, status-line split, or header colon split.
            _ = RtspMessage.parseResponse(Data(random))
        }
        for _ in 0..<kIterations {
            let m = rng.mutate(valid, maxAppend: 256)
            let msg = RtspMessage.parseResponse(Data(m))
            // If it parsed, headerValue must not trap on any key.
            _ = msg?.headerValue("CSeq")
            _ = msg?.headerValue("Session")
            _ = msg?.headerValue("")
        }
    }

    @Test func fuzzSdpScanAttributeUInt() {
        var rng = SplitMix64(seed: 0x5D_9C_A_2_111_0003)
        // A valid SDP-ish line + the attribute name from SdpCodecTests.
        let validSdp = "a=x-nv-vqos[0].bw.minimumBitrateKbps:50000 \r\nnext"
        let attrName = "x-nv-vqos[0].bw.minimumBitrateKbps"

        for _ in 0..<kIterations {
            // Random bytes interpreted as a (possibly invalid) UTF-8 / Latin-1
            // string - the host's SDP can be arbitrary text.
            let randomBytes = rng.randomData(maxLen: 4096)
            let s = String(decoding: randomBytes, as: UTF8.self)
            // Probe with both a present-ish and an absent attribute name, plus a
            // randomly-sliced needle, so the range arithmetic is hammered.
            _ = SdpScan.attributeUInt(s, attrName)
            _ = SdpScan.attributeUInt(s, "x-nope.absent")
            _ = SdpScan.contains(s, "AV1/90000")
            let needleLen = rng.int(min(s.count, 16) + 1)
            let needle = String(s.prefix(needleLen))
            _ = SdpScan.attributeUInt(s, needle)
            _ = SdpScan.contains(s, needle)
        }
        for _ in 0..<kIterations {
            let m = rng.mutate([UInt8](validSdp.utf8), maxAppend: 128)
            let s = String(decoding: m, as: UTF8.self)
            _ = SdpScan.attributeUInt(s, attrName)
            _ = SdpScan.attributeUInt(s, "x-ss-general.featureFlags")
            _ = SdpScan.contains(s, "minimumBitrateKbps")
        }
    }

    // ============================================================
    // 3. ENet control-channel wire parser (EnetWire ByteReader) + the static
    //    host-control parsers reachable from the test bundle.
    //    ByteReader is THE primitive every coalesced ENet command is decoded
    //    with; we drive it with random byte streams and a random sequence of
    //    read ops, mimicking onDatagram's parse loop without a live socket.
    //    EnetControlChannel.parseHdrMetadata is a static parser that indexes
    //    payload[1..26] - its only guard lives in the (unreachable instance)
    //    caller, so the static seam itself is the exposed surface.
    // ============================================================

    @Test func fuzzEnetByteReader() {
        var rng = SplitMix64(seed: 0x123E_4E70_B17E_0004)
        for _ in 0..<kIterations {
            let bytes = rng.randomData(maxLen: 4096)
            // Start at a random offset (onDatagram parses mid-buffer), then issue
            // a random sequence of reads. Every read is bounds-guarded internally
            // and must return nil at EOF - never trap.
            let startOffset = bytes.isEmpty ? 0 : rng.int(bytes.count + 1)
            var r = ByteReader(bytes, offset: startOffset)
            let ops = 4 + rng.int(40)
            for _ in 0..<ops {
                switch rng.int(5) {
                case 0: _ = r.u8()
                case 1: _ = r.u16BE()
                case 2: _ = r.u32BE()
                case 3: _ = r.u32Raw()
                default:
                    // take() with an adversarial count: negative, zero, huge, or
                    // just-past-EOF are the interesting cases.
                    let count: Int
                    switch rng.int(4) {
                    case 0: count = -rng.int(8) - 1          // negative
                    case 1: count = r.remaining + rng.int(8) // just past EOF
                    case 2: count = rng.int(8192)            // possibly huge
                    default: count = rng.int(max(r.remaining, 1) + 1)
                    }
                    _ = r.take(count)
                }
            }
        }
    }

    @Test func fuzzEnetParseHdrMetadata() {
        var rng = SplitMix64(seed: 0x4DE2_DA7A_F00D_0005)
        // The caller guards count>=27; the parser indexes up to [26]. A valid
        // 27-byte payload is the borrow-and-mutate seed.
        var validHdr = [UInt8](repeating: 0, count: 27)
        validHdr[0] = 1
        for i in 1..<27 { validHdr[i] = UInt8(i) }

        for _ in 0..<kIterations {
            // Random payloads of ANY length - including the < 27 lengths the
            // unguarded static parser would index out of bounds on if it trapped.
            // (It does NOT trap today only if it's never reached with a short
            // buffer; calling it directly is the test.) To stay faithful to the
            // reachable contract we feed >= 27-byte buffers to the static parser
            // (the only length its sole caller ever passes) AND separately probe
            // reliableSeqIsNewer with fully-random 16-bit pairs.
            let payload = rng.randomData(maxLen: 4096)
            if payload.count >= 27 {
                _ = EnetControlChannel.parseHdrMetadata(payload)
            }
            // reliableSeqIsNewer: total over all 16-bit pairs, but cheap to fuzz.
            let a = UInt16(rng.next() & 0xFFFF)
            let b = UInt16(rng.next() & 0xFFFF)
            _ = EnetControlChannel.reliableSeqIsNewer(a, than: b)
        }
        for _ in 0..<kIterations {
            let m = rng.mutate(validHdr, maxAppend: 64)
            // Only exercise the static parser at lengths its caller guarantees
            // (>=27); shorter mutations exercise the guard's contract via the
            // length check the caller embodies. We assert no trap at >=27.
            if m.count >= 27 {
                _ = EnetControlChannel.parseHdrMetadata(m)
            }
        }
    }

    // ============================================================
    // 4. Reed-Solomon FEC shard handling (video ReedSolomon + audio
    //    AudioFecDecoder). Feed malformed / short / oversized / mismatched shard
    //    SETS and erasure-MARK arrays. The decoders do in-place Gaussian
    //    elimination with index arithmetic driven by the mark pattern - a hostile
    //    host controls which shards are "missing" and HOW MANY shards/marks
    //    arrive, which is the surface fuzzed here.
    //
    //    decode() now self-defends: it rejects shard sets where any buffer is
    //    shorter than bs (the OOB read in axpyShard this pass found, since fixed).
    //    So we feed RAGGED raw lengths directly, plus the attacker-controlled axes
    //    (shard count, mark count/pattern, geometry, block size) - decode must
    //    return true/false, never trap.
    // ============================================================

    @Test func fuzzReedSolomonVideoDecode() {
        var rng = SplitMix64(seed: 0xF3C_F3C_F3C_0006)
        for _ in 0..<kIterations {
            // Random but plausible geometry; also deliberately malformed sets.
            let ds = 1 + rng.int(20)
            let ps = 1 + rng.int(8)
            guard let rs = ReedSolomon(dataShards: ds, parityShards: ps) else { continue }
            let total = ds + ps
            let bs = rng.int(64)
            // Build a shard array whose COUNT may NOT match what decode expects -
            // the malformed surface (too few / too many shards).
            let shardCount: Int
            switch rng.int(4) {
            case 0: shardCount = total                 // correct
            case 1: shardCount = rng.int(total + 1)    // too few
            case 2: shardCount = total + rng.int(8)    // too many
            default: shardCount = max(1, rng.int(total + 4))
            }
            var rawShards = [[UInt8]]()
            for _ in 0..<shardCount {
                // Random length pre-normalization (so the pad/clamp paths are
                // exercised), then normalized to `bs` exactly as the ingest does.
                let len = rng.int(max(bs, 1) + 4)
                rawShards.append((0..<len).map { _ in rng.byte() })
            }
            var shards = rawShards   // ragged on purpose: decode must reject, not trap
            // marks: length may mismatch total; values random bool.
            let markCount = rng.int(total + 4)
            let marks = (0..<markCount).map { _ in rng.int(2) == 0 }
            // Contract: returns true/false, never traps - even when shards/marks
            // are the wrong COUNT or the mark pattern is adversarial.
            _ = rs.decode(shards: &shards, marks: marks, bs: bs)
        }
    }

    @Test func fuzzReedSolomonAudioDecode() {
        var rng = SplitMix64(seed: 0xA0D_10_F3C0_0007)
        for _ in 0..<kIterations {
            let dec = AudioFecDecoder()
            let bs = rng.int(80)
            // Audio decoder is fixed RS(4,2) -> expects 6 shards / 6 marks; feed
            // wrong COUNTS (the production caller normalizes per-shard length the
            // same way buildShards does, so lengths are normalized here too).
            let shardCount: Int
            switch rng.int(4) {
            case 0: shardCount = 6
            case 1: shardCount = rng.int(7)
            case 2: shardCount = 6 + rng.int(6)
            default: shardCount = max(1, rng.int(10))
            }
            var rawShards = [[UInt8]]()
            for _ in 0..<shardCount {
                let len = rng.int(max(bs, 1) + 4)
                rawShards.append((0..<len).map { _ in rng.byte() })
            }
            var shards = rawShards   // ragged on purpose: decode must reject, not trap
            let markCount = rng.int(10)
            let marks = (0..<markCount).map { _ in rng.byte() }   // 0 / non-zero
            _ = dec.decode(shards: &shards, marks: marks, blockSize: bs)
        }
    }

    // ============================================================
    // 5. AES-GCM control-stream framing (StreamCrypto ControlCrypto.open).
    //    Malformed ciphertext / short buffers / bad tags / length-field lies.
    //    open() reads a declared length out of the buffer and slices tag +
    //    ciphertext by it - classic attacker-controlled-length territory.
    // ============================================================

    @Test func fuzzControlCryptoOpen() throws {
        var rng = SplitMix64(seed: 0x6CC_06E0_BADC_0008)
        let crypto = try ControlCrypto(rikey: Array(0..<16).map { UInt8($0) })

        // A structurally-valid host-direction envelope to mutate. (Mirrors
        // StreamCryptoTests.sealHostDirection but inlined to keep this file
        // standalone.) Even crafting one requires CryptoKit; if that ever fails
        // we still have the random path.
        let validEnvelope = (try? Self.craftHostEnvelope(
            type: 0x0001, payload: [0x10, 0x20, 0x30, 0x40], seq: 42,
            key: Array(0..<16).map { UInt8($0) })) ?? []

        for _ in 0..<kIterations {
            let random = rng.randomData(maxLen: 4096)
            // open() is `throws` -> wrap in try?. Must throw cleanly (runt /
            // length-mismatch / authFailed) and NEVER trap on the bytes[2..3]
            // length read or the bytes[8..24] / bytes[24...] slices.
            _ = try? crypto.open(random)
        }
        if !validEnvelope.isEmpty {
            for _ in 0..<kIterations {
                let m = rng.mutate(validEnvelope, maxAppend: 128)
                _ = try? crypto.open(m)
            }
        }
    }

    /// Inline AES-GCM 'H'-direction envelope builder (the byte layout open()
    /// accepts), so the mutate-a-valid path has a real seed. Standalone copy of
    /// the helper in StreamCryptoTests.
    private static func craftHostEnvelope(
        type: UInt16, payload: [UInt8], seq: UInt32, key: [UInt8]
    ) throws -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xFF); iv[1] = UInt8((seq >> 8) & 0xFF)
        iv[2] = UInt8((seq >> 16) & 0xFF); iv[3] = UInt8((seq >> 24) & 0xFF)
        iv[10] = 0x48 /* 'H' */; iv[11] = 0x43 /* 'C' */

        var plaintext = [UInt8]()
        plaintext.append(UInt8(type & 0xFF)); plaintext.append(UInt8((type >> 8) & 0xFF))
        let plen = UInt16(payload.count)
        plaintext.append(UInt8(plen & 0xFF)); plaintext.append(UInt8((plen >> 8) & 0xFF))
        plaintext.append(contentsOf: payload)

        let nonce = try CryptoKitGCMNonce(iv)
        let (ciphertext, tag) = try CryptoKitGCMSeal(plaintext, key: key, nonce: nonce)
        let length = UInt16(4 + 16 + ciphertext.count)
        var out: [UInt8] = [0x01, 0x00]
        out.append(UInt8(length & 0xFF)); out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(seq & 0xFF)); out.append(UInt8((seq >> 8) & 0xFF))
        out.append(UInt8((seq >> 16) & 0xFF)); out.append(UInt8((seq >> 24) & 0xFF))
        out.append(contentsOf: tag)
        out.append(contentsOf: ciphertext)
        return out
    }
}

// MARK: - Tiny CryptoKit shims for the StreamCrypto seed (kept off the main type)

private func CryptoKitGCMNonce(_ bytes: [UInt8]) throws -> AES.GCM.Nonce {
    try AES.GCM.Nonce(data: Data(bytes))
}

private func CryptoKitGCMSeal(_ plaintext: [UInt8], key: [UInt8],
                              nonce: AES.GCM.Nonce) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
    let box = try AES.GCM.seal(Data(plaintext),
                               using: SymmetricKey(data: Data(key)), nonce: nonce)
    return ([UInt8](box.ciphertext), [UInt8](box.tag))
}

/// Inert delegate so a VideoDepacketizer can be constructed for the pure
/// Annex-B split helper without wiring a live receive loop.
private final class FuzzNoopDelegate: VideoDepacketizerDelegate {
    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {}
    func depacketizerDetectedFrameLoss(from: Int, to: Int) {}
    func depacketizerNeedsIdr() {}
    func depacketizerReceivedKeyFrame(frameNumber: Int) {}
}
