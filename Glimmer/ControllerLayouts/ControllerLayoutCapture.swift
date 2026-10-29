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
            let lease = ControllerLayoutInputLease(controller: controller, reader: reader, queue: .main,
                                                    receive: receive)
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
    private(set) var chord: Set<ControllerLayoutSource> = []
    private let recordingChord: Bool
    private let minimumButtons: Int
    private var chordBegan: TimeInterval?
    private var chordHeld = false
    private var waitingForNeutral = true
    private var candidate: ControllerLayoutSource?
    private var escape: ControllerEscapeGesture?
    private var release: (() -> Void)?
    private let input: ControllerLayoutCaptureSource
    private var onCancel: (() -> Void)?
    private var epoch = UUID()
    private let ownership = UUID()

    init(input: ControllerLayoutCaptureSource, recordingChord: Bool = false, minimumButtons: Int = 3) {
        self.input = input
        self.recordingChord = recordingChord
        self.minimumButtons = minimumButtons
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

    func restart(cancel: @escaping () -> Void) {
        stop()
        finished = false
        chord = []
        chordBegan = nil
        chordHeld = false
        waitingForNeutral = true
        message = "Release the controls to begin."
        start(cancel: cancel)
    }

    private func deliver(_ sample: ControllerMappingSample, at now: TimeInterval, epoch: UUID) {
        guard self.epoch == epoch, release != nil else { return }
        receive(sample, at: now)
    }

    private func receive(_ sample: ControllerMappingSample, at now: TimeInterval) {
        guard !finished else { return }
        if recordingChord { receiveChord(sample, at: now); return }
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

    private func receiveChord(_ sample: ControllerMappingSample, at now: TimeInterval) {
        let active = activeControls(sample, threshold: 0.5).filter(\.isChordButton)
        if waitingForNeutral {
            if active.isEmpty {
                waitingForNeutral = false
                message = "Hold \(minimumButtons == 1 ? "one or more buttons" : "at least three buttons") together, then release."
            }
            return
        }
        if active.isEmpty {
            if chord.count >= minimumButtons, chordHeld || chordBegan.map({ now - $0 >= ControllerShortcutGesture.holdSeconds }) == true {
                finished = true
                message = "Shortcut recorded. Review it before saving."
            } else {
                chord = []
                chordBegan = nil
                message = "Hold \(minimumButtons == 1 ? "one or more buttons" : "at least three buttons") for a moment, then release."
            }
        } else if chord.isSubset(of: active), !chordHeld {
            if chord != active { chord = active; chordBegan = now }
        } else if active.isSubset(of: chord), chordBegan.map({ now - $0 >= ControllerShortcutGesture.holdSeconds }) == true {
            chordHeld = true
        } else {
            chord = []
            chordBegan = nil
            chordHeld = false
            waitingForNeutral = true
            message = "Hold all the buttons together. Release them to try again."
        }
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
    private let input: GCControllerLiveInput
    private let controller: GCController
    private let previousQueue: DispatchQueue?
    private let previousHandler: ((any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void)?
    private let previousGamepadHandler: GCExtendedGamepadValueChangedHandler?
    private let previousButtonHandlers: [GCControllerButtonValueChangedHandler?]
    private var active = true
    private let delivery = Delivery()

    convenience init(controller: GCController, reader: ControllerLayoutReader, queue: DispatchQueue,
                     receive: @escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) {
        self.init(controller: controller, input: reader.input, queue: queue, read: reader.sample, receive: receive)
    }

    init(controller: GCController, input: GCControllerLiveInput, queue: DispatchQueue,
         read: @escaping @Sendable () -> ControllerMappingSample,
         receive: @escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) {
        self.controller = controller
        self.input = input
        previousQueue = input.queue
        previousHandler = input.elementValueDidChangeHandler
        previousGamepadHandler = controller.extendedGamepad?.valueChangedHandler
        previousButtonHandlers = ControllerButtonRoutes.buttons(controller).map(\.pressedChangedHandler)
        controller.extendedGamepad?.valueChangedHandler = nil
        ControllerButtonRoutes.set(controller, nil)
        input.queue = queue
        // GameController calls this on the input queue; nested closures must not inherit the main actor.
        input.elementValueDidChangeHandler = { @Sendable [delivery] input, _ in
            guard delivery.valid.withLock({ $0 }) else { return }
            receive(read(), ProcessInfo.processInfo.systemUptime - max(0, input.lastEventLatency))
        }
    }

    isolated deinit { stop() }

    func stop() {
        guard active else { return }
        active = false
        delivery.valid.withLock { $0 = false }
        input.elementValueDidChangeHandler = nil
        input.queue = previousQueue
        input.elementValueDidChangeHandler = previousHandler
        controller.extendedGamepad?.valueChangedHandler = previousGamepadHandler
        for (button, handler) in zip(ControllerButtonRoutes.buttons(controller), previousButtonHandlers) {
            button.pressedChangedHandler = handler
        }
    }
}
