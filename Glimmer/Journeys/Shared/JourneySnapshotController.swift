// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GameController
import ObjectiveC

// All discovery and mutation happen on main; installed handlers run on the framework's assigned serial queue.
final class JourneySnapshotController: GCController {
    private let device = GCController.withExtendedGamepad()
    private let pad: JourneyTimestampGamepad
    private let category: String
    private let name: String
    override var extendedGamepad: GCExtendedGamepad? { pad }
    override var physicalInputProfile: GCPhysicalInputProfile { pad }
    override var input: GCControllerLiveInput { device.input }
    override var productCategory: String { category }
    override var vendorName: String? { name }
    override var isSnapshot: Bool { true }
    // A subclass never gets GameController's queue storage; reading the inherited property crashes.
    private var assignedQueue = DispatchQueue.main
    override var handlerQueue: DispatchQueue {
        get { assignedQueue }
        set { assignedQueue = newValue }
    }

    init(profile: String) {
        guard let gamepad = device.extendedGamepad else { preconditionFailure("Missing snapshot gamepad") }
        pad = JourneyTimestampGamepad(base: gamepad)
        category = profile == "ps" ? "Backbone One" : profile == "nintendo" ? "Switch Pro Controller" : "Xbox One"
        name = profile == "ps" ? "Backbone One PlayStation Edition" : category
        super.init()
        guard let pad = extendedGamepad else { return }
        let labels = profile == "ps" ? ["Cross", "Circle", "Square", "Triangle"]
            : profile == "nintendo" ? ["B", "A", "Y", "X"] : ["A", "B", "X", "Y"]
        let symbols = profile == "ps" ? ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"]
            : labels.map { $0.lowercased() + ".circle" }
        for (index, button) in [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY].enumerated() {
            button.localizedName = labels[index]
            button.unmappedLocalizedName = labels[index]
            button.sfSymbolsName = symbols[index]
            button.unmappedSfSymbolsName = symbols[index]
        }
    }

    @MainActor func send(element: String, value: Float, y: Float?, buttonOnly: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            send(element: element, value: value, y: y, buttonOnly: buttonOnly) { continuation.resume(returning: $0) }
        }
    }

    @MainActor func send(element: String, value: Float, y: Float?, buttonOnly: Bool = false,
                         completion: @escaping @Sendable (Bool) -> Void) {
        guard let pad = extendedGamepad, let changed = update(element: element, value: value, y: y) else {
            completion(false)
            return
        }
        let group = DispatchGroup()
        if buttonOnly, let button = changed as? GCControllerButtonInput {
            if let handler = button.pressedChangedHandler {
                deliver(Self.buttonDelivery(button, handler: handler), on: handlerQueue, group: group)
            }
        } else {
            if let handler = pad.valueChangedHandler {
                deliver(Self.delivery(pad, changed: changed, handler: handler), on: handlerQueue, group: group)
            }
            let physical = input.unmapped ?? input
            if let handler = physical.elementValueDidChangeHandler {
                deliver(Self.physicalDelivery(name: element, handler: handler),
                        on: physical.queue ?? handlerQueue, group: group)
            }
        }
        group.notify(queue: .global()) { @Sendable in completion(true) }
    }

    @MainActor private func deliver(_ work: DispatchWorkItem, on queue: DispatchQueue, group: DispatchGroup) {
        // Native menu tracking nests the main run loop inside a main-queue callback.
        if queue.label == DispatchQueue.main.label { work.perform(); return }
        group.enter()
        work.notify(queue: .global()) { @Sendable in group.leave() }
        queue.async(execute: work)
    }

    @MainActor private func update(element: String, value: Float, y: Float?) -> GCControllerElement? {
        guard let pad = extendedGamepad else { return nil }
        if let y {
            let axes = ["left": pad.leftThumbstick, "right": pad.rightThumbstick, "dpad": pad.dpad]
            guard let axis = axes[element] else { return nil }
            axis.setValueForXAxis(value, yAxis: y)
            return axis
        }
        let buttons = ["a": pad.buttonA, "b": pad.buttonB, "x": pad.buttonX, "y": pad.buttonY,
            "lb": pad.leftShoulder, "rb": pad.rightShoulder, "lt": pad.leftTrigger, "rt": pad.rightTrigger,
            "ls": pad.leftThumbstickButton, "rs": pad.rightThumbstickButton,
            "menu": pad.buttonMenu, "options": pad.buttonOptions].compactMapValues { $0 }
        guard let button = buttons[element] else { return nil }
        button.setValue(value)
        return button
    }

    private final class Element: NSObject, GCPhysicalInputElement {
        let aliases: Set<String>
        let localizedName: String? = nil
        let sfSymbolsName: String? = nil
        init(name: String) { aliases = [name] }
    }

    // Snapshot physical inputs report an old hardware latency; injected events occur at delivery time.
    private final class PhysicalEvent: GCControllerLiveInput {
        override var lastEventTimestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
        override var lastEventLatency: TimeInterval { 0 }
    }

    private static func physicalDelivery(name: String,
                                         handler: @escaping (any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void)
        -> DispatchWorkItem {
        DispatchWorkItem { handler(PhysicalEvent(), Element(name: name)) }
    }

    private static func buttonDelivery(_ button: GCControllerButtonInput,
                                       handler: @escaping GCControllerButtonValueChangedHandler) -> DispatchWorkItem {
        DispatchWorkItem { handler(button, button.value, button.isPressed) }
    }

    private static func delivery(_ pad: GCExtendedGamepad, changed: GCControllerElement,
                                 handler: @escaping GCExtendedGamepadValueChangedHandler) -> DispatchWorkItem {
        DispatchWorkItem { handler(pad, changed) }
    }
}

@MainActor
final class JourneyControllerRegistry {
    // The Objective-C discovery method and every mutation run on main, checked at the callback boundary.
    nonisolated(unsafe) private(set) var controllers: [GCController] = []
    private var original: IMP?

    func install() {
        precondition(ProcessInfo.processInfo.environment["GLIMMER_JOURNEY_DIRECTORY"] != nil)
        guard original == nil, let method = class_getClassMethod(GCController.self, #selector(GCController.controllers))
        else { return }
        // This process-only test replacement supplies devices at the framework discovery boundary.
        let block: @convention(block) () -> NSArray = { [self] in
            precondition(Thread.isMainThread)
            return controllers as NSArray
        }
        original = method_setImplementation(method, imp_implementationWithBlock(block))
        #if os(iOS)
        Self.hideHostKeyboardsAndMice()
        #endif
    }

    #if os(iOS)
    /// Simulators forward the host's own mice and keyboards (CI's VM adds a Generic Keyboard); fixtures see none.
    static func hideHostKeyboardsAndMice() {
        replace(GCMouse.self, #selector(GCMouse.mice),
                with: { () -> NSArray in [] } as @convention(block) () -> NSArray)
        replace(GCMouse.self, #selector(getter: GCMouse.current),
                with: { () -> GCMouse? in nil } as @convention(block) () -> GCMouse?)
        replace(GCKeyboard.self, #selector(getter: GCKeyboard.coalesced),
                with: { () -> GCKeyboard? in nil } as @convention(block) () -> GCKeyboard?)
    }
    #endif

    private static func replace(_ type: AnyClass, _ selector: Selector, with block: Any) {
        guard let method = class_getClassMethod(type, selector) else { return }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    func add(_ controller: GCController) {
        controllers.append(controller)
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: controller)
    }

    func remove(_ controller: GCController) {
        controllers.removeAll { $0 === controller }
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
    }
}
#endif
