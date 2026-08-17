//
//  EnvKeepalivePolicyTests.swift
//
//  The conditional-keepalive decision table, including the wifi WARM-UP row
//  added 2026-08-17. Measured fault: a 6GHz session at -43dBm took 36 gaps
//  >100ms in its first 30 seconds - then zero for the next 150 - because
//  "clear state + active input" relaxed the cadence to 500ms while the AP's
//  power-save/aggregation posture was still ramping, and the radio dozed
//  between packets (the clear→gap→caution→fast→clear→relaxed limit cycle).
//  The table is pure (`resolveSteadyPingInterval`), so every row is asserted
//  directly; the instance wrapper only gathers the live inputs.
//

import Foundation
import Testing
@testable import Glimmer

struct EnvKeepalivePolicyTests {

    private let fast = EnvSignalController.fastPingIntervalSeconds
    private let relaxed = EnvSignalController.relaxedPingIntervalSeconds

    private func resolve(
        link: EnvSignalController.LinkClass, state: EnvSignalController.EnvState = .clear,
        routeFresh: Bool = true, inputIdle: Bool = false, inWarmup: Bool = false
    ) -> TimeInterval {
        EnvSignalController.resolveSteadyPingInterval(
            link: link, state: state, routeFresh: routeFresh,
            inputIdle: inputIdle, inWarmup: inWarmup)
    }

    /// THE fix: wifi + clear + active input used to relax to 500ms from the
    /// first second - inside the warm-up window it must pin fast, because the
    /// downlink gaps regardless of uplink input while the AP posture ramps.
    @Test func wifiWarmupPinsFastDespiteClearActiveInput() {
        #expect(resolve(link: .wifi, state: .clear, inputIdle: false, inWarmup: true) == fast)
    }

    /// Past the warm-up, the pre-existing table is unchanged: clear + active
    /// input relaxes (input traffic genuinely holds the radio awake by then).
    @Test func wifiSteadyClearActiveInputRelaxes() {
        #expect(resolve(link: .wifi, state: .clear, inputIdle: false, inWarmup: false) == relaxed)
    }

    /// Idle input opens the doze window - fast, warm-up or not.
    @Test func wifiIdleInputStaysFast() {
        #expect(resolve(link: .wifi, inputIdle: true, inWarmup: false) == fast)
        #expect(resolve(link: .wifi, inputIdle: true, inWarmup: true) == fast)
    }

    /// Any non-clear verdict keeps the countermeasure regardless of warm-up.
    @Test func wifiCautionAndDistressStayFast() {
        #expect(resolve(link: .wifi, state: .caution) == fast)
        #expect(resolve(link: .wifi, state: .distress) == fast)
    }

    /// A wired NIC doesn't doze - relaxed even during warm-up; the fast
    /// cadence there would spend packets for nothing.
    @Test func wiredRelaxesEvenInWarmup() {
        #expect(resolve(link: .wired, inWarmup: true) == relaxed)
        #expect(resolve(link: .wired, inWarmup: false) == relaxed)
    }

    /// Stale route truth always falls back to the validated fast dial - the
    /// guard outranks every other input, including a wired claim.
    @Test func staleRouteAlwaysFast() {
        #expect(resolve(link: .wired, routeFresh: false) == fast)
        #expect(resolve(link: .wifi, routeFresh: false, inWarmup: false) == fast)
    }

    /// Tunnel and unknown routes may be riding the radio - fast, always.
    @Test func tunnelAndUnknownStayFast() {
        #expect(resolve(link: .tunnel) == fast)
        #expect(resolve(link: .unknown, inWarmup: false) == fast)
    }
}
