// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import CryptoKit
import GameController
@testable import GlimmerEngine
import UIKit

@MainActor
final class UITestJourneyPC {
    private let directory: URL
    private let receipts: JourneyReceipts
    private var paired: Bool
    private var running = false
    private var saved: [SavedPC] = []
    private var videoTask: Task<Void, Never>?
    private var physical: [GCController] = []
    private var controllerCommand = ""
    private let controllerDriver: JourneyControllerDriver
    private var hardware: [String: Double] = [:]

    init(directory: URL, firstRun: Bool) {
        self.directory = directory
        let receipts = JourneyReceipts(directory: directory)
        self.receipts = receipts
        controllerDriver = JourneyControllerDriver(directory: directory, receipts: receipts)
        paired = !firstRun
        if paired { saved = [SavedPC(server: server)] }
        record(["fixture": 1])
        recordHardware()
    }

    private var server: ServerInfo {
        var server = ServerInfo(address: "pc.invalid", uniqueId: "journey-pc", serverName: "Journey PC")
        server.pairStatus = paired ? .paired : .unpaired
        server.serverCertPEM = paired ? "fixture-only" : nil
        server.currentGameID = running ? 1 : 0
        return server
    }

    private func prepared() -> PreparedPC {
        let identity = IdentityManager(defaultsSuite: "journey-unused",
                                       supportBase: FileManager.default.temporaryDirectory,
                                       protectedDataAvailable: { false })
        let network = NetworkClient(server: server, identity: identity, deviceName: "Simulator")
        return PreparedPC(network: network, server: server)
    }

    func launcher() -> LauncherModel {
        controllerDriver.start()
        let calls = LauncherModel.Calls(savedPCs: { self.saved }, prepare: { _, _ in self.prepared() },
            pair: { _, pin in
                let expected = SHA256.hash(data: Data(pin.utf8)).description
                self.record(["pairRequested": 1])
                for _ in 0..<400 {
                    try Task.checkCancellation()
                    let approval = try? String(contentsOf: self.directory.appendingPathComponent("approve"),
                                               encoding: .utf8)
                    if approval == expected {
                        self.paired = true
                        self.record(["paired": 1])
                        return self.prepared()
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw CancellationError()
            }, apps: { _ in [HostApp(id: 1, name: "Journey game", hdrCapable: false, hidden: false)] },
            remember: { pc in self.saved = [SavedPC(server: pc.server)]; return self.saved },
            protectedDataChanged: { _ in }, artwork: { _, _ in Data() }, status: { _ in self.server },
            makeSession: { launch in
                StreamSessionModel(launch: launch, makePlayback: { launch, surface, _ in
                    try self.playback(launch: launch, surface: surface)
                })
            })
        return LauncherModel(calls: calls, discoveryEnabled: false)
    }

    private func playback(launch: StreamLaunch, surface: StreamSurface) throws -> StreamPlayback {
        let format = try launch.profile.resolve(surface: surface)
        let updates = AsyncStream<StreamSession.Update>.makeStream()
        let id = UUID()
        let input = StreamInput(backend: JourneyBackend(receipts: receipts)) { event in
            updates.continuation.yield(.init(sessionID: id, attemptID: id, event: .input(event)))
        }
        StreamPlayback.configureInput(input)
        input.activate(true)
        let native = NativeInputLifetime()
        let touch = TouchGamepadCapture(calls: .init(register: input.registerController,
            unregister: input.unregisterController, submit: { [self] registration, sample, time in
                record(["buttons": Double(sample.buttons.rawValue), "lt": Double(sample.leftTrigger),
                        "rt": Double(sample.rightTrigger), "lx": Double(sample.leftStickX),
                        "ly": Double(sample.leftStickY), "rx": Double(sample.rightStickX),
                        "ry": Double(sample.rightStickY), "time": time])
                input.submitController(registration, sample: sample, capturedAt: time)
            }))
        let controllers = IOSControllerCapture(input: input,
            readControllers: { self.physical + self.controllerDriver.controllers })
        native.start(input: input, controllers: controllers, touch: touch)
        let video = JourneyVideo(layer: surface.displayLayer)
        let stats = StreamStats(surface: surface, snapshot: {
            var snapshot = StreamStatsSnapshot()
            snapshot.hostFps = 10
            return snapshot
        }, collection: { _ in }, videoSize: { surface.bounds.size }, backdrop: { _ in nil })
        return StreamPlayback(id: id, events: updates.stream, start: { [self] in
            await startVideo(video, updates: updates.continuation, id: id, launch: launch, controllers: controllers)
            return nil
        }, stop: { [self] in
            await MainActor.run {
                videoTask?.cancel()
                videoTask = nil
                native.stop()
                stats.setVisible(false)
                running = launch.leaveGamesRunning
                record(["stop": 1, "quit": launch.leaveGamesRunning ? 0 : 1])
                updates.continuation.finish()
            }
            input.activate(false)
        }, screenChanged: {}, input: input, focusInput: native.focus,
           format: format, observeControllers: { [self] changed in
               native.observeControllers { connected in
                   self.record(["nativeControllers": connected ? 1 : 0])
                   changed(connected)
               }
           },
           touchGamepad: touch, showTouchControls: native.showTouchControls,
           requestFormatChange: { [self] format in
               record(["resize": 1, "width": Double(format.width), "height": Double(format.height)])
               return .applied
           }, showStats: stats.setVisible)
    }

    private func startVideo(_ video: JourneyVideo, updates: AsyncStream<StreamSession.Update>.Continuation,
                            id: UUID, launch: StreamLaunch, controllers: IOSControllerCapture) {
        running = true
        record([launch.continuing ? "resume" : "launch": 1])
        videoTask = Task { [self] in
            var first = true
            do {
                while !Task.isCancelled {
                    try video.draw()
                    if first && video.ready {
                        first = false
                        record(["rendered": 1])
                        updates.yield(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                    }
                    refreshController(controllers)
                    recordHardware()
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                return
            } catch {
                record(["videoError": 1])
            }
        }
    }

    private func refreshController(_ controllers: IOSControllerCapture) {
        let command = (try? String(contentsOf: directory.appendingPathComponent("controller"), encoding: .utf8)) ?? ""
        guard command != controllerCommand else { return }
        controllerCommand = command
        physical = command == "connect" ? [GCController.withExtendedGamepad()] : []
        controllers.refresh()
        record(["controller": physical.isEmpty ? 0 : 1])
    }

    private func recordHardware() {
        let current = ["controllers": Double(GCController.controllers().count),
                       "keyboards": GCKeyboard.coalesced == nil ? 0.0 : 1.0,
                       "mice": Double(GCMouse.mice().count)]
        guard current != hardware else { return }
        hardware = current
        record(current)
    }

    private func record(_ event: [String: Double]) { receipts.record(event) }
}
#endif
