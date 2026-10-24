// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct TouchLayoutEditor: View {
    let launch: StreamLaunch
    let area: CGRect
    let close: () -> Void
    @State private var draft = TouchLayout()
    @State private var selected: TouchElement = .rightStick
    @State private var size = 1.0
    @State private var dragging = false
    @State private var origin: TouchLayout.Placement?
    @State private var resetRequested = false
    @State private var family: TouchLayout.Family = .compact
    @State private var drafts: [TouchLayout.Family: TouchLayout] = [:]
    @State private var draftAreas: [TouchLayout.Family: CGRect] = [:]
    @State private var addBlocked = false
    @FocusState private var focused: TouchElement?

    var body: some View {
        ZStack(alignment: .top) {
            let frames = draft.frames(in: area)
            TouchGamepadRepresentation(layout: draft, area: area, preview: true).allowsHitTesting(false)
            ForEach(TouchElement.allCases) { element in
                if let frame = frames[element] {
                    Button { select(element) } label: {
                        Text(element.name).foregroundStyle(.clear)
                            .frame(width: frame.width, height: frame.height).contentShape(.rect)
                    }
                        .buttonStyle(.plain)
                        .focused($focused, equals: element)
                        .overlay {
                            if element == selected { RoundedRectangle(cornerRadius: 24).stroke(.tint, lineWidth: 3) }
                        }
                        .position(x: frame.midX, y: frame.midY)
                        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("touch-editor"))
                            .onChanged { move(element, $0.translation) }.onEnded { _ in finishMove() })
                        .onKeyPress(.leftArrow) { nudge(element, x: -12, y: 0); return .handled }
                        .onKeyPress(.rightArrow) { nudge(element, x: 12, y: 0); return .handled }
                        .onKeyPress(.upArrow) { nudge(element, x: 0, y: -12); return .handled }
                        .onKeyPress(.downArrow) { nudge(element, x: 0, y: 12); return .handled }
                        .accessibilityAction(named: "Move left") { nudge(element, x: -12, y: 0) }
                        .accessibilityAction(named: "Move right") { nudge(element, x: 12, y: 0) }
                        .accessibilityAction(named: "Move up") { nudge(element, x: 0, y: -12) }
                        .accessibilityAction(named: "Move down") { nudge(element, x: 0, y: 12) }
                }
            }
            if !dragging {
                let panel = inspectorFrame
                inspector.frame(width: panel.width, height: panel.height).position(x: panel.midX, y: panel.midY)
            }
        }
        .coordinateSpace(name: "touch-editor")
        .onAppear { load() }
        .onChange(of: area) { _, _ in
            dragging = false
            origin = nil
            drafts[family] = draft
            load()
        }
        .confirmationDialog("Reset this app's layout?", isPresented: $resetRequested, titleVisibility: .visible) {
            Button("Reset layout", role: .destructive) { draft = TouchLayout(); select(selected) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Move a control to make room.", isPresented: $addBlocked) { Button("OK", role: .cancel) {} }
    }

    private var inspector: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Edit controls").font(.headline)
                HStack {
                    Button("Cancel", action: close)
                    Spacer()
                    Button("Done", action: save).fontWeight(.semibold)
                }
                Text(selected.name).font(.subheadline)
                Slider(value: Binding(get: { size }, set: resize), in: 0.75...1.5, step: 0.05) { Text("Size") }
                    .accessibilityValue(size.formatted(.percent.precision(.fractionLength(0))))
                ViewThatFits(in: .horizontal) {
                    HStack { editingActions }
                    VStack { editingActions }
                }.buttonStyle(.bordered)
                if selected.isTrigger {
                    Text("Press fully, then drag inward to reduce the trigger.").font(.caption)
                }
            }.padding()
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }

    private var inspectorFrame: CGRect {
        let selectedFrame = draft.frames(in: area)[selected] ?? CGRect(x: area.midX, y: area.maxY, width: 0, height: 0)
        let candidates = [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, selectedFrame.minY - area.minY - 8)),
            CGRect(x: area.minX, y: selectedFrame.maxY + 8, width: area.width,
                   height: max(0, area.maxY - selectedFrame.maxY - 8)),
            CGRect(x: area.minX, y: area.minY, width: max(0, selectedFrame.minX - area.minX - 8), height: area.height),
            CGRect(x: selectedFrame.maxX + 8, y: area.minY,
                   width: max(0, area.maxX - selectedFrame.maxX - 8), height: area.height)
        ].filter { $0.width >= 200 && $0.height >= 100 }
        let region = candidates.max { min($0.width, 440) * min($0.height, 240)
            < min($1.width, 440) * min($1.height, 240) } ?? area
        let width = min(440, region.width - 16)
        let height = min(240, region.height - 8)
        return CGRect(x: region.midX - width / 2, y: region.minY + 4, width: width, height: height)
    }

    @ViewBuilder private var editingActions: some View {
        Button("Hide") {
            var value = draft.placement(selected, in: area)
            value.hidden = true
            draft.changes[selected] = value
        }
        Menu("Add control…") {
            ForEach(TouchElement.allCases.filter { draft.placement($0, in: area).hidden }) { element in
                Button(element.name) {
                    var value = draft.placement(element, in: area)
                    value.hidden = false
                    if draft.accepts(element, placement: value, in: area) {
                        draft.changes[element] = value
                        select(element)
                    } else { addBlocked = true }
                }
            }
        }
        Button("Reset layout…") { resetRequested = true }
    }

    private func save() {
        drafts[family] = draft
        let store = TouchLayoutStore(defaults: .standard)
        for (family, saved) in drafts {
            let defaults = TouchLayout.defaults(in: draftAreas[family] ?? area)
            var layout = saved
            layout.changes = layout.changes.filter { defaults[$0.key] != $0.value }
            store.save(layout, pcID: launch.pcID, appID: launch.appID, family: family)
        }
        close()
    }

    private func finishMove() {
        if let origin, draft.editable(in: area).placement(selected, in: area) != origin {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        dragging = false
        origin = nil
    }

    private func load() {
        family = TouchLayout.family(in: area)
        draftAreas[family] = area
        draft = drafts[family] ?? TouchLayoutStore(defaults: .standard).load(
            pcID: launch.pcID, appID: launch.appID, family: family)
        select(selected)
    }

    private func select(_ element: TouchElement) {
        selected = element
        size = draft.editable(in: area).placement(element, in: area).scale
    }

    private func resize(_ value: Double) {
        var placement = draft.editable(in: area).placement(selected, in: area)
        guard value != placement.scale else { return }
        placement.scale = value
        if let edited = draft.editing(selected, to: placement, in: area) { draft = edited }
        size = draft.editable(in: area).placement(selected, in: area).scale
    }

    private func move(_ element: TouchElement, _ translation: CGSize) {
        if origin == nil {
            select(element)
            origin = draft.editable(in: area).placement(element, in: area)
        }
        dragging = true
        guard var placement = origin else { return }
        placement.edge += element.isLeft ? translation.width : -translation.width
        placement.bottom -= translation.height
        if let edited = draft.editing(element, to: placement, in: area) { draft = edited }
    }

    private func nudge(_ element: TouchElement, x: Double, y: Double) {
        move(element, CGSize(width: x, height: y))
        dragging = false
        origin = nil
    }
}
