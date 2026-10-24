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
    private var handler: (@Sendable (Int32, GamepadAnalog, TimeInterval) -> Void)?

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
        lock.withLock { self.handler = handler }
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
        let buttons: Int32
        let analog: GamepadAnalog
        let handler: (@Sendable (Int32, GamepadAnalog, TimeInterval) -> Void)?
    }

    private func flush() {
        let value = lock.withLock { () -> Report? in
            guard reading, let pending else { return nil }
            self.pending = nil
            reportCount &+= 1
            let state = mapping.translate(readings.snapshot)
            return Report(timestamp: pending.timestamp, entered: handlerEntry, buttons: state.buttons,
                          analog: state.analog, handler: handler)
        }
        guard let value else { return }
        InputTimingContext.begin(source: .rawHID, timestamp: HIDInputThread.seconds(ticks: value.timestamp),
                                 handler: value.entered)
        defer { InputTimingContext.end() }
        value.handler?(value.buttons, value.analog, HIDInputThread.seconds(ticks: value.timestamp))
    }
}
