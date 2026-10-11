// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

struct DisconnectRegressionTests {
    @MainActor @Test(arguments: [false, true])
    func backToStreamOnlyAppearsInTheBackground(backgrounded: Bool) throws {
        let fixture = try FakePCModel("stream-tile-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        fixture.model.lastLaunchAttempt = (app, host)
        fixture.model.isStreaming = true
        fixture.model.streamPhase = .streaming
        fixture.model.nativeStreamBackgrounded = backgrounded
        #expect(AppIconsRow.tileState(app, on: host, model: fixture.model, connectingShown: false)
                == (backgrounded ? .hiddenStream : .ready))
    }

    @Test func disconnectOnlyCommandsAreNoLongerAccepted() {
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["stop", "Tower"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["quit", "Tower", "--force"]) }
    }
}
