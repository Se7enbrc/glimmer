// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

struct EngineLink {
    let request: Data
    let protocolVersion: Int

    init() {
        var message = RtspMessage(command: "OPTIONS", target: "*")
        message.headers = [("CSeq", "1"), ("X-GS-ClientVersion", String(RtspMessage.clientVersion))]
        request = message.serialize()
        protocolVersion = RtspMessage.clientVersion
    }
}
