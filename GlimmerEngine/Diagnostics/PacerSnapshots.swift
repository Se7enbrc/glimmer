// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// A snapshot of the pacer's present-side health, read by the external
/// watchdog (StreamSession) and the NOTICE instrumentation. All fields are
/// read under the lock in one shot so they're mutually consistent.
@usableFromInline package struct PacerLivenessSnapshot: Sendable {

    @usableFromInline package init(
        secondsSinceLastTick: Double,
        secondsSinceLastRelease: Double,
        depth: Int,
        secondsQueueNonEmpty: Double,
        running: Bool,
        totalTicks: UInt64,
        totalReleases: UInt64,
        streamFrameIntervalSeconds: Double,
        adaptiveTargetDepth: Int,
        recentTicksPerSecond: Double,
        recentReleasesPerSecond: Double,
        tickDeficitSeconds: Double,
        expectedTickHz: Double,
        tickDeficitModeActive: Bool,
        presentRejectStreak: Int,
        rendererRefusalSeconds: Double,
        secondsSinceLastReject: Double
    ) {
        self.secondsSinceLastTick = secondsSinceLastTick
        self.secondsSinceLastRelease = secondsSinceLastRelease
        self.depth = depth
        self.secondsQueueNonEmpty = secondsQueueNonEmpty
        self.running = running
        self.totalTicks = totalTicks
        self.totalReleases = totalReleases
        self.streamFrameIntervalSeconds = streamFrameIntervalSeconds
        self.adaptiveTargetDepth = adaptiveTargetDepth
        self.recentTicksPerSecond = recentTicksPerSecond
        self.recentReleasesPerSecond = recentReleasesPerSecond
        self.tickDeficitSeconds = tickDeficitSeconds
        self.expectedTickHz = expectedTickHz
        self.tickDeficitModeActive = tickDeficitModeActive
        self.presentRejectStreak = presentRejectStreak
        self.rendererRefusalSeconds = rendererRefusalSeconds
        self.secondsSinceLastReject = secondsSinceLastReject
    }

    /// Seconds since the last `handleTick` (link liveness). `.infinity`
    /// before the first tick. A 240Hz link ticks every ~4.17ms; a large
    /// value means the CADisplayLink has stopped.
    @usableFromInline package let secondsSinceLastTick: Double
    /// Seconds since the last frame actually reached the renderer.
    /// `.infinity` before the first release.
    @usableFromInline package let secondsSinceLastRelease: Double
    /// Frames currently waiting in the jitter buffer. A non-empty queue
    /// combined with a stale `secondsSinceLastRelease` is the wedge.
    @usableFromInline package let depth: Int
    /// Seconds the visible queue has held frames without emptying, 0 when empty.
    /// A refill or suppression-clear starts a fresh stall-evidence window.
    @usableFromInline package let secondsQueueNonEmpty: Double
    /// Whether the pacer is between start() and stop().
    @usableFromInline package let running: Bool
    /// Cumulative tick count since start() - the instrumentation derives a
    /// ticks/sec rate by differencing against the previous window's value.
    @usableFromInline package let totalTicks: UInt64
    /// Cumulative release count since start() - same, for presents/sec.
    @usableFromInline package let totalReleases: UInt64
    /// Learned stream frame interval (seconds) - surfaced so the
    /// instrumentation can show what cadence the gate is pacing against.
    @usableFromInline package let streamFrameIntervalSeconds: Double
    /// Current jitter-driven adaptive target depth (1 on a clean link -
    /// passthrough rest state - up to `maxTargetDepth` under sustained
    /// MEASURED jitter) - surfaced so the metric line shows how deep the
    /// adaptive buffer is currently riding.
    @usableFromInline package let adaptiveTargetDepth: Int
    /// MEASURED realized tick/release rates from the pacer's own rolling
    /// ~250ms window (FramePacer+TickDeficit.swift), `.nan` until the first
    /// window completes. The watchdog's tick-deficit trip keys on these -
    /// measured, never inferred - so a partial-rate tick collapse (13-58
    /// ticks/s against a 120fps stream) is finally visible to it.
    @usableFromInline package let recentTicksPerSecond: Double
    @usableFromInline package let recentReleasesPerSecond: Double
    /// How long (seconds) the measured tick rate has been in deficit
    /// against `expectedTickHz` (hysteresis: enter <0.5×, clear ≥0.8×).
    /// 0 when healthy. The watchdog trips on this SUSTAINED, with the
    /// release rate also collapsed - i.e. only when the in-pacer degraded
    /// mode did NOT keep frames flowing.
    @usableFromInline package let tickDeficitSeconds: Double
    /// What the tick rate SHOULD be: min(stream Hz, nominal panel Hz).
    /// `.nan` until the first window completes.
    @usableFromInline package let expectedTickHz: Double
    /// True while the off-tick degraded release path is active.
    @usableFromInline package let tickDeficitModeActive: Bool
    /// Consecutive pacer-path releases the RENDERER refused (willPresent
    /// false), 0 after any successful present. A high streak alongside a
    /// stale release clock means the gate is releasing fine and the
    /// renderer is the wedged organ (the renderer-refusal class) - the
    /// ladder reaches for the flush instead of cadence/link medicine.
    @usableFromInline package let presentRejectStreak: Int
    /// Time spanned by observed refusals, excluding silence after the last attempt.
    @usableFromInline package let rendererRefusalSeconds: Double
    @usableFromInline package let secondsSinceLastReject: Double
}

/// Per-second display-refresh telemetry: the realized vsync cadence over the
/// window SINCE THE LAST CALL (min/avg/max derived refresh Hz) plus whether a
/// refresh CHANGE was seen in that window. RESET-ON-READ - so it must be
/// called by exactly ONE consumer at the publish cadence (the 1Hz exporter),
/// NOT the 20Hz watchdog or 2Hz metric timer (which use the non-destructive
/// `livenessSnapshot`). All nil when no tick landed this window (link idle /
/// torn down). Hz is derived as 1/interval; min-interval ⇒ max-Hz and vice
/// versa, so we map accordingly (a long interval = a LOW refresh, the
/// ProMotion ramp-down).
@usableFromInline package struct PacerRefreshWindowSnapshot: Sendable {

    @usableFromInline package init(
        minHz: Double? = nil,
        avgHz: Double? = nil,
        maxHz: Double? = nil,
        changed: Bool
    ) {
        self.minHz = minHz
        self.avgHz = avgHz
        self.maxHz = maxHz
        self.changed = changed
    }

    @usableFromInline package let minHz: Double?
    @usableFromInline package let avgHz: Double?
    @usableFromInline package let maxHz: Double?
    @usableFromInline package let changed: Bool
}
