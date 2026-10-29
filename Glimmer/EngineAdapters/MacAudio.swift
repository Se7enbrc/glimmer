// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AVFAudio
import CoreAudio
import Foundation

// The decoder's graph gate serializes this adapter; listeners only enqueue onto its route queue.
final class MacAudio: @unchecked Sendable {
    weak var halOutput: AudioHALOutput?
    var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, Int)] = []
    var routeListenerKey: Int?
    var routeListenerQueue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.route", qos: .userInteractive)
    var configurationChanged: (@Sendable (UInt64) -> Void)?
    var outputRoute = AudioOutputRoute() {
        didSet {
            if oldValue != outputRoute { outputRoute.logRoute() }
        }
    }

    func platform() -> AudioPlatform {
        AudioPlatform(makeOutput: { try self.makeOutput(format: $0) }, sampleRoute: Self.sampleAudioRoute,
            installRouteListener: { queue, logID, changed in
                self.installAudioRouteListener(queue: queue, logID: logID, changed: changed)
            }, removeRouteListener: { self.removeAudioRouteListener(logID: $0) },
            installDeviceListeners: { queue, changed in
                self.routeListenerQueue = queue
                self.configurationChanged = changed
                self.installDeviceListeners()
            }, removeDeviceListeners: { self.removeDeviceListeners() }, captureVolume: {
                let initial = MacAudioVolume.defaultOutputDevice()
                return { MacAudioVolume.readDefaultOutputVolume(initialDevice: initial) }
            }, environment: {
                AudioEnvironment(host: StreamRouteProbe.currentLatchedHost ?? "unknown",
                    link: EnvSignalController.shared.streamLink,
                    jitterMs: EnvSignalController.shared.decision.smoothedJitterMs)
            })
    }

    private func makeOutput(format: AVAudioFormat) throws -> AudioOutput {
        outputRoute = AudioOutputRoute.current() ?? outputRoute
        let output = AudioHALOutput(channels: Int(format.channelCount))
        try output.configure(format: format, route: outputRoute)
        halOutput = output
        return output.sharedOutput
    }

    private func installAudioRouteListener(queue: DispatchQueue, logID: String,
                                           changed: @escaping @Sendable (UInt64) -> Void) {
        guard routeListenerKey == nil else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let (key, status) = HALListener.add(system, Self.defaultOutputDeviceAddress) {
            let changedAt = DispatchTime.now().uptimeNanoseconds
            queue.async { changed(changedAt) }
        }
        if status == noErr {
            routeListenerKey = key
            Diag.notice("audio route listener installed (decoder \(logID))", "Stream")
        } else {
            Diag.notice("audio route listener install failed (OSStatus \(status)) - "
                + "under-run route attribution will not track device switches", "Stream")
        }
    }

    private func removeAudioRouteListener(logID: String) {
        guard let key = routeListenerKey else { return }
        routeListenerKey = nil
        let status = HALListener.remove(AudioObjectID(kAudioObjectSystemObject),
                                        Self.defaultOutputDeviceAddress, key: key)
        Diag.notice("audio route listener removed (decoder \(logID), OSStatus \(status))", "Stream")
    }
}

extension AudioDecoder {
    convenience init(defaults: UserDefaults = PersistentStorage.defaults) { self.init(platform: MacAudio().platform(), defaults: defaults) }
}
