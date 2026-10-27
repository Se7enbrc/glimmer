// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package final class ControllerLayoutRouting {
    package final class State {
        package var plan: ControllerMappingPlan?
        package var gesture: ControllerShortcutGesture
        package var timer: DispatchWorkItem?
        package var systemSuppression: ControllerPhysicalChord?
        package var rearm: ControllerLayoutRearm
        package var gameRearm: ControllerLayoutRearm
        package var physical = ControllerMappingSample()
        package var rawCenter: Int32?
        package var rawShoulders: Int32 = 0
        package var last = ControllerMappingSample()
        package var lastSystem = ControllerMappingSample()
        package let acceptAfter: TimeInterval
        package var originalArrival: ControllerArrival?
        package let removing: Bool

        package init(_ configuration: ControllerLayoutConfiguration?, held: ControllerMappingSample,
                     systemHeld: ControllerMappingSample,
                     acceptAfter: TimeInterval) {
            physical = held
            plan = configuration?.plan
            gesture = ControllerShortcutGesture(stop: configuration?.stop ?? .empty, stats: configuration?.stats ?? .empty)
            rearm = ControllerLayoutRearm(held: held)
            gameRearm = ControllerLayoutRearm(held: systemHeld)
            self.acceptAfter = acceptAfter
            removing = configuration == nil
        }

        deinit { timer?.cancel() }
    }

    package var states = [State?](repeating: nil, count: 16)

    package func reset() {
        for state in states.compactMap({ $0 }) {
            state.gesture.reset()
            state.rawCenter = nil
            state.rawShoulders = 0
            state.timer?.cancel()
            state.timer = nil
            state.systemSuppression = nil
            state.plan?.reset()
            state.rearm = ControllerLayoutRearm(held: state.last)
            state.gameRearm = ControllerLayoutRearm(held: state.lastSystem)
        }
    }
}

extension InputCore {
    package func removeLayout(slot: UInt8) {
        withLock {
            guard slot < 16 else { return }
            layouts?.states[Int(slot)] = nil
            if layouts?.states.allSatisfy({ $0 == nil }) == true { layouts = nil }
        }
    }

    package func configureLayout(_ configuration: ControllerLayoutConfiguration?, slot: UInt8,
                                 held: ControllerMappingSample, at now: TimeInterval,
                                 systemHeld: ControllerMappingSample? = nil) {
        withLock {
            guard slot < 16 else { return }
            let previous = layouts?.states[Int(slot)]
            guard configuration != nil || previous != nil else { return }
            releases.hold(.controller(slot))
            releases.release(.controller(slot))
            releaseControllerTouches(slot: slot)
            resetControllerMouse(slot: slot)
            updateChord(slot: slot, held: false, invalidate: true)
            let arrival = previous?.originalArrival ?? announcedControllers[slot] ?? pendingArrivals[slot]
            if let configuration {
                if layouts == nil { layouts = ControllerLayoutRouting() }
                let state = ControllerLayoutRouting.State(configuration, held: held, systemHeld: systemHeld ?? held,
                                                           acceptAfter: now)
                state.originalArrival = arrival
                layouts?.states[Int(slot)] = state
            } else {
                let state = ControllerLayoutRouting.State(nil, held: held, systemHeld: systemHeld ?? held, acceptAfter: now)
                state.originalArrival = arrival
                layouts?.states[Int(slot)] = state
            }
            flushReleases()
            if let arrival { announceController(slot: slot, arrival: arrival) }
        }
    }

    package func layoutArrival(_ arrival: ControllerArrival, slot: UInt8) -> ControllerArrival {
        guard let state = layouts?.states[Int(slot)] else { return arrival }
        if state.originalArrival == nil { state.originalArrival = arrival }
        let original = state.originalArrival ?? arrival
        return ControllerArrival(type: original.type,
            supportedButtons: original.supportedButtons | (state.plan?.supportedButtons ?? 0), caps: original.caps)
    }

    package func layoutStopHeld(slot: UInt8) -> Bool? {
        withLock {
            guard layouts?.states[Int(slot)] != nil else { return nil }
            return chordSlots.contains(slot)
        }
    }

    package func layoutSample(_ state: ControllerLayoutRouting.State, physical: ControllerMappingSample?,
                              supplement: (center: Int32, shoulders: Int32)?) -> ControllerMappingSample {
        if let supplement {
            state.rawCenter = supplement.center
            state.rawShoulders = supplement.shoulders
        }
        if let physical { state.physical = physical }
        var merged = state.physical
        if let center = state.rawCenter {
            let mask = StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG
                | StreamProtocol.SPECIAL_FLAG | StreamProtocol.MISC_FLAG
            merged.buttons = (merged.buttons & ~UInt32(bitPattern: mask)) | UInt32(bitPattern: center & mask)
        }
        merged.buttons |= UInt32(bitPattern: state.rawShoulders & (StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG))
        return merged
    }

    package func receiveLayout(_ state: ControllerLayoutRouting.State, slot: UInt8,
                               sample: ControllerMappingSample, systemSample: ControllerMappingSample,
                               at now: TimeInterval) -> ControllerAcceptance {
        guard now >= state.acceptAfter else { return .gated }
        state.last = sample
        state.lastSystem = systemSample
        let sample = state.rearm.filter(sample)
        let gameSample = state.plan == nil ? state.gameRearm.filter(systemSample) : systemSample
        if state.removing, state.rearm.isNeutral, state.gameRearm.isNeutral {
            removeLayout(slot: slot)
        }
        current[slot] = (Int32(bitPattern: sample.buttons), sample.gamepadAnalog)
        let wasLatched = state.gesture.latched != nil
        let action = state.gesture.update(sample, at: now)
        let suppression = state.gesture.suppressing
        if !wasLatched, suppression != nil {
            let sameButtons = sample.buttons == gameSample.buttons && sample.analog[0] == gameSample.analog[0]
                && sample.analog[1] == gameSample.analog[1]
            // A system remap has no compiled plan; release its held outputs conservatively.
            state.systemSuppression = sameButtons ? suppression : ControllerPhysicalChord(sample: gameSample)
        }
        let filtered = suppression?.removing(from: sample) ?? sample
        let system = state.systemSuppression?.removing(from: gameSample) ?? gameSample
        let consumes = suppression != nil || action != nil
        let isMouse = routeControllerMouse(slot: slot, buttons: Int32(bitPattern: filtered.buttons),
            analog: filtered.gamepadAnalog, chordHeld: consumes || state.gesture.deadline != nil, now: now)
        if !isMouse {
            if let output = state.plan?.apply(filtered) {
                sendController(slot: slot, buttons: Int32(bitPattern: output.buttons), analog: output.gamepadAnalog)
            } else {
                let mapped = ControllerButtonLayout.apply(Int32(bitPattern: system.buttons),
                                                          useNintendoLabels: snapshot.nintendoSlots.contains(slot))
                sendController(slot: slot, buttons: mapped, analog: system.gamepadAnalog)
            }
        }
        scheduleLayoutHold(state, slot: slot, at: now)
        if let action {
            state.systemSuppression = nil
            if releases.pending.isEmpty { onControllerShortcut?(action) }
        }
        if !activityPublished, needsReconciliation { activityPublished = true; onActivity?() }
        return consumes ? .chord : (isMouse ? .mouse : .forwarded)
    }

    private func scheduleLayoutHold(_ state: ControllerLayoutRouting.State, slot: UInt8, at now: TimeInterval) {
        guard let deadline = state.gesture.deadline else {
            state.timer?.cancel()
            state.timer = nil
            return
        }
        guard state.timer == nil else { return }
        let work = DispatchWorkItem { [weak self, weak state] in
            guard let self, let state else { return }
            self.advanceLayoutHold(state, slot: slot, at: ProcessInfo.processInfo.systemUptime)
        }
        state.timer = work
        mouseQueue.asyncAfter(deadline: .now() + max(0, deadline - now), execute: work)
    }

    package func advanceLayoutHold(_ state: ControllerLayoutRouting.State, slot: UInt8, at now: TimeInterval) {
        withLock {
            state.timer?.cancel()
            state.timer = nil
            guard layouts?.states[Int(slot)] === state, snapshot.ready, snapshot.focused,
                  snapshot.mask & (1 << slot) != 0 else { return }
            _ = receiveLayout(state, slot: slot, sample: state.last, systemSample: state.lastSystem, at: now)
        }
    }

    package func rememberUnfocusedLayout(slot: UInt8, physical: ControllerMappingSample?, system: ControllerMappingSample) {
        guard !snapshot.focused, let state = layouts?.states[Int(slot)] else { return }
        state.last = physical ?? system
        state.lastSystem = system
        state.rearm = ControllerLayoutRearm(held: state.last)
        state.gameRearm = ControllerLayoutRearm(held: system)
    }
}
