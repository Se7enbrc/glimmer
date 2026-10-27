// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamWindowResizeCoordinatorTests {
    let initial = StreamFormat(width: 1536, height: 2048, fps: 60)
    let narrow = StreamFormat(width: 750, height: 1706, fps: 60)
    let wide = StreamFormat(width: 2048, height: 1536, fps: 60)

    @Test func continuedGameAtAnEarlierSizeMovesToTheWindowModeWithoutRelaunching() async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        let clock = WindowResizeClock()
        let id = UUID()
        var starts = 0
        var stops = 0
        var requests: [StreamFormat] = []
        let earlier = StreamFormat(width: 1920, height: 1080, fps: 60)
        let model = StreamSessionModel(launch: testLaunch(), resizeSleep: clock.sleep, makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in },
                start: { await MainActor.run { starts += 1 }; return nil },
                stop: { await MainActor.run { stops += 1 } }, screenChanged: {}, format: earlier,
                requestFormatChange: { requests.append($0); return .applied })
        })
        model.start(surface: surface)
        await model.waitUntilStartFinishes()
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.windowChanged(surface: surface)
        await clock.waitForSleeps(1)
        #expect(await clock.durations == [.milliseconds(750)])
        await clock.advance()
        await model.waitForWindowResize()
        let target = try #require(requests.first)
        #expect(requests.count == 1 && target.fps == earlier.fps && target != earlier)
        #expect(StreamDisplayModes.bundled.contains { $0.width == target.width && $0.height == target.height })
        #expect(model.requestedFormat == target)
        #expect(starts == 1 && stops == 0 && model.phase == .streaming)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func a120FPSStreamResizesOnlyToAListed120FPSMode() async throws {
        let scene = try await testWindowScene()
        let window = UIWindow(windowScene: scene)
        let surface = StreamSurface()
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        surface.frame.size = CGSize(width: 1184 / scene.screen.scale, height: 1668 / scene.screen.scale)
        let initial = StreamFormat(width: 2388, height: 1668, fps: 120)
        let id = UUID()
        var requests: [StreamFormat] = []
        let model = StreamSessionModel(launch: testLaunch(), resizeSleep: { _ in }, makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                format: initial, requestFormatChange: { requests.append($0); return .applied })
        })
        model.start(surface: surface)
        await model.waitUntilStartFinishes()
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.windowChanged(surface: surface)
        await model.waitForWindowResize()
        for target in requests {
            #expect(target.fps == initial.fps)
            #expect(StreamDisplayModes.bundled.contains(target))
        }
        #expect(requests.count == 1)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func resizeDebouncesLatestSizeAndDoesNotResetForDuplicateLayout() async {
        let clock = WindowResizeClock()
        var requests: [StreamFormat] = []
        var applied: [StreamFormat] = []
        let resize = StreamWindowResize(format: initial, request: { requests.append($0); return .applied },
                                        applied: { applied.append($0) }, sleep: clock.sleep)
        resize.setAvailable(true)
        resize.submit(narrow)
        await clock.waitForSleeps(1)
        resize.submit(narrow)
        resize.submit(wide)
        await clock.waitForSleeps(2)
        #expect(requests.isEmpty)
        #expect(await clock.durations == [.milliseconds(750), .milliseconds(750)])
        await clock.advance()
        await resize.waitForPendingChange()
        #expect(requests == [wide] && applied == [wide])
        resize.submit(wide)
        #expect(await clock.durations.count == 2)
        resize.stop()
    }

    @Test func inFlightResizeKeepsLatestSizeWithoutOverlappingRequests() async {
        let clock = WindowResizeClock()
        let applying = StreamTestGate()
        var requests: [StreamFormat] = []
        let resize = StreamWindowResize(format: initial, request: {
            requests.append($0)
            await applying.wait()
            return .applied
        }, applied: { _ in }, sleep: clock.sleep)
        resize.setAvailable(true)
        resize.submit(narrow)
        await clock.waitForSleeps(1)
        await clock.advance()
        await applying.waitUntilEntered()
        resize.submit(wide)
        resize.submit(initial)
        #expect(requests == [narrow])
        await applying.release()
        await clock.waitForSleeps(2)
        await clock.advance()
        await resize.waitForPendingChange()
        #expect(requests == [narrow, initial])
        resize.stop()
    }

    @Test func deferredResizeWaitsForLifecycleEvidenceAndStopCancelsPendingWork() async {
        let clock = WindowResizeClock()
        var requests: [StreamFormat] = []
        var applied: [StreamFormat] = []
        let resize = StreamWindowResize(format: initial, request: { requests.append($0); return .deferred },
                                        applied: { applied.append($0) }, sleep: clock.sleep)
        resize.submit(narrow)
        #expect(await clock.durations.isEmpty)
        resize.setAvailable(true)
        await clock.waitForSleeps(1)
        await clock.advance()
        await resize.waitForPendingChange()
        #expect(requests == [narrow] && applied.isEmpty)
        resize.setAvailable(false)
        resize.setAvailable(true)
        await clock.waitForSleeps(2)
        resize.stop()
        await clock.advance()
        await resize.waitForPendingChange()
        #expect(requests == [narrow])
    }

    @Test func stoppingDuringApplicationCannotPublishAStaleFormat() async {
        let clock = WindowResizeClock()
        let applying = StreamTestGate()
        var applied: [StreamFormat] = []
        let resize = StreamWindowResize(format: initial, request: { _ in
            await applying.wait()
            return .applied
        }, applied: { applied.append($0) }, sleep: clock.sleep)
        resize.setAvailable(true)
        resize.submit(narrow)
        await clock.waitForSleeps(1)
        await clock.advance()
        await applying.waitUntilEntered()
        resize.stop()
        await applying.release()
        await resize.waitForPendingChange()
        #expect(applied.isEmpty)
    }

    @Test func inactiveWindowCancelsDebounceAndRetainsLatestTarget() async {
        let clock = WindowResizeClock()
        var requests: [StreamFormat] = []
        let resize = StreamWindowResize(format: initial, request: { requests.append($0); return .applied },
                                        applied: { _ in }, sleep: clock.sleep)
        resize.setAvailable(true)
        resize.submit(narrow)
        await clock.waitForSleeps(1)
        resize.setAvailable(false)
        await clock.advance()
        #expect(requests.isEmpty)
        resize.submit(wide)
        resize.setAvailable(true)
        await clock.waitForSleeps(2)
        await clock.advance()
        await resize.waitForPendingChange()
        #expect(requests == [wide])
        resize.stop()
    }
}

actor WindowResizeClock {
    private(set) var durations: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
            let ready = observers.filter { $0.0 <= durations.count }
            observers.removeAll { $0.0 <= durations.count }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func waitForSleeps(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func advance() {
        let ready = sleepers
        sleepers.removeAll()
        for continuation in ready { continuation.resume() }
    }
}
