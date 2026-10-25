// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if TOUCH_INPUT_EVIDENCE
import Foundation
import Network
import Synchronization
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@Suite(.serialized)
@MainActor
struct TouchInputEvidenceTests {
    @Test func pairedControllerTiming() async throws {
        var lines = ["run,load,path,stage,count,p50_ms,p95_ms,p99_ms,max_ms,dropped,capture_window_ms"]
        for load in ["idle", "input", "main"] {
            for run in 0..<3 {
                for touch in (run.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    lines += try await measure(touch: touch, load: load, run: run)
                }
            }
        }
        Attachment.record(Array((lines.joined(separator: "\n") + "\n").utf8), named: "touch-input-timing.csv")
    }

    private func measure(touch: Bool, load: String, run: Int) async throws -> [String] {
        let fixture = try await TouchTimingFixture()
        defer { fixture.stop() }
        let capture = TouchGamepadCapture(input: fixture.input)
        #expect(capture.attach())
        fixture.input.setFocused(true)
        capture.setEnabled(true)
        let registration = try #require(capture.registration)
        let tracking = TouchTracking(.leftStick)
        tracking.capture = capture
        let button = TouchTracking(.a)
        button.capture = capture
        var sample = ControllerInputSample()
        let size = CGSize(width: 96, height: 96)
        if touch { #expect(tracking.begin(at: CGPoint(x: 48, y: 48), size: size,
                                         timestamp: ProcessInfo.processInfo.systemUptime)) }
        let tracker = FrameTimingTracker(sessionId: "touch-evidence",
                                         traceDirectory: FileManager.default.temporaryDirectory)
        FrameTimingTracker.installForTesting(tracker)
        defer { FrameTimingTracker.installForTesting(nil) }
        let count = 240
        let interval = load == "idle" ? 5 : 1
        let start = ContinuousClock.now
        let captureStart = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            try await Task.sleep(until: start + .milliseconds(index * interval), clock: .continuous)
            let point = CGPoint(x: index.isMultiple(of: 2) ? 68 : 28, y: 40)
            let value = TouchGamepadState.stick(location: point, size: size)
            let timestamp = captureStart + Double(index * interval) / 1000
            if load == "main" { fixture.occupyMainThread() }
            if touch { tracking.update(at: point, size: size, timestamp: timestamp) } else {
                sample.leftStickX = Float(value.x)
                sample.leftStickY = Float(value.y)
                fixture.input.submitController(registration, sample: sample, capturedAt: timestamp)
            }
            if load != "idle" {
                if touch {
                    if index.isMultiple(of: 2) {
                        _ = button.begin(at: CGPoint(x: 23, y: 23), size: CGSize(width: 46, height: 46),
                                         timestamp: timestamp)
                    } else { button.end(at: timestamp) }
                } else {
                    sample.buttons = index.isMultiple(of: 2) ? .a : []
                    fixture.input.submitController(registration, sample: sample, capturedAt: timestamp)
                }
            }
        }
        fixture.batcher.stop()
        let dropped = tracker.inputTimingDropped.value
        #expect(dropped == 0)
        return tracker.inputLatency.snapshot().filter {
            $0.source == .controller && [.captureHandler, .handlerBatcher, .batcherFlush, .flushSend, .captureSend]
                .contains($0.stage)
        }.map { row in
            let expectedCount = UInt64(count * (load == "idle" ? 1 : 2))
            #expect(row.histogram.observationCount == expectedCount)
            let quantiles = [0.5, 0.95, 0.99].map {
                String(TelemetryRenderer.histogramQuantile($0, stage: row.histogram) ?? -1)
            }.joined(separator: ",")
            return "\(run),\(load),\(touch ? "touch" : "direct"),\(row.stage.rawValue),"
                + "\(row.histogram.observationCount),\(quantiles),\(row.maxMs),\(dropped),\((count - 1) * interval)"
        }
    }
}

@MainActor
private final class TouchTimingFixture {
    let listener: NWListener
    let channel: EnetControlChannel
    let backend = NativeBackend()
    let batcher: InputBatcher
    let input: StreamInput
    private let received = TouchTimingConnections()
    private var work = [Double](repeating: 0, count: 256)

    init() async throws {
        listener = try NWListener(using: .udp, on: .any)
        let received = received
        listener.newConnectionHandler = { connection in
            received.values.withLock { $0.append(connection) }
            connection.start(queue: .global(qos: .utility))
        }
        let listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = Mutex<CheckedContinuation<Void, Error>?>(continuation)
            listener.stateUpdateHandler = { state in
                if case .ready = state { pending.withLock { value in value?.resume(); value = nil } }
                if case .failed(let error) = state {
                    pending.withLock { value in value?.resume(throwing: error); value = nil }
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
        let port = try #require(listener.port)
        channel = EnetControlChannel(host: "127.0.0.1", port: port.rawValue, controlConnectData: 0,
                                     crypto: try ControlCrypto(rikey: Array(repeating: 0x48, count: 16)))
        try await channel.openSocket()
        // The sink isolates client submission cost: no PC handshake, network backpressure or video runs here.
        batcher = InputBatcher(enet: channel, backpressure: { _ in false })
        input = StreamInput(backend: backend, emit: { _ in })
        backend.withState { backend.enetChannel = channel; backend.inputBatcher = batcher; backend.inputReady = true }
        input.activate(true)
    }

    func occupyMainThread() {
        for index in work.indices { work[index] = sin(Double(index) + work[index]) }
        work.sort()
    }

    func stop() {
        input.stop()
        backend.stopConnection()
        listener.cancel()
        received.values.withLock { values in for value in values { value.cancel() }; values.removeAll() }
    }
}

private final class TouchTimingConnections: Sendable {
    let values = Mutex<[NWConnection]>([])
}
#endif
