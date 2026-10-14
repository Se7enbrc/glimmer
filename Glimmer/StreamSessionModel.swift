// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Observation
import UIKit

@MainActor
@Observable
final class StreamSessionModel {
    enum Phase: Equatable {
        case idle, connecting, streaming, stopping, ended(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var audioUnavailable = false
    private(set) var connectionPoor = false
    private(set) var canStart = true
    nonisolated let launch: StreamLaunch
    private let makePlayback: @MainActor (StreamLaunch, StreamSurface, AsyncStream<StreamPlayback.Event>.Continuation)
        -> StreamPlayback
    private let readIdleTimer: () -> Bool
    private let writeIdleTimer: (Bool) -> Void
    private var savedIdleTimer: Bool?
    private var playback: StreamPlayback?
    private var generation: UInt64 = 0
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamPlayback.Event>.Continuation?

    init(launch: StreamLaunch,
         makePlayback: @escaping @MainActor (StreamLaunch, StreamSurface,
            AsyncStream<StreamPlayback.Event>.Continuation) -> StreamPlayback = StreamPlayback.make,
         readIdleTimer: @escaping () -> Bool = { UIApplication.shared.isIdleTimerDisabled },
         writeIdleTimer: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.launch = launch
        self.makePlayback = makePlayback
        self.readIdleTimer = readIdleTimer
        self.writeIdleTimer = writeIdleTimer
    }

    func start(surface: StreamSurface) {
        guard canStart, phase == .idle, stopTask == nil else { return }
        generation &+= 1
        let attempt = generation
        let events = AsyncStream<StreamPlayback.Event>.makeStream()
        continuation = events.continuation
        let playback = makePlayback(launch, surface, events.continuation)
        self.playback = playback
        phase = .connecting
        savedIdleTimer = readIdleTimer()
        writeIdleTimer(true)
        eventTask = Task { [weak self] in
            for await event in events.stream {
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.receive(event)
            }
        }
        connectTask = Task { [weak self] in
            do {
                try await playback.connect()
            } catch {
                guard let self, self.generation == attempt else { return }
                self.stop(message: "Couldn't connect to \(self.launch.pcName). Check Sunshine on the PC and try again.")
            }
        }
    }

    func stop(message: String? = nil) {
        guard stopTask == nil else { return }
        let ending = message ?? "Disconnected from \(launch.pcName)."
        guard let playback else {
            if phase == .idle { phase = .ended(ending) }
            return
        }
        generation &+= 1
        phase = .stopping
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        continuation?.finish()
        continuation = nil
        if let savedIdleTimer { writeIdleTimer(savedIdleTimer); self.savedIdleTimer = nil }
        stopTask = Task {
            await playback.stop()
            playback.teardown()
            self.playback = nil
            phase = .ended(ending)
            stopTask = nil
        }
    }

    func availabilityChanged(active: Bool, background: Bool, protectedDataAvailable: Bool) {
        canStart = active && protectedDataAvailable
        if background || !protectedDataAvailable { stop() }
    }

    func screenChanged() { playback?.screenChanged() }

    func waitUntilStopped() async { await stopTask?.value }

    func receive(_ event: StreamPlayback.Event) {
        guard phase == .connecting || phase == .streaming else { return }
        switch event {
        case .firstFrame(let id):
            guard playback?.id == id else { return }
            phase = .streaming
        case .connection(let id, let event):
            guard playback?.id == id else { return }
            switch event {
            case .terminated:
                stop(message: "The connection to \(launch.pcName) ended. Check the PC and reconnect when you're ready.")
            case .stageFailed:
                stop(message: "Couldn't connect to \(launch.pcName). Check Sunshine on the PC and try again.")
            case .connectionPoor(let poor): connectionPoor = poor
            case .audioFailed: audioUnavailable = true
            case .hdrMode(let enabled): playback?.setHDR(enabled)
            case .connected, .stageStarting, .stageComplete: break
            }
        }
    }
}
