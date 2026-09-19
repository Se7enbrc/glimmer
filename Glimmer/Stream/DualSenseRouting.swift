import Foundation
import GameController

/// Shared by the forwarder and diagnostics. Feedback threads only read the locked routes.
final class DualSenseRouting: @unchecked Sendable {
    static let shared = DualSenseRouting()
    private let lock = NSLock()
    private var binder = DualSenseBinder()
    private var faces: [ObjectIdentifier: Set<DualSenseFaceButton>] = [:]
    private var slots: [UInt8: ObjectIdentifier] = [:]

    func device(for controller: ObjectIdentifier) -> DualSenseDeviceKey? {
        lock.lock(); defer { lock.unlock() }
        return binder.hidDevice(for: controller)
    }

    func device(slot: UInt16) -> DualSenseDeviceKey? {
        lock.lock(); defer { lock.unlock() }
        guard let slot = UInt8(exactly: slot), let controller = slots[slot] else { return nil }
        return binder.hidDevice(for: controller)
    }

    func controller(for device: DualSenseDeviceKey) -> ObjectIdentifier? {
        lock.lock(); defer { lock.unlock() }
        return binder.controller(for: device)
    }

    @MainActor func syncControllers() {
        let live = Set(GCController.controllers().filter {
            $0.extendedGamepad is GCDualSenseGamepad
        }.map(ObjectIdentifier.init))
        let matched = lock.withLock {
            let before = boundRoutes
            for id in faces.keys where !live.contains(id) {
                binder.disconnectController(id)
                faces[id] = nil
                slots = slots.filter { $0.value != id }
            }
            for id in live where faces[id] == nil { faces[id] = [] }
            binder.connectControllers(live)
            return newDevices(since: before)
        }
        notifyMatches(matched)
    }

    func register(slot: UInt8, controller: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        slots[slot] = controller
    }

    func unregister(slot: UInt8) {
        lock.lock(); defer { lock.unlock() }
        slots[slot] = nil
    }

    func connectDevices(_ devices: Set<DualSenseDeviceKey>) {
        let matched = lock.withLock {
            let before = boundRoutes
            binder.connectDevices(devices)
            return newDevices(since: before)
        }
        notifyMatches(matched)
    }

    func disconnectDevice(_ device: DualSenseDeviceKey) {
        let matched = lock.withLock {
            let before = boundRoutes
            binder.disconnectDevice(device)
            return newDevices(since: before)
        }
        notifyMatches(matched)
    }

    func disconnectController(_ controller: ObjectIdentifier) {
        let matched = lock.withLock {
            let before = boundRoutes
            binder.disconnectController(controller)
            faces[controller] = nil
            return newDevices(since: before)
        }
        notifyMatches(matched)
    }

    // Access only while holding lock.
    private var boundRoutes: [ObjectIdentifier: DualSenseDeviceKey] {
        Dictionary(uniqueKeysWithValues: faces.keys.compactMap { id in
            binder.hidDevice(for: id).map { (id, $0) }
        })
    }

    private func newDevices(since previous: [ObjectIdentifier: DualSenseDeviceKey]) -> Set<DualSenseDeviceKey> {
        Set(boundRoutes.filter { previous[$0.key] != $0.value }.values)
    }

    private func notifyMatches(_ devices: Set<DualSenseDeviceKey>) {
        guard !devices.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for device in devices { DualSenseHID.shared.onChange?(device) }
            }
        }
    }

    func hid(device: DualSenseDeviceKey, pressed: Set<DualSenseFaceButton>, at time: TimeInterval) {
        lock.withLock {
            for button in pressed { binder.hid(deviceID: device, button: button, at: time) }
        }
        scheduleResolution()
    }

    @MainActor func gc(pad: GCExtendedGamepad) {
        guard pad is GCDualSenseGamepad, let controller = pad.controller else { return }
        let id = ObjectIdentifier(controller)
        let inputs: [(DualSenseFaceButton, Bool)] = [
            (.cross, pad.buttonA.isPressed), (.circle, pad.buttonB.isPressed),
            (.square, pad.buttonX.isPressed), (.triangle, pad.buttonY.isPressed)
        ]
        let held = Set(inputs.filter(\.1).map(\.0))
        let time = ProcessInfo.processInfo.systemUptime
        let changed = lock.withLock {
            let pressed = held.subtracting(faces[id] ?? [])
            faces[id] = held
            for button in pressed { binder.gc(controllerID: id, button: button, at: time) }
            return !pressed.isEmpty
        }
        if changed { scheduleResolution() }
    }

    private func scheduleResolution() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * DualSenseBinder.window + 0.001) { [weak self] in
            guard let self else { return }
            let matched = self.lock.withLock {
                let before = self.boundRoutes
                self.binder.advance(to: ProcessInfo.processInfo.systemUptime)
                return self.newDevices(since: before)
            }
            self.notifyMatches(matched)
        }
    }
}

func dualSenseButtons(pad: GCExtendedGamepad?) -> DualSenseExtraButtons {
    guard let controller = pad?.controller else { return DualSenseExtraButtons() }
    return DualSenseHID.shared.state(for: ObjectIdentifier(controller))?.buttons ?? DualSenseExtraButtons()
}
