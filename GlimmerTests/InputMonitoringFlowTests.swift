// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os
import Testing
@testable import Glimmer

@MainActor
struct InputMonitoringFlowTests {
    @Test func grantedReopensAndDeniedOpensSettingsWithoutRequestingAgain() {
        var reopened = 0
        var settings = 0
        for access in [InputMonitoring.State.granted, .denied] {
            InputMonitoring.ask(access: access, reopen: { reopened += 1 }, settings: { settings += 1 },
                                request: { Issue.record("An answered permission must not prompt again"); return false })
        }
        #expect(reopened == 1)
        #expect(settings == 1)
        #expect(InputMonitoring.actionTitle(.denied) == "Open System Settings")
        #expect(InputMonitoring.actionTitle(.unknown) == "Continue")
        #expect(InputMonitoring.actionTitle(.granted) == "Continue")
        #expect(InputMonitoring.guidance(.denied).contains("remove it with the minus button"))
        #expect(InputMonitoring.guidance(.unknown) == InputMonitoring.guidance(.granted))
    }

    @Test(arguments: [false, true])
    func unknownRequestsOffMainAndOnlyReopensAfterAGrant(granted: Bool) async {
        let requested = DispatchSemaphore(value: 0)
        let reopened = DispatchSemaphore(value: 0)
        InputMonitoring.ask(access: .unknown, reopen: { reopened.signal() },
                            settings: { Issue.record("Settings must not cover the system prompt") }, request: {
            #expect(!Thread.isMainThread)
            requested.signal()
            return granted
        })
        #expect(await requested.waitAsync(for: .seconds(2)) == .success)
        #expect(await reopened.waitAsync(for: .seconds(granted ? 2 : 0.1)) == (granted ? .success : .timedOut))
    }

    @Test func returningFromSettingsReopensOnlyOnTheGrantEdge() {
        var reopened = 0
        for access in [InputMonitoring.State.denied, .unknown, .granted, .granted, .denied, .granted] {
            InputMonitoring.noticeReturn(access: access) { reopened += 1 }
        }
        #expect(reopened == 2)
    }
}
