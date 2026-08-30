//
//  AudioDecoder+Decode.swift
//
//  The per-packet DECODE path and the `NativeAudioSink` entry points that feed
//  it: opus decode (with the ★6 in-band FEC gap recovery below), the channel
//  demux/reorder into the player's non-interleaved format, the meter's backlog
//  gates, and the schedule into `AVAudioPlayerNode`. Split from
//  AudioDecoder.swift - same idiom as the FramePacer split, to keep that file
//  under the length limit; the engine lifecycle it hands off to lives in
//  AudioDecoder+Engine.swift.
//
//  Split cost (the ControllerForwarder.swift note, applied here): stored
//  properties cannot live in an extension, so the opus/format state and the
//  `pendingFecGap` latch stay on `AudioDecoder` and are `internal` rather than
//  `private` for the methods here to reach. See the property docs in
//  AudioDecoder.swift for the locking rationale each one carries.
//

import AVFoundation
import Foundation
import os

extension AudioDecoder {

    // MARK: Per-sample decoding

    // MARK: - ★6 Opus in-band FEC on decode (lossy-link resilience)
    //
    // Opus carries low-bitrate in-band FEC: a frame lost on the wire can be
    // RECONSTRUCTED from the FEC payload the NEXT packet carries, which is
    // higher fidelity than plain PLC (NULL-input concealment) for the same gap.
    // The standard opus PLC-with-FEC pattern is: on a detected gap, when the
    // next real packet arrives, decode it ONCE with `decode_fec=1` at the gap's
    // frame size to recover the missing frame, schedule that, THEN decode the
    // same packet normally with `decode_fec=0` for its own frame.
    //
    // Composition with the existing PLC path: the queue emits a `.lostPlaceholder`
    // per missing data shard, which lands here as `decodeAndPlayPLC()`. Rather
    // than immediately fabricate a NULL-input PLC frame, that call now ARMS a
    // single pending-gap latch (`pendingFecGap`) and produces NO frame yet. The
    // gap frame is then minted EXACTLY ONCE, by whichever resolves first:
    //   • the next REAL packet (`decodeCore`) - FEC recovery (decode_fec=1); if
    //     that packet happens to carry no FEC, opus still returns a concealed
    //     frame for the gap, so we always get one frame, never zero; or
    //   • a SECOND consecutive `decodeAndPlayPLC()` - we can't defer a gap past
    //     one packet without adding latency, so the standing gap is flushed with
    //     a NULL-input PLC frame and the new gap re-arms.
    // Bounded to ONE recovered/concealed frame per gap (no double-count: the
    // latch is cleared the instant the gap frame is scheduled). On a CLEAN link
    // `pendingFecGap` is never armed, so this whole path is inert - `decodeCore`
    // takes the plain `decode_fec=0` branch with zero added work or latency.

    /// The shared decode → schedule path for a REAL opus packet. If a wire gap is
    /// pending (`pendingFecGap`), first mint the gap's concealment frame from
    /// THIS packet's opus in-band FEC (`decode_fec=1`) before decoding the packet
    /// itself (`decode_fec=0`) - the standard opus PLC-with-FEC pattern. Used by
    /// the Swift-native `NativeAudioSink` path.
    func decodeCore(input: UnsafePointer<UInt8>?, length: Int32) {
        // Hold the state lock for the whole decode so `shutdown()` can't
        // destroy the opus decoder mid-call. The work is microseconds at
        // 200 Hz on a single audio thread, so the contention cost is nil.
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let decoder, let fmt = inputFormat else { return }

        // `AudioFrame` interval - covers opus decode + scheduleBuffer. One
        // per network-delivered opus packet, on whatever audio receive thread
        // we're called on. Cheap enough at 200 Hz (5 ms packets) that we don't
        // gate it.
        let audioSignpostID = OSSignposter.audio.makeSignpostID()
        let audioIntervalState = OSSignposter.audio.beginInterval(
            "AudioFrame",
            id: audioSignpostID,
            "bytes=\(length, privacy: .public)")
        defer {
            OSSignposter.audio.endInterval("AudioFrame", audioIntervalState)
        }

        // ★6: a gap is owed a frame. Recover it from THIS packet's in-band FEC
        // (decode_fec=1) BEFORE the packet's own frame, so the recovered frame
        // keeps its place in the timeline. One frame per gap; latch cleared
        // either way so it can't double-mint.
        if pendingFecGap {
            pendingFecGap = false
            _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                               input: input, length: length, decodeFec: 1)
        }

        _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                           input: input, length: length, decodeFec: 0)
    }

    /// Decode exactly one opus frame (or conceal one) and, if it produced
    /// samples, demux + meter + schedule it into the player. `decodeFec=1` with a
    /// real `input` recovers the PREVIOUS (lost) frame from this packet's in-band
    /// FEC; `decodeFec=0` decodes the packet's own frame; `input==nil` (length 0)
    /// is NULL-input PLC. Returns true iff a frame was scheduled. Caller holds
    /// `stateLock`.
    @discardableResult
    private func decodeOneFrame(decoder: OpaquePointer, fmt: AVAudioFormat,
                                input: UnsafePointer<UInt8>?, length: Int32,
                                decodeFec: Int32) -> Bool {
        let frameCount = AVAudioFrameCount(samplesPerFrame)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return false }

        // opus_multistream_decode_float writes interleaved float; we declared
        // a non-interleaved format. Use a small interleaved scratch and then
        // demux into channelData[i]. A NULL input + frameSize triggers PLC; a
        // real input with decode_fec=1 reconstructs the prior lost frame.
        var interleaved = [Float](repeating: 0, count: samplesPerFrame * channelCount)
        let decoded = opus_multistream_decode_float(
            decoder, input, length,
            &interleaved, Int32(samplesPerFrame), decodeFec
        )
        guard decoded > 0 else {
            // -1..-7 are recoverable; just drop the packet.
            return false
        }
        pcm.frameLength = AVAudioFrameCount(decoded)

        guard let channelData = pcm.floatChannelData else { return false }
        if let reorder = outputReorder {
            // 7.1 path - swap surround pairs into AVAudio's expected layout.
            for srcChannel in 0..<channelCount {
                let dstChannel = reorder[srcChannel]
                let dst = channelData[dstChannel]
                for i in 0..<Int(decoded) {
                    dst[i] = interleaved[i * channelCount + srcChannel]
                }
            }
        } else {
            for channel in 0..<channelCount {
                let dst = channelData[channel]
                for i in 0..<Int(decoded) {
                    dst[i] = interleaved[i * channelCount + channel]
                }
            }
        }

        // P1 AUDIO meter: account this buffer for the buffer-fill / under-run /
        // over-run / A/V-drift signals. Two backlog guards run first, both dropping
        // this freshly-decoded buffer (which is the NEWEST packet; since an
        // AVAudioPlayerNode buffer can't be pulled once scheduled, declining to queue
        // the incoming packet trims the scheduled-ahead backlog by exactly one 5ms
        // packet - the same net effect as dropping the oldest, with no reschedule
        // churn): (a) the steady-state TRIM-TOWARD-TARGET, which clips the backlog
        // back to the adaptive cushion target so it can't pin high, and (b) the hard
        // OVER-RUN ceiling backstop for genuinely bad links. Both keep latency bounded.
        let decodedFrames = UInt64(decoded)
        if meterRegisterScheduleOrOverrun(frames: decodedFrames) {
            // Trimmed/over-run: do not schedule (keeps A/V latency bounded). If the
            // meter latched a playout STALL under this drop (node consuming nothing
            // while every arrival hits the backlog gates), rebuild the output path
            // now - this is the stateLock-serialized decode path, the one place AV
            // calls are safe against shutdown (`recoverIfPlayoutStalled`).
            recoverIfPlayoutStalled()
            return false
        }
        playerNode.scheduleBuffer(pcm, completionHandler: { [weak self] in
            self?.meterCompleteOnePlayout(frames: decodedFrames)
        })
        // PRE-ROLL / RE-PRIME: now that this buffer is queued (into a paused node
        // only before the cold-start prime), decide whether the cushion is deep
        // enough to (re)declare playback primed - and, on a re-prime whose grace
        // expired clumpless, schedule the silence backfill (which needs the node
        // format, hence the parameter). No-op once primed, so this stays one lock
        // + a compare on the steady-state path.
        maybePrime(format: fmt)
        // Drives the drift resampler's PI loop (self-rate-limited to ~4Hz) + the
        // 1Hz audio-state gauge. The resampler replaced the decode-path micro-stretch.
        publishAudioState()
        return true
    }

    /// ★6: a wire gap occurred (the queue emitted a `.lostPlaceholder`). Arm the
    /// pending-gap latch so the NEXT real packet recovers this frame via opus
    /// in-band FEC. If a gap is ALREADY pending (a second consecutive loss), we
    /// can't defer further without adding latency, so flush the standing gap with
    /// a NULL-input PLC frame now and re-arm for this one. Caller is the
    /// `NativeAudioSink` PLC entry point. Holds `stateLock` for the decoder.
    func concealGap() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let decoder, let fmt = inputFormat else { return }
        if pendingFecGap {
            // Two gaps in a row: the first can't wait for FEC any longer. Conceal
            // it with NULL-input PLC, then this new gap takes the pending slot.
            _ = decodeOneFrame(decoder: decoder, fmt: fmt,
                               input: nil, length: 0, decodeFec: 0)
        }
        pendingFecGap = true
    }
}

// MARK: - NativeAudioSink conformance (Swift-native engine)
//
// Lets RtpAudioReceiver feed the AudioDecoder. `initialize` reuses the shared
// opus/engine setup; `decodeAndPlay([UInt8])` runs the shared decodeCore (with
// opus in-band FEC recovery ahead of the packet when a gap is pending, ★6), and
// `decodeAndPlayPLC()` arms the pending-gap latch (`concealGap`) so the gap's
// concealment frame is minted by FEC or, failing that, by NULL-input PLC.
extension AudioDecoder: NativeAudioSink {
    public func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 {
        let chCount = Int(gl_channel_count_from_audio_configuration(audioConfig))
        // ★5 - NEGOTIATED multistream config. The passed `opus` carries the
        // STEREO defaults (RtspHandshakeResult.defaultOpusConfig); the RTSP
        // SETUP-audio response does NOT send an explicit per-channel opus
        // stream layout. As in moonlight-common-c (AudioStream.c's
        // `opusConfigArray`, indexed by the negotiated AudioConfiguration), the
        // host encodes the opus multistream packets per the channel count it was
        // asked for, and the client derives {streams, coupledStreams, mapping}
        // from that same channel count. Feeding the hardcoded stereo
        // {streams:1, coupled:1, mapping:[0,1]} into a 6/8-channel decoder
        // produces inconsistent surround (the bug). Resolve the real config
        // from `chCount` so a 5.1/7.1 stream decodes coherently; stereo is
        // unchanged (config(forChannels:2) == the stereo default).
        let cfg = Self.opusMultistreamConfig(forChannels: chCount, fallback: opus)
        return initDecoderCore(
            channelCount: chCount,
            sampleRate: opus.sampleRate,
            streams: cfg.streams,
            coupledStreams: cfg.coupledStreams,
            samplesPerFrame: Int(opus.samplesPerFrame),
            mapping: cfg.mapping)
    }

    /// Canonical opus MULTISTREAM config (streams / coupledStreams / channel
    /// mapping) for a channel count, mirroring moonlight-common-c's
    /// `opusConfigArray` (AudioStream.c). The host builds its multistream
    /// encoder from the SAME table keyed by the negotiated AudioConfiguration,
    /// so these MUST match byte-for-byte or surround decodes to garbage:
    ///   2ch stereo : streams 1, coupled 1, mapping [0,1]
    ///   6ch  5.1   : streams 4, coupled 2, mapping [0,4,1,5,2,3]
    ///   8ch  7.1   : streams 5, coupled 3, mapping [0,6,1,7,2,3,4,5]
    /// The mapping is the opus surround mapping (which opus stream feeds which
    /// output channel); the front L/R + back/side reorder onto Apple's layout
    /// is a SEPARATE, later step (`outputReorder` in `initDecoderCore`). An
    /// unrecognized channel count falls back to the passed config (the stereo
    /// default), padded/trimmed to the channel count - the prior behavior.
    static func opusMultistreamConfig(
        forChannels channels: Int, fallback: OpusConfig
    ) -> (streams: Int32, coupledStreams: Int32, mapping: [UInt8]) {
        switch channels {
        case 2: return (1, 1, [0, 1])
        case 6: return (4, 2, [0, 4, 1, 5, 2, 3])
        case 8: return (5, 3, [0, 6, 1, 7, 2, 3, 4, 5])
        default:
            // The opus mapping array carries `channels` valid entries; pad/trim
            // the fallback so the core sees a consistent layout.
            var map = fallback.mapping
            if map.count < channels {
                map += [UInt8](repeating: 0, count: channels - map.count)
            }
            return (fallback.streams, fallback.coupledStreams, Array(map.prefix(channels)))
        }
    }

    public func decodeAndPlay(_ opus: [UInt8]) {
        guard !opus.isEmpty else { decodeAndPlayPLC(); return }
        opus.withUnsafeBufferPointer { buf in
            decodeCore(input: buf.baseAddress, length: Int32(buf.count))
        }
    }

    public func decodeAndPlayPLC() {
        // ★6: arm the pending-gap latch so the next real packet recovers this
        // frame via opus in-band FEC (decode_fec=1). The actual concealment
        // frame is minted there, or by `concealGap` itself on a second
        // consecutive loss (NULL-input PLC) - exactly one frame per gap.
        concealGap()
    }

    public func cleanup() {
        shutdown()
    }
}
