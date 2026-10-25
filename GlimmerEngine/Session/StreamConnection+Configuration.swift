// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Encoder sizes for ordinary and Low Data Mode play, both from the client's listed-mode resolver.
public struct DataModeSizes: Sendable, Equatable {
    public let fullWidth: Int, fullHeight: Int
    public let lowDataWidth: Int, lowDataHeight: Int

    public init(fullWidth: Int, fullHeight: Int, lowDataWidth: Int, lowDataHeight: Int) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.lowDataWidth = lowDataWidth
        self.lowDataHeight = lowDataHeight
    }

    func size(lowData: Bool) -> (width: Int, height: Int) {
        lowData ? (lowDataWidth, lowDataHeight) : (fullWidth, fullHeight)
    }
}

extension StreamConnection {
    public struct Configuration: Sendable {
        let request: StreamRequest
        let routeMTU: Int?

        /// Advertise only formats the supplied video sink can decode. Route observations are supplied by the shell.
        public init(width: Int, height: Int, fps: Int, bitrateKbps: Int,
                    videoFormats: VideoFormats, audio: AudioConfig = .stereo,
                    remote: Bool = false, routeMTU: Int? = nil, changeResolution: Bool = true,
                    resumeResolutionChange: Bool = false, dataModeSizes: DataModeSizes? = nil) {
            var request = StreamRequest(width: width, height: height, fps: fps,
                                        bitrateKbps: bitrateKbps, videoFormats: videoFormats)
            request.changeResolution = changeResolution
            request.resumeResolutionChange = resumeResolutionChange
            request.dataModeSizes = dataModeSizes
            request.audio = audio
            request.remoteness = remote ? .remote : .local
            self.request = request
            self.routeMTU = routeMTU
        }

        func validate() throws {
            guard StreamSizeBounds.width.contains(request.width), StreamSizeBounds.height.contains(request.height),
                  StreamSizeBounds.fps.contains(request.fps), request.bitrateKbps > 0,
                  Int32(exactly: request.bitrateKbps) != nil, !request.videoFormats.isEmpty,
                  routeMTU.map({ $0 > 0 }) ?? true else { throw Failure.invalidConfiguration }
        }

        func backendConfig(launch: LaunchResponse) throws -> BackendStreamConfig {
            try launch.validateSessionKey()
            return BackendStreamConfig(width: Int32(request.width), height: Int32(request.height),
                fps: Int32(request.fps), bitrate: Int32(request.bitrateKbps),
                packetSize: Int32(StreamPathMTU.advertisedPacketSize(configured: request.packetSize,
                    isRemote: request.remoteness == .remote, mtu: routeMTU)),
                streamingRemotely: request.remoteness.cValue, audioConfiguration: request.audio.cValue,
                supportedVideoFormats: request.videoFormats.rawValue, clientRefreshRateX100: Int32(request.fps * 100),
                colorSpace: request.colorSpace.cValue, colorRange: request.colorRange.cValue, encryptionFlags: 0,
                remoteInputAesKey: [UInt8](launch.gcmKey), remoteInputAesIv: [UInt8](launch.gcmKeyId))
        }
    }
}
