// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import GlimmerEngine
import SwiftUI
import Synchronization
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerShortcutRenderTests {
    @Test(arguments: [false, true])
    func recordingScreens(dark: Bool) async throws {
        let renderer = ControllerLayoutRenderTests()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"))
        await model.load()
        var device = renderer.fixture(.dualSense)
        let receive = Mutex<(@Sendable (ControllerMappingSample, TimeInterval) -> Void)?>(nil)
        let input = ControllerLayoutCaptureSource(controls: device.controls, extras: [], read: { .init() }, acquire: { value in
            receive.withLock { $0 = value }
            return { receive.withLock { $0 = nil } }
        })
        device.captureSource = input
        device.hidID = 1
        let style = dark ? "dark" : "light"
        try await renderer.record(NavigationStack {
            Form {
                Section { ControllerLayoutDiagram(family: device.diagramFamily, controls: device.controls) { _ in } }
                ControllerShortcutSection(model: model, device: device)
            }.formStyle(.grouped).navigationTitle(device.name)
        }, name: "chords-summary-\(style)", dark: dark)
        let capture = ControllerLayoutCapture(input: input, recordingChord: true)
        try await renderer.record(ControllerShortcutRecorder(model: model, device: device, action: .stats, capture: capture),
                                  name: "chords-recording-\(style)", dark: dark)
        capture.start(cancel: {})
        let buttons = ControllerLayoutShortcuts.defaultStats.reduce(UInt32.zero) { mask, source in
            if case .button(let button) = source { return mask | button.rawValue }
            return mask
        }
        let deliver = receive.withLock { $0 }
        deliver?(.init(buttons: buttons), 10)
        deliver?(.init(), 10.5)
        #expect(capture.finished)
        capture.stop()
        try await renderer.record(ControllerShortcutRecorder(model: model, device: device, action: .stats, capture: capture),
                                  name: "chords-review-\(style)", dark: dark)
        try await renderer.record(StatsBoardView(), name: "chords-stats-\(style)", dark: dark)
    }
}

private struct StatsBoardView: View {
    var body: some View {
        ZStack {
            Color.black
            NativeStatsBoard().padding(24)
        }.ignoresSafeArea()
    }
}

@MainActor
private struct NativeStatsBoard {
    func configure(_ overlay: StatsOverlayLayer) {
        var snapshot = StreamStatsSnapshot()
        snapshot.renderedFps = 119.9
        snapshot.rttMs = 3.5
        snapshot.measuredBitrateMbps = 46.2
        snapshot.negotiatedBitrateMbps = 120
        snapshot.videoCodec = "HEVC"
        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 120)
        overlay.setVisible(true)
    }
}

#if os(macOS)
extension NativeStatsBoard: NSViewRepresentable {
    func makeNSView(context: Context) -> StatsBoardNativeView { StatsBoardNativeView() }
    func updateNSView(_ view: StatsBoardNativeView, context: Context) { configure(view.overlay) }
}

private final class StatsBoardNativeView: NSView {
    let overlay = StatsOverlayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let layer { overlay.attach(to: layer) }
        overlay.displayView = self
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if let layer { overlay.layoutInHost(layer) }
    }
}
#else
extension NativeStatsBoard: UIViewRepresentable {
    func makeUIView(context: Context) -> StatsBoardNativeView { StatsBoardNativeView() }
    func updateUIView(_ view: StatsBoardNativeView, context: Context) { configure(view.overlay) }
}

private final class StatsBoardNativeView: UIView {
    let overlay = StatsOverlayLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        overlay.attach(to: layer)
        overlay.displayView = self
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.layoutInHost(layer)
    }
}
#endif
