//
//  StreamBridgeContext.swift
//
//  The single retained bridge object handed to the native backend as the render
//  + audio context. Holds weak references to the session and each subsystem so a
//  torn-down subsystem's callback safely no-ops, and exposes the FIFO event
//  continuation that backend receive-thread callbacks yield to directly. Split
//  out of StreamSession.swift; see that file's top comment for the lifetime
//  contract.
//

import Foundation
import os

//
// The single callback-retained bridge that replaces the trio of "active X"
// globals we used to maintain (VideoDecoder.activeContext, AudioDecoder._active,
// StreamSession.ActiveSessionRegistry). One instance is created per session;
// it's retained for the connection lifetime as the renderContext + audioContext
// and also published via the `current` weak static for callbacks that don't take
// a context pointer.
//
// All references are *weak*. A subsystem that's been torn down (e.g. the
// VideoDecoder during stop() but before the backend stops) simply becomes nil
// at the callback site, which is the no-op behaviour we want - no UAF, no order
// dependency between subsystem teardown and the backend's own thread drain.
//
// Threading: the native backend serializes its callbacks per-stream, so the
// fields are accessed from at most one receive thread at a time after the
// initial setup on the StreamSession actor. The weak refs are atomic loads
// at the Swift runtime level (weak storage is thread-safe by spec). We mark
// them `nonisolated(unsafe)` because Swift 6 strict-concurrency can't see
// through to the backend's serialization guarantee, but the underlying load
// is sound.
//
// Lifetime contract:
//   * Allocated by StreamSession.start()
//   * `passRetained(bridge).toOpaque()` produces the opaque pointer retained
//     as both renderContext and audioContext. That retain count keeps the
//     bridge alive across the lifetime of the connection - even if every weak
//     ref it holds nils out.
//   * StreamSession also stores a strong `bridge` field for direct access.
//   * StreamSession.stop() stops the backend (which drains the receive
//     threads) and only then calls `Unmanaged.fromOpaque(ptr).release()`
//     to drop the retain. The strong `bridge` field is nil'd after.
//   * `current` is a weak static; it auto-nils when the last strong reference
//     drops. We also explicitly clear it in stop() for release ordering.
public final class StreamBridgeContext: @unchecked Sendable {
    nonisolated(unsafe) public weak var session: StreamSession?
    nonisolated(unsafe) public weak var videoDecoder: VideoDecoder?
    nonisolated(unsafe) public weak var audioDecoder: AudioDecoder?
    nonisolated(unsafe) public weak var inputForwarder: InputForwarder?

    /// The session's event-stream continuation. Stored here so backend
    /// receive-thread callbacks (stageStarting/stageComplete/connectionStarted/
    /// etc.) can yield events directly without an actor hop. AsyncStream.Continuation
    /// is Sendable and guarantees thread-safe FIFO ordering of yield()
    /// calls, so emitting from the backend receive thread preserves the order
    /// the backend invoked us in. Hopping through `Task { await deliver(...) }`
    /// would lose ordering because consecutive Tasks land on the global
    /// concurrent executor without inter-Task happens-before. Living on the
    /// bridge also captures stageStarting/stageComplete callbacks fired
    /// synchronously during startConnection itself, which a session-local
    /// continuation created post-startConnection would miss.
    nonisolated(unsafe) public var eventContinuation: AsyncStream<StreamEvent>.Continuation?

    /// Weak-static fallback for callbacks that don't take a context pointer
    /// (the decoder-renderer slots except setup, the audio-renderer slots
    /// except init, and the connection-listener slots). The native backend
    /// only runs one session at a time so a single-slot global is correct.
    /// Guarded by an NSLock so the setter on the actor and the getter on a
    /// receive thread don't tear.
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static weak var _current: StreamBridgeContext?

    public static var current: StreamBridgeContext? {
        get {
            currentLock.lock(); defer { currentLock.unlock() }
            return _current
        }
        set {
            currentLock.lock(); defer { currentLock.unlock() }
            _current = newValue
        }
    }

    public init(
        session: StreamSession,
        videoDecoder: VideoDecoder,
        audioDecoder: AudioDecoder,
        inputForwarder: InputForwarder
    ) {
        self.session = session
        self.videoDecoder = videoDecoder
        self.audioDecoder = audioDecoder
        self.inputForwarder = inputForwarder
    }

    /// Resolve a context pointer handed to a context-aware callback back
    /// into a bridge instance. Returns nil if the pointer is null.
    public static func from(_ ptr: UnsafeMutableRawPointer?) -> StreamBridgeContext? {
        guard let ptr else { return nil }
        return Unmanaged<StreamBridgeContext>.fromOpaque(ptr).takeUnretainedValue()
    }
}
