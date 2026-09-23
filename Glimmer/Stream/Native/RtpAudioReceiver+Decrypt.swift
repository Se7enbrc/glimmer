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
        let payload = Array(packet[RtpAudioQueue.fixedRtpHeaderSize...])

        if audioEncryption {
            // The host's seq lives in the assembled header (host built it BE).
            let seq = UInt16(packet[2]) << 8 | UInt16(packet[3])
            guard let opus = decryptCbc(payload, sequenceNumber: seq) else {
                if !loggedDecryptFailure {
                    loggedDecryptFailure = true
                    Diag.warn("NativeAudio AES-CBC decrypt failed (seq=\(seq)); "
                        + "dropping undecryptable packets, first sighting this session", Self.cat)
                }
                return
            }
            sink?.decodeAndPlay(opus)
        } else {
            sink?.decodeAndPlay(payload)
        }
    }

    /// AES-128-CBC decrypt one audio payload (AudioStream.c:178-219) with remoteInputAesKey
    /// and IV = BE32(avRiKeyId &+ seq) plus 12 zero bytes. Strips the host's PKCS7 padding
    /// (Sunshine's cbc_t) so opus never sees it. Returns nil on failure.
    func decryptCbc(_ ciphertext: [UInt8], sequenceNumber seq: UInt16) -> [UInt8]? {
        guard aesKey.count == 16, !ciphertext.isEmpty else { return nil }

        // IV first 4 bytes = BE32(avRiKeyId &+ seq); remaining 12 bytes zero.
        let ivSeq = avRiKeyId &+ UInt32(seq)
        var iv = [UInt8](repeating: 0, count: 16)
        iv[0] = UInt8((ivSeq >> 24) & 0xFF)
        iv[1] = UInt8((ivSeq >> 16) & 0xFF)
        iv[2] = UInt8((ivSeq >> 8) & 0xFF)
        iv[3] = UInt8(ivSeq & 0xFF)

        return AesCbc.decryptPkcs7(ciphertext, key: aesKey, iv: iv)
    }
}

/// AES-128-CBC via CommonCrypto with PKCS7 padding removal, the host's audio
/// cipher (moonlight's OpenSSL/mbedTLS decrypt strips the same padding).
private enum AesCbc {
    static func decryptPkcs7(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        // One spare block, like the C's ROUND_TO_PKCS7_PADDED_LEN buffer.
        let outCapacity = ciphertext.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outCapacity)
        var outMoved = 0
        let status = ciphertext.withUnsafeBytes { ctPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    out.withUnsafeMutableBytes { outPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                ctPtr.baseAddress, ciphertext.count,
                                outPtr.baseAddress, outPtr.count,
                                &outMoved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<outMoved])
    }
}
