// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import Foundation

/// Route identity remains local, for attribution and per-device clock memory only.
public struct AudioRoute: Sendable {
    public let label: String
    public let uid: String?

    public init(label: String, uid: String?) {
        self.label = label
        self.uid = uid
    }
}

/// The shell supplies existing route/link evidence; reading it never introduces a new sampler.
public struct AudioEnvironment: Sendable {
    public var host: String
    public var link: String
    public var jitterMs: Double

    public init(host: String, link: String, jitterMs: Double) {
        self.host = host
        self.link = link
        self.jitterMs = jitterMs
    }
}

/// Graph/listener hooks are serialized; route, volume and environment probes must be thread safe.
/// Deliver notifications asynchronously on the supplied queue, never inline from an adapter hook.
public struct AudioPlatform {
    /// Native session events join the recording. Pass only scalar state and system route types,
    /// never device names, identifiers, error text or audio contents.
    public static func recordSessionDiagnostic(_ message: String) {
        #if os(macOS)
        Diag.notice("\(message)", "Stream.Audio")
        #endif
    }

    let makeOutput: (AVAudioFormat) throws -> AudioOutput
    let sampleRoute: () -> AudioRoute
    let installRouteListener: (DispatchQueue, String, @escaping @Sendable (UInt64) -> Void) -> Void
    let removeRouteListener: (String) -> Void
    let installDeviceListeners: (DispatchQueue, @escaping @Sendable (UInt64) -> Void) -> Void
    let removeDeviceListeners: () -> Void
    let captureVolume: () -> (() -> AudioOutputVolume)
    let environment: @Sendable () -> AudioEnvironment
    // Session-backed output opts into packet-driven recovery, preparing after disposal and before rebuilding.
    let prepareForRecovery: (() -> Void)?

    public init(makeOutput: @escaping (AVAudioFormat) throws -> AudioOutput,
                sampleRoute: @escaping () -> AudioRoute,
                installRouteListener: @escaping (DispatchQueue, String, @escaping @Sendable (UInt64) -> Void) -> Void,
                removeRouteListener: @escaping (String) -> Void,
                installDeviceListeners: @escaping (DispatchQueue, @escaping @Sendable (UInt64) -> Void) -> Void,
                removeDeviceListeners: @escaping () -> Void,
                captureVolume: @escaping () -> (() -> AudioOutputVolume),
                environment: @escaping @Sendable () -> AudioEnvironment,
                prepareForRecovery: (() -> Void)? = nil) {
        self.makeOutput = makeOutput
        self.sampleRoute = sampleRoute
        self.installRouteListener = installRouteListener
        self.removeRouteListener = removeRouteListener
        self.installDeviceListeners = installDeviceListeners
        self.removeDeviceListeners = removeDeviceListeners
        self.captureVolume = captureVolume
        self.environment = environment
        self.prepareForRecovery = prepareForRecovery
    }
}

/// Missing output volume remains missing; a changed route invalidates the sampled values.
public struct AudioOutputVolume {
    public let volume: Float?
    public let muted: Bool?
    public let routeChanged: Bool

    public init(volume: Float?, muted: Bool?, routeChanged: Bool) {
        self.volume = volume
        self.muted = muted
        self.routeChanged = routeChanged
    }
}
