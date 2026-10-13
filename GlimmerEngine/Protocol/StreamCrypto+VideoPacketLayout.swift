// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

@usableFromInline package enum VideoPacketLayout {
    @usableFromInline package static let fixedRtpHeaderSize = 12
    /// sizeof(ENC_VIDEO_HEADER): iv[12], frameNumber (u32 LE), tag[16].
    @usableFromInline package static let headerSize = 32
    @usableFromInline package static let ssEncVideo: UInt32 = 0x02

    /// The x-nv-video[0].packetSize to advertise: encrypted video fits ENC_VIDEO_HEADER inside the
    /// configured size, as SdpGenerator.c does, so the datagram on the wire stays the same length.
    @usableFromInline package static func packetSize(_ configured: Int, encryptionFeaturesEnabled: UInt32) -> Int {
        encryptionFeaturesEnabled & ssEncVideo != 0 ? configured - headerSize : configured
    }
}
