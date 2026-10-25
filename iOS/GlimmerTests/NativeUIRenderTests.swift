// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct NativeUIRenderTests {
    @Test(arguments: [CGSize(width: 667, height: 375), CGSize(width: 956, height: 440),
                      CGSize(width: 390, height: 844)], [false, true])
    func launcherAndPairing(size: CGSize, dark: Bool) async throws {
        let launch = testLaunch()
        let server: ServerInfo = {
            var server = ServerInfo(address: "pc.invalid", uniqueId: launch.pcID, serverName: "Living room PC")
            server.pairStatus = .paired
            server.serverCertPEM = "test placeholder, never sent to a transport"
            return server
        }()
        let saved = SavedPC(server: server)
        let apps = [HostApp(id: 1, name: "Desktop", hdrCapable: false, hidden: false),
                    HostApp(id: 2, name: "A game with a long title that should wrap without hiding the launch control",
                            hdrCapable: false, hidden: false),
                    HostApp(id: 3, name: "Racing", hdrCapable: false, hidden: false)]
        var calls = LauncherModel.Calls(savedPCs: { [] },
            prepare: { _, _ in PreparedPC(network: launch.network, server: server) },
            pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in [saved] }, protectedDataChanged: { _ in })
        let empty = LauncherModel(calls: calls, discoveryEnabled: false)
        empty.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        let style = "\(Int(size.width))-\(dark ? "dark" : "light")"
        try await record(LauncherView(model: empty), name: "launcher-empty-\(style)", size: size, dark: dark)
        calls.savedPCs = { [saved] }
        let library = LauncherModel(calls: calls, discoveryEnabled: false)
        library.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        library.select(saved)
        await library.waitUntilOperationFinishes()
        #expect(library.apps.count == 3)
        library.streamProfile = .native120
        try await record(LauncherView(model: library), name: "launcher-library-\(style)", size: size, dark: dark)
        try await record(PairingView(prompt: .init(name: "Living room PC", pin: "1234"), cancel: {}),
                         name: "pairing-\(style)", size: size, dark: dark)
        try await record(AddPCView(connect: { _ in }), name: "add-pc-\(style)", size: size, dark: dark)
        try await record(GlimmerSettings(profile: .constant(.native120),
                                        stick: .constant(dark ? .left : .right), model: library),
                         name: "mouse-settings-\(style)", size: size, dark: dark)
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func connectingLauncherOffersCancellation(textSize: DynamicTypeSize) async throws {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.prepareGate = gate
        let model = fixture.model()
        let sizeLabel = textSize.isAccessibilitySize ? "accessibility" : "standard"
        var captureError: Error?
        do {
            try await record(LauncherView(model: model), name: "launcher-connecting-cancel-\(sizeLabel)",
                             size: CGSize(width: 667, height: 375), dark: false, textSize: textSize, prepare: {
                model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
                model.select(fixture.saved)
                await gate.waitUntilEntered()
                #expect(model.busy && model.selectedName == "Test PC")
            })
        } catch { captureError = error }
        model.cancelOperation()
        await gate.release()
        await model.waitUntilOperationFinishes()
        #expect(model.busy == false && fixture.remembers == 0)
        if let captureError { throw captureError }
    }

    @Test(arguments: [CGSize(width: 667, height: 375), CGSize(width: 956, height: 440),
                      CGSize(width: 390, height: 844)], [false, true])
    func settingsPages(size: CGSize, dark: Bool) async throws {
        let saved = SavedPC(server: ServerInfo(address: "pc.invalid", uniqueId: "settings-pc",
                                               serverName: "Living room gaming PC"))
        let calls = LauncherModel.Calls(savedPCs: { [saved] },
            prepare: { _, _ in throw CancellationError() }, pair: { pc, _ in pc }, apps: { _ in [] },
            remember: { _ in [] }, protectedDataChanged: { _ in })
        let model = LauncherModel(calls: calls, discoveryEnabled: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model)
        for page in GlimmerSettings.Page.allCases {
            let style = "\(Int(size.width))-\(dark ? "dark" : "light")"
            try await record(NavigationStack { settings.settingsPage(page) },
                             name: "settings-\(page.rawValue)-\(style)", size: size, dark: dark)
        }
    }

    @Test(arguments: [CGSize(width: 667, height: 375), CGSize(width: 956, height: 440)], [false, true])
    func responsiveButtonsAndCovers(size: CGSize, dark: Bool) async throws {
        var server = ServerInfo(address: "pc.invalid", uniqueId: "covers-fixture", serverName: "Living room PC")
        server.pairStatus = .paired
        let saved = SavedPC(server: server)
        let prepared = PreparedPC(network: testLaunch().network, server: server)
        let titles = ["Desktop", "Steam Big Picture", "Adventure", "A very long game title", "Racing", "Puzzle"]
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 30, y: 80, width: 180, height: 160))
        }
        let data = try #require(artwork.pngData())
        var calls = LauncherModel.Calls(savedPCs: { [saved] }, prepare: { _, _ in prepared },
            pair: { pc, _ in pc }, apps: { _ in titles.enumerated().map {
                HostApp(id: $0.offset, name: $0.element, hdrCapable: false, hidden: false)
            } }, remember: { _ in [saved] }, protectedDataChanged: { _ in },
            artwork: { _, id in id > 1 ? data : Data() })
        let covers = LauncherModel(calls: calls, discoveryEnabled: false)
        covers.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        covers.select(saved)
        await covers.waitUntilOperationFinishes()
        let style = "\(Int(size.width))-\(dark ? "dark" : "light")"
        try await record(LauncherView(model: covers, style: .covers),
                         name: "launcher-covers-\(style)", size: size, dark: dark, prepare: {
            covers.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
            covers.select(saved)
            await covers.waitUntilOperationFinishes()
            if let app = covers.apps.first(where: { $0.id == 2 }) {
                #expect(await covers.artwork(for: app) != nil)
            } else {
                Issue.record("Artwork fixture app is missing.")
            }
        })
        if size.width == 956, !dark {
            try await record(LauncherView(model: covers, style: .covers), name: "launcher-covers-standard",
                             size: CGSize(width: 874, height: 402), dark: false, textSize: .large, prepare: {
                covers.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
                covers.select(saved)
                await covers.waitUntilOperationFinishes()
            })
        }
        calls.apps = { _ in Array(covers.apps.prefix(2)) }
        let buttons = LauncherModel(calls: calls, discoveryEnabled: false)
        buttons.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        buttons.select(saved)
        await buttons.waitUntilOperationFinishes()
        try await record(LauncherView(model: buttons, style: .buttons),
                         name: "launcher-two-buttons-\(style)", size: size, dark: dark)
    }

    @Test(arguments: [false, true])
    func pairingFailureMessages(dark: Bool) async throws {
        let fixture = LauncherFixture()
        fixture.prepareFailure = LauncherServices.Failure.invalidIdentity
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        try await record(LauncherView(model: model), name: "pairing-failure-\(dark ? "dark" : "light")",
                         size: nil, dark: dark, textSize: .large)
    }

    @Test(arguments: [false, true])
    func testFlightScreens(dark: Bool) async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        let style = dark ? "dark" : "light"
        try await record(LauncherView(model: model), name: "testflight-launcher-\(style)",
                         size: nil, dark: dark, textSize: .large)
        let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model)
        for page in [GlimmerSettings.Page.input, .quality] {
            try await record(NavigationStack { settings.settingsPage(page) },
                             name: "testflight-\(page.rawValue)-\(style)", size: nil, dark: dark, textSize: .large)
        }
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
    func settingsSupportLinks(dark: Bool, textSize: DynamicTypeSize) async throws {
        let calls = LauncherModel.Calls(savedPCs: { [] },
            prepare: { _, _ in throw CancellationError() }, pair: { pc, _ in pc }, apps: { _ in [] },
            remember: { _ in [] }, protectedDataChanged: { _ in })
        let model = LauncherModel(calls: calls, discoveryEnabled: false)
        let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model)
        let style = "\(dark ? "dark" : "light")-\(textSize.isAccessibilitySize ? "accessibility" : "standard")"
        try await record(settings, name: "settings-support-\(style)", size: nil,
                         dark: dark, textSize: textSize, portrait: true)
    }

    @Test func actualSimulatorLauncherSupportsPortrait() async throws {
        let calls = LauncherModel.Calls(savedPCs: { [] },
            prepare: { _, _ in throw CancellationError() }, pair: { pc, _ in pc }, apps: { _ in [] },
            remember: { _ in [] }, protectedDataChanged: { _ in })
        let model = LauncherModel(calls: calls, discoveryEnabled: false)
        try await record(LauncherView(model: model), name: "launcher-simulator-portrait",
                         size: nil, dark: false, portrait: true)
    }

    @Test(arguments: [CGSize(width: 400, height: 700), CGSize(width: 600, height: 600),
                      CGSize(width: 900, height: 500)], [false, true])
    func streamStartsInUsableWindow(size: CGSize, dark: Bool) async throws {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {})
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let shouldStart = pad || size.width > size.height
        let name = "window-\(Int(size.width))-\(Int(size.height))-\(dark ? "dark" : "light")"
        try await recordController(controller, name: name, size: size, dark: dark, prepare: {
            #expect(fixture.makes == (shouldStart ? 1 : 0))
            #expect(model.phase == (shouldStart ? .connecting : .idle))
            #expect(controller.surface.displayLayer.videoGravity == .resizeAspectFill)
            if fixture.makes == 1 {
                model.receive(fixture.update(.firstFrame))
                model.showControls()
            }
            controller.view.frame.size = CGSize(width: size.height, height: size.width)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            controller.startWhenReady()
            if shouldStart { #expect(fixture.makes == 1) }
            let replacement = controller.surface.replaceDisplayLayer { _ in }
            #expect(replacement.videoGravity == .resizeAspectFill)
        })
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func actualLauncherAllowsPortraitAfterStreamDismissal() async throws {
        let scene = try await testWindowScene()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let fixture = LauncherFixture()
        let id = UUID()
        fixture.makeSession = { launch in
            StreamSessionModel(launch: launch, makePlayback: { _, _, _ in
                StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                               format: StreamFormat(width: 2622, height: 1206, fps: 120),
                               observeControllers: { $0(true) })
            })
        }
        let model = fixture.model()
        let launcher = UIHostingController(rootView: LauncherView(model: model))
        window.rootViewController = launcher
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        launcher.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitForOrientation(scene, portrait: true, controller: launcher)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        try await waitForLauncherLayout(launcher, window: window)
        try recordPhase(launcher.view, name: "orientation-launcher-before-stream")
        model.launch(fixture.app)
        let stream = try #require(model.stream)
        var captureError: Error?
        do {
            try await waitForUIState("The launcher's stream cover did not appear.") {
                launcher.presentedViewController != nil
            }
            let player = try #require(launcher.presentedViewController)
            try await waitForUIState("The stream did not start in the presented window.") {
                stream.phase == .connecting
            }
            let pad = window.traitCollection.userInterfaceIdiom == .pad
            if !pad {
                try await waitForOrientation(scene, portrait: false, controller: player)
                #expect(player.view.bounds.width > player.view.bounds.height)
            }
            stream.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
            #expect(AppDelegate.orientationMask(for: window) == (pad ? .all : .landscape))
            try recordPhase(player.view, name: "orientation-stream-presented")
        } catch { captureError = error }
        stream.disconnect()
        try await waitForUIState("The launcher's stream cover did not dismiss.") {
            model.stream == nil && launcher.presentedViewController == nil
        }
        await model.waitUntilStreamClosed()
        #expect(model.hasActiveStream == false)
        #expect(AppDelegate.orientationMask(for: window).contains(.portrait))
        // Model a subsequent phone rotation; production must release its lock without a test invalidation.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitForOrientation(scene, portrait: true, controller: launcher)
        #expect(launcher.view.bounds.height > launcher.view.bounds.width)
        try await waitForLauncherLayout(launcher, window: window)
        try recordPhase(launcher.view, name: "orientation-launcher-after-disconnect")
        if let captureError { throw captureError }
    }

    @Test(arguments: ["connecting", "streaming", "playing", "waiting", "mouse", "mouse-controls",
                      "reconnecting", "ended"])
    func streamControls(state: String) async throws {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           format: StreamFormat(width: 2622, height: 1206, fps: 120),
                           observeControllers: { $0(true) })
        })
        model.start(surface: StreamSurface())
        if ["streaming", "playing", "waiting", "mouse", "mouse-controls"].contains(state) {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.controllersActive(true))))
        }
        if ["playing", "waiting", "mouse"].contains(state) { model.resumeInput() }
        if state == "streaming" || state == "mouse-controls" { model.showControls() }
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        if state.hasPrefix("mouse") {
            let controller = try #require(connection.input.registerController(
                ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [])))
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.mouseMode(controller, enabled: true))))
        }
        if state == "waiting" {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .waitingForVideo(true)))
        }
        if state == "reconnecting" {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
        }
        if state == "ended" { model.stop(); await model.waitUntilStopped() }
        try await record(ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) },
                         name: "stream-\(state)", size: CGSize(width: 667, height: 375), dark: true)
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
    }

    @Test(arguments: [CGSize(width: 667, height: 375), CGSize(width: 956, height: 440)], [false, true])
    func recoveringNativeSurface(size: CGSize, dark: Bool) async throws {
        let (model, controller) = recoveryController()
        let theme = dark ? "dark" : "light"
        try await recordController(controller, name: "recovery-\(Int(size.width))-\(theme)", size: size, dark: dark)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func actualSimulatorScenePresentsRecovery() async throws {
        let (model, controller) = recoveryController()
        try await recordController(controller, name: "recovery-simulator-landscape", size: nil, dark: true)
        model.stop()
        await model.waitUntilStopped()
    }

    private func recoveryController() -> (StreamSessionModel, StreamViewController) {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           format: StreamFormat(width: 2622, height: 1206, fps: 120))
        })
        let controller = StreamViewController(model: model, close: {})
        controller.loadViewIfNeeded()
        model.start(surface: controller.surface)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.resumeInput()
        let original = controller.surface.displayLayer
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
        #expect(controller.surface.displayLayer === original)
        #expect(original.superlayer === controller.surface.layer)
        #expect(controller.controllerUserInteractionEnabled && !model.inputFocused)
        return (model, controller)
    }

    func record<Content: View>(_ content: Content, name: String, size: CGSize?, dark: Bool,
                               textSize: DynamicTypeSize = .xxxLarge, portrait: Bool = false,
                               landscapeRight: Bool = false,
                               prepare: (() async -> Void)? = nil,
                               inspect: ((UIView) throws -> Void)? = nil) async throws {
        let host = UIHostingController(rootView: content.dynamicTypeSize(textSize))
        try await recordController(host, name: name, size: size, dark: dark, portrait: portrait,
                                   prepare: prepare, textSize: textSize, landscapeRight: landscapeRight,
                                   inspect: inspect)
    }

    func recordController(_ host: UIViewController, name: String, size: CGSize?, dark: Bool,
                          portrait: Bool = false, prepare: (() async -> Void)? = nil,
                          textSize: DynamicTypeSize = .xxxLarge, landscapeRight: Bool = false,
                          inspect: ((UIView) throws -> Void)? = nil) async throws {
        let scene = try await testWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.traitOverrides.preferredContentSizeCategory = textSize == .accessibility5
            ? .accessibilityExtraExtraExtraLarge : (textSize == .large ? .large : .extraExtraExtraLarge)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let root: UIViewController
        if let size {
            root = FixtureViewportController(content: host, size: size)
            if name.hasPrefix("ipad-") {
                host.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            }
        } else { root = host }
        window.rootViewController = root
        window.makeKeyAndVisible()
        // Resizable iPad scenes ignore orientation requests; they record the window as it is.
        if portrait || (size == nil && scene.traitCollection.userInterfaceIdiom != .pad) {
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
            let landscape: UIInterfaceOrientationMask = landscapeRight ? .landscapeRight : .landscapeLeft
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: portrait ? .portrait : landscape))
            try await waitForOrientation(scene, portrait: portrait, controller: root)
            if landscapeRight {
                try await waitForUIState("The scene did not rotate to landscape right.") {
                    scene.effectiveGeometry.interfaceOrientation == .landscapeRight
                }
            }
        }
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        // Give SwiftUI one finite layout transaction on the hosted Simulator.
        try await Task.sleep(for: .milliseconds(200))
        await finishTransition(root)
        await prepare?()
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let expectedSize = size ?? scene.effectiveGeometry.coordinateSpace.bounds.size
        #expect(host.view.bounds.size == expectedSize)
        if host is StreamViewController {
            #expect(host.children.allSatisfy { $0.view.bounds.size == expectedSize })
            #expect(host.children.allSatisfy { $0.traitCollection.userInterfaceStyle == .dark })
        }
        if portrait {
            #expect(scene.effectiveGeometry.interfaceOrientation == .portrait)
            #expect(window.bounds.height > window.bounds.width)
        }
        if size == nil, host is StreamViewController, window.traitCollection.userInterfaceIdiom != .pad {
            #expect(scene.effectiveGeometry.interfaceOrientation.isLandscape)
            #expect(window.bounds.width > window.bounds.height)
        }
        if name.hasPrefix("ipad-") { recordIPadGeometry(host.view, name: name) }
        let format = UIGraphicsImageRendererFormat()
        if name.hasPrefix("ipad-") { format.scale = 1 }
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
        var rendered = false
        let image = renderer.image { _ in
            rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        #expect(rendered)
        #expect(image.size == expectedSize)
        let data = try #require(image.pngData())
        #expect(data.count > 1_000)
        Attachment.record(Array(data), named: "\(name)-large-text.png")
        try inspect?(host.view)
        if size == nil {
            let traits = host.traitCollection
            let geometry = "bounds=\(host.view.bounds); safeArea=\(host.view.safeAreaInsets); "
                + "sizeClass=\(traits.horizontalSizeClass.rawValue),\(traits.verticalSizeClass.rawValue)"
            Attachment.record(geometry, named: "\(name)-geometry.txt")
        }
    }

    private func recordPhase(_ view: UIView, name: String) throws {
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        var rendered = false
        let image = renderer.image { _ in rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        #expect(rendered)
        let data = try #require(image.pngData())
        Attachment.record(Array(data), named: "\(name).png")
    }

    private func waitForUIState(_ message: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "\(message)")
    }

    private func waitForLauncherLayout(_ host: UIViewController, window: UIWindow) async throws {
        for child in host.children { await finishTransition(child) }
        try await waitForUIState("The launcher's navigation or scroll viewport remained outside the rotated window.") {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let views = launcherViewports(in: host.view)
            guard host.view.bounds.size == window.bounds.size,
                  window.bounds.size == window.windowScene?.effectiveGeometry.coordinateSpace.bounds.size,
                  views.contains(where: { $0 is UINavigationBar }),
                  views.contains(where: { $0 is UIScrollView }) else { return false }
            let checkedViews: [UIView] = [window, host.view] + views
            return checkedViews.allSatisfy { view in
                let rect = view.convert(view.bounds, to: window)
                guard rect.minX >= -1, rect.maxX <= window.bounds.maxX + 1,
                      rect.minY >= -1, rect.maxY <= window.bounds.maxY + 1 else { return false }
                guard let shown = view.layer.presentation() else { return true }
                return shown.bounds == view.layer.bounds && shown.position == view.layer.position &&
                    CATransform3DEqualToTransform(shown.transform, view.layer.transform)
            }
        }
    }

    private func launcherViewports(in view: UIView) -> [UIView] {
        guard view.isHidden == false, view.alpha > 0 else { return [] }
        let own = view is UINavigationBar || view is UIScrollView ? [view] : []
        return own + view.subviews.flatMap { launcherViewports(in: $0) }
    }

    private func waitForOrientation(_ scene: UIWindowScene, portrait: Bool,
                                    controller: UIViewController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func matches() -> Bool {
            let orientation = scene.effectiveGeometry.interfaceOrientation
            return portrait ? orientation == .portrait : orientation.isLandscape
        }
        while !matches(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(matches(), "The scene did not reach its requested interface orientation.")
        await finishTransition(controller)
        controller.view.layoutIfNeeded()
    }

    private func finishTransition(_ host: UIViewController) async {
        guard let transition = host.transitionCoordinator else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = Mutex<CheckedContinuation<Void, Never>?>(continuation)
            let finish: @Sendable () -> Void = {
                let value = pending.withLock { value in defer { value = nil }; return value }
                value?.resume()
            }
            let joined = transition.animate(alongsideTransition: nil) { _ in finish() }
            #expect(joined)
            if !joined { finish() }
        }
    }
}

@MainActor
private final class FixtureViewportController: UIViewController {
    private let content: UIViewController
    private let size: CGSize

    init(content: UIViewController, size: CGSize) {
        self.content = content
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { content.supportedInterfaceOrientations }
    override var prefersStatusBarHidden: Bool { content.prefersStatusBarHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = CGRect(origin: .zero, size: size)
    }
}
