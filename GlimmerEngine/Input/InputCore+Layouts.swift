// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package final class ControllerLayoutRouting {
    package final class State {
        package var plan: ControllerMappingPlan?
        package let stop: ControllerPhysicalChord?
        package var escape: ControllerEscapeGesture
        package var rearm: ControllerLayoutRearm
        package var gameRearm: ControllerLayoutRearm
        package var last = ControllerMappingSample()
        package var lastSystem = ControllerMappingSample()
        package let acceptAfter: TimeInterval
        package var originalArrival: ControllerArrival?
        package var blocksLegacyStop = false
        package let removing: Bool

        package init(_ configuration: ControllerLayoutConfiguration?, held: ControllerMappingSample,
                     systemHeld: ControllerMappingSample,
                     acceptAfter: TimeInterval) {
            plan = configuration?.plan
            stop = configuration?.stop
            escape = ControllerEscapeGesture(chord: configuration?.escape ?? .empty)
            rearm = ControllerLayoutRearm(held: held)
            gameRearm = ControllerLayoutRearm(held: systemHeld)
            self.acceptAfter = acceptAfter
            removing = configuration == nil
        }
    }

    package var states = [State?](repeating: nil, count: 16)

    package func reset() {
        for state in states.compactMap({ $0 }) {
            state.escape.reset()
            state.plan?.reset()
            state.rearm = ControllerLayoutRearm(held: state.last)
            state.gameRearm = ControllerLayoutRearm(held: state.lastSystem)
        }
    }
}

extension InputCore {
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
                let escapeButtons = heldControllerButtons(buttons: Int32(bitPattern: configuration.escape.buttons),
                                                           leftTrigger: 0, rightTrigger: 0)
                state.blocksLegacyStop = ControllerChord.satisfied(snapshot.chord, custom: snapshot.customChord,
                                                                   held: escapeButtons)
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

    package func refreshLayoutStopPolicy() {
        guard let layouts else { return }
        for state in layouts.states.compactMap({ $0 }) {
            state.blocksLegacyStop = ControllerChord.satisfied(snapshot.chord, custom: snapshot.customChord,
                held: heldControllerButtons(buttons: Int32(bitPattern: state.escape.chord.buttons),
                                             leftTrigger: 0, rightTrigger: 0))
        }
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
            layouts?.states[Int(slot)] = nil
            if layouts?.states.allSatisfy({ $0 == nil }) == true { layouts = nil }
        }
        let buttons = Int32(bitPattern: sample.buttons)
        let analog = sample.gamepadAnalog
        current[slot] = (buttons, analog)
        let escaped = state.escape.update(sample, at: now)
        let escapePending = state.escape.isPending
        let chord: Bool
        if let stop = state.stop {
            chord = stop.held(in: sample)
        } else if state.blocksLegacyStop {
            chord = false
        } else {
            chord = ControllerChord.satisfied(snapshot.chord, custom: snapshot.customChord,
                held: heldControllerButtons(buttons: buttons, leftTrigger: analog.leftTrigger,
                                             rightTrigger: analog.rightTrigger))
        }
        updateChord(slot: slot, held: chord && !escapePending)
        let consumes = chord || escapePending || escaped
        let isMouse = routeControllerMouse(slot: slot, buttons: buttons, analog: analog, chordHeld: consumes, now: now)
        if consumes {
            sendController(slot: slot, buttons: 0, analog: Self.neutral)
            if escaped { onControllerEscape?() }
        } else if !isMouse {
            if let output = state.plan?.apply(sample) {
                sendController(slot: slot, buttons: Int32(bitPattern: output.buttons), analog: output.gamepadAnalog)
            } else {
                let mapped = ControllerButtonLayout.apply(Int32(bitPattern: gameSample.buttons),
                                                          useNintendoLabels: snapshot.nintendoSlots.contains(slot))
                sendController(slot: slot, buttons: mapped, analog: gameSample.gamepadAnalog)
            }
        }
        if !activityPublished, needsReconciliation { activityPublished = true; onActivity?() }
        return consumes ? .chord : (isMouse ? .mouse : .forwarded)
    }

    package func rememberUnfocusedLayout(slot: UInt8, physical: ControllerMappingSample?, system: ControllerMappingSample) {
        guard !snapshot.focused, let state = layouts?.states[Int(slot)] else { return }
        state.last = physical ?? system
        state.lastSystem = system
        state.rearm = ControllerLayoutRearm(held: state.last)
        state.gameRearm = ControllerLayoutRearm(held: system)
    }
}
