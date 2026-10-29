// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SettingsShortcutRecorders.swift
//
//  The Input pane's recorders: HotkeyRow / HotkeyBadge for the keyboard
//  shortcuts and ChordCaptureSheet for the controller chord, with the rules
//  that keep a recording from clashing with another shortcut or with the Mac.
//

import GlimmerEngine
import Accessibility
import AppKit
import Combine
import GameController
import SwiftUI

// MARK: - Recording rules

@MainActor
extension HotkeyChord {
    /// Why this chord can't be an in-stream shortcut, or nil when it can.
    /// `taken` lists every other shortcut by the name Settings shows.
    func recordingProblem(taken: [(name: String, chord: HotkeyChord)],
                          menu: NSMenu? = NSApp.mainMenu) -> String? {
        if let problem = recordingConflict(taken: []) { return problem }
        // The main menu answers its key equivalents before the stream sees them.
        if let menu, let title = menuItemTitle(in: menu) {
            return "Already used for \(title.hasSuffix("…") ? String(title.dropLast()) : title)."
        }
        return recordingConflict(taken: taken)
    }

    /// The title of the visible menu item this chord triggers, searching submenus.
    private func menuItemTitle(in menu: NSMenu) -> String? {
        for item in menu.items where !item.isHidden {
            if triggers(item) { return item.title }
            if let submenu = item.submenu, let title = menuItemTitle(in: submenu) { return title }
        }
        return nil
    }

    /// An uppercase key equivalent implies ⇧, as AppKit reads it.
    private func triggers(_ item: NSMenuItem) -> Bool {
        let key = item.keyEquivalent, mods = item.keyEquivalentModifierMask
        guard !key.isEmpty, key.lowercased() == keyChar.lowercased() else { return false }
        return mods.contains(.command) == cmd && mods.contains(.option) == alt && mods.contains(.control) == ctrl
            && (mods.contains(.shift) || key != key.lowercased()) == shift
    }
}

// MARK: - Keyboard shortcut recorder

enum ShortcutCaptureEvent: Equatable {
    case capture
    case endAndPassThrough

    static func disposition(eventWindow: NSWindow?, captureWindow: NSWindow?) -> Self {
        guard let captureWindow, eventWindow === captureWindow else { return .endAndPassThrough }
        return .capture
    }
}

struct HotkeyRow: View {
    let label: String
    /// One line under the name saying what the shortcut does.
    var detail: String?
    @Binding var hotkey: HotkeyChord
    /// Every shortcut on the pane plus the fixed ones; this row's own is skipped.
    let taken: [(name: String, chord: HotkeyChord)]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HotkeyBadge(label: label, hotkey: $hotkey, taken: taken.filter { $0.name != label })
        }
    }
}

struct HotkeyBadge: View {
    let label: String
    @Binding var hotkey: HotkeyChord
    let taken: [(name: String, chord: HotkeyChord)]
    @State private var isCapturing = false
    @State private var livePreview = ""
    /// Why the last chord pressed wasn't saved; capture stays open for another.
    @State private var problem: String?
    @State private var monitor: Any?
    @State private var captureWindow: NSWindow?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isCapturing { stop() } else { start() }
                } label: {
                    Text(displayText)
                        .transaction { $0.animation = nil }
                        .font(.body.weight(.medium).monospaced())
                        .frame(minWidth: 80, minHeight: 22)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        // Capture state tints the glass with the accent color so it
                        // reads as "live", otherwise it's a neutral glass capsule.
                        .glassSurface(in: .capsule, tint: isCapturing ? Color.accentColor.opacity(0.22) : nil,
                                      interactive: true)
                        .overlay(
                            Capsule().stroke(
                                isCapturing ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                            .animation(Motion.fade, value: isCapturing)
                        )
                        .animation(Motion.fade) { content in
                            content.foregroundStyle(isCapturing ? Color.accentColor : .primary)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change \(label) shortcut")
                .accessibilityValue(displayText)

                // Esc-to-cancel hint shown only during capture. Mirrors macOS's
                // own keyboard-shortcut capture UI (System Settings ›
                // Keyboard › Keyboard Shortcuts).
                if isCapturing {
                    Text("Press Esc to cancel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.animation(Motion.fade))
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { stop() }
    }

    private var displayText: String {
        if isCapturing {
            return livePreview.isEmpty ? "Press keys…" : livePreview
        }
        return hotkey.displayString
    }

    private func start() {
        isCapturing = true
        livePreview = ""
        problem = nil
        captureWindow = NSApp.keyWindow
        // Local event monitor catches keys regardless of first-responder state.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch ShortcutCaptureEvent.disposition(eventWindow: event.window, captureWindow: captureWindow) {
            case .endAndPassThrough:
                DispatchQueue.main.async { stop() }
                return event
            case .capture:
                // VoiceOver's own ⌃⌥ keys keep working while recording; no stream chord could use them anyway.
                if NSWorkspace.shared.isVoiceOverEnabled, event.modifierFlags.isSuperset(of: [.control, .option]) {
                    return event
                }
                handle(event)
                return nil  // swallow so Cmd+Q etc. don't activate menu items
            }
        }
    }

    private func stop() {
        isCapturing = false
        livePreview = ""
        problem = nil
        captureWindow = nil
        if let activeMonitor = monitor {
            NSEvent.removeMonitor(activeMonitor)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Update live modifier preview on flagsChanged
        if event.type == .flagsChanged {
            var parts: [String] = []
            if mods.contains(.control) { parts.append("⌃") }
            if mods.contains(.option) { parts.append("⌥") }
            if mods.contains(.shift) { parts.append("⇧") }
            if mods.contains(.command) { parts.append("⌘") }
            livePreview = parts.isEmpty ? "" : parts.joined() + "…"
            return
        }

        // keyDown: commit the chord if it's a letter or number
        // ESC = cancel
        if event.keyCode == 53 {
            stop()
            return
        }

        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let char = chars.first,
              char.isLetter || char.isNumber else {
            return
        }
        let hk = HotkeyChord(
            ctrl: mods.contains(.control),
            alt: mods.contains(.option),
            shift: mods.contains(.shift),
            cmd: mods.contains(.command),
            keyChar: String(char).lowercased()
        )
        guard hk.ctrl || hk.alt || hk.shift || hk.cmd else { return }
        if let reason = hk.recordingProblem(taken: taken) {
            problem = reason
            livePreview = ""
            return
        }
        hotkey = hk
        stop()
        AccessibilityNotification.Announcement("Shortcut set to \(hk.displayString)").post()
    }
}
