//
//  EnetControlChannel.swift
//
//  A focused, single-peer, client-only ENet subset over NWConnection(UDP) for
//  the Moonlight CONTROL channel. NOT a full ENet port — only what is needed to
//  reach "connected": the CONNECT handshake, VERIFY_CONNECT validation + ACK,
//  and reliable SEND_RELIABLE for START_A / START_B (encrypted control-V2).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md. Source:
//  vendored enet (protocol.h / host.c / protocol.c) + ControlStream.c. The
//  enet protocol logic originates from the enet project by Lee Salzman
//  (MIT License, Copyright (c) 2002-2024 Lee Salzman) — notice preserved in
//  CREDITS.md as the MIT license requires.
//
//  WIRE FACTS (all confirmed against the C source):
//   - ALL multi-byte ENet fields are BIG-ENDIAN (htons/htonl) EXCEPT connectID,
//     which is passed RAW and compared un-byteswapped.
//   - NO CRC trailer and NO compression (moonlight sets neither).
//   - ProtocolHeader is variable length: 2 bytes (peerID only) when SENT_TIME
//     is clear, 4 bytes (peerID + sentTime) when set. SENT_TIME is set on any
//     datagram carrying an ack-flagged or ACK command.
//   - peerID field packs: low 12 bits peer id, bits 12-13 sessionID, bits 14-15
//     flags. Session bits are OR'd in only AFTER outgoingPeerID < 0xFFF (i.e.
//     only after VERIFY_CONNECT) — NOT on the CONNECT we send.
//   - CommandHeader: u8 command (low 4 bits number, bit7 ACK, bit6 UNSEQ),
//     u8 channelID, u16 reliableSequenceNumber (BE).
//   - reliableSequenceNumber is PER-CHANNEL, pre-incremented: first reliable on
//     a channel = 1. CONNECT (channel 0xFF) uses the peer counter → 1.
//     START_A → channel 0 seq 1, START_B → channel 0 seq 2.
//
//  The implementation is split across cohesive extensions to keep each unit
//  focused: this file holds the type, its stored state, and small accessors;
//  EnetControlChannel+Handshake.swift drives CONNECT → VERIFY_CONNECT → START_A/B;
//  EnetControlChannel+ControlLoop.swift runs the post-START keepalive loop;
//  EnetControlChannel+Inbound.swift parses inbound datagrams; and
//  EnetControlChannel+Send.swift holds the outbound send + client→host control.

import Foundation
import Network

// (ENet wire primitives — constants, errors, byte writer/reader, SentReliable —
// live in EnetWire.swift.)

// MARK: - ENet control channel

/// Single-peer ENet client over UDP. Drives the CONNECT → VERIFY_CONNECT → ACK
/// handshake, then sends START_A / START_B reliably. All socket I/O is on a
/// serial dispatch queue; the public API is async and runs the handshake to
/// completion (or throws at a specific stage).
final class EnetControlChannel: @unchecked Sendable {
    static let logCategory = "NativeConnection"

    let host: NWEndpoint.Host
    let port: UInt16
    let controlConnectData: UInt32
    let crypto: ControlCrypto

    /// NWConnection I/O queue. This is the SOLE context that runs the inbound
    /// receive callback chain (startReceiveLoop → onDatagram → handleAcknowledge,
    /// the only writer of lastAckRecvMs + the only place sentReliable drains).
    /// QoS .userInteractive so ACK processing is never de-prioritized behind
    /// main-thread UI/input. Critically it does NOT carry outbound sends anymore
    /// (see sendQueue) — that is the primary fix for the all-stream wedge.
    let queue = DispatchQueue(label: "io.ugfugl.Glimmer.enet", qos: .userInteractive)
    /// Dedicated outbound-send queue. Every connection.send hops here so a
    /// controller-driven send storm can NEVER block the receive/ACK chain on
    /// `queue`. NWConnection.send is internally thread-safe and ordered
    /// per-connection, so submitting from a separate serial queue preserves wire
    /// order. Mirrors moonlight's separate InputSend pthread vs ControlRecv.
    let sendQueue = DispatchQueue(label: "io.ugfugl.Glimmer.enet.send", qos: .userInteractive)

    /// Guards `connection` — the same discipline as RtspClient.connLock for the
    /// identical "set on the async pipeline, cancelled from another thread"
    /// shape. The var is written on the connect pipeline (openSocket), read by
    /// sendDatagram from the 20ms control-loop thread / the 1ms input-flush
    /// queue / the receive chain's ACK emission, and cancelled+nil'd by close()
    /// on the teardown context. Swift class-reference loads are NOT atomic: an
    /// unguarded load-then-retain races close()'s store(nil)+release, and on
    /// every session end (where the 50Hz keepalive + input flush overlap the
    /// teardown) the release can land inside the reader's load→retain window —
    /// a use-after-free. Every access goes through the locked accessors below.
    private let connLock = NSLock()
    private var connection: NWConnection?

    /// Locked read: the strong reference is retained UNDER connLock, so a
    /// concurrent close() either hasn't nil'd yet (we get the live connection
    /// and our retain keeps it valid for the send) or already has (we get nil
    /// and the caller drops the datagram — correct during teardown).
    func currentConnection() -> NWConnection? {
        connLock.lock(); defer { connLock.unlock() }
        return connection
    }

    /// Locked write from the connect pipeline (openSocket).
    func setConnection(_ conn: NWConnection?) {
        connLock.lock(); connection = conn; connLock.unlock()
    }

    /// Take-and-nil in one lock acquisition for close(): after this returns no
    /// reader can obtain the connection again. The caller cancels OUTSIDE the
    /// lock (cancel is thread-safe; holding a lock shared with the hot send
    /// path across it would re-create the contention this split avoids).
    private func takeConnection() -> NWConnection? {
        connLock.lock(); defer { connLock.unlock() }
        let conn = connection
        connection = nil
        return conn
    }

    /// Bounded in-flight send backpressure (mirrors sendMessageEnet's 10ms cap,
    /// ControlStream.c:787-789). Incremented before each connection.send,
    /// decremented in its contentProcessed completion. The InputBatcher consults
    /// `sendBacklogged` and drops/merges latest-state input instead of enqueuing
    /// when the radio is draining slowly — input is latest-state, so a superseded
    /// controller frame is correctly discarded rather than backing up the queue.
    let inFlightSends = AtomicCounter()
    /// Backlog threshold. Keepalives/handshake/ACKs are never gated by this — only
    /// the high-rate input flush path checks it. Small so input can't outrun the
    /// wire on the single connection.
    static let maxInFlightSends = 8

    /// True when the outstanding (submitted-but-not-yet-radio-acknowledged) send
    /// count is at/over the cap. The InputBatcher flush path uses this to drop a
    /// superseded latest-state frame instead of enqueuing another datagram.
    var sendBacklogged: Bool { inFlightSends.value >= Self.maxInFlightSends }

    /// Count of reliable commands sent but not yet ACKed — mirrors
    /// `sentReliable.count`, maintained lock-free at every append/remove site. No
    /// longer the backpressure trigger (see `reliableBacklogged`); kept as a cheap
    /// host-keeping-up signal for telemetry.
    let unackedReliables = AtomicCounter()

    /// HOST-side reliable backpressure (the mouse-spin fix), now RTT-RELATIVE so it
    /// is DO-NO-HARM on a stable link. `inFlightSends` keys only on local
    /// NWConnection send-completion (drains fast even under loss), so it never
    /// reflects the host falling behind. The first cut gated on a fixed un-ACKed
    /// COUNT (≥6) — but on a stable link the natural in-flight count is rate×RTT,
    /// so a fast input stream on a low-but-nonzero-RTT LAN (e.g. 5ms) could brush
    /// that cap with NO actual problem: a false throttle on a perfect link. The
    /// gate is now purely evidence-based — the host is "behind" ONLY when it has
    /// gone ACK-SILENT for longer than a few RTTs WHILE reliables are outstanding.
    /// On a clean link ACKs return within ~one RTT, so this can never fire
    /// regardless of latency; it engages only when the host genuinely stops
    /// draining our backlog. Computed once per ~20ms control-loop tick from the
    /// live RTT estimate, stored here for the 1ms InputBatcher flush to read
    /// lock-free (bare-Bool load/store, same discipline as the watchdog latches).
    nonisolated(unsafe) var reliableBackloggedFlag = false
    /// Floor for the ACK-silence threshold (when multiple·RTT is below it on a
    /// sub-10ms LAN): never throttle under this much silence.
    static let backpressureAckSilenceFloorMs: UInt32 = 30
    /// "Behind" at this many RTTs of ACK silence — 3× normal ack latency is the
    /// host genuinely not keeping up, not just normal in-flight.
    static let backpressureRttMultiple: UInt32 = 3

    /// True when the host has stopped draining our reliable backlog (ACK-silent for
    /// > max(floor, multiple·RTT) with reliables outstanding). The InputBatcher
    /// flush coalesces the merged-state drain while this is set. RTT-relative, so a
    /// stable link — wired OR a higher-RTT-but-clean link — never trips it.
    var reliableBacklogged: Bool { reliableBackloggedFlag }

    // Peer state (mirrors the C ENetPeer subset).
    var outgoingPeerID: UInt16 = Enet.maximumPeerID  // until VERIFY_CONNECT
    var incomingPeerID: UInt16 = 0                   // single-peer slot 0
    var outgoingSessionID: UInt8 = 0xFF
    var incomingSessionID: UInt8 = 0xFF
    let connectID: UInt32
    var peerOutgoingReliableSeq: UInt16 = 0          // channel 0xFF counter
    /// Per-channel outgoing reliable sequence numbers (pre-incremented; first
    /// reliable on a channel = 1). channel 0 = GENERIC (START/ping 0x0200),
    /// channel 1 = URGENT (IDR/RFI/LTR). Channel 0xFF (CONNECT/PING) uses
    /// peerOutgoingReliableSeq above.
    var channelOutgoingReliableSeq: [UInt8: UInt16] = [:]
    /// Per-channel outgoing UNRELIABLE sequence numbers (pre-incremented; first
    /// unreliable on a channel = 1). Mirrors enet_peer_setup_outgoing_command:
    /// SEND_UNRELIABLE stamps the channel's CURRENT (not incremented) reliable seq
    /// plus this pre-incremented counter, and ENet zeroes this counter whenever a
    /// reliable command goes out on the channel (peer.c:658) — sendEncryptedControl
    /// resets the matching entry to 0 on every reliable send.
    var channelOutgoingUnreliableSeq: [UInt8: UInt16] = [:]

    var sentReliable: [SentReliable] = []
    var connected = false
    var disconnected = false

    // MARK: - IDR / RFI request coalescing (ControlStream.c idrFrameRequiredEvent)
    //
    // moonlight funnels EVERY LiRequestIdrFrame() into a level-triggered event
    // (idrFrameRequiredEvent) drained by ONE dedicated thread (requestIdrFrameFunc,
    // ControlStream.c:1624-1640): N sets between two drains collapse into ONE wire
    // REQUEST_IDR, and a pending IDR flushes any queued RFIs (LiRequestIdrFrame
    // ControlStream.c:415-422 → freeBasicLbqList(referenceFrameControlQueue)).
    // Without this, every failed frame fires its own reliable wire IDR — the
    // 890,891,892… "decoder requested IDR" storm that amplifies loss.
    //
    // Glimmer's drain point is the existing 20ms control-loop tick (controlLoopTick
    // → drainPendingRecoveryRequests). `requestIdrFrame()` and
    // `invalidateReferenceFrames(from:to:)` now only SET state here; the tick
    // sends AT MOST ONE REQUEST_IDR (and at most one RFI) per loss event. All
    // guarded by stateLock via withState.

    /// Level-triggered "an IDR is needed" flag (mirrors PltSetEvent on
    /// idrFrameRequiredEvent). Multiple requests between drains collapse to one
    /// wire REQUEST_IDR. Cleared by the control-loop drain.
    var idrPending = false
    /// The pending RFI window to send on the next drain, if any. An IDR request
    /// supersedes it (LiRequestIdrFrame flushes referenceFrameControlQueue), so
    /// setting `idrPending` clears this. nil = no RFI pending. Coalesced to the
    /// widest window seen since the last drain (the host re-IDRs/recovers the
    /// whole span anyway, and one packet beats per-frame spam).
    var pendingRfi: (from: Int, to: Int)?

    /// currentEnetSequenceNumber (ControlStream.c) — monotonic from 0. GLOBAL
    /// across ALL encrypted control sends; must increment under stateLock to
    /// avoid GCM nonce reuse.
    var enetSeq: UInt32 = 0

    /// Last time (ms) we SENT any datagram — drives the proactive ENet ping.
    var lastSendMs: UInt32 = 0

    /// First-0x010b breadcrumb latch: handleRumbleData logs the first host
    /// rumble's ctl/low/high values once per SESSION (the channel is built per
    /// stream) — rumble runs at ~135/s during combat so per-event logging
    /// would evict the diagnostic ring, but the one sighting proves the wire
    /// layout postmortem (0x010b cost a whole investigation because nothing
    /// ever logged its bytes). Confined to `queue` (the receive callback
    /// chain), so no lock.
    var loggedFirstRumble = false

    /// First-sighting latch for SET_ADAPTIVE_TRIGGERS (0x5503), the
    /// loggedFirstRumble discipline: one INFO sighting per session proves the
    /// host's wire layout + which trigger modes it sent, without flooding the
    /// ring if a game re-arms the trigger effect at frame rate.
    var loggedFirstAdaptiveTriggers = false

    /// Per-channel HIGHEST-DISPATCHED inbound reliable sequence number — the
    /// receive-side half of ENet's per-channel reliable bookkeeping this subset
    /// was missing. The host sends ALL control messages (rumble, triggers, LED,
    /// motion, HDR, termination) as SEND_RELIABLE on channel 0 and relies on
    /// real enet's ordered, exactly-once delivery; without this map a host
    /// retransmission (lost client ACK) or UDP reordering dispatched stale
    /// state AFTER its supersessor — e.g. a retransmitted rumble(x,y) landing
    /// after the burst-ending motors-off and latching the pad buzzing until
    /// the next host event. Every current consumer is latest-wins, so "ACK
    /// everything, dispatch only strictly-newer" (drop stale/duplicate) is the
    /// correct subset — we delay no message and never give up, we only refuse
    /// to resurrect superseded state. Confined to `queue` (the receive
    /// callback chain, the sole inbound-dispatch context), so no lock.
    var lastDispatchedInboundRelSeq: [UInt8: UInt16] = [:]

    /// First stale/duplicate inbound-reliable drop breadcrumb latch (the
    /// loggedFirstRumble discipline): one INFO sighting per session proves the
    /// dedup gate fired on a real retransmit/reorder; per-event logging could
    /// flood under sustained loss. Confined to `queue`, so no lock.
    var loggedFirstStaleReliableDrop = false

    /// First "reliable received in a datagram WITHOUT the SENT_TIME header flag"
    /// breadcrumb latch. We now ACK these (we used to silently skip the ACK,
    /// which left the host retransmitting until its ~10s ENet peer-timeout fired
    /// and it tore the session down — the lock-screen / secure-desktop disconnect:
    /// Sunshine emits a control message across the transition in a datagram that
    /// omits SENT_TIME). One NOTICE per session confirms the path actually
    /// occurs on this host so the fix is verifiable from a single repro log.
    /// Confined to `queue`, so no lock.
    var loggedFirstReliableWithoutSentTime = false

    /// Last time (ms) we RECEIVED any matched ACK from the host. Initialized at
    /// connect so a fresh session isn't falsely stale; updated on every matched
    /// ACK in handleAcknowledge. Drives the fast silent-peer-dead detection in
    /// runControlLoop: if the host stops ACKing our reliable traffic for ~3s while
    /// we still have unacked commands outstanding, the host has silently reset our
    /// peer (it sends no DISCONNECT/TERMINATION on a timeout), so we declare the
    /// peer dead and fire onTerminated(-1) rather than waiting ~10s for the video
    /// frame watchdog to trip.
    var lastAckRecvMs: UInt32 = 0

    /// ENet peer RTT estimate (ms) + variance, EWMA-updated on every matched ACK.
    /// FRACTIONAL ms (Double): the round trip is measured from a HIGH-RES LOCAL
    /// monotonic clock — we stamp `localSentByToken` when sending a SENT_TIME
    /// datagram and difference it against `monotonicMs` on the echoed ack — NOT
    /// from the 16-bit-ms wire `sentTime` token (which quantizes to whole ms and
    /// loses all sub-ms signal). The wire token is used ONLY as the match key.
    /// Seeded to ENet's default until the first sample; surfaced via estimatedRtt()
    /// to the stats overlay (LiGetEstimatedRttInfo equivalent). EWMA gains mirror
    /// ENet's peer update (1/8 mean, 1/4 variance), just in Double.
    var roundTripTime: Double = 500
    var rttVariance: Double = 0
    var hasRttSample = false

    /// HIGH-RES local send instants (fractional ms on the monotonic `monotonicMs`
    /// clock), keyed by the 16-bit wire `sentTime` token we stamped on the
    /// datagram. Populated in `wrapDatagram` (SENT_TIME branch, recordRtt only —
    /// outbound ACK datagrams carry the wire token but are never echoed back, so
    /// they don't record), consumed + the entry removed in `handleAcknowledge`
    /// when the host echoes the token back. Recorded tokens are pings + reliable
    /// command sends (input/keepalive/recovery), all of which the host ACKs, so
    /// the live set tracks the in-flight reliable backlog: small while acks
    /// flow, at most one entry per ms (tokens are ms-keyed) while they don't.
    /// `recordLocalSent` evicts entries older than `localSentTtlMs` so an ack
    /// that never arrives can't grow this map without bound.
    var localSentByToken: [UInt16: Double] = [:]
    /// Eviction horizon (ms) for `localSentByToken`. Far beyond any plausible RTT
    /// (the dead-peer envelope is 10s) yet short enough that a never-acked token
    /// is reclaimed promptly. The wire token wraps every ~65s, so this is also
    /// comfortably under one wrap period — a stale entry is gone before its token
    /// value could be reused.
    static let localSentTtlMs: Double = 5000
    /// Hard cap on `localSentByToken` so a pathological never-acking peer cannot
    /// grow it without bound between TTL sweeps. Sizing: acked traffic keeps the
    /// live set near the in-flight backlog (a handful); even a total ack stall
    /// with input flushing every ms accrues ~1 ms-keyed token/ms, so 256 covers
    /// a quarter second of dead air before the sweep runs at all.
    static let localSentMaxEntries = 256

    /// Current RTT (ms) + variance as fractional ms, or nil before the first ACK.
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? {
        withState { hasRttSample ? (roundTripTime, rttVariance) : nil }
    }

    /// Stamp the high-res local send instant for `token` (the 16-bit wire sentTime
    /// we just put on a SENT_TIME datagram). Overwrites any prior stamp for the
    /// same token value (a wrap collision matches the most-recent send, which is
    /// the one whose ack we'll see next). Sweeps TTL-expired entries so an ack
    /// that never comes can't leak the map. MUST be called under stateLock.
    func recordLocalSent(token: UInt16, atMs now: Double) {
        // Drop entries older than the TTL (and, as a backstop, cap the count).
        if localSentByToken.count >= Self.localSentMaxEntries {
            localSentByToken = localSentByToken.filter { now - $0.value < Self.localSentTtlMs }
            // The TTL filter alone cannot converge when every survivor is
            // young — e.g. an ack stall on a fading link while input keeps
            // flushing every ms fills the map with sub-TTL entries, and the
            // old code then re-ran the full filter on EVERY send (an O(n)
            // scan + realloc under stateLock, on the latency-critical input
            // path, exactly while the link is struggling). Keep the NEWEST
            // half instead: those are the stamps whose acks arrive next, so
            // the RTT estimator recovers the moment acks resume, and one
            // eviction buys at least cap/2 sweep-free sends (amortized, not
            // per-send). Dropping the oldest stamps only forfeits RTT samples
            // a recovering link would have superseded anyway — never a
            // permanent loss of the measurement.
            if localSentByToken.count >= Self.localSentMaxEntries {
                let newestHalf = localSentByToken
                    .sorted { $0.value > $1.value }
                    .prefix(Self.localSentMaxEntries / 2)
                localSentByToken = Dictionary(uniqueKeysWithValues: Array(newestHalf))
            }
        }
        localSentByToken[token] = now
    }

    /// Reliable-stream health, the same three numbers the 1Hz control-loop
    /// snapshot logs (sentReliable depth + oldest-unacked age + since-last-ack):
    /// the host-timeout fingerprint is `sentReliable` climbing while
    /// `oldestUnackedMs` / `sinceLastAckMs` cross ~5s right before a stall, so
    /// surfacing them to the telemetry exporter makes the INITIAL-CONNECTION and
    /// pre-stall phases visible. One lock-guarded read so the trio is mutually
    /// consistent. Cheap — three integer reads under the existing stateLock.
    func health() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32) {
        let now = serviceTimeMs
        return withState {
            let oldest = sentReliable.map { now &- $0.firstSentAtMs }.max() ?? 0
            return (sentReliable.count, oldest, now &- lastAckRecvMs)
        }
    }

    /// Silence window (ms) of no matched ACK (with reliable outstanding) before we
    /// treat the peer as dead. Set to ENet's OWN peer timeout — moonlight uses
    /// enet_peer_timeout(peer, 2, 10000, 10000) (ControlStream.c:1837) — so a brief
    /// network blip (e.g. BT/Wi-Fi 2.4GHz coexistence while a controller connects)
    /// self-heals by retransmitting instead of tearing down. Like moonlight we have
    /// NO earlier give-up: a transient stall must never self-terminate inside this
    /// envelope, or there is nothing to recover into when the air clears.
    static let ackSilenceDeadMs: UInt32 = 10000
    /// Cadence (ms) of the 1Hz control-loop health snapshot.
    static let healthSnapshotIntervalMs: UInt32 = 1000

    let stateLock = NSLock()
    let interrupted = ManagedAtomicFlag()

    /// Fired when the host sends a TERMINATION (0x0109). Wired by NativeBackend
    /// to connectionTerminated + teardown.
    var onTerminated: ((Int32) -> Void)?
    /// Fired (on CHANGE only) when the host signals HDR mode (0x010e).
    var onHdrMode: ((Bool) -> Void)?
    /// Fired for EVERY host SS_RUMBLE_DATA (0x010b): (controllerNumber,
    /// lowFreqMotor, highFreqMotor), raw 0...65535 wire units — (0,0) means
    /// "motors off" and MUST be delivered too. Called on the receive thread at
    /// up to ~135/s during gameplay, so the consumer MUST hop off it
    /// (ControllerHaptics does a latest-wins coalesce onto its own serial
    /// queue); ACK processing can never be made to wait on Core Haptics.
    var onRumble: ((UInt16, UInt16, UInt16) -> Void)?
    /// Fired for EVERY host SS_RUMBLE_TRIGGERS (0x5500): (controllerNumber,
    /// leftTriggerMotor, rightTriggerMotor), raw 0...65535 wire units — (0,0)
    /// means "trigger motors off" and MUST be delivered too. Same threading
    /// contract as onRumble: called on the receive thread, so the consumer
    /// hops off it (ControllerHaptics' latest-wins coalesce).
    var onRumbleTriggers: ((UInt16, UInt16, UInt16) -> Void)?
    /// Fired for EVERY host SET_RGB_LED (0x5502): (controllerNumber, r, g, b).
    /// Sunshine paints the slot color at session start and games can re-color
    /// the light bar at frame rate, so the consumer coalesces latest-wins off
    /// this thread exactly like rumble.
    var onSetRgbLed: ((UInt16, UInt8, UInt8, UInt8) -> Void)?
    /// Fired for EVERY host SET_MOTION_EVENT (0x5501): (controllerNumber,
    /// motionType LI_MOTION_TYPE_*, reportRateHz — 0 means stop). Rare state
    /// changes (a per-sensor open/close when a game grabs the IMU), not a
    /// per-frame flood, but the threading contract is rumble's anyway: called
    /// on the receive thread, and the consumer (ControllerMotion) hops to
    /// main before touching GameController sensors.
    var onSetMotionEvent: ((UInt16, UInt8, UInt16) -> Void)?
    /// Fired for EVERY host SET_ADAPTIVE_TRIGGERS (0x5503): (controllerNumber,
    /// eventFlags — DS_EFFECT_RIGHT_TRIGGER 0x04 / DS_EFFECT_LEFT_TRIGGER 0x08
    /// bitset for which trigger blocks are present, typeLeft/typeRight — the
    /// DualSense-native mode bytes, left/right — 10-byte param arrays each).
    /// Same threading contract as onRumble: called on the receive thread, so
    /// the consumer hops off it (DualSenseHID does its IOKit write on its own
    /// serial path). Only sent to DualSense pads (Sunshine extension).
    var onSetAdaptiveTriggers: ((UInt16, UInt8, UInt8, UInt8, [UInt8], [UInt8]) -> Void)?
    /// Fired AT MOST ONCE when the channel tears down (interrupt()/close(),
    /// whichever lands first — see fireTeardownOnce). Covers every stream-end
    /// path: user stop, watchdog teardown, and host TERMINATION (which funnels
    /// into stopConnection → close()). Sole consumer today parks all controller
    /// rumble motors at (0,0): the host's own "motors off" event can no longer
    /// arrive once the channel is dead, so without this a stream ending
    /// mid-rumble leaves a pad buzzing until its battery dies.
    var onTeardown: (() -> Void)?
    /// Last HDR enable state, so we only fire onHdrMode + log on transitions
    /// (the host re-announces HDR ~10×/s).
    var lastHdrEnabled: Bool?
    /// Latest SS_HDR_METADATA parsed from a 0x010e message (lock-guarded), so
    /// NativeBackend.hdrMetadata() can hand the decoder the MDCV/CLL blobs.
    var lastHdrMetadata: HdrMetadata?
    /// Per-type counts of inbound control messages we receive but don't
    /// dispatch (lock-guarded). Key presence = that type's first sighting was
    /// already logged, so handleInboundControl logs each type ONCE (the same
    /// transition-gating discipline as lastHdrEnabled) — before rumble (0x010b)
    /// grew a real dispatch it arrived here at up to ~135/s during combat, and
    /// logging every datagram evicted the 2000-entry diagnostic ring down to
    /// ~90s of coverage; any future undispatched type could flood identically.
    /// The totals are surfaced once at teardown by logIgnoredControlTotals().
    var ignoredControlCounts: [UInt16: UInt64] = [:]

    /// Most recent HDR mastering metadata the host announced, if any.
    func hdrMetadata() -> HdrMetadata? { withState { lastHdrMetadata } }

    /// Scoped lock helper — `NSLock.lock()/unlock()` are unavailable from async
    /// contexts under Swift 6, so async functions use this synchronous closure.
    func withState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// A reference instant for the 16-bit ms service clock.
    let startInstant = DispatchTime.now()

    init(host: NWEndpoint.Host, port: UInt16, controlConnectData: UInt32,
         crypto: ControlCrypto) {
        self.host = host
        self.port = port
        self.controlConnectData = controlConnectData
        self.crypto = crypto
        self.connectID = UInt32.random(in: UInt32.min...UInt32.max)
    }

    func interrupt() {
        interrupted.set()
        // Locked read, cancel outside the lock (RtspClient.interrupt's
        // discipline). interrupt() deliberately does NOT nil the var — close()
        // owns the final take-and-nil.
        currentConnection()?.cancel()
        logIgnoredControlTotals()
        fireTeardownOnce()
    }

    /// Take-and-nil onTeardown under stateLock so the interrupt() + close()
    /// teardown pair fires it at most once, whichever runs first (the same
    /// discipline as logIgnoredControlTotals). Both entry points call this so
    /// no stream-end path can skip the rumble (0,0) clear.
    private func fireTeardownOnce() {
        let teardown = withState { () -> (() -> Void)? in
            let hook = onTeardown
            onTeardown = nil
            return hook
        }
        teardown?()
    }

    /// Human-readable tag for a known-but-undispatched control type, so the
    /// suppression logs can label a hex code. Every past tenant (rumble
    /// 0x010b, trigger rumble 0x5500, motion enable 0x5501, RGB LED 0x5502)
    /// has since grown a real dispatch and can no longer reach the ignored
    /// path; the hook stays for the next protocol extension we meet.
    static func ignoredControlTypeName(_ type: UInt16) -> String { "" }

    /// Emit the per-type totals of ignored inbound control messages as ONE
    /// NOTICE line ("type -> count"), so the frequency signal the per-datagram
    /// suppression withheld survives for diagnosis. Takes-and-clears the counts
    /// under stateLock, so the interrupt() + close() teardown pair logs at most
    /// once (whichever runs first with a non-empty map wins).
    func logIgnoredControlTotals() {
        let counts = withState { () -> [UInt16: UInt64] in
            let taken = ignoredControlCounts
            ignoredControlCounts = [:]
            return taken
        }
        guard !counts.isEmpty else { return }
        let summary = counts.sorted { $0.key < $1.key }
            .map { "0x\(String($0.key, radix: 16))\(Self.ignoredControlTypeName($0.key)) -> \($0.value)" }
            .joined(separator: ", ")
        Diag.notice("ENet ignored inbound control totals: \(summary)", Self.logCategory)
    }

    var serviceTimeMs: UInt32 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startInstant.uptimeNanoseconds
        return UInt32(truncatingIfNeeded: elapsed / 1_000_000)
    }

    /// HIGH-RES fractional-ms reading of the SAME monotonic clock `serviceTimeMs`
    /// truncates. Used for the sub-ms RTT measurement: stamped at send in
    /// `recordLocalSent`, differenced on the echoed ack in `handleAcknowledge`.
    /// `uptimeNanoseconds` ignores wall-clock jumps/sleep, so an RTT can never go
    /// negative or spike on a time adjustment.
    var monotonicMs: Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startInstant.uptimeNanoseconds
        return Double(elapsed) / 1_000_000.0
    }

    func close() {
        interrupted.set()
        // Atomic take-and-nil under connLock, then cancel outside it: a racing
        // sendDatagram either retained the connection before we took it (its
        // send lands on a cancelled-but-alive object — harmless) or reads nil
        // and drops the datagram. The unguarded cancel+nil this replaces gave
        // the 50Hz control loop and 1ms input flush a use-after-free window on
        // every teardown.
        takeConnection()?.cancel()
        logIgnoredControlTotals()
        fireTeardownOnce()
    }

    // MARK: - Per-frame FEC status (Sunshine SS_FRAME_FEC_PTYPE feedback)

    /// Sink for per-frame FEC status reports produced by the video FEC path
    /// (RtpVideoQueue → VideoRtpReceiver). Intentionally a no-op: moonlight only
    /// sends FEC status on actual loss/abandonment, and the Sunshine wire type for
    /// it (0x5502) COLLIDES with IDX_SET_RGB_LED — sending it would be misread by
    /// the host — so Glimmer never emits it. The session keepalive is the periodic
    /// ping + transport PING (see the control loop), which is what keeps video
    /// flowing. Kept (rather than removed) because NativeBackend wires it as the
    /// FEC status sink; must NEVER block the calling video thread.
    func queueFrameFecStatus(_ status: FrameFecStatus) {
        _ = status
    }

    func enetCode(_ error: Error) -> Int32 {
        if let enetError = error as? EnetError {
            switch enetError {
            case .connectTimeout: return -110 // ETIMEDOUT-ish
            case .interrupted: return -4
            case .disconnected: return -103
            default: return -1
            }
        }
        return -1
    }
}

/// A small thread-safe integer counter for in-flight send backpressure. NSLock is
/// sufficient (the few inc/dec/read sites are not in a tight inner loop), and it
/// matches the codebase's existing ManagedAtomicFlag style.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
    func increment() { lock.lock(); total += 1; lock.unlock() }
    func decrement() { lock.lock(); if total > 0 { total -= 1 }; lock.unlock() }
}
