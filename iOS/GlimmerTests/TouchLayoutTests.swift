// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

struct TouchLayoutTests {
    @Test(arguments: [CGSize(width: 590, height: 330), CGSize(width: 667, height: 354), CGSize(width: 844, height: 369),
                      CGSize(width: 956, height: 419), CGSize(width: 1133, height: 724),
                      CGSize(width: 1376, height: 1011), CGSize(width: 744, height: 500)])
    func defaultTargetsAreSafeAndSeparate(size: CGSize) {
        let area = CGRect(origin: CGPoint(x: 24, y: 8), size: size)
        let frames = TouchLayout().frames(in: area)
        #expect(frames.count == TouchElement.allCases.count)
        for (element, frame) in frames {
            #expect(area.contains(frame))
            #expect(frame.width >= 44 && frame.height >= 44)
            #expect(!frame.insetBy(dx: -7.9, dy: -7.9).intersects(TouchLayout.menuFrame(in: area)))
            for (other, target) in frames where other != element {
                #expect(!frame.insetBy(dx: -7.9, dy: -7.9).intersects(target), "\(element) overlaps \(other)")
            }
        }
    }

    @Test func draftRejectsCollisionAndTemporaryClampingDoesNotOverwriteMemory() {
        let area = CGRect(x: 0, y: 0, width: 844, height: 369)
        var layout = TouchLayout()
        let collision = layout.placement(.leftStick, in: area)
        #expect(!layout.accepts(.leftStickButton, placement: collision, in: area))
        layout.changes[.leftStick] = .init(edge: 700, bottom: 800)
        let original = layout
        let frame = layout.frames(in: area)[.leftStick]
        #expect(frame.map(area.contains) == true)
        #expect(layout == original)
        #expect(TouchLayout().frames(in: CGRect(x: 0, y: 0, width: 400, height: 300)).isEmpty)
    }

    @Test func activeFoldUsesLowerRegionAndRefusesTooSmallRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 800)
        let area = TouchLayout.playableArea(bounds, avoiding: [CGRect(x: 0, y: 390, width: 900, height: 20)])
        #expect(area == CGRect(x: 0, y: 410, width: 900, height: 390))
        #expect(!TouchLayout().frames(in: area).isEmpty)
        let small = TouchLayout.playableArea(bounds, avoiding: [CGRect(x: 0, y: 600, width: 900, height: 20)])
        #expect(TouchLayout().frames(in: small).isEmpty)
    }

    @Test func editingStartsAtVisibleClampedPositionsWithoutChangingSavedLayout() throws {
        let area = CGRect(x: 0, y: 0, width: 844, height: 369)
        var saved = TouchLayout()
        saved.changes[.leftStick] = .init(edge: 700, bottom: 800)
        let original = saved
        let frame = try #require(saved.frames(in: area)[.leftStick])
        let draft = saved.editable(in: area)
        let placement = draft.placement(.leftStick, in: area)
        #expect(placement.edge == frame.midX && placement.bottom == area.maxY - frame.midY)
        #expect(draft.frames(in: area) == saved.frames(in: area))
        #expect(saved == original)
    }

    @Test func persistenceIsScopedAndForgetRemovesOnlyThatPC() throws {
        let suite = "touch-layout-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TouchLayoutStore(defaults: defaults)
        var layout = TouchLayout()
        layout.changes[.dpad] = .init(edge: 214, bottom: 80, hidden: true)
        store.save(layout, pcID: "first", appID: 1, family: .compact)
        store.save(layout, pcID: "second", appID: 1, family: .expanded)
        #expect(store.load(pcID: "first", appID: 1, family: .compact) == layout)
        #expect(store.load(pcID: "first", appID: 2, family: .compact).changes.isEmpty)
        #expect(store.load(pcID: "first", appID: 1, family: .expanded).changes.isEmpty)
        store.forget(pcID: "first")
        #expect(store.load(pcID: "first", appID: 1, family: .compact).changes.isEmpty)
        #expect(store.load(pcID: "second", appID: 1, family: .expanded) == layout)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ios.touchLayout.") {
            defaults.set(Data("broken".utf8), forKey: key)
        }
        #expect(store.load(pcID: "second", appID: 1, family: .expanded).changes.isEmpty)
    }
}
