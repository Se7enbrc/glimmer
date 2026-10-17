// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import Foundation
import GlimmerEngine
import OSLog

// The lock serializes session calls, leases and notification state. No render callback enters this object.
final class IOSAudioSession: @unchecked Sendable {
    struct Route: Sendable {
        let label: String
        let uid: String?
        let sampleRate: Double
        let channels: Int
        let latency: Double
        let bufferDuration: Double
        let volume: Float

        var isUsable: Bool {
            sampleRate.isFinite && sampleRate > 0 && channels > 0 && latency.isFinite && latency >= 0
                && bufferDuration.isFinite && bufferDuration > 0
        }
    }

    struct Calls {
        var configure: (Double) throws -> Void = { rate in
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(rate)
        }
        var activate: () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) }
        var deactivate: () throws -> Void = {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        var route: () -> Route = {
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            return Route(label: outputs.map(\.portName).joined(separator: ", "),
                         uid: outputs.isEmpty ? nil : outputs.map(\.uid).joined(separator: ","),
                         sampleRate: session.sampleRate, channels: session.outputNumberOfChannels,
                         latency: session.outputLatency, bufferDuration: session.ioBufferDuration,
                         volume: session.outputVolume)
        }
    }

    struct Lease {
        let route: Route
        let generation: UInt64
    }

    struct Listener: Sendable {
        let queue: DispatchQueue
        let changed: @Sendable (UInt64) -> Void
    }

    let lock = NSLock()
    let events = DispatchQueue(label: "Glimmer.audio.session.events")
    let calls: Calls
    let notifications: NotificationCenter
    var tokens: [NSObjectProtocol] = []
    var observerGeneration: UInt64 = 0
    var generation: UInt64 = 0
    var routeListener: Listener?
    var deviceListener: Listener?
    var routeID: String?
    var interrupted = false
    var servicesLost = false
    var active = false
    var configured = false
    var wantsPlayback = false
    var leases = 0
    static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Audio")

    init(calls: Calls = Calls(), notifications: NotificationCenter = .default) {
        self.calls = calls
        self.notifications = notifications
    }

    deinit {
        for token in tokens { notifications.removeObserver(token) }
        if active { deactivate() }
    }

    func acquire(sampleRate: Double) throws -> Lease {
        try lock.withLock {
            wantsPlayback = true
            guard !interrupted, !servicesLost else {
                throw AudioOutput.Failure(status: kAudioUnitErr_CannotDoInCurrentContext)
            }
            do {
                if !configured { try calls.configure(sampleRate); configured = true }
                if !active { try calls.activate(); active = true }
                let route = calls.route()
                guard route.isUsable else { throw AudioOutput.Failure(status: kAudioUnitErr_FormatNotSupported) }
                leases += 1
                return Lease(route: route, generation: generation)
            } catch {
                if leases == 0, active { deactivate() }
                throw error
            }
        }
    }

    func release() {
        lock.withLock {
            leases -= 1
            if leases == 0, !wantsPlayback, active { deactivate() }
        }
    }

    func withPlayback<T>(generation: UInt64, unavailable: T, _ body: () -> T) -> T {
        lock.withLock {
            guard wantsPlayback, active, !interrupted, !servicesLost, generation == self.generation else {
                return unavailable
            }
            return body()
        }
    }

    func sampleRoute() -> AudioRoute {
        lock.withLock {
            let route = calls.route()
            return AudioRoute(label: route.label, uid: route.uid)
        }
    }

    func captureVolume() -> () -> AudioOutputVolume {
        let uid = lock.withLock { calls.route().uid }
        return { [self] in
            lock.withLock {
                let route = calls.route()
                let changed = route.uid != uid
                let available = route.uid != nil && route.channels > 0 && route.volume.isFinite
                return AudioOutputVolume(volume: changed || !available ? nil : route.volume,
                                         muted: nil, routeChanged: changed)
            }
        }
    }

    func deactivate() {
        do {
            try calls.deactivate()
            active = false
            configured = false
        } catch {
            Self.log.error("audio session deactivation failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
