//
//  TelemetryCounters+AudioGauges.swift
//
//  The AUDIO gauge accessors: live playout state (buffer fill + clock drift),
//  the windowed buffer-fill trough, the audio cold-start
//  (time-to-first-decoded-audio) anchor + measurement, the AUDIO-TTF
//  context (warm/cold classification + host-idle covariate), and the
//  cushion-memory telemetry latch (seed + live loss floor). The cross-stream
//  A/V-skew store (`av_skew_ms`) that used to sit between the last two is a
//  pure move into TelemetryCounters+AudioSkew.swift, so both units stay under
//  the file-length budget. Split out of TelemetryCounters.swift to keep that
//  file under the length limit (pure move, same idiom as the FramePacer split).
//  The stored gauge state (the locks + values) stays on the class in
//  TelemetryCounters.swift - stored properties cannot live in extensions; the
//  new stores below are self-locked top-level classes (the `AudioTtfContext`
//  idiom) so they need no class storage.
//

import Foundation
import os

extension TelemetryCounters {

    // MARK: - Audio playout gauges + cold-start

    /// Publish the live AUDIO playout state (buffer fill + A/V sync drift). Called
    /// off the hot path - the audio decode path stamps it under the lock it already
    /// holds for the decode (no extra lock on the audio path).
    func setAudioState(_ state: AudioState) {
        os_unfair_lock_lock(audioStateLock); audioStateValue = state; os_unfair_lock_unlock(audioStateLock)
    }
    /// Latest AUDIO playout state, or nil before the first decoded audio packet.
    /// Read by the exporter on its 1Hz queue (never the hot path).
    var audioState: AudioState? {
        os_unfair_lock_lock(audioStateLock); defer { os_unfair_lock_unlock(audioStateLock) }
        return audioStateValue
    }

    /// Lower the windowed MIN buffer-fill if this sample is a new trough. Called
    /// from the audio playout completion path (under the audio meter lock there,
    /// not this one - these are independent locks, no nesting). One compare + a
    /// conditional store; far below the 5ms audio budget.
    func noteAudioBufferFill(ms: Double) {
        os_unfair_lock_lock(audioStateLock)
        if ms < audioBufferFillMinMsValue { audioBufferFillMinMsValue = ms }
        os_unfair_lock_unlock(audioStateLock)
    }
    /// Take + RESET the windowed MIN buffer-fill (ms). Read once per tick by the
    /// exporter on its 1Hz queue (never the hot path); resetting on read makes each
    /// tick's min cover only that window's troughs. nil when no sample this window.
    func takeAudioBufferFillMinMs() -> Double? {
        os_unfair_lock_lock(audioStateLock)
        let value = audioBufferFillMinMsValue
        audioBufferFillMinMsValue = .infinity
        os_unfair_lock_unlock(audioStateLock)
        return value.isFinite ? value : nil
    }

    /// Anchor the audio cold-start clock at STREAM START. Called once when the
    /// audio receiver opens its socket; idempotent (a second call before the first
    /// packet is harmless, and after is ignored so the anchor stays the true start).
    func anchorAudioStreamStart() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(audioFirstPacketLock)
        if audioStreamStartNanosValue == 0 { audioStreamStartNanosValue = now }
        os_unfair_lock_unlock(audioFirstPacketLock)
    }

    /// Record the FIRST decoded-audio instant: compute time-to-first-audio (ms)
    /// from the TRUE session/connect-start anchor. Called once by the audio receive
    /// path on the first packet. No-op if no anchor is available, or if already
    /// recorded (keeps the first measurement). The cold-start (~5-7s on a lossy
    /// link) metric.
    ///
    /// The anchor is the P2 `connectStart`, stamped at the connect edge in
    /// `StreamSession.start()` immediately after `resetForNewSession` - which
    /// now ALSO runs at that edge, BEFORE any receiver exists, so neither this
    /// gauge nor the socket-open fallback epoch can carry a stale prior-session
    /// value into a warm-host race anymore (the chimeric audio_ttf mechanism).
    /// Measuring from the session-lifecycle anchor ties TTF to the real session
    /// start. NOTE: a big reading here is usually NOT an anchor bug - a ~40s
    /// reading has been observed as REAL host-side cold-start audio delay (our
    /// pings flowed at the designed cadence the whole time). Host audio bring-up
    /// is bimodal - warm ~0.3-1s, cold ~4.6-40s - and client-uncontrollable; this
    /// gauge makes that delay visible, it cannot shrink it. The audio-socket-
    /// open epoch is kept only as a fallback when the connect anchor is somehow
    /// unset.
    func recordAudioFirstPacket() {
        let now = DispatchTime.now().uptimeNanoseconds
        let connectStart = p2.connectStart
        os_unfair_lock_lock(audioFirstPacketLock)
        defer { os_unfair_lock_unlock(audioFirstPacketLock) }
        guard audioFirstPacketMsValue == 0 else { return }
        // Prefer the true session/connect-start anchor; fall back to the
        // audio-socket-open epoch only if connect-start was never stamped.
        let anchor = connectStart != 0 ? connectStart : audioStreamStartNanosValue
        guard anchor != 0, now >= anchor else { return }
        audioFirstPacketMsValue = Double(now &- anchor) / 1_000_000.0
    }
    /// Time-to-first-decoded-audio (ms), or nil if not yet measured. Read by the
    /// exporter on its 1Hz queue (never the hot path).
    var audioFirstPacketMs: Double? {
        os_unfair_lock_lock(audioFirstPacketLock); defer { os_unfair_lock_unlock(audioFirstPacketLock) }
        return audioFirstPacketMsValue != 0 ? audioFirstPacketMsValue : nil
    }
}

// MARK: - Audio-TTF context (warm/cold classification + host-idle covariate)

/// The shared state behind the `audio_ttf` event's warm/cold classification and
/// its `host_idle_s` covariate, plus the latched record the session scorecard
/// reads at stop. Host audio bring-up is bimodal (warm ~0.3-1s vs cold
/// ~4.6-40s, host-side and client-uncontrollable); classifying every session
/// makes the warm-host-luck confound machine-checkable instead of agent-argued.
///
/// HOST-IDLE APPROXIMATION (data-first honesty - the field is best-effort):
/// `host_idle_s` measures from a WALL-CLOCK stamp of when THIS CLIENT's
/// previous session ended (`markStreamEnd()`, called at session teardown), not
/// the host's true last packet - teardown trails the last packet by under a
/// second, close enough for a covariate whose interesting scale is minutes.
/// The stamp is PROCESS-LIFETIME only: after an app relaunch there is no prior
/// stamp and `host_idle_s` is simply omitted (absent ≠ 0). And it cannot see
/// another client warming the host in between. Wall clock (not mach uptime)
/// deliberately: the Mac may sleep across the idle gap, and uptime stops while
/// asleep.
///
/// Self-locked like `P2State` so the rare TTF-latch / teardown writes stay off
/// every other counter's lock.
final class AudioTtfContext: @unchecked Sendable {
    /// Classification threshold (ms) on the ping→first-RTP span: ~2s cleanly
    /// splits the measured bimodal data (warm 284-984ms vs cold 4.6-40.2s
    /// across 12 sessions). Source sites classify against THIS constant so the
    /// event row and the scorecard can never disagree on the split.
    static let warmPingToRtpThresholdMs: Double = 2000

    /// One session's latched TTF classification, written once at the TTF event.
    struct Record: Sendable {
        /// "warm" | "cold", keyed on ping_to_rtp_ms vs the threshold above
        /// (nil ping span → "cold": no RTP answer inside any warm window).
        var ttfClass: String
        /// The host-side bring-up span the class was keyed on, when measured.
        var pingToRtpMs: Double?
        /// Seconds since this client's previous session ended (see the
        /// approximation note on the type). nil when underivable.
        var hostIdleSeconds: Double?
        /// The startup-pacing verdict ("burst" | "paced") carried alongside so
        /// the scorecard tells the whole startup story on one line.
        var startup: String?
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var record: Record?
    /// Wall-clock stamp (`timeIntervalSinceReferenceDate`) of the previous
    /// stream's end; 0 = no stream has ended this process run.
    private var lastStreamEndReference: Double = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// Stamp the stream-end instant. Called from session teardown (the source
    /// site wires this); idempotence doesn't matter - last writer wins and a
    /// double teardown stamps the same instant twice.
    func markStreamEnd() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        lastStreamEndReference = now
        os_unfair_lock_unlock(lock)
    }

    /// Classify + latch this session's TTF record (first writer wins, like the
    /// cold-start gauge it travels with), deriving `host_idle_s` from the
    /// previous stream-end stamp. Returns the latched record so the event row
    /// emits exactly what the scorecard will report. Called once per session
    /// from the audio receive path's TTF latch - never a hot path.
    @discardableResult
    func latchClassifying(pingToRtpMs: Double?, startup: String?) -> Record {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if let existing = record { return existing }
        let warm = (pingToRtpMs ?? .infinity) <= Self.warmPingToRtpThresholdMs
        let idle = lastStreamEndReference > 0 && now > lastStreamEndReference
            ? now - lastStreamEndReference : nil
        let latched = Record(ttfClass: warm ? "warm" : "cold",
                             pingToRtpMs: pingToRtpMs,
                             hostIdleSeconds: idle,
                             startup: startup)
        record = latched
        return latched
    }

    /// This session's latched record, or nil before the TTF event. Read by the
    /// scorecard at stop.
    var latched: Record? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return record
    }

    /// Clear the per-session record but PRESERVE the last-stream-end stamp -
    /// the stamp is the previous session's teardown instant, exactly what this
    /// session's `host_idle_s` measures from.
    func resetForNewSession() {
        os_unfair_lock_lock(lock); record = nil; os_unfair_lock_unlock(lock)
    }
}

// MARK: - Cushion-memory telemetry latch (seed + live loss floor)

/// Visibility shim for the audio cushion's persistent memory (the decay-
/// limit-cycle fix): the seed the session started from (ridden by the
/// `audio_ttf` event so every session self-describes its starting cushion) and
/// the LIVE learned loss floor (1Hz `audio_cushion_floor_ms` field). Stored
/// here - not on `AudioState` - so the exporter reads it without touching the
/// snapshot structs; written only on the rare seed/learn/decay edges.
final class AudioCushionTelemetry: @unchecked Sendable {
    static let shared = AudioCushionTelemetry()

    /// One session's seed record, latched at audio-decoder init (last writer
    /// wins - one audio init per session IS the session edge).
    struct Seed: Sendable {
        let link: String
        let targetMs: Double
        let floorMs: Double
        let fromMemory: Bool
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var seedValue: Seed?
    private var floorMsValue: Double = 0
    private var seedMsValue: Double = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    func latchSeed(_ seed: Seed) {
        os_unfair_lock_lock(lock)
        seedValue = seed
        floorMsValue = seed.floorMs
        seedMsValue = seed.targetMs
        os_unfair_lock_unlock(lock)
    }
    var seed: Seed? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return seedValue
    }

    /// The live learned loss floor (0 = unlearned). Updated on learn/decay/
    /// link-resolve edges only.
    func setFloorMs(_ value: Double) {
        os_unfair_lock_lock(lock); floorMsValue = value; os_unfair_lock_unlock(lock)
    }
    var floorMs: Double {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return floorMsValue
    }

    /// The COLD-START seed target (ms): the t=0 cushion chosen before the grow
    /// ratchet runs. Set at init (latchSeed, from the per-host/default seed) and
    /// updated when the one-shot link resolve applies a jitter-aware cold seed on
    /// a fresh (no-memory) link. A clean/wired link reads the 30ms base.
    func setSeedMs(_ value: Double) {
        os_unfair_lock_lock(lock); seedMsValue = value; os_unfair_lock_unlock(lock)
    }
    var seedMs: Double {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return seedMsValue
    }
}
