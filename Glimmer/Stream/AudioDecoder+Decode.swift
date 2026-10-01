//
//  AudioDecoder+Decode.swift
//
//  The per-packet DECODE path and the `NativeAudioSink` entry points that feed it: Opus decode (or
//  concealment of a lost packet), the demux into the player's non-interleaved format, the meter's backlog
//  gates, and the schedule into `AVAudioPlayerNode`. The engine lifecycle lives in AudioDecoder+Engine.swift.
//

import AVFoundation
import Foundation
import os

extension AudioDecoder {

    // MARK: Per-packet decoding
    //
    // A lost packet is concealed as soon as the queue reports it. Sunshine's Opus is CELT-only, which
    // carries no in-band FEC, so the next packet holds nothing to recover the gap from.

    /// Decode one packet, or conceal one lost frame when `packet` is nil, and schedule the result.
    func decodeCore(_ packet: UnsafeRawBufferPointer?) {
        // Hold the state lock for the whole decode so `shutdown()` can't release the decoder mid-call.
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown, let decoder, let fmt = inputFormat else { return }

        // `AudioFrame` interval - decode + scheduleBuffer, one per 5 ms packet; cheap enough not to gate.
        let audioSignpostID = OSSignposter.audio.makeSignpostID()
        let audioIntervalState = OSSignposter.audio.beginInterval(
            "AudioFrame",
            id: audioSignpostID,
            "bytes=\(packet?.count ?? 0, privacy: .public)")
        defer {
            OSSignposter.audio.endInterval("AudioFrame", audioIntervalState)
        }
        decodeOneFrame(decoder: decoder, fmt: fmt, packet: packet)
    }

    /// Decode one frame (or conceal one) and, if it produced samples, demux + meter + schedule it into the
    /// player. Returns true iff a frame was scheduled. Caller holds `stateLock`.
    @discardableResult
    private func decodeOneFrame(decoder: OpusDecoder, fmt: AVAudioFormat, packet: UnsafeRawBufferPointer?) -> Bool {
        let frameCount = AVAudioFrameCount(samplesPerFrame)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return false }

        // The decoder writes interleaved float; the player's format is non-interleaved, so decode into a
        // scratch and demux into channelData[i].
        var interleaved = [Float](repeating: 0, count: samplesPerFrame * channelCount)
        let decoded = interleaved.withUnsafeMutableBufferPointer { scratch in
            scratch.baseAddress.map { decoder.decode(packet, into: $0) } ?? 0
        }
        guard decoded > 0 else {
            // A malformed packet, or a loss before any packet: nothing to play.
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
}

// MARK: - NativeAudioSink conformance (Swift-native engine)
//
// Lets RtpAudioReceiver feed the AudioDecoder: `initialize` runs the shared decoder/engine setup, and both
// `decodeAndPlay` (a packet) and `decodeAndPlayPLC` (the queue's `.lostPlaceholder`) run `decodeCore`.
extension AudioDecoder: NativeAudioSink {
    public func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 {
        let chCount = Int(gl_channel_count_from_audio_configuration(audioConfig))
        // `opus` is the layout the PC encodes with (SdpScan.audioLayout). Opus reads
        // one mapping entry per channel, so a short mapping must never reach it.
        guard opus.mapping.count == chCount else {
            log.error("opus layout has \(opus.mapping.count) channels, the stream has \(chCount)")
            return -1
        }
        return initDecoderCore(
            channelCount: chCount,
            sampleRate: opus.sampleRate,
            streams: opus.streams,
            coupledStreams: opus.coupledStreams,
            samplesPerFrame: Int(opus.samplesPerFrame),
            mapping: opus.mapping)
    }

    public func decodeAndPlay(_ opus: [UInt8]) {
        guard !opus.isEmpty else { decodeAndPlayPLC(); return }
        opus.withUnsafeBytes { decodeCore($0) }
    }

    public func decodeAndPlayPLC() {
        decodeCore(nil)
    }

    public func cleanup() {
        shutdown()
    }
}
