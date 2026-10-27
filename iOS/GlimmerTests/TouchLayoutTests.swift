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

    // SE, 17 Pro and iPad share one arrangement: Options and Menu below, the stream menu button above.
    @Test(arguments: [CGSize(width: 590, height: 600), CGSize(width: 667, height: 375),
                      CGSize(width: 667, height: 354), CGSize(width: 750, height: 381),
                      CGSize(width: 1194, height: 790), CGSize(width: 700, height: 900)])
    func optionsAndMenuStayAtTheBottomAwayFromTheStreamMenuButton(size: CGSize) throws {
        let area = CGRect(origin: .zero, size: size)
        let frames = TouchLayout().frames(in: area)
        let menu = TouchLayout.menuFrame(in: area)
        for element in [TouchElement.options, .menu] {
            let frame = try #require(frames[element])
            #expect(frame.minY > area.midY, "\(element) sits at the bottom")
            #expect(frame.minY - menu.maxY > 100, "\(element) is clear of the stream menu button")
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

    @Test func rejectedEditDoesNotReplaceStoredGeometryWithTemporaryClamping() throws {
        let area = CGRect(x: 0, y: 0, width: 844, height: 369)
        var saved = TouchLayout()
        saved.changes[.leftStick] = .init(edge: 700, bottom: 800, scale: 1.5)
        let original = saved
        let visible = saved.editable(in: area)
        let collision = visible.placement(.leftStickButton, in: area)
        #expect(saved.editing(.leftStick, to: collision, in: area) == nil)
        #expect(saved == original)
        var hidden = visible.placement(.leftStick, in: area)
        hidden.hidden = true
        let edited = try #require(saved.editing(.leftStick, to: hidden, in: area))
        #expect(edited.frames(in: area)[.leftStick] == nil)
        #expect(saved == original)
    }

    @Test func opacityIsBoundedAndOldLayoutsKeepTheApprovedDefault() throws {
        var layout = TouchLayout()
        #expect(layout.opacity == 0.2)
        for (input, expected) in [(-1.0, 0.1), (0.0, 0.1), (0.12, 0.1), (0.23, 0.25),
                                  (0.6, 0.6), (2.0, 0.6), (.infinity, 0.2), (.nan, 0.2)] {
            layout.opacity = input
            #expect(layout.opacity == expected)
        }
        let old = Data(#"{"changes":[]}"#.utf8)
        #expect(try JSONDecoder().decode(TouchLayout.self, from: old) == TouchLayout())
        for (stored, expected) in [("-1", 0.1), ("9", 0.6), ("0.4", 0.4)] {
            let data = Data("{\"changes\":[],\"opacity\":\(stored)}".utf8)
            #expect(try JSONDecoder().decode(TouchLayout.self, from: data).opacity == expected)
        }
    }

    @Test func opacityOnlyEditsPersistIndependentlyIncludingTheDefault() throws {
        let suite = "touch-opacity-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TouchLayoutStore(defaults: defaults)
        var layout = TouchLayout()
        layout.opacity = 0.6
        store.save(layout, pcID: "first", appID: 1, family: .compact)
        #expect(store.load(pcID: "first", appID: 1, family: .compact) == layout)
        #expect(store.load(pcID: "first", appID: 2, family: .compact) == TouchLayout())
        #expect(store.load(pcID: "second", appID: 1, family: .compact) == TouchLayout())
        #expect(store.load(pcID: "first", appID: 1, family: .expanded) == TouchLayout())
        var cancelled = store.load(pcID: "first", appID: 1, family: .compact)
        cancelled.opacity = 0.1
        #expect(store.load(pcID: "first", appID: 1, family: .compact).opacity == 0.6)
        let area = CGRect(x: 0, y: 0, width: 844, height: 369)
        var placement = layout.placement(.a, in: area)
        placement.hidden = true
        let edited = try #require(layout.editing(.a, to: placement, in: area))
        #expect(edited.opacity == 0.6 && edited.frames(in: area)[.a] == nil)
        store.save(TouchLayout(), pcID: "first", appID: 1, family: .compact)
        #expect(store.load(pcID: "first", appID: 1, family: .compact) == TouchLayout())
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ios.touchLayout.") })
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
