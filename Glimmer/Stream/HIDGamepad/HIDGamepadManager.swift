import Foundation
import GameController
import IOKit.hid

@MainActor
final class HIDGamepadManager {
    static let shared = HIDGamepadManager()
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var clients = 0
    private(set) var devices: [UInt64: HIDGamepadDevice] = [:]
    private var ownershipObserver: NSObjectProtocol?
    var onAttach: ((HIDGamepadDevice) -> Void)?
    var onDetach: ((HIDGamepadDevice) -> Void)?
    var onReport: ((HIDGamepadDevice) -> Void)?
    /// A pad attached without Input Monitoring; the launcher offers the prompt.
    var onPermissionNeeded: ((HIDGamepadDevice) -> Void)?
    private(set) var slots: [UInt8: HIDGamepadDevice] = [:]
    private var slotAssignedAt: [UInt8: UInt64] = [:]
    private var pendingRumble: [UInt8: (low: UInt16, high: UInt16)] = [:]
    private var rumbleFlushScheduled = false

    private init() {}

    /// Input Monitoring as macOS reports it. Only asked for once a pad that
    /// GameController does not own is actually present, never at stream start.
    static var accessGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    func retain() {
        clients += 1
        guard clients == 1 else { return }
        let matches = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removed, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Diag.notice("Generic HID manager open: \(result)", "Controller")
        ownershipObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.recheckOwnership() } }
    }

    func release() {
        guard clients > 0 else { return }
        clients -= 1
        guard clients == 0 else { return }
        if let ownershipObserver { NotificationCenter.default.removeObserver(ownershipObserver) }
        ownershipObserver = nil
        for id in Array(devices.keys) { remove(id) }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func register(slot: UInt8, pad: HIDGamepadDevice) {
        slots[slot] = pad
        slotAssignedAt[slot] = DispatchTime.now().uptimeNanoseconds
        pendingRumble[slot] = nil
    }

    func unregister(slot: UInt8) {
        slots.removeValue(forKey: slot)?.rumble.close()
        slotAssignedAt[slot] = nil
        pendingRumble[slot] = nil
    }

    func enqueueRumble(_ values: [UInt8: (low: UInt16, high: UInt16)], submittedAt: [UInt8: UInt64]) {
        for (slot, motors) in values {
            guard let assignedAt = slotAssignedAt[slot], let receivedAt = submittedAt[slot],
                  assignedAt <= receivedAt else { continue }
            pendingRumble[slot] = motors
        }
        guard !pendingRumble.isEmpty, !rumbleFlushScheduled else { return }
        rumbleFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rumbleFlushScheduled = false
            let pending = self.pendingRumble
            self.pendingRumble.removeAll(keepingCapacity: true)
            for (slot, motors) in pending { self.slots[slot]?.rumble.set(low: motors.low, high: motors.high) }
        }
    }

    func stopRumble() {
        pendingRumble.removeAll(keepingCapacity: true)
        for pad in slots.values { pad.rumble.stop() }
    }

    private static let matched: IOHIDDeviceCallback = { context, result, _, device in
        guard result == kIOReturnSuccess, let context else { return }
        let owner = Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue()
        // The synchronous callback runs on the scheduled main run loop; the device remains alive across this assertion.
        let address = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            owner.add(Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue())
        }
    }

    private static let removed: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let owner = Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue()
        let address = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        MainActor.assumeIsolated {
            if let id = owner.devices.first(where: {
                UInt(bitPattern: Unmanaged.passUnretained($0.value.device).toOpaque()) == address
            })?.key { owner.remove(id) }
        }
    }

    /// Debug switch: `defaults write io.ugfugl.Glimmer hidGamepadClaimAll -bool YES` makes the
    /// HID path take pads GameController owns too, to exercise it without exotic hardware.
    static var claimAll: Bool { UserDefaults.standard.bool(forKey: "hidGamepadClaimAll") }

    private func add(_ device: IOHIDDevice) {
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        guard Self.claimAll || (![0x054C, 0x045E, 0x057E, 0x05AC].contains(vendor)
              && !GCController.controllers().contains(where: { name != nil && $0.vendorName == name })) else { return }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == kIOReturnSuccess,
              devices[id] == nil else { return }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Diag.notice("Generic HID pad present; Input Monitoring access=\(access.rawValue) (0 granted, 1 denied, 2 unknown)",
                    "Controller")
        let pad = HIDGamepadDevice(device: device, id: id)
        guard pad.open() else { return }
        devices[id] = pad
        pad.onReport = { [weak self] pad in self?.onReport?(pad) }
        Diag.notice("HID attached: \(pad.name) \(pad.hardwareID) \(pad.transport) registry=\(id) "
            + "mapping=\(pad.mappingSource)", "Controller")
        onAttach?(pad)
        if access != kIOHIDAccessTypeGranted { onPermissionNeeded?(pad) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.recheckOwnership() }
    }

    /// After a grant: re-open every pad so reports flow without a relaunch.
    func reopenAll() {
        for pad in devices.values where !pad.reopen() {
            Diag.notice("HID reopen failed: \(pad.name) \(pad.hardwareID)", "Controller")
        }
    }

    func recheckOwnership() {
        guard !Self.claimAll else { return }
        let names = Set(GCController.controllers().compactMap(\.vendorName))
        for pad in Array(devices.values) where names.contains(pad.name) {
            Diag.notice("HID yielding \(pad.name) to GameController", "Controller")
            remove(pad.id)
        }
    }

    private func remove(_ id: UInt64) {
        guard let pad = devices.removeValue(forKey: id) else { return }
        onDetach?(pad)
        pad.close()
    }
}
