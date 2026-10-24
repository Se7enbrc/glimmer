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

    /// A native-size trial asks for the window's listed size at this profile's refresh cap.
    func screenSize(windowPixels: CGSize, maximumFramesPerSecond: Int) throws -> StreamFormat {
        try Self.native120.resolve(windowPixels: windowPixels,
                                   maximumFramesPerSecond: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond))
    }

    enum Failure: Error { case displayUnavailable, modesUnavailable }

    func resolve(windowPixels: CGSize, maximumFramesPerSecond: Int) throws -> StreamFormat {
        let width = windowPixels.width
        let height = windowPixels.height
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width < CGFloat(Int32.max), height < CGFloat(Int32.max),
              maximumFramesPerSecond >= 30 else { throw Failure.displayUnavailable }
        let target = StreamQuality.encodableSize(width: Int(width), height: Int(height))
        let size = self == .native120
            ? CGSize(width: max(2, target.width), height: max(2, target.height))
            : CGSize(width: 1920, height: 1080)
        guard let mode = StreamDisplayModes.closest(to: size,
            maximumFPS: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond)) else {
            throw Failure.modesUnavailable
        }
        return mode
    }

    @MainActor
    func resolve(surface: StreamSurface) throws -> StreamFormat {
        guard let screen = surface.window?.windowScene?.screen else { throw Failure.displayUnavailable }
        return try resolve(windowPixels: surface.streamPixels, maximumFramesPerSecond: screen.maximumFramesPerSecond)
    }
}

/// One immutable format supplies decoder configuration, session negotiation and display pacing.
struct StreamFormat: Hashable, Sendable {
    let width: Int
    let height: Int
    let fps: Int
    var changeResolution = true

    var continuationFormat: ContinuationFormat {
        ContinuationFormat(width: width, height: height, fps: fps, hdr: false, changeResolution: changeResolution)
    }

    static func continuing(_ launch: StreamLaunch, native: StreamFormat, maximumFPS: Int) -> StreamFormat {
        guard !launch.useScreenSize else { return native }
        let previous = launch.continuing ? launch.previousFormat : launch.startFormat
        if let old = previous?.supported(maximumWidth: 3840, maximumHeight: 2160,
                                                       maximumFPS: maximumFPS, supportsHDR: false) {
            return StreamFormat(width: old.width, height: old.height, fps: old.fps,
                                changeResolution: old.changeResolution)
        }
        var result = native
        result.changeResolution = !launch.continuing
        return result
    }

    var summary: String { "\(width) × \(height) · \(fps) fps" }
    var pacingFPS: Int32 { Int32(fps) }
    func configuration(potentialEDRHeadroom: Double,
                       hardwareFormats: VideoFormats = .hardwareSupported) -> StreamConnection.Configuration {
        let formats = hardwareFormats.forDisplay(potentialEDRHeadroom: potentialEDRHeadroom)
        return StreamConnection.Configuration(width: width, height: height, fps: fps,
            bitrateKbps: StreamProfile.bitrateKbps, videoFormats: formats, audio: .stereo,
            changeResolution: changeResolution, resumeResolutionChange: true)
    }
}
