// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing

struct InputAPITests {
    @Test func controllerCategoryIdentifiesLayoutWithoutRequiringExtraControls() {
        let cases: [(String, ControllerDescriptor.Kind)] = [
            ("DualSense", .playStation), ("DualShock 4", .playStation), ("Xbox One", .xbox),
            ("Switch Pro Controller", .nintendo), ("Nintendo Switch Joy-Con (L)", .nintendo),
            ("Nintendo Switch Joy-Con (R)", .nintendo), ("MFi", .unknown), ("HID", .unknown), ("Other", .unknown)
        ]
        for (category, kind) in cases {
            #expect(ControllerDescriptor.Kind.identify(productCategory: category) == kind, "\(category)")
        }
    }

    @Test(arguments: [ControllerDescriptor.Kind.playStation, .xbox, .nintendo])
    func nativeProfileIdentifiesLayoutWithAGenericCategory(kind: ControllerDescriptor.Kind) {
        #expect(ControllerDescriptor.Kind.identify(productCategory: "MFi", profile: kind) == kind)
    }

    @Test(arguments: [false, true])
    func completePlayStationGlyphsIdentifyAGenericProfile(filled: Bool) {
        let symbols = ["xmark.circle", "circle.circle", "square.circle", "triangle.circle"]
            .map { Optional(filled ? $0 + ".fill" : $0) }
        #expect(ControllerDescriptor.Kind.identify(productCategory: "MFi", faceSymbols: symbols) == .playStation)
        #expect(ControllerDescriptor.Kind.identify(productCategory: "HID", faceSymbols: symbols) == .playStation)
        #expect(ControllerDescriptor.Kind.identify(productCategory: "Xbox One", faceSymbols: symbols) == .xbox)
    }

    @Test func missingOrMixedGlyphsDoNotInventAPlayStationController() {
        let cases: [[String?]] = [[], [nil, nil, nil, nil], ["a.circle", "b.circle", "x.circle", "y.circle"],
            ["xmark.circle", "b.circle", "square.circle", "triangle.circle"],
            ["xmark.circle", nil, "square.circle", "triangle.circle"]]
        for symbols in cases {
            #expect(ControllerDescriptor.Kind.identify(productCategory: "MFi", faceSymbols: symbols) == .unknown)
        }
    }

    private final class Sink: VideoSink {
        let capabilities: Int32 = 0
        func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 { 0 }
        func start() {}
        func stop() {}
        func cleanup() {}
        func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { 0 }
    }

    @Test func publicInputRegistrationIsConnectionBoundAndStopIsTerminal() async throws {
        let connection = StreamConnection(video: Sink(), onEvent: { _, _ in })
        let input = connection.input
        let descriptor = ControllerDescriptor(kind: .unknown, supportedButtons: [.a, .menu], capabilities: .analogTriggers)
        let original = try #require(input.registerController(descriptor))
        input.setControllerMouseMapping(.rightStick)
        input.unregisterController(original)
        let replacement = try #require(input.registerController(descriptor))
        #expect(original.slot == replacement.slot)
        #expect(original != replacement)
        input.unregisterController(original)
        var slots = [replacement.slot]
        for _ in 0..<15 { slots.append(try #require(input.registerController(descriptor)).slot) }
        #expect(input.registerController(descriptor) == nil)
        #expect(slots.count == 16 && Set(slots).count == 16)
        input.setFocused(true)
        input.submitController(original, sample: .init(buttons: .a), capturedAt: ProcessInfo.processInfo.systemUptime)
        await connection.stop()
        input.setFocused(true)
        input.movePointer(dx: 1, dy: 1, capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(input.registerController(descriptor) == nil)
        await connection.stop()
    }
}
