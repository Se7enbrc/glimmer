// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

@MainActor
final class IOSControllerLayouts {
    private struct Entry {
        let controller: GCController
        let registration: ControllerRegistration
        let reader: ControllerLayoutReader
        let mapsGameInput: Bool
        var lease: ControllerLayoutInputLease?
    }

    private let input: StreamInput
    private let scope: ControllerLayoutScope
    private let queue: DispatchQueue
    private var entries: [ObjectIdentifier: Entry] = [:]

    init(input: StreamInput, scope: ControllerLayoutScope, queue: DispatchQueue) {
        self.input = input
        self.scope = scope
        self.queue = queue
    }

    func configure(_ controller: GCController, registration: ControllerRegistration) {
        remove(controller)
        let model = ControllerLayoutsModel.shared
        guard model.loaded,
              let reader = ControllerLayoutReader(controller) else { return }
        let record = model.library.resolve(reader.identity, scope: scope)
        let shortcuts = model.shortcuts(for: reader.identity)
        guard let configuration = try? ControllerLayoutConfiguration(layout: record?.layout, shortcuts: shortcuts,
                available: reader.available, extras: reader.extras) else { return }
        input.setControllerLayout(configuration, for: registration,
                                  held: reader.sample(), systemHeld: reader.systemSample())
        entries[ObjectIdentifier(controller)] = Entry(controller: controller, registration: registration,
            reader: reader, mapsGameInput: configuration.plan != nil)
    }

    func install(_ controller: GCController) -> Bool {
        let id = ObjectIdentifier(controller)
        guard var entry = entries[id] else { return false }
        entry.lease?.stop()
        let reader = entry.reader
        let registration = entry.registration
        let mapsGameInput = entry.mapsGameInput
        entry.lease = ControllerLayoutInputLease(controller: controller, reader: reader,
            queue: queue) { [input] sample, now in
            input.submitController(registration, sample: reader.streamSample(sample, mapsGameInput: mapsGameInput),
                                   capturedAt: now)
        }
        entries[id] = entry
        return true
    }

    func sample(_ controller: GCController) -> ControllerInputSample? {
        guard let entry = entries[ObjectIdentifier(controller)] else { return nil }
        return entry.reader.streamSample(entry.reader.sample(), mapsGameInput: entry.mapsGameInput)
    }

    func suspend(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        entries[id]?.lease?.stop()
        entries[id]?.lease = nil
    }

    func remove(_ controller: GCController) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        entry.lease?.stop()
        input.setControllerLayout(nil, for: entry.registration,
                                  held: entry.reader.sample(), systemHeld: entry.reader.systemSample())
    }

    func stop() {
        for entry in entries.values { entry.lease?.stop() }
        entries.removeAll()
    }
}
