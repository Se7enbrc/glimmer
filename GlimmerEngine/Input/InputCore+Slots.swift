// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

package struct ControllerArrival: Equatable {
    package let type: UInt8
    package let supportedButtons: UInt32
    package let caps: UInt16
    package init(type: UInt8, supportedButtons: UInt32, caps: UInt16) {
        self.type = type
        self.supportedButtons = supportedButtons
        self.caps = caps
    }
}

extension InputCore {
    package func reserveControllerSlot() -> UInt8? {
        withLock {
            guard let slot = (0..<UInt8(16)).first(where: { snapshot.mask & (1 << $0) == 0 }) else { return nil }
            snapshot.mask |= 1 << slot
            return slot
        }
    }

    @discardableResult
    package func announceController(slot: UInt8, arrival: ControllerArrival) -> Int32 {
        withLock {
            pendingArrivals[slot] = arrival
            guard snapshot.ready, flushReleases() else { return -2 }
            let result = backend?.sendControllerArrival(num: slot, mask: snapshot.mask, type: arrival.type,
                supportedButtons: arrival.supportedButtons, caps: arrival.caps) ?? -2
            record("LiSendControllerArrivalEvent", result)
            if result == 0 {
                announcedControllers[slot] = arrival
                pendingArrivals[slot] = nil
            }
            return result
        }
    }

    package func flushControllerArrivals() -> Bool {
        guard snapshot.ready else { return pendingArrivals.isEmpty }
        for slot in pendingArrivals.keys.sorted() {
            guard let arrival = pendingArrivals[slot], announceController(slot: slot, arrival: arrival) == 0
                else { return false }
        }
        return true
    }

    package func retireController(slot: UInt8) {
        withLock {
            pendingArrivals[slot] = nil
            releases.controllerRemovals.insert(slot)
            releases.hold(.controller(slot))
            releases.release(.controller(slot))
            buttons[slot] = 0
            flushReleases()
        }
    }

    package static func staleControllerSlots(announced: [UInt8: ControllerArrival],
                                             current: [UInt8: ControllerArrival]) -> [UInt8] {
        announced.filter { current[$0.key] != $0.value }.keys.sorted()
    }
}
