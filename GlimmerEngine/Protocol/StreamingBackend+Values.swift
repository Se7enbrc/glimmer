// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Analog state for one controller frame (triggers + both sticks), grouped so
/// `sendMultiController` mirrors LiSendMultiControllerEvent without a 9-argument
/// signature.
package struct GamepadAnalog: Sendable, Equatable {
    package var leftTrigger: UInt8
    package var rightTrigger: UInt8
    package var leftStickX: Int16
    package var leftStickY: Int16
    package var rightStickX: Int16
    package var rightStickY: Int16

    package init(leftTrigger: UInt8, rightTrigger: UInt8,
                 leftStickX: Int16, leftStickY: Int16,
                 rightStickX: Int16, rightStickY: Int16) {
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

/// Stream-configuration inputs for `start`. Mirrors STREAM_CONFIGURATION.
/// `remoteInputAesKey`/`remoteInputAesIv` are the 16-byte per-session GCM
/// key/IV-id from the launch handshake (launch.gcmKey / launch.gcmKeyId).
package struct BackendStreamConfig: Sendable {
    package var width: Int32
    package var height: Int32
    package var fps: Int32
    package var bitrate: Int32
    package var packetSize: Int32
    package var streamingRemotely: Int32
    package var audioConfiguration: Int32
    package var supportedVideoFormats: Int32
    package var clientRefreshRateX100: Int32
    package var colorSpace: Int32
    package var colorRange: Int32
    package var encryptionFlags: Int32
    /// Exactly 16 bytes.
    package var remoteInputAesKey: [UInt8]
    /// Exactly 16 bytes.
    package var remoteInputAesIv: [UInt8]

    package init(
        width: Int32, height: Int32, fps: Int32, bitrate: Int32,
        packetSize: Int32, streamingRemotely: Int32, audioConfiguration: Int32,
        supportedVideoFormats: Int32, clientRefreshRateX100: Int32,
        colorSpace: Int32, colorRange: Int32, encryptionFlags: Int32,
        remoteInputAesKey: [UInt8], remoteInputAesIv: [UInt8]
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.packetSize = packetSize
        self.streamingRemotely = streamingRemotely
        self.audioConfiguration = audioConfiguration
        self.supportedVideoFormats = supportedVideoFormats
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.encryptionFlags = encryptionFlags
        self.remoteInputAesKey = remoteInputAesKey
        self.remoteInputAesIv = remoteInputAesIv
    }

    /// True when the connect-time path probe resolved this session to remote. `.auto` is resolved BEFORE this type is
    /// built (StreamSession .makeBackendConfig), so an unresolved STREAM_CFG_AUTO reaching here is treated as local -
    /// the pre-probe behaviour.
    package var isRemoteSession: Bool {
        streamingRemotely == StreamProtocol.STREAM_CFG_REMOTE
    }
}

/// Opus multistream configuration. Mirrors OPUS_MULTISTREAM_CONFIGURATION
/// (AudioDecoder.swift:80-100).
public struct OpusConfig: Sendable {
    public var sampleRate: Int32
    public var channelCount: Int32
    public var streams: Int32
    public var coupledStreams: Int32
    public var samplesPerFrame: Int32
    public var mapping: [UInt8]

    public init(
        sampleRate: Int32, channelCount: Int32, streams: Int32,
        coupledStreams: Int32, samplesPerFrame: Int32, mapping: [UInt8]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
    }
}
