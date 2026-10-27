// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreGraphics
import XCTest

@MainActor
struct JourneyInputAssertions {
    let receipts: () -> [[String: Double]]
    let send: ([[String: Any]]) throws -> Void

    private func press(_ element: String, duration: Int) throws {
        try send([["element": element, "value": 1, "milliseconds": duration], ["element": element, "value": 0]])
    }

    func digital() throws {
        for (name, mask) in [("a", 0x1000), ("b", 0x2000), ("x", 0x4000), ("y", 0x8000),
            ("lb", 0x100), ("rb", 0x200), ("ls", 0x40), ("rs", 0x80), ("options", 0x20), ("menu", 0x10)] {
            let index = receipts().count
            try press(name, duration: 600)
            let delivered = receipts().dropFirst(index).filter { $0["pcButtons"] != nil }
            let pressed = try XCTUnwrap(delivered.first { $0["pcButtons"] == Double(mask) }, name)
            let released = try XCTUnwrap(delivered.last)
            XCTAssertEqual(released["pcButtons"], 0, name + " must release")
            XCTAssertGreaterThanOrEqual((released["receivedAt"] ?? 0) - (pressed["receivedAt"] ?? 0), 0.5)
            let injected = try XCTUnwrap(receipts().dropFirst(index).first { $0["injected"] != nil }?["receivedAt"])
            XCTAssertLessThan((pressed["receivedAt"] ?? .infinity) - injected, 0.1,
                              "Normal input must arrive without waiting for a chord hold")
        }
    }

    func analog() throws {
        for (name, key, full) in [("lt", "lt", 255.0), ("rt", "rt", 255.0),
                                   ("left", "lx", 32767.0), ("left", "ly", 32767.0),
                                   ("right", "rx", 32767.0), ("right", "ry", 32767.0)] {
            let index = receipts().count
            let stick = name == "left" || name == "right"
            let values: [Double] = stick ? [-1, -0.75, 0.25, 0.75, 1, 0] : [0.25, 0.75, 1, 0]
            let steps: [[String: Any]] = values.map { value in
                var step: [String: Any] = ["element": name, "value": value, "milliseconds": 150]
                if stick {
                    step["y"] = key.hasSuffix("y") ? value : 0
                    step["value"] = key.hasSuffix("y") ? 0 : value
                }
                return step
            }
            try send(steps)
            let delivered = receipts().dropFirst(index).filter { $0["pcButtons"] != nil }
            for value in values.dropLast() {
                XCTAssertTrue(delivered.contains { abs(($0[key] ?? -1) - (value * full).rounded()) < 2 }, name)
            }
            XCTAssertEqual(delivered.last?[key], 0, name + " must return to centre")
        }
    }

    func partialChord() throws {
        let index = receipts().count
        try send(["lb", "rb", "ls"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "ls" ? 600 : 10]
        } + ["ls", "rb", "lb"].map { ["element": $0, "value": 0] })
        let events = Array(receipts().dropFirst(index))
        let pressed = try XCTUnwrap(events.first { $0["pcButtons"] == 0x340 }?["receivedAt"])
        let injected = try XCTUnwrap(events.first { $0["injected"] != nil }?["receivedAt"])
        XCTAssertLessThan(pressed - injected, 0.1, "A partial chord must not wait for the hold threshold")
        XCTAssertFalse(events.contains { $0["stop"] == 1 })
        XCTAssertEqual(events.last { $0["pcButtons"] != nil }?["pcButtons"], 0)
    }

    func dpad() throws {
        for (x, y, mask) in [(0, 1, 1), (0, -1, 2), (-1, 0, 4), (1, 0, 8)] {
            let index = receipts().count
            try send([["element": "dpad", "value": x, "y": y, "milliseconds": 600],
                      ["element": "dpad", "value": 0, "y": 0]])
            let received = receipts().dropFirst(index).filter { $0["pcButtons"] != nil }
            XCTAssertTrue(received.contains { $0["pcButtons"] == Double(mask) })
            XCTAssertEqual(received.last?["pcButtons"], 0)
        }
    }
}

enum JourneyPicture {
    static func assertColors(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let colorful = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return stride(from: 0, to: bytes.count, by: 4).filter {
                let channels = [bytes[$0], bytes[$0 + 1], bytes[$0 + 2]]
                return Int(channels.max() ?? 0) - Int(channels.min() ?? 0) > 150
            }.count
        }
        XCTAssertGreaterThan(colorful, 200, "The player must see colored video, not a black surface",
                             file: file, line: line)
    }
}
