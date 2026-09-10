//
//  AppModel+Streaming.swift
//
//  The streaming session lifecycle: the launch entry points (requestStream /
//  takeover confirm / stream(app:on:)), the single teardown cleanup, the
//  engine's StreamEvent handling, the connect cancel + connect-hold
//  adjudication, and the stream-ended toast copy. Split out of AppModel.swift
//  to keep each unit focused; the derived spec/hero-verb accessors and the
//  Host → engine config bridge live in AppModel+Streaming+Config.swift.
//

import Foundation
import AppKit
import AudioToolbox
import CoreAudio
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

extension AppModel {

    /// UI entry point for a launch. If the host is already streaming an app
    /// that ISN'T ours, arm `pendingTakeover` for a confirm before we /launch
    /// over the live occupant; otherwise stream straight through.
    func requestStream(app: LibraryApp, on host: Host) {
        if !isStreaming,
           let live = hostLiveStatus, live.hostID == host.id,
           Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale,
           case .streamingApp(let occupant) = live.state {
            pendingTakeover = PendingTakeover(app: app, host: host, occupantApp: occupant)
            return
        }
        stream(app: app, on: host)
    }

    /// Confirm the armed takeover and launch over the host's current session.
    func confirmPendingTakeover() {
        guard let pending = pendingTakeover else { return }
        pendingTakeover = nil
        stream(app: pending.app, on: pending.host)
    }

    func stream(app: LibraryApp, on host: Host) {
        // RE-ENTRANCY GUARD. The native backend runs ONE session at a time
        // (StreamBridgeContext.current is a single process-global slot), and
        // a second entry here would corrupt it wholesale: a second
        // StreamSession overwrites nativeSession, markStreamStart() wipes the
        // live session's pending receipt, the new launch's /cancel kills the
        // old host-side session, and the old session's teardown then clobbers
        // isStreaming/streamPhase out from under the new one. The UI disables
        // its launch surfaces while a session exists, but a double-click can
        // land before SwiftUI re-renders - this guard is the actual wall.
        guard !isStreaming else {
            Diag.notice("Ignoring stream request (\(app.name) on \(host.displayName)) - a session is already in flight", "Stream")
            return
        }
        Diag.notice("Starting stream → \(host.displayName) · \(app.name)", "Stream")
        streamPhase = .connecting(stage: "Connecting to \(host.displayName)…")
        nativeStreamError = nil
        nativeHDRActive = false
        // Re-arm the disconnect toast for back-to-back cycles: if the
        // previous session's toast is still inside its 2-4 s hold, dropping
        // the flag here unmounts it (cancelling its hold task) so the NEXT
        // stream end mounts a fresh toast with a full hold, instead of the
        // new toast inheriting the old one's residual timer.
        streamEndedToastVisible = false
        // Connect-hold adjudication breadcrumb, half one: anchor the span at
        // the CLICK (the engine's own clock starts after HTTPS + window
        // build, so it can't answer "did the user wait >400 ms"). The live
        // edge in handleNativeEvent logs the verdict.
        Self.connectClickedAt = Date()
        // True click-to-pixels anchor (telemetry): clear any prior session's
        // latch, then anchor at this launch click - before the connect Task spins
        // up - the leg handshake_total_ms (connect-start anchored) can't see.
        // Resolved at the .firstFrame edge. Reset HERE (not in
        // TelemetryCounters.resetForNewSession, which runs AFTER the click).
        ConnectTimingTelemetry.shared.resetForNewSession()
        ConnectTimingTelemetry.shared.anchorClick()
        Self.connectCapsuleShown = false
        Self.connectCancelRequested = false
        // NB: the "last played" timestamp is intentionally NOT written here.
        // It records when the stream ENDED, not when it started - writing it
        // on start made the launcher's "last played N ago" label tick from
        // the moment a (possibly still-live) session began. The write now
        // lives in the single teardown cleanup site below, gated on
        // `wasStreaming` so it only stamps real sessions.
        isStreaming = true
        // Park awdl0 for the life of the stream - but ONLY off a confirmed-wired
        // route. AWDL contention is a single-radio Wi-Fi problem; on Ethernet,
        // parking awdl0 just disables AirDrop/Continuity system-wide for nothing.
        // Wi-Fi/tunnel/unknown still engage (no-op unless the helper is enabled);
        // cleanupAfterStream releases it on every exit path.
        if hostRoute.routeClass != .wired {
            AWDLHelperManager.shared.suppressForStream()
        }
        // Cancel the chip poller while the stream is up - the native
        // engine reports its own RTT to the stats overlay, and polling
        // /serverinfo concurrently with the RTSP handshake confuses both
        // Sunshine's logs and our own latency story.
        hostStatusTask?.cancel()
        hostStatusTask = nil

        // Synchronous (not a Task): a fire-and-forget restore from the prior session
        // could otherwise land after this mute and un-mute the new stream.
        beforeStreamStart()

        var cfg = nativeStreamConfig(for: host)
        cfg.windowTitle = Self.streamWindowTitle(hostName: host.displayName, appName: app.name)
        // One line naming how the stream will be shown and what was asked for,
        // so a "why is it 1080p in a window" report answers itself from the log.
        Diag.info("Show the stream: \(cfg.displayMode.displayName.lowercased()) - requesting "
            + "\(cfg.width)x\(cfg.height) at \(cfg.fps) Hz", "Stream")
        let info = nativeServerInfo(for: host)
        // Hero-verb memory: stamp the app NAME at stream START (unlike the
        // lastConnected DATE above) so the next launcher visit names the app in
        // "Stream <app>" even if this session ends badly.
        UserDefaults.standard.set(app.name, forKey: Self.lastPlayedAppKey(for: host.id))
        // Arm the session-receipt latch with this session's identity (host +
        // requested mode). The live edge stamps the wall clock; the teardown
        // hook in StreamSession.stop() adds the end-of-session numbers; the
        // cleanup below finalizes. See SessionReceiptStore for the contract.
        SessionReceiptStore.markStreamStart(
            hostId: host.id, width: cfg.width, height: cfg.height, refreshHz: cfg.fps)
        // Hotkey chords are read live via providers (see below) rather
        // than captured here, so edits to quitHotkey/statsHotkey in
        // Settings take effect mid-stream without restarting.
        //
        // Seed the session-scoped stats-overlay state from the user's
        // persisted preference. The in-stream hotkey toggles this value
        // but intentionally does not write back to UserDefaults - see the
        // doc on `statsHotkey`.
        let initialStatsOverlay = showStreamStats

        Task { [weak self] in
            guard let self else { return }
            // The Swift-native engine is the only path.
            let session = StreamSession(backend: NativeBackend())
            await MainActor.run { self.nativeSession = session }
            var caughtError: Error?
            do {
                // Provider closures (rather than captured values) so the user
                // can edit either hotkey in Settings while a stream is live
                // and the change takes effect on the next keyDown - no need
                // to restart the stream to see a new chord work. `self` is
                // captured weakly to avoid a cycle with the session.
                let events = try await session.start(
                    server: info, config: cfg, appID: app.id,
                    quitHotkeyProvider: { [weak self] in self?.quitHotkey ?? .defaultQuit },
                    statsHotkeyProvider: { [weak self] in self?.statsHotkey ?? .defaultStats },
                    // Telemetry-bookmark chord (signal 4). Fixed default ⌃B for
                    // now - client-only, consumed in the input path, never
                    // forwarded to the host. (Made user-configurable later if
                    // desired, alongside quit/stats in Settings.)
                    bookmarkHotkeyProvider: { .defaultBookmark },
                    releasePointerHotkeyProvider: { [weak self] in
                        self?.releasePointerHotkey ?? .defaultReleasePointer
                    },
                    initialStatsOverlay: initialStatsOverlay,
                    initialStatsCorner: streamStatsCorner,
                    // Provider closure so a Settings preset/checkbox
                    // change during a live stream takes effect on the
                    // next 1Hz overlay tick. Resolves through
                    // `effectiveStatsRows` (preset → curated set, or
                    // custom → user toggles); the weak-self collapse to
                    // the Extended default is a defensive fallback.
                    statsRowsProvider: { [weak self] in
                        self?.effectiveStatsRows ?? StatsOverlayDefaults.extendedRows
                    },
                    statsThresholdsProvider: { [weak self] in
                        self?.statsThresholds ?? .default
                    },
                    controllerQuitChordProvider: { [weak self] in
                        self?.controllerQuitChord ?? .none
                    },
                    customControllerChordProvider: { [weak self] in
                        self?.customControllerChord ?? []
                    },
                    onBackgroundedChanged: { [weak self] backgrounded in
                        self?.nativeStreamBackgrounded = backgrounded
                    }
                )
                for await event in events {
                    // Pass the SESSION's host, not selectedHost: ⌘1-⌘9 / the
                    // toolbar pill can re-select mid-flight, and failure copy
                    // resolved at event time would then blame the wrong PC.
                    await MainActor.run { self.handleNativeEvent(event, host: host) }
                }
            } catch {
                caughtError = error
            }
            // Single cleanup site: runs whether start() threw or the event
            // loop drained normally.
            self.cleanupAfterStream(host: host, caughtError: caughtError)
        }
    }

    /// The single teardown cleanup for stream(app:on:). Main-actor by class
    /// isolation; named so the entry path stays readable and the cleanup
    /// stays one site - never duplicate any of this elsewhere (a second
    /// "cleanup" is how zombie state is made).
    private func cleanupAfterStream(host: Host, caughtError: Error?) {
        if caughtError != nil, Self.connectCancelRequested {
            // The user cancelled this connect from the capsule -
            // start()'s throw is the teardown ARRIVING, not a failure
            // to report. A red "couldn't reach" banner here would
            // contradict a deliberate, successful cancel.
            self.log.info("Connect cancelled by user - suppressing the failure banner")
            self.nativeStreamError = nil
        } else if let caughtError {
            let hostName = host.displayName
            // One human sentence - never splice the raw NSError tail
            // ("The request timed out", domain codes, ...) into the
            // banner. The technical detail goes to the log; the user
            // gets an actionable line. StreamError already carries
            // user-facing copy and is handled on its own path.
            let localized = (caughtError as NSError).localizedDescription
            self.log.error("Stream start failed for \(hostName, privacy: .public): \(localized, privacy: .public)")
            // Diag too - the os.Logger line above never reaches the in-app
            // log viewer or the Diag file, which made pre-flight failures
            // (the only line naming the real cause) invisible in every
            // pasted log. One line, ERROR level, same redaction rules.
            Diag.error("Stream start failed for \(hostName): \(localized)", "Stream")
            // HONEST banner: only show the "make sure it's awake" copy
            // for a GENUINE reach failure (host off / not on the
            // network). A pairing or launch failure means the host
            // demonstrably answered - telling the user it's "asleep"
            // there is a false negative that sends them chasing the
            // wrong problem. Reserve the asleep guidance for the
            // unreachable / never-established cases; surface the real
            // cause otherwise. (This is the start()-throw path only:
            // start() throwing means the connection never reached
            // established and no frames ever decoded, so the
            // reach-failure copy is correct there.)
            self.nativeStreamError =
                Self.connectFailureBanner(for: caughtError, hostName: hostName)
        }
        // M3: do NOT unconditionally clear nativeStreamError here. A host-side
        // "ended unexpectedly" terminate (code != 0) already set the banner on
        // the event loop, and this single teardown runs for BOTH a clean quit
        // and that host error - unconditionally nilling wiped the banner before
        // it ever rendered (host crash / power-loss / watchdog stall looked
        // identical to a clean quit, and Retry went dead). Leaving an already-set
        // banner in place lets it survive; a clean quit set it to nil up above
        // (line 273 at stream start) so nothing stale leaks through.
        let wasStreaming = self.isStreaming
        self.streamPhase = .idle
        self.isStreaming = false
        // Restore awdl0 (AirDrop/Continuity) now the stream is down - covers the
        // clean-stop, error, and user-cancel paths since this is the single
        // teardown site. No-op if the helper was never engaged.
        AWDLHelperManager.shared.releaseForStream()
        self.nativeStreamBackgrounded = false
        self.nativeSession = nil
        // Disconnect beat (#3) - surface the "Stream ended" toast on
        // the launcher only when we actually had a live session.
        // Skipping the toast on the connection-failure path (where
        // wasStreaming is true but the user already sees a
        // ConnectBanner error explaining what happened) would lose
        // the acknowledgement; the toast is intentionally redundant
        // with the banner because the banner reads as "still trying"
        // and the toast reads as "we're done here".
        if wasStreaming {
            // Build + stash the session receipt BEFORE the toast flag
            // flips so the toast's first render already carries its
            // quiet line. nil for short (<5 min) sessions and dead
            // connects - the toast stays a single line for those.
            self.lastSessionReceipt = SessionReceiptStore.finalizeSession()
            // One INFO either way - in testing the receipt write was
            // log-silent (stash vs skip was indistinguishable in any
            // artifact), so adjudicating the ≥5-min gate took a
            // UserDefaults spelunk. One grep now.
            if let receipt = self.lastSessionReceipt {
                Diag.info("Session receipt stashed - \(receipt.summaryLine) · "
                    + "\(receipt.width)x\(receipt.height)@\(receipt.refreshHz)", "Stream")
            } else {
                Diag.info("Session receipt skipped - never went live or under the "
                    + "5-minute stash threshold", "Stream")
            }
            self.streamEndedToastVisible = true
            // Stamp "last played" with the stream-END time (now),
            // not the start time. This is the value HostsStore reads
            // back into `Host.lastConnected` for both the
            // launcher's "last played N ago" label and most-recent-host
            // ordering - writing it at end keeps this host most-recent
            // while making the relative-time label read time-since-end.
            // Always a past instant, so the relative-time label can
            // never go stale/negative while the next stream is live.
            // Shares the `wasStreaming` gate with the toast above: the
            // connection-failure path stamps the attempt's end time too
            // (matching the previous start-time write, which also fired
            // on failures), and the label still reads correctly.
            UserDefaults.standard.set(Date(), forKey: "glimmer.lastConnected.\(host.id)")
        }
        // Re-arm the readiness-chip poller so it goes back to
        // "Ready · 12 ms" instead of holding its last value from
        // the moment polling stopped at stream start. `afterStream:
        // true` adds a short settle delay before the first probe so it
        // doesn't race the host's `/cancel`-induced HTTP blip and
        // publish a false "Asleep" on a host that was streaming moments
        // ago (the chip slander bug). Combined with the two-strikes
        // unreachable guard in the poller, an awake host that just
        // streamed can never be declared asleep on a single transient
        // miss.
        self.restartHostStatusPolling(afterStream: true)
        NSApp.activate()
        if let main = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "Glimmer"
        }) {
            main.makeKeyAndOrderFront(nil)
        }
        afterStreamEnd()
    }

    /// Map a start()-throw error to an honest user-facing banner. The
    /// "asleep / make sure it's awake" copy is reserved for a GENUINE reach
    /// failure (host off / not on the network / handshake never completed) -
    /// it must never be shown for a pairing or launch failure, where the host
    /// demonstrably answered. Static so it has no actor state and is trivially
    /// unit-testable.
    static func connectFailureBanner(for error: Error, hostName: String) -> String {
        guard let streamError = error as? StreamError else {
            // Any non-StreamError on the start path is unexpected - the control
            // layer always throws StreamError - so treat it as a reach failure,
            // by far the most likely cause.
            return "Couldn't reach \(hostName). Make sure it's awake and on the same network."
        }
        switch streamError {
        case .hostUnreachable(let detail):
            // The network layer crafts user-facing guidance for the cases it
            // can prove (cert mismatch / not-paired disambiguation) - dropping
            // that for generic "is it awake" copy buries the real fix.
            // "Restart Sunshine" marks the wedged-HTTPS-listener verdict
            // (NetworkClient.classifyPairedPathFailure): the box is awake, so
            // the "is it awake" copy would send the user to the wrong fix.
            if detail.contains("cert") || detail.contains("Restart Sunshine") {
                return detail
            }
            return "Couldn't reach \(hostName). Make sure it's awake and on the same network."
        case .sessionFailed, .binaryNotFound, .truncatedRead:
            // Genuinely never reached the host / handshake aborted before
            // establishment (a truncated control read = the host dropped mid-
            // response) → asleep guidance is honest.
            return "Couldn't reach \(hostName). Make sure it's awake and on the same network."
        case .pairingFailed(let detail) where detail.contains("pair it again"):
            // The paired-path classification (NetworkClient.
            // classifyPairedPathFailure) - already the actionable, host-named
            // sentence (401 or a TLS-level rejection of our client cert).
            return detail
        case .pairingFailed, .pairingRejected:
            // The host answered but pairing failed - point the user at the
            // real fix, not at the power switch.
            return "Couldn't pair with \(hostName). Re-pair from Settings → PCs."
        case .launchFailed:
            return "\(hostName) answered but couldn't start the app. It may already be in use."
        case .decoderFailed:
            return "Couldn't start the video decoder for \(hostName)."
        case .audioFailed:
            // Audio is non-fatal to the visual stream, but if start() threw on
            // it the session never came up - keep the message about the host.
            return "Couldn't start audio for \(hostName)."
        case .crypto:
            return "A security error stopped the connection to \(hostName)."
        }
    }

    /// Handle one engine event for the session streaming `host`. The host is
    /// the SESSION's host captured at stream() entry - never `selectedHost`,
    /// which the ⌘1-⌘9 shortcuts and the toolbar pill can re-point mid-flight
    /// (failure copy resolved at event time then names the wrong machine).
    func handleNativeEvent(_ event: StreamEvent, host: Host) {
        // Stage names are engineering jargon ("Starting RTSP handshake"). Keep
        // them in logs but show the user a friendly "Connecting to <host>..."
        // through the whole handshake.
        let connecting = "Connecting to \(host.displayName)…"
        switch event {
        case .stageStarting:
            // Don't let a late stage event repaint "Connecting…" over the
            // "Cancelling…" the user's cancel click just earned.
            if !Self.connectCancelRequested { streamPhase = .connecting(stage: connecting) }
        case .stageComplete:              break
        case .stageFailed:
            nativeStreamError = "Couldn't reach \(host.displayName)."
        case .connectionEstablished:
            streamPhase = .streaming
            logConnectHoldAdjudication()
            // Receipt wall-clock starts at the LIVE edge (not the click) so
            // "2h 12m" measures time actually streaming, not handshake.
            // Latched once inside the store - repeat edges are no-ops.
            SessionReceiptStore.markSessionLive()
        case .firstFrame:
            promoteToStreamingOnFirstFrame()
        case .connectionTerminated(let code):
            streamPhase = .idle
            nativeHDRActive = false
            if code != 0 {
                nativeStreamError = "Stream to \(host.displayName) ended unexpectedly."
            }
        case .reconnecting:
            // The host closed a live session (it likely restarted across a
            // lock/desktop transition) and the engine is silently re-establishing
            // under the frozen last frame. Show "Reconnecting..." - DON'T go .idle,
            // which would tear the hero card back to the launcher; the stream
            // window stays up holding the frame. Resolves on .reconnected or, if
            // the engine gives up, a real .connectionTerminated.
            streamPhase = .connecting(stage: "Reconnecting to \(host.displayName)…")
        case .reconnected:
            // Resumed in place. (The fresh .connectionEstablished / .firstFrame
            // edges also promote the phase, so this is belt-and-braces.)
            streamPhase = .streaming
        case .connectionStatus(let quality):
            // .good / .degraded both leave us in the streaming phase -
            // the stats overlay carries the real-time network signal,
            // and there's no other user-visible surface for "network is
            // slow" copy that distinguishing them would feed.
            _ = quality
            streamPhase = .streaming
        case .hdrModeChanged: break  // intent signal only - see .hdrActive
        case .hdrActive(let active): nativeHDRActive = active
        case .audioFailed:
            // H7: audio receive failed to start - the session is video-only.
            // Non-fatal to the visual stream, so stay in the streaming phase;
            // the failure is already logged + counted at the source.
            break
        case .log: break
        }
    }

    /// Ground-truth liveness: a decoded/rendered frame proves the stream is up
    /// regardless of whether the one-shot .connectionEstablished edge was
    /// delivered. Promote ONLY out of a connecting phase - never override a
    /// teardown that has already moved us to .idle/.error (a late first-frame
    /// yield racing stop() must not resurrect the streaming phase). This is the
    /// belt-and-suspenders fix for "stuck on Connecting while video is actually
    /// flowing": if .connectionEstablished was lost, the first frame repairs the
    /// transition within ~one frame.
    private func promoteToStreamingOnFirstFrame() {
        guard case .connecting = streamPhase else { return }
        streamPhase = .streaming
        logConnectHoldAdjudication()
        // Same live-edge stamp as .connectionEstablished - whichever edge
        // arrives first starts the receipt clock (store-latched).
        SessionReceiptStore.markSessionLive()
    }

    // MARK: - Connect cancel + connect-hold adjudication

    // Static (type-level) storage: extensions can't add instance properties,
    // and these are single-session scratch by construction - the re-entrancy
    // guard in stream() means at most one connect is ever in flight. All
    // three inherit the class's @MainActor isolation.

    /// Wall clock of the most recent stream() entry (the user's CLICK). The
    /// engine's own clock starts after HTTPS + window build, so only this
    /// anchor can adjudicate the 400 ms connect hold. Consumed (nil'd) by
    /// `logConnectHoldAdjudication()` so the verdict logs exactly once.
    private static var connectClickedAt: Date?

    /// Whether the 400 ms-held connecting capsule actually mounted for the
    /// in-flight connect. Ground truth reported by ConnectSurface at the flip
    /// - not inferred from the span, which would assume the launcher was
    /// frontmost and the hold task uncancelled.
    private static var connectCapsuleShown = false

    /// True once the user cancelled the in-flight connect. Read by the
    /// teardown cleanup to suppress the failure banner (a deliberate cancel
    /// is not a failure) and by `.stageStarting` to keep a late stage event
    /// from repainting over "Cancelling…". Reset at every stream() entry.
    private static var connectCancelRequested = false

    /// ConnectSurface calls this when its 400 ms hold elapses and the
    /// connecting capsule mounts - the "shown" half of the adjudication line.
    func noteConnectCapsuleShown() {
        Self.connectCapsuleShown = true
    }

    /// Abort an in-flight connect - the connecting capsule's click action
    /// (and its ⎋ shortcut). Routes through the SESSION's own teardown so
    /// there is exactly ONE cleanup site: stop() interrupts the handshake,
    /// start() returns or throws, and the single cleanup in stream()'s Task
    /// drains state back to idle. We only repaint the visible stage here -
    /// never isStreaming/streamPhase-to-idle directly - because faking the
    /// end state from a second site is how zombie sessions are made.
    func cancelConnect() {
        guard case .connecting = streamPhase, let session = nativeSession else { return }
        guard !Self.connectCancelRequested else { return }  // one stop() is plenty (it's idempotent anyway)
        Self.connectCancelRequested = true
        Diag.notice("User cancelled connect - stopping the in-flight session", "Stream")
        streamPhase = .connecting(stage: "Cancelling…")
        Task { await session.stop() }
    }

    /// One INFO adjudicating the 400 ms connect hold at the live edge: the
    /// click→established span plus whether the capsule mounted. In testing
    /// the suppress-flash promise could not be verified from any artifact
    /// (the engine clock misses HTTPS + window build); this makes the
    /// verdict one grep. No-op when the click anchor was already consumed
    /// (e.g. a duplicate live edge).
    private func logConnectHoldAdjudication() {
        guard let clicked = Self.connectClickedAt else { return }
        Self.connectClickedAt = nil
        let spanMs = Int(Date().timeIntervalSince(clicked) * 1000)
        let capsule = Self.connectCapsuleShown
            ? "capsule shown" : "capsule suppressed (established inside the hold)"
        Diag.info("Connect hold - click→established \(spanMs) ms · \(capsule)", "Stream")
    }

    // MARK: - Stream-ended toast copy

    /// Display line for the stream-ended toast. `summaryLine`'s integer
    /// rounding renders a sub-millisecond wired median as "0 ms median" -
    /// which reads like a broken measurement when it's actually the best
    /// number the link can post. Present those as "<1 ms median"; everything
    /// else passes through unchanged.
    var lastSessionReceiptToastLine: String? {
        guard let receipt = lastSessionReceipt else { return nil }
        guard let rtt = receipt.medianRttMs, Int(rtt.rounded()) < 1 else {
            return receipt.summaryLine
        }
        // The duration is always summaryLine's first " · " segment - reuse it
        // so the duration formatting stays single-sourced in SessionReceipt.
        let duration = receipt.summaryLine.components(separatedBy: " · ").first
            ?? receipt.summaryLine
        return "\(duration) · <1 ms median"
    }
}
