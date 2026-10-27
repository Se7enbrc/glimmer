// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct TouchLayoutEditor: View {
    let launch: StreamLaunch
    let area: CGRect
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var draft = TouchLayout()
    @State private var selected: TouchElement?
    @State private var size = 1.0
    @State private var dragging = false
    @State private var origin: TouchLayout.Placement?
    @State private var resetRequested = false
    @State private var family: TouchLayout.Family = .compact
    @State private var drafts: [TouchLayout.Family: TouchLayout] = [:]
    @State private var draftAreas: [TouchLayout.Family: CGRect] = [:]
    @State private var addBlocked = false
    @FocusState private var focused: TouchElement?

    init(launch: StreamLaunch, area: CGRect, selected: TouchElement? = nil, close: @escaping () -> Void) {
        self.launch = launch
        self.area = area
        self.close = close
        _selected = State(initialValue: selected)
    }

    var body: some View {
        ZStack(alignment: .top) {
            let frames = draft.frames(in: area)
            TouchGamepadRepresentation(layout: draft, area: area, preview: true)
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(TouchElement.allCases) { element in
                if let frame = frames[element] {
                    Button { select(element) } label: {
                        Text(element.name).foregroundStyle(.clear)
                            .frame(width: frame.width, height: frame.height).contentShape(.rect)
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("touch-editor-\(element.rawValue)")
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
            Button("Reset layout", role: .destructive) { draft = TouchLayout(); select(nil) }
                .accessibilityIdentifier("touch-editor-reset-confirm")
            Button("Cancel", role: .cancel) {}.accessibilityIdentifier("touch-editor-reset-cancel")
        }
        .alert("Move a control to make room.", isPresented: $addBlocked) {
            Button("OK", role: .cancel) {}.accessibilityIdentifier("touch-editor-room-dismiss")
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    cancelButton
                    Spacer(minLength: 0)
                    title
                    Spacer(minLength: 0)
                    doneButton
                }
                // A narrow panel drops the title rather than spend a second row on it.
                HStack { cancelButton; Spacer(minLength: 8); doneButton }
                VStack(spacing: 8) { doneButton; cancelButton }
            }
            .padding(12)
            ScrollView {
                VStack(spacing: 10) {
                    // At accessibility sizes the actions lead the list; pinned, they would fill the panel.
                    if textSize.isAccessibilitySize { actions }
                    if let selected {
                        VStack(alignment: .leading, spacing: 4) {
                            ViewThatFits(in: .horizontal) {
                                HStack { selectedName(selected); Spacer(); hideButton(selected) }
                                VStack(alignment: .leading) { selectedName(selected); hideButton(selected) }
                            }
                            sizeControl
                            if selected.isTrigger {
                                Text("Press fully, then drag inward to reduce the trigger.").font(.caption)
                            }
                        }
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All controls").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        opacityControl
                    }
                    if selected == nil {
                        Text("Select a control to move or resize it.").font(.callout).foregroundStyle(.secondary)
                    } else if !textSize.isAccessibilitySize {
                        actions
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .accessibilityIdentifier("touch-editor-inspector")
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // While a control is selected its settings get the room; the actions follow them.
                if !textSize.isAccessibilitySize && selected == nil {
                    actions.padding(.horizontal, 8).padding(.vertical, 12)
                }
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .tint(.primary)
    }

    private func selectedName(_ element: TouchElement) -> some View {
        Text(element.name).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func hideButton(_ element: TouchElement) -> some View {
        Button("Hide") { hide(element) }.buttonStyle(.bordered).controlSize(.large)
            .accessibilityIdentifier("touch-editor-hide")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { editingActions }
            HStack(spacing: 6) { editingActions }.font(.subheadline)
            HStack(spacing: 6) { editingActions }.font(.footnote)
            VStack { editingActions }
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    // At accessibility sizes Cancel and Done name the mode; the title would crowd out the controls.
    @ViewBuilder private var title: some View {
        if !textSize.isAccessibilitySize {
            Text("Edit controls").font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }

    private var cancelButton: some View {
        Button("Cancel", action: close).lineLimit(1).fixedSize().buttonStyle(.bordered).controlSize(.large)
            .accessibilityIdentifier("touch-editor-cancel")
    }

    private var doneButton: some View {
        Button("Done", action: save).lineLimit(1).fixedSize().fontWeight(.semibold).foregroundStyle(.background)
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("touch-editor-done")
    }

    private var sizeControl: some View {
        HStack {
            Text("Size").font(.subheadline).accessibilityHidden(true)
            Slider(value: Binding(get: { size }, set: { resize($0) }), in: 0.75...1.5, step: 0.05) { Text("Size") }
                .accessibilityIdentifier("touch-editor-size")
                .accessibilityValue(size.formatted(.percent.precision(.fractionLength(0))))
        }.frame(minWidth: 140)
    }

    private var opacityControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Opacity")
                Spacer()
                Text(draft.opacity, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline).accessibilityHidden(true)
            // Whole percentage points keep SwiftUI's stepped range from truncating the final fractional step.
            Slider(value: Binding(get: { draft.opacity * 100 }, set: { draft.opacity = $0 / 100 }),
                   in: (TouchLayout.opacityRange.lowerBound * 100)...(TouchLayout.opacityRange.upperBound * 100),
                   step: 5) { Text("Opacity") }
                .accessibilityIdentifier("touch-editor-opacity")
                .accessibilityValue(draft.opacity.formatted(.percent.precision(.fractionLength(0))))
        }.frame(minWidth: 140)
    }

    private var inspectorFrame: CGRect {
        let frames = draft.frames(in: area)
        // Dock between the controls so every one stays tappable while the panel is open.
        let band = TouchLayout.clearArea(in: area, avoiding: Array(frames.values),
                                         target: CGSize(width: 400, height: 200))
        // Accessibility sizes dock only where Cancel and Done fit side by side.
        if band.width >= (textSize.isAccessibilitySize ? 420 : 260), band.height >= 180 {
            let width = min(textSize.isAccessibilitySize ? 560 : 440, band.width - 8)
            let preferred = textSize.isAccessibilitySize ? band.height : selected == nil ? 300.0 : 360.0
            let height = min(preferred, band.height - 8)
            return CGRect(x: band.midX - width / 2, y: band.minY + 4, width: width, height: height)
        }
        let selectedFrame = selected.flatMap { frames[$0] } ?? CGRect(x: area.midX, y: area.maxY, width: 0, height: 0)
        let candidates = [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, selectedFrame.minY - area.minY - 8)),
            CGRect(x: area.minX, y: selectedFrame.maxY + 8, width: area.width,
                   height: max(0, area.maxY - selectedFrame.maxY - 8)),
            CGRect(x: area.minX, y: area.minY, width: max(0, selectedFrame.minX - area.minX - 8), height: area.height),
            CGRect(x: selectedFrame.maxX + 8, y: area.minY,
                   width: max(0, area.maxX - selectedFrame.maxX - 8), height: area.height)
        ].filter { $0.width >= 200 && $0.height >= 100 }
        let region = candidates.max { min($0.width, 440) * min($0.height, 340)
            < min($1.width, 440) * min($1.height, 340) } ?? area
        let width = min(440, region.width - 16)
        let preferredHeight = textSize.isAccessibilitySize ? region.height - 8 : selected == nil ? 280.0 : 340.0
        let height = min(preferredHeight, region.height - 8)
        return CGRect(x: region.midX - width / 2, y: region.minY + 4, width: width, height: height)
    }

    @ViewBuilder private var editingActions: some View {
        Menu("Add control…") {
            ForEach(TouchElement.allCases.filter { draft.placement($0, in: area).hidden }) { element in
                Button(element.name) {
                    var value = draft.placement(element, in: area)
                    value.hidden = false
                    if draft.accepts(element, placement: value, in: area) {
                        draft.changes[element] = value
                        select(element)
                    } else { addBlocked = true }
                }.accessibilityIdentifier("touch-editor-add-\(element.rawValue)")
            }
        }.accessibilityIdentifier("touch-editor-add")
        Button("Reset layout…") { resetRequested = true }.accessibilityIdentifier("touch-editor-reset")
    }

    private func save() {
        drafts[family] = draft
        let store = TouchLayoutStore(defaults: PersistentStorage.defaults)
        for (family, saved) in drafts {
            let defaults = TouchLayout.defaults(in: draftAreas[family] ?? area)
            var layout = saved
            layout.changes = layout.changes.filter { defaults[$0.key] != $0.value }
            store.save(layout, pcID: launch.pcID, appID: launch.appID, family: family)
        }
        close()
    }

    private func finishMove() {
        if let selected, let origin, draft.editable(in: area).placement(selected, in: area) != origin {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        dragging = false
        origin = nil
    }

    private func load() {
        family = TouchLayout.family(in: area)
        draftAreas[family] = area
        draft = drafts[family] ?? TouchLayoutStore(defaults: PersistentStorage.defaults).load(
            pcID: launch.pcID, appID: launch.appID, family: family)
        select(selected)
    }

    private func select(_ element: TouchElement?) {
        selected = element
        if let element { size = draft.editable(in: area).placement(element, in: area).scale }
    }

    private func hide(_ element: TouchElement) {
        var value = draft.placement(element, in: area)
        value.hidden = true
        draft.changes[element] = value
        select(nil)
    }

    private func resize(_ value: Double) {
        guard let selected else { return }
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
