// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct DisconnectTests {
    @Test(arguments: [DisconnectReason.userStopped, .hostError, .consumerDropped, .connectFailed, .watchdogStall, .systemSleep, .hostClosedClean])
    func everyStopCancelsTheGameExactlyOnce(cause: DisconnectReason) async throws {
        let sunshine = FakeSunshine.scripted(["launch": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        let server = SessionFlow.pairedPC()
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) })
        await session.prepareLaunchFlow(server: server)
        _ = try await session.launchAndRecordOwnership(client: FakeSunshine.clientUniqueID, appID: 7) {
            try await sunshine.client(server).launch(appID: 7, config: SessionFlow.config)
        }
        await session.stop(cause: cause)
        await session.stop()
        #expect(sunshine.paths == ["launch", "cancel"])
        #expect(await !session.isStreaming)
        #expect(await !session.stopInProgress)
    }
}
