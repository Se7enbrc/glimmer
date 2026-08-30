//
//  FramePacer+TickDeficitEvents.swift
//
//  The tick-deficit TRANSITION VOCABULARY and its OFF-LOCK handling: the
//  `TickDeficitEvent` cases the locked service pass in
//  FramePacer+TickDeficit.swift returns, and the breadcrumb logging each one
//  mints. Split out of that file - pure move, same file-split idiom as the rest
//  of the FramePacer extensions - to keep both units under the length budget.
//
//  Everything here runs OFF the pacer lock, which is the whole point of the
//  event vocabulary: LogStore takes its own lock and DispatchSource ops
//  allocate, so neither may run under the pacer's hot os_unfair_lock. See
//  FramePacer+TickDeficit.swift for the state machine that detects these
//  transitions and FramePacer+DeficitTimer.swift for the off-tick timer the
//  reconcile flag drives.
//

import QuartzCore
import os

extension FramePacer {

    /// One state transition the locked service pass detected, surfaced so the
    /// caller can log / reconcile the timer OFF the lock (LogStore takes its
    /// own lock; DispatchSource ops allocate - neither belongs under the
    /// pacer's hot os_unfair_lock).
    enum TickDeficitEvent {
        case deficitEngaged(ticksPerS: Double, expectedHz: Double, depth: Int)
        case deficitDisengaged(
            reason: String, durationSeconds: Double, releases: UInt64,
            repaints: UInt64, ticksPerS: Double)
        case floorViolation(ticksPerS: Double, floorHz: Double)
        case floorRecovered(durationSeconds: Double, ticksPerS: Double)
        case floorAssistEngaged(ticksPerS: Double, floorHz: Double, depth: Int)
        case floorAssistDisengaged(reason: String, durationSeconds: Double, releases: UInt64, ticksPerS: Double)
        case warmHandoverComplete(ticksPerS: Double)
    }

    // MARK: - Event handling (OFF the lock)

    /// Log the transitions and reconcile the off-tick timer. Callable from any
    /// thread; Diag/LogStore lines land in the glimmer-*.log file sink so every
    /// engage/disengage is postmortem-visible (the os_log-only breadcrumb class
    /// this pass retires).
    func handleTickDeficitEvents(_ events: [TickDeficitEvent]) {
        guard !events.isEmpty else { return }
        var reconcile = false
        for event in events where logTickDeficitEvent(event) {
            reconcile = true
        }
        if reconcile {
            pacingQueue.async { [weak self] in self?.reconcileDeficitTimer() }
        }
    }

    /// Mint one transition's breadcrumbs. Returns true when the transition
    /// changes the DESIRED off-tick timer state, so the caller reconciles the
    /// timer once after the whole batch (never per event, and never here -
    /// DispatchSource ops belong on `pacingQueue`). Same off-lock contract as
    /// the caller.
    private func logTickDeficitEvent(_ event: TickDeficitEvent) -> Bool {
        switch event {
        case let .deficitEngaged(ticksPerS, expectedHz, depth):
            logDeficitEngaged(ticksPerS: ticksPerS, expectedHz: expectedHz, depth: depth)
            return true
        case let .deficitDisengaged(reason, duration, releases, repaints, ticksPerS):
            logDeficitDisengaged(
                reason: reason, duration: duration, releases: releases,
                repaints: repaints, ticksPerS: ticksPerS)
            return true
        case let .floorViolation(ticksPerS, floorHz):
            logFloorViolation(ticksPerS: ticksPerS, floorHz: floorHz)
            return false
        case let .floorRecovered(duration, ticksPerS):
            Diag.info(
                "FramePacer floor violation cleared after "
                + "\(String(format: "%.0f", duration * 1000))ms - ticks back at "
                + "\(String(format: "%.1f", ticksPerS))/s",
                "Stream.Pacer")
            return false
        case let .floorAssistEngaged(ticksPerS, floorHz, depth):
            logFloorAssistEngaged(ticksPerS: ticksPerS, floorHz: floorHz, depth: depth)
            return true
        case let .floorAssistDisengaged(reason, duration, releases, ticksPerS):
            logFloorAssistDisengaged(
                reason: reason, duration: duration, releases: releases, ticksPerS: ticksPerS)
            return true
        case let .warmHandoverComplete(ticksPerS):
            logWarmHandoverComplete(ticksPerS: ticksPerS)
            return true
        }
    }

    private func logDeficitEngaged(ticksPerS: Double, expectedHz: Double, depth: Int) {
        log.warning(
            // swiftlint:disable:next line_length
            "FramePacer tick-deficit degraded mode ENGAGED - measured ticks \(ticksPerS, privacy: .public)/s vs expected \(expectedHz, privacy: .public)Hz, depth=\(depth, privacy: .public); releasing off-tick at stream cadence")
        Diag.notice(
            "FramePacer tick-deficit degraded mode ENGAGED - measured ticks "
            + "\(String(format: "%.1f", ticksPerS))/s vs expected "
            + "\(String(format: "%.1f", expectedHz))Hz, depth=\(depth); "
            + "releasing off-tick at stream cadence until ticks recover",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerTickDeficitEngaged",
            "ticksPerS=\(ticksPerS, privacy: .public) depth=\(depth, privacy: .public)")
    }

    private func logDeficitDisengaged(
        reason: String, duration: Double, releases: UInt64,
        repaints: UInt64, ticksPerS: Double
    ) {
        log.notice(
            // swiftlint:disable:next line_length
            "FramePacer tick-deficit degraded mode DISENGAGED (\(reason, privacy: .public)) after \(duration * 1000, privacy: .public)ms - released \(releases, privacy: .public) frames off-tick, \(repaints, privacy: .public) governor repaints, ticks now \(ticksPerS, privacy: .public)/s")
        Diag.info(
            "FramePacer tick-deficit degraded mode DISENGAGED (\(reason)) after "
            + "\(String(format: "%.0f", duration * 1000))ms - released \(releases) "
            + "frames off-tick, \(repaints) governor repaints",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerTickDeficitDisengaged",
            "durationMs=\(duration * 1000, privacy: .public) releases=\(releases, privacy: .public)")
    }

    private func logFloorViolation(ticksPerS: Double, floorHz: Double) {
        log.notice(
            // swiftlint:disable:next line_length
            "FramePacer FLOOR VIOLATION - realized ticks \(ticksPerS, privacy: .public)/s below the pinned \(floorHz, privacy: .public)Hz preferredFrameRateRange floor for >1s (frame-rate governor overriding the advisory floor)")
        Diag.notice(
            "FramePacer FLOOR VIOLATION - realized ticks "
            + "\(String(format: "%.1f", ticksPerS))/s below the pinned "
            + "\(String(format: "%.1f", floorHz))Hz floor for >1s "
            + "(frame-rate governor overriding the advisory floor)",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerFloorViolation",
            "ticksPerS=\(ticksPerS, privacy: .public) floorHz=\(floorHz, privacy: .public)")
    }

    private func logFloorAssistEngaged(ticksPerS: Double, floorHz: Double, depth: Int) {
        log.notice(
            // swiftlint:disable:next line_length
            "FramePacer floor-violation ASSIST engaged - ticks \(ticksPerS, privacy: .public)/s vs \(floorHz, privacy: .public)Hz floor, depth=\(depth, privacy: .public); off-tick timer filling missed beats")
        Diag.notice(
            "FramePacer floor-violation ASSIST engaged - ticks "
            + "\(String(format: "%.1f", ticksPerS))/s vs "
            + "\(String(format: "%.1f", floorHz))Hz floor, depth=\(depth); "
            + "off-tick timer filling missed beats",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerFloorAssistEngaged",
            "ticksPerS=\(ticksPerS, privacy: .public) depth=\(depth, privacy: .public)")
    }

    private func logFloorAssistDisengaged(
        reason: String, duration: Double, releases: UInt64, ticksPerS: Double
    ) {
        Diag.info(
            "FramePacer floor-violation ASSIST disengaged (\(reason)) after "
            + "\(String(format: "%.0f", duration * 1000))ms - \(releases) releases "
            + "during assist, ticks \(String(format: "%.1f", ticksPerS))/s",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerFloorAssistDisengaged",
            "durationMs=\(duration * 1000, privacy: .public) releases=\(releases, privacy: .public)")
    }

    private func logWarmHandoverComplete(ticksPerS: Double) {
        log.notice(
            "FramePacer warm handover complete - rebuilt link healthy at \(ticksPerS, privacy: .public) ticks/s; paced release engaged")
        Diag.info(
            "FramePacer warm handover complete - rebuilt link healthy at "
            + "\(String(format: "%.1f", ticksPerS)) ticks/s; paced release engaged",
            "Stream.Pacer")
        OSSignposter.render.emitEvent(
            "PacerWarmHandoverComplete", "ticksPerS=\(ticksPerS, privacy: .public)")
    }
}
