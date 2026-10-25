// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamSession {
    public enum BitrateReason: String, Sendable, Codable {
        case congestion, recovery, trial, rollback
    }

    public enum BitrateAdmission: Sendable, Equatable {
        case accepted
        case deferred
        case rejected
    }

    public struct BitrateChangeReport: Sendable, Codable {
        public enum Outcome: String, Sendable, Codable { case applied, failed, cancelled }
        public let id: UUID
        public let fromKbps: Int
        public let requestedKbps: Int
        public let reason: BitrateReason
        public var outcome: Outcome?
        public var attempts = 0
        public var elapsedMs: Double?
        public var indicatorShown = false
        public var videoGapMs: Double?
        public var audioGapMs: Double?
        public var inputDisabledMs: Double?
        public var legs: [String: Double] = [:]
    }

    /// Copy for a quality change that holds the frame; both platforms show it in their reconnect slot.
    public static let adjustingQualityText = "Adjusting stream quality…"

    /// Anti-flap for the quality indicator. Times are session uptime seconds.
    package struct QualityNoticeGate: Sendable {
        /// Shorter holds read as a hitch, not a wait worth naming.
        package static let showAfter: Duration = .milliseconds(750)
        /// A policy stepping down and back up should not keep talking: one notice a minute.
        package static let quietWindowSeconds: Double = 60
        /// Inside the quiet window a hold this long looks like a stall, so it is still named.
        package static let breakthroughAfter: Duration = .seconds(2)
        package private(set) var lastShown: Double?

        package func delay(startingAt start: Double) -> Duration {
            guard let lastShown, start - lastShown < Self.quietWindowSeconds else { return Self.showAfter }
            return Self.breakthroughAfter
        }

        package mutating func shown(at time: Double) { lastShown = time }
    }

    package struct BitrateChange {
        let started: Double
        var report: BitrateChangeReport
        var oldLastFrame: Double?
        var oldLastAudio: Double?
        var inputDisabledAt: Double?
    }

    /// Accepted reserves the sole recovery owner immediately. Deferred requests are not queued:
    /// the policy must reconsider fresh evidence. Completion is reported separately from admission.
    public func request(rate: Int, reason: BitrateReason) -> BitrateAdmission {
        guard rate > 0, Int32(exactly: rate) != nil, isStreaming, !stopInProgress,
              let current = appliedBitrateKbps, rate != current else { return .rejected }
        guard reachedLiveState, ownsHostSession, !isReconnecting, bitrateTask == nil, bitrateAvailable,
              videoDecoder?.statsCollector.presentationTimes.last != nil,
              wakeProbeTask == nil, pendingLaunch == nil, launchTask == nil,
              reconnectConfig != nil, reconnectAppID != nil else { return .deferred }
        lastBitrateChange = nil
        bitrateAudioTail = nil
        preserveGameOnStop = true
        isReconnecting = true
        bitrateChange = BitrateChange(started: uptimeSeconds,
            report: BitrateChangeReport(id: UUID(), fromKbps: current, requestedKbps: rate, reason: reason))
        bitrateTask = Task { await self.performBitrateChange() }
        return .accepted
    }

    /// Native lifecycle adapters close admission before background grace or system sleep.
    /// An interrupted quality transition ends locally and never cancels the PC game.
    public func setBitrateChangesAvailable(_ available: Bool) async {
        bitrateAvailable = available
        if !available, bitrateChange != nil { await stop(cause: .systemSleep) }
    }

    private func performBitrateChange() async {
        guard bitrateChange != nil else { return }
        defer { bitrateTask = nil; bitrateChange = nil }
        let delay = qualityNotice.delay(startingAt: uptimeSeconds)
        let notice = Task {
            do { try await clock.sleep(delay) } catch { return }
            await showBitrateRecovery()
        }
        defer { notice.cancel() }
        await runReconnectEpisode(code: Self.deadPeerTerminationCode, cause: "applying requested bitrate")
        completeBitrateChange(isStreaming && !stopInProgress && !Task.isCancelled ? .applied :
            (stopCause == .userStopped || !bitrateAvailable ? .cancelled : .failed))
        await observeBitrateAudioTail()
    }

    package func showBitrateRecovery() async {
        guard bitrateChange?.report.indicatorShown == false, isReconnecting, isStreaming, !stopInProgress else { return }
        bitrateChange?.report.indicatorShown = true
        qualityNotice.shown(at: uptimeSeconds)
        bridge?.emit(.adjustingQuality)
        let surface = presentation
        await MainActor.run { surface?.showRecovery(Self.adjustingQualityText) }
    }

    package func completeBitrateChange(_ outcome: BitrateChangeReport.Outcome) {
        guard var change = bitrateChange, change.report.outcome == nil else { return }
        change.report.outcome = outcome
        change.report.elapsedMs = max(0, uptimeSeconds - change.started) * 1_000
        if let disabled = change.inputDisabledAt {
            change.report.inputDisabledMs = max(0, uptimeSeconds - disabled) * 1_000
        }
        if outcome == .applied {
            preserveGameOnStop = false
            videoDecoder?.retainImageForReconnect.store(false, ordering: .releasing)
            appliedBitrateKbps = change.report.requestedKbps
            reconnectConfig?.bitrateKbps = change.report.requestedKbps
            reconnectConfig?.bitrateBoost = 1
            if change.report.audioGapMs == nil, let oldLast = change.oldLastAudio {
                bitrateAudioTail = (change.report.id, attemptID, oldLast)
            }
        }
        bitrateChange = change
        lastBitrateChange = change.report
        recordBitrateReport(change.report)
    }

    private func recordBitrateReport(_ report: BitrateChangeReport) {
        if let data = try? JSONEncoder().encode(report), let json = String(data: data, encoding: .utf8) {
            Diag.notice("bitrate_change \(json)", "Stream")
        }
    }

    /// Audio can prime after video; finish its observation without keeping input or presentation paused.
    private func observeBitrateAudioTail() async {
        guard let tail = bitrateAudioTail else { return }
        defer { bitrateAudioTail = nil }
        let end = uptimeSeconds + 1
        while isStreaming, !stopInProgress, bitrateAvailable, !Task.isCancelled,
              tail.attempt == attemptID, uptimeSeconds < end {
            if let first = audioDecoder.renderTimes.first, var report = lastBitrateChange, report.id == tail.id {
                report.audioGapMs = max(0, first - tail.oldLast) * 1_000
                lastBitrateChange = report
                recordBitrateReport(report)
                return
            }
            do { try await clock.sleep(.milliseconds(10)) } catch { return }
        }
    }

    /// The same-app check is repeated for every attempt. There is deliberately no launch fallback.
    package func resumeForBitrateChange(network: NetworkClient, appID: Int, config: StreamRequest,
                                        info: ServerInfo, deadline: Date) async throws -> LaunchResponse {
        try checkAttempt(deadline: deadline)
        guard info.currentGameID == appID else {
            ownsHostSession = false
            hostSessionClientID = nil
            throw TakeoverRequired(appID: info.currentGameID)
        }
        let start = uptimeSeconds
        let response = try await StreamAttempt.run(until: deadline) { try await network.resume(config: config) }
        try checkAttempt(deadline: deadline)
        bitrateChange?.report.legs["resume_ms", default: 0] += (uptimeSeconds - start) * 1_000
        return response
    }

    package func prepareBitrateMedia() async throws {
        guard bitrateChange != nil else { return }
        bitrateChange?.report.attempts += 1
        let start = uptimeSeconds
        let fade = audioDecoder.prepareReconnectFade()
        try await clock.sleep(fade)
        try checkAttempt()
        bitrateChange?.report.legs["release_fade_ms", default: 0] += (uptimeSeconds - start) * 1_000
        if bitrateChange?.report.attempts == 1 { bitrateChange?.oldLastAudio = audioDecoder.renderTimes.last }
    }

    /// Renderer submission bounds the visible gap; physical scanout and speaker latency need hardware evidence.
    package func waitForBitrateMedia(deadline: Date) async throws {
        guard bitrateChange != nil else { return }
        let attempt = attemptID
        let start = uptimeSeconds
        while uptimeSeconds - start < Self.frameWatchdogTimeout {
            try checkAttempt(deadline: deadline)
            guard bitrateAvailable, attempt == attemptID, reconnectTermination?.attempt != attempt else {
                throw CancellationError()
            }
            if let first = videoDecoder?.statsCollector.presentationTimes.first {
                if let last = bitrateChange?.oldLastFrame {
                    bitrateChange?.report.videoGapMs = max(0, first - last) * 1_000
                }
                if let firstAudio = audioDecoder.renderTimes.first, let last = bitrateChange?.oldLastAudio {
                    bitrateChange?.report.audioGapMs = max(0, firstAudio - last) * 1_000
                }
                bitrateChange?.report.legs["first_frame_ms", default: 0] += (uptimeSeconds - start) * 1_000
                return
            }
            try await clock.sleep(.milliseconds(10))
        }
        throw StreamError.hostTimedOut
    }
}
