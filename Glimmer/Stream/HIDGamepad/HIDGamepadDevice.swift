// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
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
    let serialNumber: String?
    let layoutExtras: [(index: Int, name: String)]
    let mapping: HIDGamepadMapping
    let rumble: HIDGamepadRumble
    let capture: HIDGamepadCapture
    var reportCount: UInt64 { capture.count }
    private var elements: [UInt32: IOHIDElement] = [:]
    private var batteryElement: IOHIDElement?
    private var opened = false
    private var reading = false

    var state: (buttons: Int32, analog: GamepadAnalog) { capture.state }
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
        serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        let discovered = Self.discover(device)
        elements = discovered.references
        let readings = HIDGamepadReadings(descriptors: discovered.descriptors,
                                      logical: discovered.references.mapValues(Self.logicalRange))
        batteryElement = discovered.descriptors.first { $0.kind == .battery }.flatMap { discovered.references[$0.cookie] }
        mapping = GameControllerDB.lookup(vendor: vendor, product: product, version: version,
                                          bus: GameControllerDB.bus(forTransport: transport))
            ?? .heuristic(elements: discovered.descriptors)
        let boundButtons = Set(mapping.bindings.values.compactMap { input -> Int? in
            if case .button(let index) = input { return index }
            return nil
        })
        var occurrences: [String: Int] = [:]
        layoutExtras = HIDGamepadElement.ordered(discovered.descriptors, kind: .button).enumerated().compactMap { index, element in
            let usage = "hid.button.\(element.page).\(element.usage)"
            let occurrence = occurrences[usage, default: 0]
            occurrences[usage] = occurrence + 1
            guard !boundButtons.contains(index) else { return nil }
            return (index, "\(usage).\(occurrence)")
        }.prefix(128).map { $0 }
        capture = HIDGamepadCapture(readings: readings, mapping: mapping)
        rumble = HIDGamepadRumble(service: IOHIDDeviceGetService(device))
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
        return true
    }

    func startReading() {
        guard opened, !reading else { return }
        reading = true
        for element in elements.values {
            if let value = read(element) { update(value) }
        }
        registerInputCallback(true)
    }

    func stopReading() {
        guard reading else { return }
        reading = false
        registerInputCallback(false)
    }

    private func registerInputCallback(_ enabled: Bool) {
        let address = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        // Unregistration drains earlier callbacks before the main actor can release their capture context.
        HIDInputThread.shared.sync { [capture] in
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            capture.setReading(enabled)
            IOHIDDeviceRegisterInputValueCallback(device, enabled ? HIDGamepadCapture.inputValue : nil,
                                                  enabled ? Unmanaged.passUnretained(capture).toOpaque() : nil)
        }
    }

    /// Close and open again (after an Input Monitoring grant); keeps the capture subscriber.
    func reopen() -> Bool {
        let wasReading = reading
        if opened {
            stopReading()
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
        }
        guard open() else { return false }
        if wasReading { startReading() }
        return true
    }

    func close() {
        guard opened else { return }
        stopReading()
        opened = false
        capture.setHandler(nil)
        rumble.close()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var batteryPercentage: UInt8? {
        guard let element = batteryElement else { return nil }
        guard let value = read(element) else { return nil }
        return HIDGamepadReadings.batteryPercentage(raw: IOHIDValueGetIntegerValue(value),
                                                    range: Self.logicalRange(element))
    }

    private static func logicalRange(_ element: IOHIDElement) -> HIDGamepadElement.AxisRange {
        .init(minimum: IOHIDElementGetLogicalMin(element), maximum: IOHIDElementGetLogicalMax(element))
    }

    private func read(_ element: IOHIDElement) -> IOHIDValue? {
        let pointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard IOHIDDeviceGetValue(device, element, pointer) == kIOReturnSuccess else { return nil }
        return pointer.pointee.takeUnretainedValue()
    }

    private func update(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let cookie = IOHIDElementGetCookie(element)
        capture.update(cookie: cookie, raw: IOHIDValueGetIntegerValue(value))
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
