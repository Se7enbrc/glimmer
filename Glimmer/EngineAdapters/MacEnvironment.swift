// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine

enum MacEnvironment {
    static func makeObservations() -> EnvObservationSource {
        let probe = StreamRouteProbe()
        let radio = WiFiTelemetry()
        probe.start()
        return EnvObservationSource(route: { probe.current() }, wifi: { radio.sample() }, stop: { probe.stop() })
    }
}
