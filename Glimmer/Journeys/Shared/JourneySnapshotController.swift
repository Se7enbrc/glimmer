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
        guard let pad = extendedGamepad else { return false }
        let changed: GCControllerElement
        if let y {
            let axes = ["left": pad.leftThumbstick, "right": pad.rightThumbstick, "dpad": pad.dpad]
            guard let axis = axes[element] else { return false }
            axis.setValueForXAxis(value, yAxis: y)
            changed = axis
        } else {
            let buttons = ["a": pad.buttonA, "b": pad.buttonB, "x": pad.buttonX, "y": pad.buttonY,
                "lb": pad.leftShoulder, "rb": pad.rightShoulder, "lt": pad.leftTrigger, "rt": pad.rightTrigger,
                "ls": pad.leftThumbstickButton, "rs": pad.rightThumbstickButton,
                "menu": pad.buttonMenu, "options": pad.buttonOptions].compactMapValues { $0 }
            guard let button = buttons[element] else { return false }
            button.setValue(value)
            changed = button
        }
        if buttonOnly, let button = changed as? GCControllerButtonInput {
            if let handler = button.pressedChangedHandler {
                await withCheckedContinuation { continuation in
                    handlerQueue.async(execute: Self.buttonDelivery(button, handler: handler) { continuation.resume() })
                }
            }
            return true
        }
        if let handler = pad.valueChangedHandler {
            await withCheckedContinuation { continuation in
                handlerQueue.async(execute: Self.delivery(pad, changed: changed, handler: handler) { continuation.resume() })
            }
        }
        let physical = input.unmapped ?? input
        if let handler = physical.elementValueDidChangeHandler {
            let queue = physical.queue ?? handlerQueue
            await withCheckedContinuation { continuation in
                queue.async(execute: Self.physicalDelivery(name: element, handler: handler) {
                    continuation.resume()
                })
            }
        }
        return true
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
                                         handler: @escaping (any GCDevicePhysicalInput, any GCPhysicalInputElement) -> Void,
                                         completion: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        DispatchWorkItem { handler(PhysicalEvent(), Element(name: name)); completion() }
    }

    private static func buttonDelivery(_ button: GCControllerButtonInput,
                                       handler: @escaping GCControllerButtonValueChangedHandler,
                                       completion: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        DispatchWorkItem { handler(button, button.value, button.isPressed); completion() }
    }

    private static func delivery(_ pad: GCExtendedGamepad, changed: GCControllerElement,
                                 handler: @escaping GCExtendedGamepadValueChangedHandler,
                                 completion: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        DispatchWorkItem { handler(pad, changed); completion() }
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
    }

    func add(_ controller: GCController) {
        controllers.append(controller)
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: controller)
    }

    func removeLast() {
        guard let controller = controllers.popLast() else { return }
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
    }
}
#endif
