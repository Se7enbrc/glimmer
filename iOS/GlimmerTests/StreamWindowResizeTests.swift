// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamWindowResizeTests {
    @Test(arguments: [UIUserInterfaceIdiom.phone, .pad])
    func resizeAndRotationKeepTheStreamAndNeverStopOrRelaunch(idiom: UIUserInterfaceIdiom) async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let id = UUID()
        var starts = 0
        var stops = 0
        var preparations = 0
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { launch, view, _ in
            preparations += 1
            return StreamPlayback(id: id, events: AsyncStream { _ in },
                start: { await MainActor.run { starts += 1 } }, stop: { await MainActor.run { stops += 1 } },
                screenChanged: {}, format: try launch.profile.resolve(surface: view))
        })
        let controller = StreamViewController(model: model, close: {})
        controller.traitOverrides.userInterfaceIdiom = idiom
        controller.loadViewIfNeeded()
        window.addSubview(controller.view)
        defer { controller.view.removeFromSuperview() }
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        controller.viewDidLayoutSubviews()
        await model.waitUntilStartFinishes()
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        let original = try #require(model.requestedFormat)
        for size in [CGSize(width: 375, height: 486), CGSize(width: 683, height: 1032),
                     CGSize(width: 1024, height: 768)] {
            controller.view.frame.size = size
            controller.viewDidLayoutSubviews()
            controller.surface.layoutIfNeeded()
            #expect(model.requestedFormat == original && model.phase == .streaming)
            #expect(controller.surface.bounds.size == size)
            #expect(controller.surface.displayLayer.frame == controller.surface.bounds)
            #expect(controller.surface.displayLayer.videoGravity == .resizeAspect)
        }
        #expect(preparations == 1 && starts == 1 && stops == 0)
        model.stop()
        await model.waitUntilStopped()
        #expect(stops == 1)
    }
}
