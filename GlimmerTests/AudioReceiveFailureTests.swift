// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Darwin
import Foundation
import Testing

struct AudioReceiveFailureTests {
    @Test func temporaryErrorsDoNotEndReceiveOrInventAnIdleEdge() {
        let state = AudioReceiveFailure()
        #expect(state.action(for: EINTR) == .interrupted)
        #expect(state.action(for: ENOBUFS) == .pressure)
        #expect(state.action(for: ENOMEM) == .pressure)
        #expect(state.action(for: EAGAIN) == .quiet)
        #expect(state.failure == nil)
    }

    @Test func terminalFailureIsReportedOnceAndRequiresReconnect() {
        let receiver = Self.receiver()
        let failures = AtomicCounter()
        receiver.onReceiveFailed = { _ in failures.increment() }
        #expect(receiver.handleReceiveError(ENOBUFS))
        #expect(receiver.handleReceiveError(EINTR))
        #expect(!receiver.handleReceiveError(EBADF))
        #expect(!receiver.handleReceiveError(EIO))
        #expect(failures.value == 1)
        #expect(receiver.receiveFailure.failure == EBADF)
        #expect(!receiver.audioPendingProbeFired(due: RtpAudioReceiver.audioPendingProbeSeconds))
        #expect(throws: (any Error).self) { try receiver.startReceive() }
        receiver.stop()
        #expect(!receiver.handleReceiveError(EBADF))
        #expect(failures.value == 1)
    }

    @Test func intentionalStopDoesNotReportSocketFailure() {
        let receiver = Self.receiver()
        let failures = AtomicCounter()
        receiver.onReceiveFailed = { _ in failures.increment() }
        receiver.stop()
        #expect(!receiver.handleReceiveError(EBADF))
        #expect(!receiver.handleReceiveError(ENOBUFS))
        #expect(failures.value == 0)
        #expect(receiver.receiveFailure.failure == nil)
    }

    @Test func backendPublishesFailureOnlyWhileItsSessionIsActive() {
        let backend = NativeBackend()
        let events = AudioEvents()
        let receiver = Self.receiver()
        backend.wireAudioReceiveFailure(receiver, events: events)
        #expect(!receiver.handleReceiveError(EBADF))
        #expect(events.failures.value == 1)

        let lateReceiver = Self.receiver()
        backend.wireAudioReceiveFailure(lateReceiver, events: events)
        backend.stopConnection()
        #expect(!lateReceiver.handleReceiveError(EBADF))
        #expect(events.failures.value == 1)
    }

    @Test func audioFailureHandlerCanSynchronouslyStopItsBackend() async throws {
        let backend = NativeBackend()
        let receiver = Self.receiver()
        let events = AudioEvents { backend.stopConnection() }
        let finished = DispatchSemaphore(value: 0)
        backend.wireAudioReceiveFailure(receiver, events: events)
        Thread {
            _ = receiver.handleReceiveError(EBADF)
            finished.signal()
        }.start()
        try #require(await finished.waitAsync(for: .seconds(5)) == .success)
        #expect(events.failures.value == 1)
        #expect(backend.checkInterrupted())
    }

    private static func receiver() -> RtpAudioReceiver {
        RtpAudioReceiver(host: .ipv4(.loopback), audioPort: 0, pingPayload: [], audioPacketDuration: 5,
                         opusConfig: SdpScan.defaultOpusConfig, audioConfig: 0,
                         audioEncryption: false, aesKey: [], aesIvId: [], sink: SilentSink())
    }

    private final class SilentSink: NativeAudioSink {
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: UnsafeRawBufferPointer) {}
        func decodeAndPlayPLC() {}
        func cleanup() {}
    }

    private final class AudioEvents: ConnectionEvents {
        let failures = AtomicCounter()
        private let onFailure: @Sendable () -> Void
        init(onFailure: @escaping @Sendable () -> Void = {}) { self.onFailure = onFailure }
        func audioFailed(_ detail: String) {
            failures.increment()
            onFailure()
        }
        func stageStarting(_ name: String) {}
        func stageComplete(_ name: String) {}
        func stageFailed(_ name: String, code: Int32) {}
        func connectionStarted() {}
        func connectionTerminated(code: Int32) {}
        func connectionStatus(poor: Bool) {}
        func setHdrMode(_ enabled: Bool) {}
    }
}
