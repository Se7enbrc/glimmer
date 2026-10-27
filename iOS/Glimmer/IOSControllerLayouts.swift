// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

@MainActor
final class IOSControllerLayouts {
    struct Entry {
        let controller: GCController
        let registration: ControllerRegistration
        let reader: ControllerLayoutReader
        let mapsGameInput: Bool
        let shortcutElements: Set<ObjectIdentifier>
    }

    private let input: StreamInput
    private let scope: ControllerLayoutScope
    private var entries: [ObjectIdentifier: Entry] = [:]

    init(input: StreamInput, scope: ControllerLayoutScope) {
        self.input = input
        self.scope = scope
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
            reader: reader, mapsGameInput: configuration.plan != nil,
            shortcutElements: reader.shortcutElements(configuration))
    }

    func entry(_ controller: GCController) -> Entry? { entries[ObjectIdentifier(controller)] }

    func sample(_ controller: GCController) -> ControllerInputSample? {
        guard let entry = entries[ObjectIdentifier(controller)] else { return nil }
        return entry.reader.streamSample(entry.reader.sample(), mapsGameInput: entry.mapsGameInput)
    }

    func remove(_ controller: GCController) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        input.setControllerLayout(nil, for: entry.registration,
                                  held: entry.reader.sample(), systemHeld: entry.reader.systemSample())
    }

    func stop() {
        entries.removeAll()
    }
}
