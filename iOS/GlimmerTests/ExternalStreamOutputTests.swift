// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

@MainActor
struct ExternalStreamOutputTests {
    @Test func applicationConfigurationLeavesDelegateOwnershipToSwiftUI() {
        let application = ExternalStreamSceneDelegate.configuration(for: .windowApplication)
        #expect(application.role == .windowApplication)
        #expect(application.delegateClass == nil)
        let external = ExternalStreamSceneDelegate.configuration(for: .windowExternalDisplayNonInteractive)
        #expect(external.role == .windowExternalDisplayNonInteractive)
        #expect(external.delegateClass is ExternalStreamSceneDelegate.Type)
    }

    @Test func onlyNoninteractiveExternalScenesOwnDedicatedOutput() throws {
        #expect(StreamOutputCoordinator.supports(.windowExternalDisplayNonInteractive))
        #expect(!StreamOutputCoordinator.supports(.windowApplication))
        #expect(!StreamOutputCoordinator.supports(UISceneSession.Role(rawValue: "unknown")))
        let manifest = try #require(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
            as? [String: Any])
        let configurations = try #require(manifest["UISceneConfigurations"] as? [String: Any])
        let external = try #require(configurations[UISceneSession.Role.windowExternalDisplayNonInteractive.rawValue]
            as? [[String: Any]])
        #expect(external.count == 1)
        #expect(external.first?["UISceneDelegateClassName"] as? String
            == String(reflecting: ExternalStreamSceneDelegate.self))
    }

    @Test func connectedScenesKeepTheirRoleSpecificDelegates() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        #expect(scenes.contains { $0.session.role == .windowApplication })
        for scene in scenes {
            if StreamOutputCoordinator.supports(scene.session.role) {
                #expect(scene.delegate is ExternalStreamSceneDelegate)
            } else {
                #expect(!(scene.delegate is ExternalStreamSceneDelegate))
            }
        }
        let inventory = scenes.map {
            "\($0.session.role.rawValue): \($0.screen.nativeBounds.size), \($0.screen.maximumFramesPerSecond) Hz"
        }.sorted().joined(separator: "\n")
        Attachment.record(Array(inventory.utf8), named: "display-scenes.txt")
    }

    @Test func attachingAndDetachingMovesOneSurfaceWithoutRestartingPlayback() async throws {
        var prepares = 0
        var restores = 0
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in
            prepares += 1
            return { restores += 1 }
        }, screenIdentity: { ObjectIdentifier($0) })
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let local = try window(root: controller)
        let external = try window(root: UIViewController())
        defer { local.rootViewController = nil; external.rootViewController = nil }
        model.start(surface: controller.surface)
        model.receive(fixture.update(.firstFrame))
        let renderer = controller.surface.displayLayer
        outputs.update(controller)
        outputs.connect(id: "display", role: .windowExternalDisplayNonInteractive, window: external)
        #expect(controller.surface.superview === external.rootViewController?.view)
        #expect(controller.surface.displayLayer === renderer)
        #expect(model.externalDisplayActive)
        #expect(fixture.focusHistory.suffix(2) == [false, true])
        #expect(controller.children.allSatisfy { $0.view.superview === controller.view })
        outputs.update(controller)
        #expect(prepares == 1)
        outputs.disconnect(id: "display")
        #expect(controller.surface.superview === controller.view)
        #expect(!model.externalDisplayActive)
        #expect(restores == 1 && fixture.makes == 1)
        #expect(controller.surface.displayLayer === renderer)
        #expect(model.phase == .streaming)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func stoppingRestoresDisplayEvenBeforeControlsAreDismissed() async throws {
        var restores = 0
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in { restores += 1 } },
                                              screenIdentity: { ObjectIdentifier($0) })
        let fixture = PlaybackFixture()
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let local = try window(root: controller)
        let external = try window(root: UIViewController())
        defer { local.rootViewController = nil; external.rootViewController = nil }
        outputs.connect(id: "display", role: .windowExternalDisplayNonInteractive, window: external)
        controller.startWhenReady()
        #expect(model.externalDisplayActive)
        model.stop()
        await model.waitUntilStopped()
        #expect(restores == 1)
        #expect(external.isHidden)
        #expect(controller.surface.superview === controller.view)
        #expect(!model.externalDisplayActive)
        outputs.end(controller)
        outputs.disconnect(id: "display")
        #expect(restores == 1)
    }

    @Test func unrelatedSceneAndOldDisconnectCannotStealTheCurrentOutput() async throws {
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in {} }, screenIdentity: { ObjectIdentifier($0) })
        let fixture = PlaybackFixture()
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let local = try window(root: controller)
        let first = try window(root: UIViewController())
        let second = try window(root: UIViewController())
        defer {
            local.rootViewController = nil
            first.rootViewController = nil
            second.rootViewController = nil
        }
        outputs.update(controller)
        outputs.connect(id: "application", role: .windowApplication, window: first)
        #expect(controller.surface.superview === controller.view)
        outputs.connect(id: "first", role: .windowExternalDisplayNonInteractive, window: first)
        outputs.connect(id: "second", role: .windowExternalDisplayNonInteractive, window: second)
        outputs.disconnect(id: "first")
        #expect(controller.surface.superview === second.rootViewController?.view)
        outputs.disconnect(id: "first")
        #expect(controller.surface.superview === second.rootViewController?.view)
        outputs.end(controller)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func restoresOriginalModeAndOverscanOnlyOnce() {
        let original = UIScreenMode()
        let preferred = UIScreenMode()
        var state = StreamDisplayMode.State(mode: original, overscan: .insetBounds)
        var writes = 0
        let restore = StreamDisplayMode.prepare(preferredMode: preferred, read: { state }, write: {
            state = $0
            writes += 1
        })
        #expect(state.mode === preferred && state.overscan == .scale)
        restore()
        #expect(state.mode === original && state.overscan == .insetBounds)
        restore()
        #expect(writes == 2)
    }

    @Test func interactiveWindowOnTheOutputScreenKeepsItsOwnSurface() async throws {
        var prepares = 0
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in prepares += 1; return {} })
        let fixture = PlaybackFixture()
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let local = try window(root: controller)
        let external = try window(root: UIViewController())
        defer { local.rootViewController = nil; external.rootViewController = nil }
        outputs.update(controller)
        outputs.connect(id: "same-screen", role: .windowExternalDisplayNonInteractive, window: external)
        #expect(prepares == 0)
        #expect(controller.surface.superview === controller.view)
        #expect(!model.externalDisplayActive)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func restorationPreservesASubsequentSystemModeChange() {
        let preferred = UIScreenMode()
        let replacement = UIScreenMode()
        var state = StreamDisplayMode.State(mode: nil, overscan: .insetBounds)
        let restore = StreamDisplayMode.prepare(preferredMode: preferred, read: { state }, write: { state = $0 })
        state = StreamDisplayMode.State(mode: replacement, overscan: .none)
        restore()
        #expect(state.mode === replacement && state.overscan == .none)
    }

    @Test func failedPreparationRestoresTheExternalDisplay() throws {
        var restores = 0
        let outputs = StreamOutputCoordinator(prepareDisplay: { _ in { restores += 1 } },
                                              screenIdentity: { ObjectIdentifier($0) })
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            throw StreamProfile.Failure.displayUnavailable
        })
        let controller = StreamViewController(model: model, close: {}, outputs: outputs)
        let local = try window(root: controller)
        let external = try window(root: UIViewController())
        defer { local.rootViewController = nil; external.rootViewController = nil }
        outputs.connect(id: "display", role: .windowExternalDisplayNonInteractive, window: external)
        outputs.update(controller)
        model.start(surface: controller.surface)
        #expect(model.phase.isEnded)
        #expect(restores == 1)
        #expect(!model.externalDisplayActive)
        #expect(controller.surface.superview === controller.view)
    }

    private func window(root: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = root
        window.addSubview(root.view)
        root.view.frame = window.bounds
        if let controller = root as? StreamViewController { controller.surface.frame = window.bounds }
        return window
    }
}
