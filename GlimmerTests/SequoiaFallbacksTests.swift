// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SequoiaFallbacksTests.swift
//
//  The macOS 26 shims behave the same on either path; Verify's sequoia part runs the 15 one.
//

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

    @Test func trackedValuesDeliverTheCurrentValueThenEachChange() async {
        let counter = Counter()
        let (values, sink) = AsyncStream<Int>.makeStream()
        let watching = Task { await forEachTrackedValue({ counter.value }, perform: { sink.yield($0) }) }
        defer { watching.cancel() }
        var iterator = values.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        counter.value = 1
        #expect(await iterator.next() == 1)
        counter.value = 2
        #expect(await iterator.next() == 2)
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
