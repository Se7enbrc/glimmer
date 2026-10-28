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
    struct Step: Decodable, Sendable {
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
    #if os(macOS)
    private var timer: Timer?
    private var command: Command?
    private var stepIndex = 0
    private var nextStepAt: TimeInterval = 0
    private var delivering = false
    #endif
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
        #if os(macOS)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceCommand() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        #else
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
        #endif
    }

    #if os(macOS)
    private func advanceCommand() {
        guard !delivering, ProcessInfo.processInfo.systemUptime >= nextStepAt else { return }
        if command == nil {
            guard let next = nextCommand() else { return }
            command = next
            stepIndex = 0
            if let connect = next.connect {
                _ = snapshotConnection(connect, profile: next.profile)
                receipts.record(["gcConnected": Double(controllers.count)])
            }
        }
        guard let command else { return }
        let steps = command.steps ?? []
        guard stepIndex < steps.count else {
            receipts.record(["command": Double(command.id)])
            self.command = nil
            return
        }
        let step = steps[stepIndex]
        guard Self.elements[step.element] != nil, snapshots.indices.contains(command.slot ?? 0) else {
            receipts.record(["controllerError": 1])
            self.command = nil
            return
        }
        let snapshot = snapshots[command.slot ?? 0]
        receipts.record(["injected": Double(command.id)])
        delivering = true
        snapshot.send(element: step.element, value: Float(step.value), y: step.y.map(Float.init),
                      buttonOnly: step.route == "button") { [weak self] success in
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !success { self.receipts.record(["controllerError": 1]) }
                    self.stepIndex += 1
                    self.nextStepAt = ProcessInfo.processInfo.systemUptime + Double(step.milliseconds ?? 0) / 1000
                    self.delivering = false
                }
            }
        }
    }
    #endif

    private func nextCommand() -> Command? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("gamecontroller.json")),
              let command = try? JSONDecoder().decode(Command.self, from: data), command.id != lastID else { return nil }
        lastID = command.id
        return command
    }

    private func readCommand() async throws {
        guard let command = nextCommand() else { return }
        if let connect = command.connect { try await connection(connect, profile: command.profile) }
        for step in command.steps ?? [] {
            guard let element = Self.elements[step.element] else {
                receipts.record(["controllerError": 1])
                return
            }
            receipts.record(["injected": Double(command.id)])
            if let snapshot = snapshots.indices.contains(command.slot ?? 0) ? snapshots[command.slot ?? 0] : nil {
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

    private func snapshotConnection(_ connect: Bool, profile: String?) -> Bool {
        if connect, let profile {
            let snapshot = JourneySnapshotController(profile: profile)
            snapshots.append(snapshot)
            registry.add(snapshot)
            return true
        }
        if !connect, let snapshot = snapshots.popLast() {
            registry.remove(snapshot)
            return true
        }
        return false
    }

    private func connection(_ connect: Bool, profile: String?) async throws {
        if !snapshotConnection(connect, profile: profile) {
            #if os(iOS)
            if connect {
                let configuration = GCVirtualController.Configuration()
                configuration.isHidden = true
                configuration.elements = Set(Self.elements.values)
                let controller = GCVirtualController(configuration: configuration)
                virtual = controller
                try await controller.connect()
                if let device = controller.controller { registry.add(device) }
            } else {
                if let device = virtual?.controller { registry.remove(device) }
                virtual?.disconnect()
                virtual = nil
            }
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
