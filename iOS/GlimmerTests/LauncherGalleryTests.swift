// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct LauncherGalleryTests {
    @Test(arguments: [LauncherStyle.buttons, .covers])
    func runningStateKeepsTheGallerySize(style: LauncherStyle) {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.apps = [fixture.app]
        let proposal = CGSize(width: 327, height: 1_000)
        let idle = UIHostingController(rootView: LauncherGallery(model: model, style: style, size: proposal))
            .sizeThatFits(in: proposal)
        model.runningApp = fixture.app
        let running = UIHostingController(rootView: LauncherGallery(model: model, style: style, size: proposal))
            .sizeThatFits(in: proposal)
        #expect(idle == running)
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5], [Image.Scale.small, .medium, .large])
    func steamGlyphRetainsLayoutAtEveryTextSize(textSize: DynamicTypeSize, scale: Image.Scale) {
        let view = AppGlyph(name: "Steam Big Picture").dynamicTypeSize(textSize).imageScale(scale)
        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))
        #expect(size.width > 0 && size.height > 0)
    }

    @Test(arguments: [LauncherStyle.buttons, .covers])
    func accessibleAppHasRoomForItsFullTitle(style: LauncherStyle) async {
        let title = "A game with a long title that should remain readable"
        let fixture = LauncherFixture()
        let app = HostApp(id: 1, name: title, hdrCapable: false, hidden: false)
        let model = LauncherModel(calls: .init(savedPCs: { [fixture.saved] },
            prepare: { _, _ in PreparedPC(network: testLaunch().network, server: fixture.server) },
            pair: { pc, _ in pc }, apps: { _ in [app] }, remember: { _ in [fixture.saved] },
            protectedDataChanged: { _ in }), discoveryEnabled: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        let width: CGFloat = 327
        let gallery = UIHostingController(rootView:
            LauncherGallery(model: model, style: style, size: CGSize(width: width, height: 667))
                .dynamicTypeSize(.accessibility5))
        let fullTitle = UIHostingController(rootView:
            Text(title).font(style == .covers ? .headline : .body).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(.accessibility5))
        let proposal = CGSize(width: width, height: 2_000)
        let artworkHeight: CGFloat = style == .covers ? width / 0.75 + 8 : 0
        let minimumHeight = artworkHeight + fullTitle.sizeThatFits(in: proposal).height
        #expect(gallery.sizeThatFits(in: proposal).height >= minimumHeight)
    }

    @Test func gridsFillAvailableColumnsAndAdaptToLargerText() {
        #expect(LauncherGrid.columns(width: 800, minimum: 220, count: 2) == 2)
        #expect(LauncherGrid.columns(width: 800, minimum: 220, count: 7) == 3)
        #expect(LauncherGrid.columns(width: 550, minimum: 350, count: 2) == 1)
        #expect(LauncherGrid.columns(width: 0, minimum: 220, count: 0) == 1)
        #expect(LauncherGrid.coverHeight(availableHeight: 320) == 160)
        #expect(LauncherGrid.coverHeight(availableHeight: 800) == 240)
    }

    @Test func backgroundDeadlineAndOldExpirationCannotStopReturnedStream() {
        var now: TimeInterval = 0
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended = 0
        var stopped = 0
        let grace = StreamBackgroundGrace(calls: .init(begin: { expire in
            expirations.append(expire)
            return .init(rawValue: expirations.count)
        }, end: { _ in ended += 1 }, now: { now }))
        grace.prepare { stopped += 1 }
        grace.leave { stopped += 1 }
        now = 5
        #expect(grace.returned())
        grace.prepare { stopped += 1 }
        expirations[0]()
        #expect(stopped == 0 && ended == 1)
        grace.leave { stopped += 1 }
        now = 21
        #expect(!grace.returned())
        #expect(ended == 2)
        grace.finish()
        #expect(ended == 2)
    }

    @Test func systemExpirationEndsLeaseOnce() {
        var expiration: (@MainActor @Sendable () -> Void)?
        var ended = 0
        var stopped = 0
        let grace = StreamBackgroundGrace(calls: .init(begin: { expiration = $0; return .init(rawValue: 1) },
                                                       end: { _ in ended += 1 }))
        grace.prepare { stopped += 1 }
        grace.leave { stopped += 1 }
        expiration?()
        expiration?()
        #expect(stopped == 1 && ended == 1)
    }
}
