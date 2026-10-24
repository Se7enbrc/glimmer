// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

enum StreamProfile: String, CaseIterable, Identifiable, Sendable {
    case native120, fullHD60, fullHD120

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

    func resolve(windowPixels: CGSize, maximumFramesPerSecond: Int) throws -> StreamFormat {
        let width = windowPixels.width
        let height = windowPixels.height
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width < CGFloat(Int32.max), height < CGFloat(Int32.max),
              maximumFramesPerSecond >= 30 else { throw Failure.displayUnavailable }
        let portrait = height > width
        let ceiling = self == .native120
            ? CGSize(width: StreamSizeBounds.width.upperBound, height: StreamSizeBounds.height.upperBound)
            : CGSize(width: portrait ? 1080 : 1920, height: portrait ? 1920 : 1080)
        let minimumScale = max(CGFloat(StreamSizeBounds.width.lowerBound) / width,
                               CGFloat(StreamSizeBounds.height.lowerBound) / height)
        let maximumScale = min(ceiling.width / width, ceiling.height / height)
        let scale = min(max(1, minimumScale), maximumScale)
        let size = StreamQuality.encodableSize(
            width: max(StreamSizeBounds.width.lowerBound, Int((width * scale).rounded(.down))),
            height: max(StreamSizeBounds.height.lowerBound, Int((height * scale).rounded(.down))))
        return StreamFormat(width: size.width, height: size.height,
                            fps: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond))
    }

    @MainActor
    func resolve(surface: StreamSurface) throws -> StreamFormat {
        guard let screen = surface.window?.windowScene?.screen else { throw Failure.displayUnavailable }
        if surface.traitCollection.userInterfaceIdiom == .pad {
            let scale = surface.traitCollection.displayScale
            return try resolve(windowPixels: CGSize(width: surface.bounds.width * scale,
                                                     height: surface.bounds.height * scale),
                               maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }
        return try resolve(nativePixels: screen.nativeBounds.size,
                           maximumFramesPerSecond: screen.maximumFramesPerSecond)
    }

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
