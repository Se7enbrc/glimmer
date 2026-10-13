// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation
import CryptoKit

/// Opens Sunshine's encrypted video (VideoStream.c): ENC_VIDEO_HEADER, then the whole RTP packet
/// sealed with AES-128-GCM. CryptoKit takes ~0.8 µs for a 1.4 KB packet (OpenSSL ~0.2 µs), about
/// 1% of a core at 4K240's 14k packets/s, and only when the PC requires encrypted video.
@usableFromInline package final class VideoDecryptor {
    @usableFromInline internal let key: SymmetricKey
    @usableFromInline internal var loggedFailure = false

    @inlinable package init?(key: [UInt8]) {
        guard key.count == 16 else { return nil }
        self.key = SymmetricKey(data: key)
    }

    /// Opens every authenticated RTP packet, including passed frames, so trailing parity reaches
    /// the queue's receive-quality accounting. Returns nil for runts or authentication failures.
    @inlinable package func open(_ datagram: UnsafeRawBufferPointer) -> [UInt8]? {
        guard datagram.count - VideoPacketLayout.headerSize >= VideoPacketLayout.fixedRtpHeaderSize else { return nil }
        guard let nonce = try? AES.GCM.Nonce(data: UnsafeRawBufferPointer(rebasing: datagram[0..<12])),
              let box = try? AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: UnsafeRawBufferPointer(rebasing: datagram[VideoPacketLayout.headerSize...]),
                tag: UnsafeRawBufferPointer(rebasing: datagram[16..<VideoPacketLayout.headerSize])),
              let packet = try? AES.GCM.open(box, using: key) else {
            if !loggedFailure {
                loggedFailure = true
                let frameNumber = UInt32(littleEndian: datagram.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                Diag.warn("NativeVideo dropping video packets that fail decryption, first sighting "
                    + "(frame \(frameNumber))", "NativeVideo")
            }
            return nil
        }
        return [UInt8](packet)
    }
}
