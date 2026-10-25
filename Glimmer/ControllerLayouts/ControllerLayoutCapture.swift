// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Observation
import Synchronization

@MainActor
struct ControllerLayoutCaptureSource {
    let controls: [ControllerLayoutControl]
    let extras: [String]
    let read: () -> ControllerMappingSample
    let acquire: (@escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) -> (() -> Void)

    init(controller: GCController, reader: ControllerLayoutReader) {
        controls = reader.controls
        extras = reader.extras
        read = { reader.sample() }
        acquire = { receive in
            let lease = ControllerLayoutInputLease(controller: controller, reader: reader, queue: .main, receive: receive)
            return { lease.stop() }
        }
    }

    init(controls: [ControllerLayoutControl], extras: [String], read: @escaping () -> ControllerMappingSample,
         acquire: @escaping (@escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) -> (() -> Void)) {
        self.controls = controls
        self.extras = extras
        self.read = read
        self.acquire = acquire
    }
}

@MainActor @Observable
final class ControllerLayoutCapture {
    private(set) var message = "Release the controls to begin."
    private(set) var source: ControllerLayoutSource?
    private(set) var finished = false
    private var waitingForNeutral = true
    private var candidate: ControllerLayoutSource?
    private var escape: ControllerEscapeGesture?
    private var release: (() -> Void)?
    private let input: ControllerLayoutCaptureSource
    private var onCancel: (() -> Void)?
    private var epoch = UUID()
    private let ownership = UUID()

    init(input: ControllerLayoutCaptureSource) {
        self.input = input
        if let chord = try? ControllerPhysicalChord(
            sources: ControllerLayoutShortcuts.escape(available: Set(input.controls.map(\.id))), extras: input.extras) {
            escape = ControllerEscapeGesture(chord: chord)
        }
    }

    isolated deinit { stop() }

    func start(cancel: @escaping () -> Void) {
        guard release == nil else { return }
        guard ControllerLayoutEditing.acquireCapture(ownership) else {
            message = "Finish the other recording first."
            return
        }
        let epoch = UUID()
        self.epoch = epoch
        onCancel = cancel
        release = input.acquire { [weak self] sample, now in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.deliver(sample, at: now, epoch: epoch) }
            } else {
                Task { @MainActor in self?.deliver(sample, at: now, epoch: epoch) }
            }
        }
        receive(input.read(), at: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        epoch = UUID()
        release?()
        release = nil
        onCancel = nil
        ControllerLayoutEditing.releaseCapture(ownership)
    }

    private func deliver(_ sample: ControllerMappingSample, at now: TimeInterval, epoch: UUID) {
        guard self.epoch == epoch, release != nil else { return }
        receive(sample, at: now)
    }

    private func receive(_ sample: ControllerMappingSample, at now: TimeInterval) {
        guard !finished else { return }
        if escape?.update(sample, at: now) == true { onCancel?(); return }
        let active = activeControls(sample, threshold: waitingForNeutral || candidate != nil ? 0.2 : 0.6)
        if waitingForNeutral {
            if active.isEmpty {
                waitingForNeutral = false
                message = "Press the button you want to change."
            }
            return
        }
        if let candidate {
            if active.isEmpty {
                source = candidate
                finished = true
                message = "Control captured. Choose what it sends to the PC."
            } else if active != [candidate] { rejectMultiple() }
        } else if active.count == 1 {
            candidate = active.first
            message = "Release the control."
        } else if active.count > 1 { rejectMultiple() }
    }

    private func rejectMultiple() {
        candidate = nil
        waitingForNeutral = true
        message = "Press one control at a time."
    }

    private func activeControls(_ sample: ControllerMappingSample, threshold: Double) -> Set<ControllerLayoutSource> {
        var result: Set<ControllerLayoutSource> = []
        for control in input.controls {
            switch control.id {
            case .button(let button) where sample.buttons & button.rawValue != 0: result.insert(control.id)
            case .extra(let name):
                if let index = input.extras.firstIndex(of: name), sample.extras[index / 64] & (1 << (index % 64)) != 0 {
                    result.insert(control.id)
                }
            case .trigger(let trigger) where Double(sample.analog[trigger.rawValue]) >= 255 * threshold:
                result.insert(control.id)
            case .axis(let axis) where Double(abs(sample.analog[axis.rawValue])) >= 32767 * threshold:
                result.insert(control.id)
            default: break
            }
        }
        return result
    }
}

@MainActor
final class ControllerLayoutInputLease {
    private final class Delivery: Sendable {
        let valid = Mutex(true)
    }
    private let reader: ControllerLayoutReader
    private let controller: GCController
    private let previousQueue: DispatchQueue?
    private let previousHandler: ((any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void)?
    private let previousGamepadHandler: GCExtendedGamepadValueChangedHandler?
    private var active = true
    private let delivery = Delivery()

    init(controller: GCController, reader: ControllerLayoutReader, queue: DispatchQueue,
         receive: @escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) {
        self.controller = controller
        self.reader = reader
        previousQueue = reader.input.queue
        previousHandler = reader.input.elementValueDidChangeHandler
        previousGamepadHandler = controller.extendedGamepad?.valueChangedHandler
        controller.extendedGamepad?.valueChangedHandler = nil
        reader.input.queue = queue
        reader.input.elementValueDidChangeHandler = { [reader, delivery] _, _ in
            guard delivery.valid.withLock({ $0 }) else { return }
            receive(reader.sample(), ProcessInfo.processInfo.systemUptime - max(0, reader.input.lastEventLatency))
        }
    }

    isolated deinit { stop() }

    func stop() {
        guard active else { return }
        active = false
        delivery.valid.withLock { $0 = false }
        reader.input.elementValueDidChangeHandler = previousHandler
        reader.input.queue = previousQueue
        controller.extendedGamepad?.valueChangedHandler = previousGamepadHandler
    }
}
