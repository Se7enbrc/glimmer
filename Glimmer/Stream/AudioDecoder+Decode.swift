// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Decode, conceal and schedule audio packets. Engine lifecycle lives in AudioDecoder+Engine.swift.

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
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount),
              let channelData = pcm.floatChannelData else { return false }

        // The decoder writes interleaved float; the player's format is non-interleaved, so decode into the
        // scratch and demux into channelData[i]. 7.1's reorder swaps surround pairs into AVAudio's layout.
        let channels = channelCount
        let reorder = outputReorder
        if decodeScratch.count != samplesPerFrame * channels {
            decodeScratch = [Float](repeating: 0, count: samplesPerFrame * channels)
        }
        let decoded = decodeScratch.withUnsafeMutableBufferPointer { scratch -> Int in
            guard let interleaved = scratch.baseAddress else { return 0 }
            let frames = decoder.decodeOrConceal(packet, into: interleaved)
            for source in 0..<channels {
                let dst = channelData[reorder?[source] ?? source]
                for i in 0..<frames { dst[i] = interleaved[i * channels + source] }
            }
            return frames
        }
        guard decoded > 0 else {
            // A loss, or a packet that won't decode, before any good packet: nothing to play.
            return false
        }
        pcm.frameLength = AVAudioFrameCount(decoded)

        // A drained player no longer ends at the skipped block's predecessor.
        if packetSplice.hasPendingJoin, audioMeterLock.withLock({ playoutDrained }) {
            packetSplice = AudioPacketSplice()
        }
        // Drop excess audio to bound latency, retaining its start to smooth the next join.
        let decodedFrames = UInt64(decoded)
        if meterRegisterScheduleOrOverrun(frames: decodedFrames) {
            packetSplice.skip(pcm)
            // Engine recovery stays on this path, serialized against shutdown.
            recoverIfPlayoutStalled()
            return false
        }
        packetSplice.apply(to: pcm)
        playerNode.scheduleBuffer(pcm, completionHandler: { [weak self] in
            self?.meterCompleteOnePlayout(frames: decodedFrames)
        })
        // Rebuild the cushion after a drain; steady playback takes the cheap primed path.
        maybePrime(format: fmt)
        // Drives the drift resampler's PI loop (self-rate-limited to ~4Hz) + the
        // 1Hz audio-state gauge. The resampler replaced the decode-path micro-stretch.
        publishAudioState()
        return true
    }
}

/// Overlap the first millisecond of skipped audio with the next scheduled block.
/// This preserves the old boundary without adding samples or changing steady playback.
struct AudioPacketSplice {
    private var skipped: AVAudioPCMBuffer?
    var hasPendingJoin: Bool { skipped != nil }

    mutating func skip(_ buffer: AVAudioPCMBuffer) {
        if skipped == nil { skipped = buffer }
    }

    mutating func apply(to buffer: AVAudioPCMBuffer) {
        defer { skipped = nil }
        guard let skipped, skipped.format == buffer.format,
              let old = skipped.floatChannelData, let new = buffer.floatChannelData else { return }
        let count = min(Int(skipped.frameLength), Int(buffer.frameLength), Int(buffer.format.sampleRate / 1000))
        guard count > 1 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<count {
                let weight = Float(frame) / Float(count - 1)
                new[channel][frame] = old[channel][frame] * (1 - weight) + new[channel][frame] * weight
            }
        }
    }
}

// MARK: - NativeAudioSink conformance (Swift-native engine)
//
// Lets RtpAudioReceiver feed the AudioDecoder: `initialize` runs the shared decoder/engine setup, and both
// `decodeAndPlay` (a packet) and `decodeAndPlayPLC` (the queue's `.lostPlaceholder`) run `decodeCore`.
extension AudioDecoder: NativeAudioSink {
    public func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 {
        let chCount = AudioConfig.channelCount(packed: audioConfig)
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

    public func decodeAndPlay(_ opus: UnsafeRawBufferPointer) {
        guard !opus.isEmpty else { decodeAndPlayPLC(); return }
        decodeCore(opus)
    }

    public func decodeAndPlayPLC() {
        decodeCore(nil)
    }

    public func cleanup() {
        shutdown()
    }
}
