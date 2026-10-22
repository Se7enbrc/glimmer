// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  RtpAudioReceiver+Decrypt.swift
//
//  The decode hand-off: strip the 12-byte RTP header and hand the opus bytes to the sink,
//  AES-128-CBC decrypted whenever the host offered SS_ENC_AUDIO. Split out of
//  RtpAudioReceiver.swift, which keeps the aesKey/avRiKeyId material.
//

import Foundation
import CommonCrypto

extension RtpAudioReceiver {

    /// Validate ciphertext before it can establish or restart queue order. CBC has
    /// no authentication, but failed padding must never advance the receive cursor.
    /// The normal in-order path still decrypts only once, at the decode hand-off.
    func acceptsAudioPayload(_ buf: [UInt8], count: Int, arrival: UInt64) -> Bool {
        let payload = buf[RtpAudioQueue.fixedRtpHeaderSize..<count]
        guard !payload.isEmpty else { return false }
        guard audioEncryption else { return true }
        guard payload.count.isMultiple(of: kCCBlockSizeAES128) else { return false }
        let sequence = UInt16(buf[2]) << 8 | UInt16(buf[3])
        return !queue.requiresPayloadValidation(sequence: sequence, arrival: arrival)
            || decryptCbc(payload, sequenceNumber: sequence) != nil
    }

    /// Decode one assembled RTP packet: strip the 12-byte RTP header, optionally
    /// AES-CBC decrypt, and hand the opus bytes to the sink (AudioStream.c:162-236).
    func decodePacket(_ packet: [UInt8]) {
        guard packet.count >= RtpAudioQueue.fixedRtpHeaderSize else { return }
        // AV-skew AUDIO half (`av_skew_ms`): the host-timeline RTP (BE bytes
        // 4-7) of the packet about to be scheduled - the one-word store the
        // deferred cross-stream derivation needed (the header is stripped
        // before the decoder, so this hand-off is the last place it exists).
        // UNITS: this clock is NOT 48kHz samples - Sunshine advances it by
        // packetDuration per packet (a 1 tick/ms millisecond clock); the
        // store's measured-rate snap owns the conversion (see AUDIO CLOCK
        // UNITS on AudioVideoSkewStore - the /48 misread was a sawtooth/rebase
        // instrument break). One clock read + an unfair
        // lock at ~200Hz, the same always-live budget as the per-datagram
        // gap counter.
        AudioVideoSkewStore.shared.noteAudioScheduled(
            rtp: UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16
                | UInt32(packet[6]) << 8 | UInt32(packet[7]))
        // A slice, not a copy: the sink reads it in place.
        let payload = packet[RtpAudioQueue.fixedRtpHeaderSize...]

        if audioEncryption {
            // The host's seq lives in the assembled header (host built it BE).
            let seq = UInt16(packet[2]) << 8 | UInt16(packet[3])
            guard let opus = decryptCbc(payload, sequenceNumber: seq) else {
                if !loggedDecryptFailure {
                    loggedDecryptFailure = true
                    AudioDiagnostics.warn("NativeAudio AES-CBC decrypt failed (seq=\(seq)); "
                        + "dropping undecryptable packets, first sighting this session", Self.cat)
                }
                return
            }
            opus.withUnsafeBytes { sink?.decodeAndPlay($0) }
        } else {
            payload.withUnsafeBytes { sink?.decodeAndPlay($0) }
        }
    }

    /// AES-128-CBC decrypt one audio payload (AudioStream.c:178-219) with remoteInputAesKey
    /// and IV = BE32(avRiKeyId &+ seq) plus 12 zero bytes. Strips the host's PKCS7 padding
    /// (Sunshine's cbc_t) so opus never sees it. Returns nil on failure.
    func decryptCbc(_ ciphertext: ArraySlice<UInt8>, sequenceNumber seq: UInt16) -> ArraySlice<UInt8>? {
        guard aesKey.count == kCCKeySizeAES128, !ciphertext.isEmpty,
              ciphertext.count <= Self.maxPacketSize else { return nil }
        var iv = ((avRiKeyId &+ UInt32(seq)).bigEndian, UInt32(0), UInt32(0), UInt32(0))
        var outMoved = 0
        let status = ciphertext.withUnsafeBytes { input in
            aesKey.withUnsafeBytes { key in
                withUnsafeBytes(of: &iv) { ivBytes in
                    decryptScratch.withUnsafeMutableBytes { output in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), key.baseAddress, key.count,
                                ivBytes.baseAddress, input.baseAddress, input.count,
                                output.baseAddress, output.count, &outMoved)
                    }
                }
            }
        }
        // CommonCrypto can return unstripped data for invalid padding. Sunshine's
        // PKCS7 payload must lose between one byte and one complete block.
        guard status == kCCSuccess, outMoved > 0, outMoved < ciphertext.count,
              ciphertext.count - outMoved <= kCCBlockSizeAES128 else { return nil }
        return decryptScratch[..<outMoved]
    }
}
