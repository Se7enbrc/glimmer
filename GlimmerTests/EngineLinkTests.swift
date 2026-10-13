// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

struct EngineLinkTests {
    @Test func buildsRealEngineRequestWithoutNetworking() {
        let engine = EngineLink()
        #expect(engine.protocolVersion == 14)
        #expect(String(data: engine.request, encoding: .utf8) ==
            "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n")
    }
}
