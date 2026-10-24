// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
struct SettingsAccessibilityTests {
    private let settings = IsolatedDefaults()

    @Test func customFieldsExposeDistinctNamesAndValues() throws {
        let model = AppModel(defaults: settings.defaults)
        model.qualityPreset = .custom
        model.customWidth = 1920
        model.customHeight = 1080
        model.customFPS = 60
        let view = NSHostingView(rootView: QualityPane().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Quality accessibility test"
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let result = Self.readFields(process: getpid())
        #expect(result.error == AXError.success.rawValue)
        #expect(result.fields.count == 3)
        for (label, value) in [("Width in pixels", "1920"), ("Height in pixels", "1080"),
                               ("Refresh rate in hertz", "60")] {
            let field = try #require(result.fields.first { $0.name == label }, "Fields: \(result.fields)")
            #expect(field.value == value)
        }
    }

    private struct Field: Sendable {
        let name: String?
        let value: String?
    }

    private static func readFields(process: pid_t) -> (fields: [Field], error: Int32) {
        let app = AXUIElementCreateApplication(process)
        var windows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard error == .success else { return ([], error.rawValue) }
        let window = (windows as? [AXUIElement] ?? []).first {
            value(kAXTitleAttribute, of: $0) as? String == "Quality accessibility test"
        }
        guard let window else { return ([], AXError.noValue.rawValue) }
        let fields = descendants(of: window).filter { value(kAXRoleAttribute, of: $0) as? String == kAXTextFieldRole }
        return (fields.map {
            Field(name: value(kAXDescriptionAttribute, of: $0) as? String ?? value(kAXTitleAttribute, of: $0) as? String,
                  value: value(kAXValueAttribute, of: $0) as? String)
        }, error.rawValue)
    }

    private static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        return children + children.flatMap { descendants(of: $0) }
    }
}
