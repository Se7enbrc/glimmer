//
//  SettingsGeneralStreamingPanes+Window.swift
//
//  The Quality pane's Window-mode controls: what the host renders while the
//  stream is shown in a window (size + refresh), shown under "Show the stream:
//  Window" in place of the notch toggle. Its own file so the Quality pane
//  stays under the length limit; the copy follows the pane's plain tone.
//

import SwiftUI

/// "Window stream size" + refresh. The window itself is whatever size the user
/// drags it to; these pick the pixels the host encodes. Custom keeps its own
/// width x height and Hz (persisted, remembered across choices) and is clamped
/// on every commit exactly like the Custom preset's fields - the binding only
/// commits on editing end, so the clamp can't fight a mid-edit value.
struct WindowStreamSizeControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // @Bindable shim - surfaces $model.x bindings from an @Observable
        // environment value; `$model.windowStream.x` drills into the struct.
        @Bindable var model = model
        Picker("Window stream size", selection: $model.windowStream.sizeChoice) {
            ForEach(WindowStreamSizeChoice.allCases, id: \.self) { choice in
                Text(choice.displayName).tag(choice)
            }
        }
        if model.windowStream.sizeChoice == .custom {
            HStack {
                Text("Custom size")
                Spacer()
                TextField("", value: $model.windowStream.customWidth, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: model.windowStream.customWidth) { _, _ in clampWindowSize() }
                Text("×").foregroundStyle(.secondary)
                TextField("", value: $model.windowStream.customHeight, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: model.windowStream.customHeight) { _, _ in clampWindowSize() }
            }
        }
        Picker("Refresh rate", selection: $model.windowStream.refreshChoice) {
            ForEach(WindowStreamRefreshChoice.allCases, id: \.self) { choice in
                Text(choice.displayName(displayMaxHz: model.currentDisplayMaxHz)).tag(choice)
            }
        }
        if model.windowStream.refreshChoice == .custom {
            HStack {
                Text("Custom refresh")
                Spacer()
                TextField("", value: $model.windowStream.customFPS, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: model.windowStream.customFPS) { _, _ in clampWindowFPS() }
                Text("Hz").foregroundStyle(.secondary)
            }
        }
        Text("The window can be any size - this is what your gaming PC renders into it. "
            + "Refresh is capped at this display's \(model.currentDisplayMaxHz) Hz, the bitrate follows "
            + "automatically, and HDR follows the preset above. Click the picture to grab the mouse; "
            + "press \(model.releasePointerHotkey.displayString) (configurable in Input) to let it go. "
            + "Applies next stream.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Same bounds as the Custom preset's clamp (StreamSizeBounds); assigning
    /// only when the value moves keeps the didSet persistence quiet.
    private func clampWindowSize() {
        let width = StreamSizeBounds.clampWidth(model.windowStream.customWidth)
        if width != model.windowStream.customWidth { model.windowStream.customWidth = width }
        let height = StreamSizeBounds.clampHeight(model.windowStream.customHeight)
        if height != model.windowStream.customHeight { model.windowStream.customHeight = height }
    }

    private func clampWindowFPS() {
        let fps = StreamSizeBounds.clampFPS(model.windowStream.customFPS)
        if fps != model.windowStream.customFPS { model.windowStream.customFPS = fps }
    }
}
