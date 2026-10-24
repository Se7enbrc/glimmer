// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// The macOS 26 shims behave the same on either path; Verify's sequoia part runs the 15 one.

import AppKit
import Observation
import QuartzCore
import Testing
@testable import GlimmerEngine
@testable import Glimmer

/// What an HDR layer reports: macOS 26's preferred range, or macOS 15's EDR opt-in.
let hdrRangeLabel: String = {
    if #available(macOS 26, *) { return "high" }
    return "edr"
}()

@MainActor @Observable
private final class Counter {
    var value = 0
}

@MainActor
struct SequoiaFallbacksTests {

    @Test func trackedValuesDeliverTheCurrentValueThenEachChange() async throws {
        let counter = Counter()
        let delivered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        var values: [Int] = []
        let watching = Task {
            await forEachTrackedValue({ counter.value }, perform: {
                values.append($0)
                delivered.signal()
            })
            completed.signal()
        }
        defer {
            watching.cancel()
            counter.value += 1
        }
        try #require(await received(delivered))
        #expect(values == [0])
        for value in 1...4 {
            counter.value = value
            try #require(await received(delivered))
            #expect(values == Array(0...value))
        }
        watching.cancel()
        try #require(await received(completed))
        await watching.value
        counter.value = 5
        #expect(values == [0, 1, 2, 3, 4])
    }

    @Test func trackedValuesNoticeAChangeDuringDelivery() async throws {
        let counter = Counter()
        let delivered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        var values: [Int] = []
        let watching = Task {
            await forEachTrackedValue({ counter.value }, perform: { value in
                values.append(value)
                if value == 0 { counter.value = 1 }
                delivered.signal()
            })
            completed.signal()
        }
        defer {
            watching.cancel()
            counter.value += 1
        }
        try #require(await received(delivered))
        try #require(await received(delivered))
        #expect(values == [0, 1])
        counter.value = 2
        try #require(await received(delivered))
        #expect(values == [0, 1, 2])
        watching.cancel()
        try #require(await received(completed))
        await watching.value
    }

    @Test func trackedValuesCancelWithoutAChangeAndReleaseCapturedState() async throws {
        var counter: Counter? = Counter()
        weak let capturedCounter = counter
        let delivered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let watching = Task { [counter] in
            if let counter {
                await forEachTrackedValue({ counter.value }, perform: { _ in delivered.signal() })
            }
            completed.signal()
        }
        counter = nil
        defer {
            watching.cancel()
            capturedCounter?.value += 1
        }
        try #require(await received(delivered))
        #expect(capturedCounter != nil)
        watching.cancel()
        try #require(await received(completed))
        await watching.value
        #expect(capturedCounter == nil)
    }

    @Test func trackedValuesCancelledBeforeStartingDoNotReadOrDeliver() async throws {
        let completed = DispatchSemaphore(value: 0)
        var reads = 0
        var values: [Int] = []
        let watching = Task {
            await forEachTrackedValue({
                reads += 1
                return 0
            }, perform: { values.append($0) })
            completed.signal()
        }
        watching.cancel()
        try #require(await received(completed))
        await watching.value
        #expect(reads == 0)
        #expect(values.isEmpty)
    }

    private func received(_ signal: DispatchSemaphore) async throws -> Bool {
        try await onTestThread { signal.wait(timeout: .now() + .seconds(5)) == .success }
    }

    @Test func displayIDMatchesTheScreenNumber() {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            #expect(screen.displayID == number)
        }
    }

    @Test func dynamicRangeLabelFollowsTheLayerOptIn() {
        let layer = CALayer()
        layer.setDynamicRange(high: true)
        #expect(layer.dynamicRangeLabel == hdrRangeLabel)
        layer.setDynamicRange(high: false)
        #expect(layer.dynamicRangeLabel == "standard")
    }
}
