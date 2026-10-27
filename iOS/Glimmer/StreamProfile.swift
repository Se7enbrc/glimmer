// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

enum StreamProfile: String, CaseIterable, Identifiable, Sendable {
    case native120, fullHD60, fullHD120

    static let bitrateKbps = 20_000

    var id: Self { self }
    /// Adaptive quality chooses the rate from the connection, so no fixed number is promised.
    func summary(adaptive: Bool) -> String {
        adaptive ? "\(label) · adaptive bitrate" : "\(label) · \(Self.bitrateKbps / 1000) Mbps requested"
    }

    /// Low Data Mode's reduced profile: at most 1080p and 60 fps.
    static let lowData = StreamProfile.fullHD60
    var label: String {
        switch self {
        case .fullHD60: "1080p · 60 fps"
        case .fullHD120: "1080p · 120 fps"
        case .native120: "Native · 120 fps"
        }
    }

    /// A native-size trial asks for the window's listed size at this profile's refresh cap.
    func screenSize(windowPixels: CGSize, maximumFramesPerSecond: Int, requiredFPS: Int? = nil) throws -> StreamFormat {
        try Self.native120.resolve(windowPixels: windowPixels,
                                   maximumFramesPerSecond: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond),
                                   requiredFPS: requiredFPS)
    }

    enum Failure: Error { case displayUnavailable, modesUnavailable }

    func resolve(windowPixels: CGSize, maximumFramesPerSecond: Int, requiredFPS: Int? = nil) throws -> StreamFormat {
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
            maximumFPS: min(self == .fullHD60 ? 60 : 120, maximumFramesPerSecond), requiredFPS: requiredFPS) else {
            throw Failure.modesUnavailable
        }
        return mode
    }

    @MainActor
    func resolve(surface: StreamSurface, preservingFPS: Int? = nil,
                 useScreenSize: Bool = false) throws -> StreamFormat {
        guard let screen = surface.window?.windowScene?.screen else { throw Failure.displayUnavailable }
        let maximumFPS = preservingFPS ?? screen.maximumFramesPerSecond
        if useScreenSize {
            return try screenSize(windowPixels: surface.streamPixels,
                                  maximumFramesPerSecond: maximumFPS, requiredFPS: preservingFPS)
        }
        return try resolve(windowPixels: surface.streamPixels,
                           maximumFramesPerSecond: maximumFPS, requiredFPS: preservingFPS)
    }
}

/// The listed modes a stream uses: its profile's, and the reduced one for Low Data Mode.
struct StreamFormats: Equatable, Sendable {
    let full: StreamFormat
    let lowData: StreamFormat

    init(full: StreamFormat, windowPixels: CGSize, maximumFramesPerSecond: Int) throws {
        self.full = full
        let reduced = try StreamProfile.lowData.resolve(windowPixels: windowPixels,
                                                        maximumFramesPerSecond: maximumFramesPerSecond)
        let smaller = reduced.width * reduced.height < full.width * full.height ? reduced : full
        lowData = StreamFormat(width: smaller.width, height: smaller.height, fps: min(full.fps, reduced.fps),
                               changeResolution: full.changeResolution)
    }

    init(resizing full: StreamFormat) {
        self.full = full
        let reduced = StreamDisplayModes.closest(to: CGSize(width: 1920, height: 1080),
                                                 maximumFPS: full.fps, requiredFPS: full.fps) ?? full
        lowData = reduced.width * reduced.height < full.width * full.height ? reduced : full
    }

    /// Start under Low Data Mode at the reduced mode; either way both sizes ride along for later edges.
    func start(lowData constrained: Bool) -> StreamFormat { constrained ? lowData : full }

    var sizes: DataModeSizes {
        DataModeSizes(fullWidth: full.width, fullHeight: full.height,
                      lowDataWidth: lowData.width, lowDataHeight: lowData.height)
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
    func configuration(potentialEDRHeadroom: Double, hardwareFormats: VideoFormats = .hardwareSupported,
                       sizes: DataModeSizes? = nil) -> StreamConnection.Configuration {
        let formats = hardwareFormats.forDisplay(potentialEDRHeadroom: potentialEDRHeadroom)
        return StreamConnection.Configuration(width: width, height: height, fps: fps,
            bitrateKbps: StreamProfile.bitrateKbps, videoFormats: formats, audio: .stereo,
            changeResolution: changeResolution, resumeResolutionChange: true, dataModeSizes: sizes)
    }
}
