// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

struct StreamKeyboardTests {
    @Test func physicalKeysUsePositionalWireCodesAndIgnoreRepeats() {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        let now = ProcessInfo.processInfo.systemUptime
        input.setKey(hidUsage: 26, pressed: true, modifiers: 0, capturedAt: now)
        input.setKey(hidUsage: 26, pressed: true, modifiers: 0, capturedAt: now)
        input.setKey(hidUsage: 26, pressed: false, modifiers: 0, capturedAt: now)
        #expect(backend.keyboard == [
            .init(keyCode: Int16(bitPattern: 0x8057), action: Int8(StreamProtocol.KEY_ACTION_DOWN), modifiers: 0, flags: 0),
            .init(keyCode: Int16(bitPattern: 0x8057), action: Int8(StreamProtocol.KEY_ACTION_UP), modifiers: 0, flags: 0)
        ])
    }

    @Test func focusLossReleasesKeysAndFailedUpsBlockNewPresses() {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        defer { input.stop() }
        input.setFocused(true)
        input.activate(true)
        input.setKey(hidUsage: 4, pressed: true, modifiers: 0, capturedAt: ProcessInfo.processInfo.systemUptime)
        backend.inputResult = -1
        input.setFocused(false)
        input.setFocused(true)
        input.setKey(hidUsage: 7, pressed: true, modifiers: 0, capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(!backend.keyboard.contains { $0.keyCode == Int16(bitPattern: 0x8044) })
        backend.inputResult = 0
        input.setKey(hidUsage: 7, pressed: true, modifiers: 0, capturedAt: ProcessInfo.processInfo.systemUptime)
        let accepted = backend.keyboard.suffix(2)
        #expect(accepted.first?.keyCode == Int16(bitPattern: 0x8041))
        #expect(accepted.first?.action == Int8(StreamProtocol.KEY_ACTION_UP))
        #expect(accepted.last?.keyCode == Int16(bitPattern: 0x8044))
    }
}
