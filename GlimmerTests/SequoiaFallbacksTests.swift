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
    var alternate = 50
    var usesAlternate = false
}

@MainActor
struct SequoiaFallbacksTests {
    nonisolated private static var streamingObservationPaths: [Bool] {
        if #available(macOS 26, *) { return [true, false] }
        return [true]
    }

    // Exercise the launcher's observation and weak-owner delivery without starting app services.
    private func observeStreaming(
        of model: AppModel, fallback: Bool, perform body: @escaping @MainActor (Bool) -> Void
    ) async {
        if #available(macOS 26, *), !fallback {
            for await streaming in Observations({ model.isStreaming }) { body(streaming) }
        } else {
            await forEachTrackedValue({ model.isStreaming }, perform: body)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: streamingObservationPaths)
    func dockTrackingReadsCommittedStateAcrossRepeatedStreamTransitions(fallback: Bool) async {
        let settings = IsolatedDefaults()
        let model = AppModel(defaults: settings.defaults)
        let delegate = AppDelegate()
        delegate.model = model
        let (updates, signal) = AsyncStream<Bool>.makeStream()
        let tracking = Task { [weak delegate] in
            await observeStreaming(of: model, fallback: fallback) { streaming in
                #expect(delegate?.model?.isStreaming == streaming)
                let policy = AppDelegate.activationPolicy(visibleWindowIDs: [],
                                                          streaming: delegate?.model?.isStreaming == true)
                #expect(policy == (streaming ? .regular : .accessory))
                signal.yield(streaming)
            }
        }
        defer { tracking.cancel(); signal.finish() }
        var waiter = updates.makeAsyncIterator()
        #expect(await waiter.next() == false)
        for streaming in [true, false, true, false] {
            model.isStreaming = streaming
            #expect(await waiter.next() == streaming)
        }
        tracking.cancel()
        await tracking.value
        #expect(delegate.model === model)
    }

    @Test(.timeLimit(.minutes(1)), arguments: streamingObservationPaths)
    func dockTrackingDoesNotRetainTheDelegate(fallback: Bool) async {
        let settings = IsolatedDefaults()
        let model = AppModel(defaults: settings.defaults)
        var delegate: AppDelegate? = AppDelegate()
        delegate?.model = model
        weak let owner = delegate
        var refreshes = 0
        let (updates, signal) = AsyncStream<Bool>.makeStream()
        let tracking = Task { [weak delegate] in
            await observeStreaming(of: model, fallback: fallback) { _ in
                if delegate != nil { refreshes += 1 }
                signal.yield(delegate != nil)
            }
        }
        defer { tracking.cancel(); signal.finish() }
        var waiter = updates.makeAsyncIterator()
        #expect(await waiter.next() == true)
        delegate = nil
        #expect(owner == nil)
        for streaming in [true, false] {
            model.isStreaming = streaming
            #expect(await waiter.next() == false)
            #expect(refreshes == 1)
        }
        tracking.cancel()
        await tracking.value
    }

    private func reached(_ event: DispatchSemaphore) async throws {
        let completed = try await onTestThread { event.wait(timeout: .now() + 10) == .success }
        try #require(completed, "Observation milestone did not arrive within its independent deadline")
    }

    @Test func stateReadsRearmAndIgnoreUnrelatedProperties() async throws {
        let model = Counter()
        let delivered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var values: [Int] = []
        let observer = Task {
            await forEachTrackedValue({ model.usesAlternate ? model.alternate : model.value }, perform: {
                values.append($0)
                delivered.signal()
            })
            finished.signal()
        }
        defer { observer.cancel() }
        try await reached(delivered)
        #expect(values == [0])
        for value in 1...3 {
            model.value = value
            try await reached(delivered)
        }
        model.usesAlternate = true
        try await reached(delivered)
        model.value = 99
        model.alternate = 51
        try await reached(delivered)
        observer.cancel()
        try await reached(finished)
        await observer.value
        #expect(values == [0, 1, 2, 3, 50, 51])
        model.alternate = 52
        #expect(delivered.takeSignal() == .timedOut)
    }

    @Test func deliveryMutationAndBurstConvergeOnLatestState() async throws {
        let model = Counter()
        let delivered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var values: [Int] = []
        let observer = Task {
            await forEachTrackedValue({ model.value }, perform: { value in
                values.append(value)
                if value == 0 { model.value = 7 }
                delivered.signal()
            })
            finished.signal()
        }
        defer { observer.cancel() }
        try await reached(delivered)
        try await reached(delivered)
        #expect(values == [0, 7])
        for value in 8...10_000 { model.value = value }
        try await reached(delivered)
        #expect(values == [0, 7, 10_000])
        observer.cancel()
        try await reached(finished)
        await observer.value
    }

    @Test func idleCancellationDropsTheLastModelOwner() async throws {
        var model: Counter? = Counter()
        weak var released = model
        let delivered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let observer = Task { [model] in
            guard let model else { finished.signal(); return }
            await forEachTrackedValue({ model.value }, perform: { _ in delivered.signal() })
            finished.signal()
        }
        defer { observer.cancel() }
        model = nil
        try await reached(delivered)
        #expect(released != nil)
        observer.cancel()
        try await reached(finished)
        await observer.value
        #expect(released == nil)
    }

    @Test func cancellationBeforeSchedulingDoesNoWork() async throws {
        var reads = 0
        var deliveries = 0
        let finished = DispatchSemaphore(value: 0)
        let observer = Task {
            await forEachTrackedValue({ reads += 1; return reads }, perform: { _ in deliveries += 1 })
            finished.signal()
        }
        observer.cancel()
        try await reached(finished)
        await observer.value
        #expect(reads == 0 && deliveries == 0)
    }

    @Test func consumerCancellationStopsBeforeAnotherRead() async throws {
        let model = Counter()
        var reads = 0
        var deliveries = 0
        let finished = DispatchSemaphore(value: 0)
        let observer = Task {
            await forEachTrackedValue({ reads += 1; return model.value }, perform: { _ in
                deliveries += 1
                model.value += 1
                withUnsafeCurrentTask { $0?.cancel() }
            })
            finished.signal()
        }
        defer { observer.cancel() }
        try await reached(finished)
        await observer.value
        #expect(reads == 1 && deliveries == 1)
    }

    @Test func independentObserversSurvivePendingAndLateNotifications() async throws {
        for iteration in 0..<24 {
            let model = Counter()
            let firstDelivery = DispatchSemaphore(value: 0)
            let secondDelivery = DispatchSemaphore(value: 0)
            let firstDone = DispatchSemaphore(value: 0)
            let secondDone = DispatchSemaphore(value: 0)
            var firstValues: [Int] = []
            var secondValues: [Int] = []
            let first = Task {
                await forEachTrackedValue({ model.value }, perform: { firstValues.append($0); firstDelivery.signal() })
                firstDone.signal()
            }
            let second = Task {
                await forEachTrackedValue({ model.value }, perform: { secondValues.append($0); secondDelivery.signal() })
                secondDone.signal()
            }
            defer { first.cancel(); second.cancel() }
            try await reached(firstDelivery)
            try await reached(secondDelivery)
            if iteration.isMultiple(of: 2) { model.value = 1 }
            first.cancel()
            try await reached(firstDone)
            await first.value
            let stoppedCount = firstValues.count
            model.value = 2
            repeat { try await reached(secondDelivery) } while secondValues.last != 2
            second.cancel()
            try await reached(secondDone)
            await second.value
            model.value = 3
            #expect(firstValues.count == stoppedCount)
            #expect(secondValues.last == 2)
        }
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
