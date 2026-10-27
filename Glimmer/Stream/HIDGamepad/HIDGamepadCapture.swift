// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import IOKit.hid

/// The lock protects readings and subscription changes; only the HID run loop assembles and drains reports.
final class HIDGamepadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: HIDGamepadReadings
    private let mapping: HIDGamepadMapping
    private let scheduleDrain: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var reportCount: UInt64 = 0
    private var pending: (timestamp: UInt64, report: UInt32)?
    private var flushScheduled = false
    private var handlerEntry: UInt64 = 0
    private var reading = false
    private var handler: (@Sendable (ControllerMappingSample, TimeInterval) -> Void)?
    private var streamIndexes: [Int] = []
    private var layoutHandler: LayoutHandler?

    private struct LayoutHandler: Sendable {
        let id = UUID()
        let indexes: [Int]
        let receive: @Sendable (ControllerMappingSample, TimeInterval) -> Void
    }

    init(readings: HIDGamepadReadings, mapping: HIDGamepadMapping,
         scheduleDrain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
             HIDInputThread.shared.perform($0)
         }) {
        self.readings = readings
        self.mapping = mapping
        self.scheduleDrain = scheduleDrain
    }

    var state: (buttons: Int32, analog: GamepadAnalog) { lock.withLock { mapping.translate(readings.snapshot) } }
    var count: UInt64 { lock.withLock { reportCount } }

    func setHandler(_ handler: (@Sendable (Int32, GamepadAnalog, TimeInterval) -> Void)?) {
        guard let handler else { setStreamHandler(indexes: [], nil); return }
        setStreamHandler(indexes: []) { sample, now in
            handler(Int32(bitPattern: sample.buttons), sample.gamepadAnalog, now)
        }
    }

    func setStreamHandler(indexes: [Int], _ handler: (@Sendable (ControllerMappingSample, TimeInterval) -> Void)?) {
        lock.withLock { self.streamIndexes = indexes; self.handler = handler }
    }

    func layoutSample(indexes: [Int]) -> ControllerMappingSample {
        lock.withLock {
            let state = mapping.translate(readings.snapshot)
            return sample(buttons: state.buttons, analog: state.analog, indexes: indexes)
        }
    }

    func acquireLayout(indexes: [Int], receive: @escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void)
        -> @Sendable () -> Void {
        let entry = LayoutHandler(indexes: indexes, receive: receive)
        let previous = lock.withLock {
            let previous = layoutHandler
            layoutHandler = entry
            return previous
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.layoutHandler?.id == entry.id { self.layoutHandler = previous }
            }
        }
    }

    private func sample(buttons: Int32, analog: GamepadAnalog, indexes: [Int]) -> ControllerMappingSample {
        var sample = ControllerMappingSample(buttons: buttons, analog: analog)
        for (extra, index) in indexes.enumerated() where readings.snapshot.buttons.indices.contains(index) {
            sample.setExtra(extra, pressed: readings.snapshot.buttons[index])
        }
        return sample
    }

    func setReading(_ enabled: Bool) {
        lock.withLock { reading = enabled; pending = nil }
    }

    func update(cookie: UInt32, raw: Int) { lock.withLock { readings.update(cookie: cookie, raw: raw) } }

    static let inputValue: IOHIDValueCallback = { context, result, _, value in
        guard result == kIOReturnSuccess, let context else { return }
        let owner = Unmanaged<HIDGamepadCapture>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        owner.receive(cookie: IOHIDElementGetCookie(element), raw: IOHIDValueGetIntegerValue(value),
                      timestamp: IOHIDValueGetTimeStamp(value), report: IOHIDElementGetReportID(element))
    }

    func receive(cookie: UInt32, raw: Int, timestamp: UInt64, report: UInt32) {
        let entered = DispatchTime.now().uptimeNanoseconds
        let needsFlush = lock.withLock {
            pending.map { $0.timestamp != timestamp || $0.report != report } ?? false
        }
        if needsFlush { flush() }
        let schedule = lock.withLock {
            guard reading else { return false }
            if pending == nil { handlerEntry = entered }
            pending = (timestamp, report)
            readings.update(cookie: cookie, raw: raw)
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        if schedule {
            // The run-loop block drains the complete report after its element callbacks, without a main-queue hop.
            scheduleDrain { [weak self] in
                self?.lock.withLock { self?.flushScheduled = false }
                self?.flush()
            }
        }
    }

    private struct Report {
        let timestamp: UInt64
        let entered: UInt64
        let sample: ControllerMappingSample
        let handler: (@Sendable (ControllerMappingSample, TimeInterval) -> Void)?
        let layout: (ControllerMappingSample, LayoutHandler)?
    }

    private func flush() {
        let value = lock.withLock { () -> Report? in
            guard reading, let pending else { return nil }
            self.pending = nil
            reportCount &+= 1
            let state = mapping.translate(readings.snapshot)
            let layout = layoutHandler.map { (sample(buttons: state.buttons, analog: state.analog, indexes: $0.indexes), $0) }
            return Report(timestamp: pending.timestamp, entered: handlerEntry,
                          sample: sample(buttons: state.buttons, analog: state.analog, indexes: streamIndexes),
                          handler: handler, layout: layout)
        }
        guard let value else { return }
        InputTimingContext.begin(source: .rawHID, timestamp: HIDInputThread.seconds(ticks: value.timestamp),
                                 handler: value.entered)
        defer { InputTimingContext.end() }
        let timestamp = HIDInputThread.seconds(ticks: value.timestamp)
        if let (sample, layout) = value.layout { layout.receive(sample, timestamp) } else {
            value.handler?(value.sample, timestamp)
        }
    }
}
