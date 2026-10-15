// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamSession {
    public struct Update: Sendable {
        public let sessionID: UUID
        public let attemptID: UUID
        public let event: StreamEvent

        public init(sessionID: UUID, attemptID: UUID, event: StreamEvent) {
            self.sessionID = sessionID
            self.attemptID = attemptID
            self.event = event
        }
    }

    /// Concrete media is prepared once and retained through transport recovery.
    @MainActor public final class PreparedMedia {
        let video: VideoDecoder
        let audio: AudioDecoder
        private var quiesceHook: (@MainActor @Sendable () -> Void)?
        private var finalDispose: (@MainActor @Sendable () async -> Void)?
        private var disposal: Task<Void, Never>?

        public init(video: VideoDecoder, audio: AudioDecoder,
                    quiesce: @escaping @MainActor @Sendable () -> Void,
                    finalDispose: @escaping @MainActor @Sendable () async -> Void) {
            self.video = video
            self.audio = audio
            self.quiesceHook = quiesce
            self.finalDispose = finalDispose
        }

        func quiesce() { quiesceHook?() }

        func dispose() async {
            if let disposal { await disposal.value; return }
            let finish = finalDispose
            finalDispose = nil
            let task = Task { if let finish { await finish() } }
            disposal = task
            await task.value
            quiesceHook = nil
        }
    }

    /// Exactly one synchronous input handle survives every attempt. Stop ends this public session permanently.
    @MainActor public static func make(media: PreparedMedia, network: NetworkClient, hostDisposition: StreamHostDisposition)
        -> (session: StreamSession, input: StreamInput) {
        let events = SessionEventSource()
        _ = events.stream
        let input = StreamInput { events.yield(.input($0)) }
        let session = StreamSession(hostDisposition: hostDisposition, audioDecoder: media.audio,
            services: SessionServices(), backend: NativeBackend(), makeNetwork: { network.freshClient(for: $0) },
            makeBackend: { NativeBackend() }, publicMedia: media, publicInput: input, preparedNetwork: network, events: events)
        events.onTermination { [weak session] in Task { await session?.stop(cause: .consumerDropped) } }
        return (session, input)
    }

    /// Reuses the paired client's cached PC record; initial launch/resume makes no extra server-info request.
    public func start(appID: Int, configuration: StreamConnection.Configuration) async throws {
        guard !publicTerminal else { throw CancellationError() }
        guard let media = publicMedia, let ownedInput = publicInput, let network = preparedNetwork, !publicStarted else {
            throw StreamConnection.Failure.alreadyStarted
        }
        publicStarted = true
        do {
            guard appID > 0 else { throw StreamConnection.Failure.invalidConfiguration }
            try configuration.validate()
            suppliedRouteMTU = configuration.routeMTU
            let server = await network.server
            guard !publicTerminal else { throw CancellationError() }
            _ = try await start(server: server, request: configuration.request, appID: appID, cachedNetwork: network,
                prepare: { bitrate in
                    media.video.setNegotiatedBitrateKbps(bitrate)
                    let presentation = SessionPresentation()
                    if let firstFrame = media.video.onFirstDecodedFrame { presentation.firstFrame = { firstFrame() } }
                    presentation.waitForVisualClose = { await media.dispose() }
                    let hooks = SessionInputHooks(setBackend: { _ in }, setReady: { _ in },
                        quiesce: { media.quiesce() }, detach: { ownedInput.stop() }, configure: { _ in })
                    return SessionMedia(presentation: presentation, input: hooks, video: media.video)
                })
        } catch {
            await stop()
            throw error
        }
    }

    /// Shared measured evidence only; no sampler or session-retaining closure is introduced.
    public nonisolated static func audioEnvironment(host: String) -> AudioEnvironment {
        AudioEnvironment(host: host, link: EnvSignalController.shared.streamLink,
                         jitterMs: EnvSignalController.shared.decision.smoothedJitterMs)
    }
}
