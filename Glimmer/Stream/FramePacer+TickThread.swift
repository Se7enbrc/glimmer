//
//  FramePacer+TickThread.swift
//
//  The dedicated high-QoS run loop the present tick fires on when
//  `pacerTickOffMain` is set (the default). On a pristine link ~73% of the
//  pre-render frame drops were the macOS frame-rate governor STARVING the
//  CADisplayLink callback: the link was added to the MAIN run loop, so its tick
//  was delayed whenever the main thread was busy (display_refresh_min_hz dipped
//  to 48 while the panel held 120). The present itself already runs off-main on
//  `pacingQueue`; only the cheap timing-capture callback was main-bound. Moving
//  that callback onto a private userInteractive run loop un-starves it at ZERO
//  added latency. The link bind/unbind themselves stay on the main actor
//  (installLink reads the NSView); we hand the live link to this thread to add.
//  Split out of FramePacer.swift to keep that file under the length limit.
//

import Foundation
import QuartzCore
import os

extension FramePacer {
    /// UserDefaults key gating whether the CADisplayLink callback fires on the
    /// private high-QoS run loop (`true`, the default) instead of `.main`. The
    /// default-true is registered in GlimmerApp; the bool read below sees it.
    /// Flip to false for an instant fallback to the main-runloop tick (the
    /// historical path) without a rebuild.
    static let tickOffMainDefaultsKey = "pacerTickOffMain"
    static var tickOffMain: Bool {
        UserDefaults.standard.bool(forKey: tickOffMainDefaultsKey)
    }
}

/// Owns the private run loop the CADisplayLink callback fires on when the tick
/// is moved off the main run loop. One per FramePacer, created lazily on the
/// first off-main bind and stopped on teardown so no thread leaks across a
/// reconnect / screen-change rebuild.
///
/// `@unchecked Sendable`: the only cross-thread state is `runLoop`/`cfRunLoop`,
/// published once (under `lock`) by the thread body before any caller reads it
/// and immutable thereafter. The link add/invalidate are routed back ONTO this
/// thread via `perform(...)`, so they touch the loop from its owning thread;
/// `CFRunLoopStop` is documented thread-safe to call from another thread.
final class PacerTickThread: @unchecked Sendable {

    private var thread: Thread?
    /// The thread's own RunLoop object (the canonical one for that thread),
    /// published by the thread body once it is up. Used as the perform target
    /// so the link add/remove run ON the tick thread. Guarded by `lock` for the
    /// start handshake; immutable once set.
    private var runLoop: RunLoop?
    /// The CF handle for the same loop, so `stop()` can break CFRunLoopRun from
    /// the caller's thread (CFRunLoopStop is thread-safe).
    private var cfRunLoop: CFRunLoop?
    /// Set true (under `lock`) by the thread body IMMEDIATELY before
    /// `CFRunLoopRun()` - the REAL "the loop is servicing sources" flag. The
    /// published `runLoop`/`thread` pointers are NOT proof: they're set before
    /// the loop runs, so a `perform(waitUntilDone:true)` against them could block
    /// forever on an unstarted loop. `add()` and `start()` gate on this instead.
    private var loopRunning = false
    private var lock = os_unfair_lock_s()
    /// Released by the thread body once the loop is published, so `start()`
    /// returns only after the run loop can take the link.
    private let ready = DispatchSemaphore(value: 0)
    /// Signalled by the thread body the instant `CFRunLoopRun()` returns (the
    /// loop has exited). `stop()` does a bounded join on it - DEBUG ONLY - to
    /// assert the high-QoS thread actually unwound (defense-in-depth; release
    /// teardown never blocks on this). Fresh per spawn so a stale signal from a
    /// prior run can't satisfy a later join. Guarded by `lock` like the pointers.
    private var exited = DispatchSemaphore(value: 0)

    /// Spin up the thread + run loop if not already running. Idempotent: a
    /// rebuild that re-binds onto the same FramePacer reuses the live thread
    /// rather than spawning a second one. Blocks (briefly) until the run loop
    /// is ready so the immediately-following `add(_:)` lands on a live loop.
    /// Returns true only when the loop is CONFIRMED running (ready signalled AND
    /// `loopRunning` set) - the caller falls back to the main-runloop tick if
    /// false, never routing `perform(waitUntilDone:true)` onto an unconfirmed loop.
    @discardableResult
    func start() -> Bool {
        os_unfair_lock_lock(&lock)
        let alreadyUp = thread != nil
        let alreadyRunning = loopRunning
        // Fresh exit semaphore for this spawn so a prior run's signal can't
        // satisfy this run's DEBUG join. Set under the same lock as the pointers.
        if !alreadyUp { exited = DispatchSemaphore(value: 0) }
        let exitSignal = exited
        os_unfair_lock_unlock(&lock)
        guard !alreadyUp else { return alreadyRunning }

        let tickThread = Thread { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock)
            self.runLoop = RunLoop.current
            self.cfRunLoop = CFRunLoopGetCurrent()
            os_unfair_lock_unlock(&self.lock)
            // Keep the loop alive with a perpetual source (a bare RunLoop returns
            // immediately with no input source). The link, added later, is the
            // real source; the port is just the keep-alive so the loop blocks
            // instead of spinning before the link binds. Added BEFORE signaling
            // ready so the loop is fully set up when the (waited-on) link add lands.
            RunLoop.current.add(Port(), forMode: .common)
            // Mark the loop confirmed-running IMMEDIATELY before CFRunLoopRun, so
            // `add()`/`start()` gate on a true "servicing sources" fact, not the
            // pre-run published pointers. Signal ready after, so the waiter sees it.
            os_unfair_lock_lock(&self.lock)
            self.loopRunning = true
            os_unfair_lock_unlock(&self.lock)
            self.ready.signal()
            // CFRunLoopRun blocks until CFRunLoopStop breaks it; RunLoop.run()'s
            // no-source early-return is the freeze this avoids.
            CFRunLoopRun()
            // The loop has exited - signal the captured semaphore so a DEBUG join
            // in stop() can confirm the high-QoS thread actually unwound.
            exitSignal.signal()
        }
        tickThread.name = "Glimmer.pacerTick"
        tickThread.qualityOfService = .userInteractive
        os_unfair_lock_lock(&lock)
        thread = tickThread
        os_unfair_lock_unlock(&lock)
        tickThread.start()
        // Bounded wait: the run loop comes up in microseconds. The timeout only
        // guards a pathological scheduler stall; on a trip the caller falls back
        // to the main-runloop tick rather than blocking on an unconfirmed loop.
        let signalled = ready.wait(timeout: .now() + .seconds(2)) == .success
        os_unfair_lock_lock(&lock)
        let confirmed = signalled && loopRunning
        os_unfair_lock_unlock(&lock)
        return confirmed
    }

    /// Add the live link to this thread's run loop, ON that thread. Routed via
    /// `perform(...)` (waitUntilDone) so the source is registered from the loop's
    /// owning thread - the safe way to mutate a run loop's sources. Removal needs
    /// no counterpart: the caller `invalidate()`s the link, which detaches it
    /// from every run loop from any thread.
    func add(_ link: CADisplayLink) {
        os_unfair_lock_lock(&lock)
        let runLoop = runLoop
        let thread = thread
        let running = loopRunning
        os_unfair_lock_unlock(&lock)
        // Gate on the CONFIRMED-running flag, not just the published pointers:
        // a `perform(waitUntilDone:true)` onto an unstarted loop would block the
        // caller (the main actor) with no timeout. Caller falls back to `.main`.
        guard running, let runLoop, let thread else { return }
        let op = LinkRunLoopAdd(link: link, runLoop: runLoop)
        op.perform(
            #selector(LinkRunLoopAdd.run), on: thread,
            with: nil, waitUntilDone: true, modes: [RunLoop.Mode.common.rawValue])
    }

    /// Stop the run loop and let the thread exit. The link must already be
    /// `invalidate()`d by the caller (which removes it from this loop); we only
    /// break CFRunLoopRun so the thread returns. Idempotent.
    func stop() {
        os_unfair_lock_lock(&lock)
        let cf = cfRunLoop
        let exitSignal = exited
        runLoop = nil
        cfRunLoop = nil
        thread = nil
        loopRunning = false
        os_unfair_lock_unlock(&lock)
        // Idempotent: a second stop with no live loop has nothing to break or
        // join - return before touching the (already-signalled-or-unused) exit.
        guard let cf else { return }
        CFRunLoopStop(cf)
        // DEBUG-only bounded join: confirm the loop actually returned so a missed
        // CFRunLoopStop (defense-in-depth - the cross-thread stop on this single-
        // level loop is reliable) would trip the assert instead of silently
        // orphaning a high-QoS thread. Release teardown SKIPS this entirely.
        #if DEBUG
        let r = exitSignal.wait(timeout: .now() + .milliseconds(50))
        assert(r == .success, "pacer tick thread did not exit")
        #endif
    }

    deinit { stop() }
}

/// Trampoline that runs `link.add(to:forMode:)` on the tick thread. A
/// CADisplayLink's run-loop sources are safest mutated from the owning thread;
/// `perform(_:on:)` needs an `@objc` selector, so this small NSObject carries
/// the operands across.
private final class LinkRunLoopAdd: NSObject {
    let link: CADisplayLink
    let runLoop: RunLoop
    init(link: CADisplayLink, runLoop: RunLoop) {
        self.link = link
        self.runLoop = runLoop
    }
    @objc func run() {
        link.add(to: runLoop, forMode: .common)
    }
}
