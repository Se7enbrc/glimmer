// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing

struct ControllerBatteryAttemptTests {
    @Test(arguments: [false, true]) @MainActor
    func initialAnnouncementDoesNotHoldInputLockAcrossNativeRead(queued: Bool) async throws {
        let old = NativeBackend()
        let replacement = NativeBackend()
        let sent = OSAllocatedUnfairLock(initialState: [ObjectIdentifier]())
        let battery = ControllerBattery(send: { backend, _, _, _ in
            sent.withLock { $0.append(ObjectIdentifier(backend)) }; return 0
        })
        let input = StreamInput(battery: battery, emit: { _ in })
        defer { input.stop(); battery.stopAll() }
        let registration = try #require(input.registerController(
            ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [.battery])))
        let first = UUID()
        let second = UUID()
        #expect(input.rebind(to: old, attempt: first))
        input.activate(true, attempt: first)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let shouldBlock = OSAllocatedUnfairLock(initialState: true)
        DispatchQueue.global().async {
            #expect(entered.wait(timeout: .now() + 2) == .success)
            input.prepareForReplacement(attempt: first)
            #expect(input.rebind(to: replacement, attempt: second))
            input.activate(true, attempt: second)
            resume.signal()
            done.signal()
        }
        await withCheckedContinuation { continuation in
            let capture = ControllerBatteryCapture {
                if shouldBlock.withLock({ value in let prior = value; value = false; return prior }) {
                    entered.signal()
                    #expect(resume.wait(timeout: .now() + 3) == .success)
                    continuation.resume()
                }
                return ControllerBatterySample(state: .discharging, level: 0.5)
            }
            // The real backend is intentionally disconnected; simulate its successful arrival acknowledgement.
            input.core.withLock { input.registrations[registration.slot]?.announced = !queued }
            input.attachBattery(capture, to: registration)
            if queued { input.announceBattery(registration) }
        }
        #expect(await done.waitAsync(for: .seconds(2)) == .success)
        #expect(sent.withLock { $0.isEmpty })
        battery.announce(slot: registration.slot, backend: replacement)
        #expect(sent.withLock { $0 } == [ObjectIdentifier(replacement)])
    }

    @Test @MainActor func reentrantDetachDuringNativeReadCannotSendRetiredRegistration() {
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let battery = ControllerBattery(send: { _, _, _, _ in sent.withLock { $0 += 1 }; return 0 })
        defer { battery.stopAll() }
        _ = battery.register(slot: 0, capture: ControllerBatteryCapture {
            battery.unregister(slot: 0)
            return ControllerBatterySample(state: .full, level: 1)
        })
        battery.announce(slot: 0, backend: NativeBackend())
        #expect(sent.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func sampleStartedBeforeRevocationCannotReachEitherUplink(reuseBackend: Bool) {
        let old = NativeBackend()
        let replacement = reuseBackend ? old : NativeBackend()
        let sent = OSAllocatedUnfairLock(initialState: [ObjectIdentifier]())
        let battery = ControllerBattery(send: { backend, _, _, _ in
            sent.withLock { $0.append(ObjectIdentifier(backend)) }
            return 0
        })
        defer { battery.stopAll() }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let shouldBlock = OSAllocatedUnfairLock(initialState: true)
        let capture = ControllerBatteryCapture {
            if shouldBlock.withLock({ value in let previous = value; value = false; return previous }) {
                entered.signal()
                #expect(resume.wait(timeout: .now() + 3) == .success)
            }
            return ControllerBatterySample(state: .discharging, level: 0.5)
        }
        _ = battery.register(slot: 0, capture: capture)
        battery.setUplink(old)
        DispatchQueue.global().async {
            #expect(entered.wait(timeout: .now() + 2) == .success)
            battery.pause()
            battery.setUplink(replacement)
            resume.signal()
            completed.signal()
        }
        battery.pollTick()
        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(sent.withLock { $0.isEmpty })
        battery.pollTick()
        #expect(sent.withLock { $0 } == [ObjectIdentifier(replacement)])
        battery.pollTick()
        #expect(sent.withLock { $0.count } == 1)
    }
}
