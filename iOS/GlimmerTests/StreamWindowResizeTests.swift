// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import SwiftUI
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
                start: { await MainActor.run { starts += 1 }; return nil },
                stop: { await MainActor.run { stops += 1 } },
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
            #expect(controller.surface.displayLayer.videoGravity == .resizeAspectFill)
        }
        #expect(preparations == 1 && starts == 1 && stops == 0)
        model.stop()
        await model.waitUntilStopped()
        #expect(stops == 1)
    }
}

@Suite(.serialized)
@MainActor
struct StreamEditorPresentationTests {
    @Test(arguments: [UIModalPresentationStyle.fullScreen, .pageSheet], [false, true])
    func coveringStreamWithLayoutsNeverStopsPlayback(style: UIModalPresentationStyle,
                                                     leaveRunning: Bool) async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let previousKey = scene.keyWindow
        let suite = "io.ugfugl.Glimmer.tests.editor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = testLaunch()
        let launch = StreamLaunch(network: base.network, pcID: base.pcID, pcName: base.pcName,
            appID: base.appID, appName: base.appName, leaveGamesRunning: leaveRunning)
        let id = UUID()
        var stops = 0
        var quits = 0
        let model = StreamSessionModel(launch: launch, defaults: defaults, makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {
                await MainActor.run { stops += 1; if !leaveRunning { quits += 1 } }
            }, screenChanged: {})
        })
        let controller = StreamViewController(model: model, close: {}, outputs: StreamOutputCoordinator())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.loadViewIfNeeded()
        model.start(surface: controller.surface)
        await model.waitUntilStartFinishes()
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.showControls()
        let layouts = ControllerLayoutsModel(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), defaults: defaults, read: { ControllerLayoutLibrary() })
        let editor = UIHostingController(rootView: NavigationStack {
            ControllerLayoutsView(model: layouts, initialScope: .game(pcID: launch.pcID, appID: 1))
        })
        editor.modalPresentationStyle = style
        await withCheckedContinuation { continuation in
            controller.present(editor, animated: false) { continuation.resume() }
        }
        await model.waitUntilStopped()
        #expect(stops == 0 && quits == 0 && model.phase == .streaming)
        if style == .fullScreen { #expect(!controller.presentationActive) }
        await withCheckedContinuation { continuation in
            editor.dismiss(animated: false) { continuation.resume() }
        }
        #expect(model.phase == .streaming && stops == 0 && quits == 0)
        model.touchGeometryChanged(usable: true)
        model.resumeInput()
        #expect(model.inputFocused)
        StreamView.dismantleUIViewController(controller, coordinator: ())
        await model.waitUntilStopped()
        #expect(stops == 1 && quits == (leaveRunning ? 0 : 1))
    }
}
