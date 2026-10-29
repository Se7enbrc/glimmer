// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import Glimmer

extension NativeUIRenderTests {
    @Test func geometryFailureCanArriveOnUIKitBackgroundQueue() async throws {
        let active = try await activeRenderScene()
        let method = try #require(class_getInstanceMethod(UIWindowScene.self,
            #selector(UIWindowScene.requestGeometryUpdate(_:errorHandler:))))
        let deliveries = AsyncStream<Void>.makeStream()
        typealias ErrorHandler = @convention(block) (NSError) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject, ErrorHandler?) -> Void = { _, _, handler in
            // Transfer the callback once, as UIKit does when its geometry request expires.
            nonisolated(unsafe) let report = handler
            DispatchQueue.global().async {
                #expect(Thread.isMainThread == false)
                #expect(report != nil)
                report?(CocoaError(.userCancelled) as NSError)
                deliveries.continuation.yield(())
                deliveries.continuation.finish()
            }
        }
        let implementation = imp_implementationWithBlock(replacement)
        let original = method_setImplementation(method, implementation)
        StreamViewController.requestLandscape(in: active)
        method_setImplementation(method, original)
        defer { imp_removeBlock(implementation) }
        for await _ in deliveries.stream { break }
    }

    // The deadline diagnoses a missing signal; it never makes a fixture ready.
    func waitForUIState(_ message: String, in view: UIView? = nil,
                        condition: @escaping @MainActor () -> Bool) async throws {
        let scene = try await activeRenderScene()
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let link = UIUpdateLink(windowScene: scene)
        link.addAction(to: .afterUpdateComplete) { link, _ in
            link.requiresContinuousUpdates = false
            events.continuation.yield(())
        }
        let timeout = DispatchWorkItem { events.continuation.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel(); link.isEnabled = false; events.continuation.finish() }
        view?.setNeedsLayout()
        link.requiresContinuousUpdates = true
        link.isEnabled = true
        for await _ in events.stream where condition() { return }
        throw RenderReadinessFailure.missingSignal(message)
    }

    func commitLayout(_ view: UIView) async throws {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await waitForUIState("UIKit did not commit the fixture layout.", in: view) { true }
    }

    func activeRenderScene() async throws -> UIWindowScene {
        let activations = NotificationCenter.default.notifications(named: UIScene.didActivateNotification)
            .map { _ in () }
        let scene = try await testWindowScene()
        if scene.activationState == .foregroundActive { return scene }
        for await _ in activations where scene.activationState == .foregroundActive { return scene }
        throw CancellationError()
    }

    func waitForOrientation(_ scene: UIWindowScene, portrait: Bool,
                            controller: UIViewController) async throws {
        if scene.traitCollection.userInterfaceIdiom != .pad {
            try await observeGeometry(scene) {
                let orientation = scene.effectiveGeometry.interfaceOrientation
                return portrait ? orientation == .portrait : orientation.isLandscape
            }
        }
        await finishTransition(controller)
        try await commitLayout(controller.view)
        try await waitForSceneSize(controller, in: scene)
    }

    // The scene reports its new orientation before UIKit resizes the window and its controllers.
    func waitForSceneSize(_ controller: UIViewController, in scene: UIWindowScene) async throws {
        try await waitForUIState("The view did not take the rotated scene's size.") {
            controller.transitionCoordinator == nil
                && controller.view.bounds.size == scene.effectiveGeometry.coordinateSpace.bounds.size
        }
    }

    func observeGeometry(_ scene: UIWindowScene, request: (() -> Void)? = nil,
                         matches: @escaping @MainActor () -> Bool) async throws {
        if matches() { return }
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { _, _ in
            events.continuation.yield(())
        }
        let timeout = DispatchWorkItem { events.continuation.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel(); observation.invalidate(); events.continuation.finish() }
        request?()
        for await _ in events.stream where matches() { return }
        throw RenderReadinessFailure.missingSignal("The scene did not reach its requested interface orientation.")
    }

    /// The simulator refuses rotations while another transition settles; real apps simply ask again.
    func requestOrientation(_ scene: UIWindowScene, _ mask: UIInterfaceOrientationMask,
                            settling controller: UIViewController,
                            matches: @escaping @MainActor () -> Bool) async throws {
        let refusal = OrientationRefusal()
        for _ in 0..<4 where !matches() {
            do {
                try await observeGeometry(scene, request: {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
                        refusal.reason.withLock { $0 = "\(error)" }
                    }
                }, matches: matches)
            } catch {
                await finishTransition(controller)
                try await commitLayout(controller.view)
            }
        }
        guard matches() else {
            let reason = refusal.reason.withLock { $0 }.map { " (\($0))" } ?? ""
            throw RenderReadinessFailure.missingSignal(
                "The scene did not reach its requested interface orientation\(reason).")
        }
        try await waitForSceneSize(controller, in: scene)
    }

    func finishTransition(_ host: UIViewController) async {
        guard let transition = host.transitionCoordinator else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = Mutex<CheckedContinuation<Void, Never>?>(continuation)
            let finish: @Sendable () -> Void = {
                let value = pending.withLock { value in defer { value = nil }; return value }
                value?.resume()
            }
            let joined = transition.animate(alongsideTransition: nil) { _ in finish() }
            if !joined { finish() }
        }
    }
}

enum RenderReadinessFailure: Error {
    case missingSignal(String)
}

private final class OrientationRefusal: Sendable {
    let reason = Mutex<String?>(nil)
}
