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
