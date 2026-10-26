// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import UIKit

struct StreamShortcutSettings: View {
    @State private var shortcuts = StreamShortcuts()

    var body: some View {
        Section("In-stream shortcuts") {
            ForEach(StreamShortcuts.Action.allCases, id: \.self) { action in
                StreamShortcutRow(shortcuts: shortcuts, action: action)
            }
        }
    }
}

private struct StreamShortcutRow: View {
    let shortcuts: StreamShortcuts
    let action: StreamShortcuts.Action
    @State private var capturing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { label; Spacer(); recorder }
                VStack(alignment: .leading, spacing: 8) { label; recorder }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
        }
        .background {
            if capturing {
                ShortcutCapture(captured: capture, cancel: { capturing = false })
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .onDisappear { capturing = false }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.title)
            Text(action == .quit ? "Ends the stream and returns to Glimmer."
                 : "For this stream only. The next stream follows Settings › Quality.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                capturing.toggle()
                problem = nil
            } label: {
                Text(capturing ? "Press keys…" : shortcuts.chord(for: action).displayString)
                    .font(.body.weight(.medium).monospaced())
                    .frame(minWidth: 80, minHeight: 44)
                    .padding(.horizontal, 12)
                    .glassEffect(.regular.tint(capturing ? Color.accentColor.opacity(0.22) : .clear), in: .capsule)
                    .overlay(Capsule().stroke(capturing ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change \(action.title) shortcut")
            .accessibilityValue(capturing ? "Press keys…" : shortcuts.chord(for: action).displayString)
            if capturing { Text("Press Esc to cancel").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func capture(_ chord: HotkeyChord) {
        let taken = StreamShortcuts.Action.allCases.filter { $0 != action }.map {
            (name: $0.title, chord: shortcuts.chord(for: $0))
        }
        if let reason = chord.recordingConflict(taken: taken) { problem = reason; return }
        shortcuts.set(chord, for: action)
        capturing = false
        problem = nil
        UIAccessibility.post(notification: .announcement, argument: "Shortcut set to \(chord.displayString)")
    }
}

private struct ShortcutCapture: UIViewRepresentable {
    let captured: (HotkeyChord) -> Void
    let cancel: () -> Void

    func makeUIView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.captured = captured
        view.cancel = cancel
        return view
    }

    func updateUIView(_ view: ShortcutCaptureView, context: Context) {}

    static func dismantleUIView(_ view: ShortcutCaptureView, coordinator: ()) { view.resignFirstResponder() }
}

private final class ShortcutCaptureView: UIView {
    var captured: ((HotkeyChord) -> Void)?
    var cancel: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() } else { resignFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if UIAccessibility.isVoiceOverRunning, key.modifierFlags.isSuperset(of: [.control, .alternate]) {
                super.pressesBegan(presses, with: event)
                return
            }
            if key.keyCode == .keyboardEscape { cancel?(); return }
            if let chord = HotkeyChord(key: key) { captured?(chord) }
        }
    }
}
