// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import GlimmerEngine

// The platform retains only session state; each AudioOutput exclusively retains its own graph.
enum IOSAudio {
    static func platform(environment: @escaping @Sendable () -> AudioEnvironment,
                         session: IOSAudioSession = IOSAudioSession(),
                         outputCalls: IOSAudioOutput.Calls = IOSAudioOutput.Calls()) -> AudioPlatform {
        AudioPlatform(makeOutput: { format in
            guard format.channelCount == 2 else {
                throw AudioOutput.Failure(status: kAudioUnitErr_FormatNotSupported)
            }
            let lease = try session.acquire(sampleRate: format.sampleRate)
            let graph = IOSAudioOutput(channels: Int(format.channelCount), session: session, lease: lease,
                                       calls: outputCalls)
            try graph.configure(format: format)
            return graph.sharedOutput
        }, sampleRoute: { session.sampleRoute() }, installRouteListener: { queue, id, changed in
            session.installRouteListener(queue: queue, id: id, changed: changed)
        }, removeRouteListener: { session.removeRouteListener(id: $0) }, installDeviceListeners: { queue, changed in
            session.installDeviceListeners(queue: queue, changed: changed)
        }, removeDeviceListeners: { session.removeDeviceListeners() }, captureVolume: { session.captureVolume() },
        environment: environment, prepareForRecovery: { session.prepareForRecovery() })
    }
}
