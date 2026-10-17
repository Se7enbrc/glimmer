// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import Observation
import OSLog

struct ControllerSnapshot: Identifiable, Equatable {
    let id: ObjectIdentifier
    let name: String
    let hasExtendedGamepad: Bool
}

@MainActor
@Observable
final class ControllerMonitor {
    private(set) var controllers: [ControllerSnapshot] = []
    private let center: NotificationCenter
    private let readControllers: @MainActor () -> [ControllerSnapshot]
    private let logConnection: @MainActor (ControllerSnapshot, Bool) -> Void
    private var observations: [NSObjectProtocol] = []
    private var generation = 0

    init(
        center: NotificationCenter = .default,
        readControllers: @escaping @MainActor () -> [ControllerSnapshot] = { ControllerMonitor.connectedControllers() },
        logConnection: @escaping @MainActor (ControllerSnapshot, Bool) -> Void = ControllerMonitor.logConnection
    ) {
        self.center = center
        self.readControllers = readControllers
        self.logConnection = logConnection
    }

    isolated deinit {
        for observation in observations { center.removeObserver(observation) }
    }

    func start() {
        guard observations.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.refresh()
                }
            })
        }
        refresh()
    }

    func stop() {
        generation += 1
        for observation in observations { center.removeObserver(observation) }
        observations.removeAll()
        controllers.removeAll()
    }

    func refresh() {
        guard !observations.isEmpty else { return }
        let connected = readControllers()
        for controller in connected where !controllers.contains(where: { $0.id == controller.id }) {
            logConnection(controller, true)
        }
        for controller in controllers where !connected.contains(where: { $0.id == controller.id }) {
            logConnection(controller, false)
        }
        controllers = connected
    }

    static func connectedControllers(
        _ controllers: [GCController] = GCController.controllers()
    ) -> [ControllerSnapshot] {
        controllers.map {
            ControllerSnapshot(id: ObjectIdentifier($0), name: $0.vendorName ?? "Controller",
                               hasExtendedGamepad: $0.extendedGamepad != nil)
        }
    }

    static func logConnection(_ controller: ControllerSnapshot, connected: Bool) {
        let logger = Logger(subsystem: "io.ugfugl.Glimmer", category: "Controllers")
        logger.info("""
                    Controller connected=\(connected) extended=\(controller.hasExtendedGamepad) \
                    name=\(controller.name, privacy: .private)
                    """)
    }
}
