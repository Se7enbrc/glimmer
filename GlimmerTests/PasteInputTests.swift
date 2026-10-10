// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
@testable import Glimmer

@MainActor
struct PasteInputTests {
    @Test func pasteReachesTheOriginalReadyConnection() async throws {
        let (forwarder, backend) = readyForwarder()
        defer { forwarder.detach() }
        let task = try #require(forwarder.queuePasteText("café\r\nsecond line"))
        await task.value
        #expect(backend.texts == ["café\nsecond line"])
    }

    @Test func reconnectDiscardsTextEvenIfReadyAgainBeforeTheDelayEnds() async throws {
        let (forwarder, backend) = readyForwarder()
        defer { forwarder.detach() }
        let task = try #require(forwarder.queuePasteText("old connection"))
        forwarder.isReady = false
        forwarder.isReady = true
        await task.value
        #expect(backend.texts.isEmpty)
    }

    @Test func backendReplacementCannotRedirectQueuedText() async throws {
        let (forwarder, original) = readyForwarder()
        defer { forwarder.detach() }
        let task = try #require(forwarder.queuePasteText("original PC"))
        let replacement = InputRecordingBackend()
        forwarder.setBackend(replacement)
        await task.value
        #expect(original.texts.isEmpty)
        #expect(replacement.texts.isEmpty)
    }

    @Test func focusLossDiscardsQueuedText() async throws {
        let (forwarder, backend) = readyForwarder()
        defer { forwarder.detach() }
        let task = try #require(forwarder.queuePasteText("old focus"))
        forwarder.windowResignedKey()
        await task.value
        #expect(backend.texts.isEmpty)
    }

    @Test func detachDiscardsQueuedText() async throws {
        let (forwarder, backend) = readyForwarder()
        let task = try #require(forwarder.queuePasteText("ended stream"))
        forwarder.detach()
        await task.value
        #expect(backend.texts.isEmpty)
    }

    private func readyForwarder() -> (InputForwarder, InputRecordingBackend) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        return (forwarder, backend)
    }
}
