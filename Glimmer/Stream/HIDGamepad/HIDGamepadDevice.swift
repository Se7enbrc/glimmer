import Foundation
import IOKit.hid

@MainActor
final class HIDGamepadDevice: Identifiable {
    let device: IOHIDDevice
    let id: UInt64
    let vendor: UInt16
    let product: UInt16
    let version: UInt16
    let transport: String
    let name: String
    let mapping: HIDGamepadMapping
    let rumble: HIDGamepadRumble
    private(set) var snapshot = HIDGamepadSnapshot()
    private(set) var reportCount: UInt64 = 0
    private var elements: [UInt32: IOHIDElement] = [:]
    private var axes: [HIDGamepadElement] = []
    private var buttons: [HIDGamepadElement] = []
    private var hats: [HIDGamepadElement] = []
    private var ranges: [UInt32: HIDGamepadElement.AxisRange] = [:]
    private var batteryElement: IOHIDElement?
    private var pendingReport: UInt64?
    private var pendingReportID: UInt32?
    private var flushScheduled = false
    private var opened = false
    var onReport: ((HIDGamepadDevice) -> Void)?

    var state: (buttons: Int32, analog: GamepadAnalog) { mapping.translate(snapshot) }
    var hasBattery: Bool { batteryElement != nil }
    var hardwareID: String { String(format: "%04X:%04X", vendor, product) }
    var mappingSource: String { mapping.isHeuristic ? "heuristic" : mapping.name }

    init(device: IOHIDDevice, id: UInt64) {
        self.device = device
        self.id = id
        func number(_ key: String) -> UInt16 {
            UInt16(truncatingIfNeeded: (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0)
        }
        vendor = number(kIOHIDVendorIDKey)
        product = number(kIOHIDProductIDKey)
        version = number(kIOHIDVersionNumberKey)
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "HID Gamepad"
        transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        let discovered = Self.discover(device)
        elements = discovered.references
        axes = HIDGamepadElement.ordered(discovered.descriptors, kind: .axis)
        buttons = HIDGamepadElement.ordered(discovered.descriptors, kind: .button)
        hats = HIDGamepadElement.ordered(discovered.descriptors, kind: .hat)
        batteryElement = discovered.descriptors.first { $0.kind == .battery }.flatMap { discovered.references[$0.cookie] }
        mapping = GameControllerDB.lookup(vendor: vendor, product: product, version: version,
                                          bus: GameControllerDB.bus(forTransport: transport))
            ?? .heuristic(elements: discovered.descriptors)
        rumble = HIDGamepadRumble(service: IOHIDDeviceGetService(device))
        snapshot.axes = Array(repeating: 0, count: axes.count)
        snapshot.buttons = Array(repeating: false, count: buttons.count)
        snapshot.hats = Array(repeating: 0, count: hats.count)
        for descriptor in axes {
            guard let element = elements[descriptor.cookie] else { continue }
            ranges[descriptor.cookie] = .init(minimum: IOHIDElementGetLogicalMin(element),
                                              maximum: IOHIDElementGetLogicalMax(element))
        }
        if mapping.isHeuristic {
            Diag.notice("Unmapped HID pad \(name) \(hardwareID): assuming X/Y left stick, Z/Rz right stick, "
                + "Rx/Ry or brake/accelerator triggers, first hat dpad, standard b0–b11 layout", "Controller")
        }
    }

    func open() -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Diag.notice("HID open failed \(name) \(hardwareID): \(result)", "Controller")
            return false
        }
        opened = true
        for element in elements.values {
            if let value = read(element) { update(value) }
        }
        IOHIDDeviceRegisterInputValueCallback(device, Self.inputValue, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    /// Close and open again (after an Input Monitoring grant); keeps `onReport`.
    func reopen() -> Bool {
        if opened {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
        }
        return open()
    }

    func close() {
        guard opened else { return }
        opened = false
        pendingReport = nil
        pendingReportID = nil
        onReport = nil
        rumble.close()
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var batteryPercentage: UInt8? {
        guard let element = batteryElement else { return nil }
        guard let value = read(element) else { return nil }
        let minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element)
        guard maximum > minimum else { return nil }
        let fraction = Double(IOHIDValueGetIntegerValue(value) - minimum) / Double(maximum - minimum)
        return UInt8((min(1, max(0, fraction)) * 100).rounded())
    }

    private func read(_ element: IOHIDElement) -> IOHIDValue? {
        let pointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard IOHIDDeviceGetValue(device, element, pointer) == kIOReturnSuccess else { return nil }
        return pointer.pointee.takeUnretainedValue()
    }

    private static let inputValue: IOHIDValueCallback = { context, result, _, value in
        guard result == kIOReturnSuccess, let context else { return }
        let owner = Unmanaged<HIDGamepadDevice>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        let cookie = IOHIDElementGetCookie(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let timestamp = IOHIDValueGetTimeStamp(value)
        let reportID = IOHIDElementGetReportID(element)
        MainActor.assumeIsolated { owner.receive(cookie: cookie, raw: raw, timestamp: timestamp, reportID: reportID) }
    }

    private func receive(cookie: UInt32, raw: Int, timestamp: UInt64, reportID: UInt32) {
        guard opened else { return }
        if pendingReport != nil && (pendingReport != timestamp || pendingReportID != reportID) { flush() }
        pendingReport = timestamp
        pendingReportID = reportID
        update(cookie: cookie, raw: raw)
        guard !flushScheduled else { return }
        flushScheduled = true
        // Element callbacks from one report share a timestamp; flush its final snapshot after the callback batch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    private func flush() {
        guard opened, pendingReport != nil else { return }
        pendingReport = nil
        pendingReportID = nil
        reportCount &+= 1
        onReport?(self)
    }

    private func update(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let cookie = IOHIDElementGetCookie(element)
        update(cookie: cookie, raw: IOHIDValueGetIntegerValue(value))
    }

    private func update(cookie: UInt32, raw: Int) {
        guard let element = elements[cookie] else { return }
        if let index = axes.firstIndex(where: { $0.cookie == cookie }), var range = ranges[cookie] {
            snapshot.axes[index] = range.scale(raw)
            ranges[cookie] = range
        } else if let index = buttons.firstIndex(where: { $0.cookie == cookie }) {
            snapshot.buttons[index] = raw > 0
        } else if let index = hats.firstIndex(where: { $0.cookie == cookie }) {
            snapshot.hats[index] = HIDGamepadElement.hat(value: raw, minimum: IOHIDElementGetLogicalMin(element),
                                                        maximum: IOHIDElementGetLogicalMax(element))
        }
    }

    private static func discover(_ device: IOHIDDevice)
        -> (descriptors: [HIDGamepadElement], references: [UInt32: IOHIDElement]) {
        var descriptors: [HIDGamepadElement] = []
        var references: [UInt32: IOHIDElement] = [:]
        var seen: Set<UInt32> = []
        func visit(_ element: IOHIDElement) {
            let cookie = IOHIDElementGetCookie(element)
            guard seen.insert(cookie).inserted else { return }
            let type = IOHIDElementGetType(element)
            if type == kIOHIDElementTypeCollection {
                for child in IOHIDElementGetChildren(element) as? [IOHIDElement] ?? [] { visit(child) }
                return
            }
            guard [kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Button, kIOHIDElementTypeInput_Axis]
                .contains(type) else { return }
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            guard let kind = HIDGamepadElement.classify(page: page, usage: usage) else { return }
            descriptors.append(.init(cookie: cookie, page: page, usage: usage, kind: kind))
            references[cookie] = element
        }
        for element in IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? [] { visit(element) }
        return (descriptors, references)
    }
}
