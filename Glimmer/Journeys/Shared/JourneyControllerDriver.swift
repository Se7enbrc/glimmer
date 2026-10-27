// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GameController
import Foundation

@MainActor
final class JourneyControllerDriver {
    struct Command: Decodable {
        let id: Int
        let connect: Bool?
        let profile: String?
        let slot: Int?
        let steps: [Step]?
    }
    struct Step: Decodable {
        let element: String
        let value: Double
        let y: Double?
        let milliseconds: Int?
        let route: String?
    }

    private let directory: URL
    private let receipts: JourneyReceipts
    #if os(iOS)
    private var virtual: GCVirtualController?
    #endif
    private let registry = JourneyControllerRegistry()
    private var snapshots: [JourneySnapshotController] = []
    private var task: Task<Void, Never>?
    private var lastID = 0
    var controllers: [GCController] {
        #if os(iOS)
        snapshots + (virtual?.controller.map { [$0] } ?? [])
        #else
        snapshots
        #endif
    }

    init(directory: URL, receipts: JourneyReceipts) {
        self.directory = directory
        self.receipts = receipts
    }

    func start() {
        registry.install()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await readCommand()
                    try await Task.sleep(for: .milliseconds(10))
                } catch is CancellationError { return } catch {
                    receipts.record(["controllerError": 1])
                }
            }
        }
    }

    private func readCommand() async throws {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("gamecontroller.json")),
              let command = try? JSONDecoder().decode(Command.self, from: data), command.id != lastID else { return }
        lastID = command.id
        if let connect = command.connect { try await connection(connect, profile: command.profile) }
        for step in command.steps ?? [] {
            guard let element = Self.elements[step.element] else {
                receipts.record(["controllerError": 1])
                return
            }
            receipts.record(["injected": Double(command.id)])
            if let snapshot = snapshots.indices.contains(command.slot ?? 0) ? snapshots[command.slot ?? 0] : nil {
                let physical = snapshot.input.unmapped ?? snapshot.input
                receipts.record(["gcProfileCallback": snapshot.extendedGamepad?.valueChangedHandler == nil ? 0 : 1,
                                 "gcPhysicalCallback": physical.elementValueDidChangeHandler == nil ? 0 : 1])
                guard await snapshot.send(element: step.element, value: Float(step.value),
                                          y: step.y.map(Float.init), buttonOnly: step.route == "button")
                else { receipts.record(["controllerError": 1]); return }
            } else {
                #if os(iOS)
                if let virtual, let y = step.y {
                    virtual.setPosition(CGPoint(x: step.value, y: y), forDirectionPadElement: element)
                } else { virtual?.setValue(step.value, forButtonElement: element) }
                #endif
            }
            if let delay = step.milliseconds { try await Task.sleep(for: .milliseconds(delay)) }
        }
        receipts.record(["command": Double(command.id)])
    }

    private func connection(_ connect: Bool, profile: String?) async throws {
        if connect, let profile {
            let snapshot = JourneySnapshotController(profile: profile)
            receipts.record(["profileButtons": Double(snapshot.input.buttons.count),
                             "unmappedButtons": Double(snapshot.input.unmapped?.buttons.count ?? 0)])
            snapshots.append(snapshot)
            registry.add(snapshot)
        } else if connect {
            #if os(iOS)
            let configuration = GCVirtualController.Configuration()
            configuration.isHidden = true
            configuration.elements = Set(Self.elements.values)
            let controller = GCVirtualController(configuration: configuration)
            virtual = controller
            try await controller.connect()
            // Discovery is limited to journey devices, so the framework controller joins it explicitly.
            if let device = controller.controller { registry.add(device) }
            #endif
        } else if !snapshots.isEmpty, let snapshot = snapshots.popLast() {
            registry.remove(snapshot)
        } else {
            #if os(iOS)
            if let device = virtual?.controller { registry.remove(device) }
            virtual?.disconnect()
            virtual = nil
            #endif
        }
        receipts.record(["gcConnected": Double(controllers.count)])
    }

    private static let elements = [
        "a": GCInputButtonA, "b": GCInputButtonB, "x": GCInputButtonX, "y": GCInputButtonY,
        "lb": GCInputLeftShoulder, "rb": GCInputRightShoulder,
        "lt": GCInputLeftTrigger, "rt": GCInputRightTrigger,
        "ls": GCInputLeftThumbstickButton, "rs": GCInputRightThumbstickButton,
        "menu": GCInputButtonMenu, "options": GCInputButtonOptions,
        "left": GCInputLeftThumbstick, "right": GCInputRightThumbstick, "dpad": GCInputDirectionPad
    ]
}
#endif
