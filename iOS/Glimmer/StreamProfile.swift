// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

enum StreamProfile: String, CaseIterable, Identifiable, Sendable {
    case fullHD60, fullHD120, native120

    static let bitrateKbps = 20_000

    var id: Self { self }
    var summary: String { "\(label) · \(Self.bitrateKbps / 1000) Mbps requested" }
    var label: String {
        switch self {
        case .fullHD60: "1080p · 60 fps"
        case .fullHD120: "1080p · 120 fps"
        case .native120: "Native · 120 fps"
        }
    }

    enum Failure: Error { case displayUnavailable }

    func resolve(nativePixels: CGSize, maximumFramesPerSecond: Int) throws -> StreamFormat {
        guard nativePixels.width.isFinite, nativePixels.height.isFinite,
              nativePixels.width > 0, nativePixels.height > 0,
              nativePixels.width < CGFloat(Int32.max), nativePixels.height < CGFloat(Int32.max),
              maximumFramesPerSecond > 0 else { throw Failure.displayUnavailable }
        let native = self == .native120
        let size = StreamQuality.encodableSize(
            width: native ? Int(max(nativePixels.width, nativePixels.height)) : 1920,
            height: native ? Int(min(nativePixels.width, nativePixels.height)) : 1080)
        return StreamFormat(width: size.width, height: size.height,
                            fps: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond))
    }
}

/// One immutable format supplies decoder configuration, session negotiation and display pacing.
struct StreamFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let fps: Int

    var summary: String { "\(width) × \(height) · \(fps) fps" }
    var pacingFPS: Int32 { Int32(fps) }
    var configuration: StreamConnection.Configuration {
        StreamConnection.Configuration(width: width, height: height, fps: fps, bitrateKbps: StreamProfile.bitrateKbps,
                                       videoFormats: .h264, audio: .stereo)
    }
}
