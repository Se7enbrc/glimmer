// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamConnection {
    public struct Configuration: Sendable {
        let request: StreamRequest
        let routeMTU: Int?

        /// Advertise only formats the supplied video sink can decode. Route observations are supplied by the shell.
        public init(width: Int, height: Int, fps: Int, bitrateKbps: Int,
                    videoFormats: VideoFormats, audio: AudioConfig = .stereo,
                    remote: Bool = false, routeMTU: Int? = nil) {
            var request = StreamRequest(width: width, height: height, fps: fps,
                                        bitrateKbps: bitrateKbps, videoFormats: videoFormats)
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
            guard launch.gcmKey.count == 16, launch.gcmKeyId.count == 16 else { throw Failure.invalidSessionKey }
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
