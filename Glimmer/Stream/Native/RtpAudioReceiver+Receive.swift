//
//  RtpAudioReceiver+Receive.swift
//
//  The audio RTP receive loop and the per-datagram path (AudioStream.c:239-383):
//  the cancellable recvfrom loop on the dedicated high-priority queue, the runt
//  check + first-packet time-to-first-packet metric, the backlog-aware startup
//  gate hand-off, the BE→host RTP header byteswap, the queue feed and the drain
//  of ready packets / PLC placeholders, plus the per-socket GAP-EVENT
//  accumulation. Split out of RtpAudioReceiver.swift - pure move, the FramePacer
//  split idiom - to keep that file under the length limit; every line here still
//  runs on the single receive thread (`recvQueue`), exactly as before.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.
//

import Foundation
import Darwin

extension RtpAudioReceiver {

    // MARK: - Receive loop (callback-driven, cancellable)

    // Internal (not private) so `startReceive()` in RtpAudioReceiver.swift can
    // call across the split - the same access note the type already carries.
    func startReceiveLoop() {
        let sock = fd
        let bufSize = Self.maxPacketSize
        recvQueue.async { [weak self] in
            // Session-long owned loop: name it so the per-thread CPU telemetry
            // resolves it (cleared at exit; same medicine as the video loop).
            pthread_setname_np("Glimmer.audioRecv")
            defer { pthread_setname_np("") }
            var buf = [UInt8](repeating: 0, count: bufSize)
            while let self, !self.interrupted.isSet {
                let received = recvfrom(sock, &buf, bufSize, 0, nil, nil)
                if received > 0 {
                    self.handleDatagram(buf, count: received)
                } else if received == 0 {
                    // Quiet socket after we've heard from the peer: no kernel
                    // backlog remains, so a pending startup-pacing measurement
                    // resolves to the live edge (AudioStream.c:276-288 clears
                    // its pendingDrops on the same evidence).
                    self.resolveStartupPacingOnIdle()
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                        // Poll timeout (100ms of recv silence): same quiet-socket
                        // proof as above - whatever arrives NEXT is delayed LIVE
                        // audio (a radio-coalesced clump), not a host backlog,
                        // and must not be eaten by the startup gate.
                        self.resolveStartupPacingOnIdle()
                        continue
                    }
                    break // socket closed (stop) or fatal
                }
            }
        }
    }

    private func handleDatagram(_ buf: [UInt8], count: Int) {
        // Per-socket GAP-EVENT accumulation first (before the runt check - a runt
        // is still a socket arrival, and the counters measure the ARRIVAL process).
        noteAudioArrivalGap()

        // Runt check: must be at least a full 12-byte RTP header (AudioStream.c:290).
        if count < RtpAudioQueue.fixedRtpHeaderSize {
            return
        }

        if !receivedDataFromPeer {
            receivedDataFromPeer = true
            firstRtpReceived.set()
            // Time-to-first-packet metric: how long from the first ping until the
            // host aimed audio at us, and how many pings it took. Target <1s -
            // met on warm reconnects (~284ms), but a COLD host takes 4-40s to
            // bring its audio pipeline up (host-side; the ping cadence never
            // pauses), so over-target reads are expected and flagged by the
            // `audio_ttf` event emitted at the startup-pacing verdict latch.
            let startUs = pingStartTimeUs.load()
            firstRtpPings = pingsSent.load()
            if startUs != 0 {
                let nowUs = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
                let ttfpMs = Double(nowUs &- startUs) / 1000.0
                firstRtpPingToRtpMs = ttfpMs
                Diag.notice("NativeAudio METRIC time-to-first-packet=\(String(format: "%.0f", ttfpMs))ms "
                    + "pings-until-first-RTP=\(firstRtpPings) (target <1000ms; len=\(count))", Self.cat)
            } else {
                Diag.notice("NativeAudio first audio packet received (len=\(count))", Self.cat)
            }
        }

        // Peek the packet type (single byte, no swap).
        let packetType = buf[1]

        // Backlog-aware startup gate (replaces the C's fixed 500ms drop,
        // AudioStream.c:312-318): classify the first window's arrivals as PACED
        // (live - decode everything, withhold nothing) or BURST (a flushed
        // backlog - drain the stale excess). Either way this datagram still
        // feeds the queue below, so sequence/FEC/stats bookkeeping stays
        // coherent (an early return here would read to the queue as a giant
        // loss gap and churn the FEC/PLC machinery when feeding resumed); the
        // discard happens at the decode hand-off instead.
        var dropForStartup = false
        if startupPacing != .decided {
            dropForStartup =
                updateStartupPacing(isData: packetType == RtpAudioQueue.payloadTypeAudio)
        }

        // Byteswap the multi-byte RTP fields BE→host (AudioStream.c:321-323). The
        // header + packetType bytes are single bytes (no swap).
        let packet = Array(buf[0..<count])
        let rtp = RtpAudioQueue.RtpHeader(
            header: packet[0],
            packetType: packet[1],
            sequenceNumber: UInt16(packet[2]) << 8 | UInt16(packet[3]),
            timestamp: UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16
                | UInt32(packet[6]) << 8 | UInt32(packet[7]),
            ssrc: UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16
                | UInt32(packet[10]) << 8 | UInt32(packet[11]))

        if !loggedFirstPacket {
            loggedFirstPacket = true
            // P1 AUDIO cold-start: record the first DECODED audio RTP instant -
            // the exporter surfaces (this − the stream-start anchor) as the
            // time-to-first-audio gauge. Always-live; read only when telemetry
            // on. With the backlog-aware gate the first arrival IS the first
            // decode (the measuring phase withholds nothing), so this lands
            // ~500ms earlier than under the old fixed drop. The audio_ttf event
            // row is emitted later, at the gate's verdict latch, so it can carry
            // the verdict alongside both TTF spans.
            TelemetryCounters.shared.recordAudioFirstPacket()
            Diag.notice("NativeAudio first decoded RTP "
                + "(seq=\(rtp.sequenceNumber) type=\(rtp.packetType) len=\(count))", Self.cat)
        }

        let result = queue.addPacket(packet, rtp: rtp)
        // P1 AUDIO receive-quality: fold the queue's cumulative stats into the
        // always-live telemetry totals once per ~1s window (off the per-packet
        // path). Done after addPacket so the window sees this packet's effect.
        flushAudioMetricsIfDue()
        switch result {
        case .handleNow:
            // In-order fast path: decode this packet immediately - unless the
            // startup gate marked it stale (burst drain), in which case the
            // queue bookkeeping above already ran and only the listener-facing
            // decode is withheld.
            if dropForStartup {
                startupDroppedPackets += 1
            } else {
                decodePacket(packet)
            }
        case .packetReady:
            // Drain ready packets (and PLC placeholders) until none remain. The
            // whole batch shares this datagram's startup-gate verdict: queue
            // outputs lag the newest arrival by at most the small OOS window,
            // so the verdict-boundary error is a packet or two of extra
            // cushion - noise next to the decoder's trim machinery.
            while let queued = queue.getQueuedPacket() {
                switch queued {
                case .bytes(let bytes):
                    if dropForStartup {
                        startupDroppedPackets += 1
                    } else {
                        decodePacket(bytes)
                    }
                case .lostPlaceholder:
                    // P1 AUDIO: an unrecovered missing data shard. Count the
                    // wire loss either way (it happened; a single integer add
                    // on the receive thread, no lock) - but only conceal a gap
                    // the user will actually hear: during a startup drain the
                    // surrounding audio is being discarded, so PLC would just
                    // synthesize filler into a timeline nobody plays. Dropped
                    // placeholders still count toward dropped_ms because it
                    // measures the TIMELINE removed, not just decodable audio.
                    audioLostInWindow += 1
                    if dropForStartup {
                        startupDroppedPackets += 1
                    } else {
                        sink?.decodeAndPlayPLC()
                    }
                }
            }
        case .none:
            break
        }
    }

    /// Per-socket GAP-EVENT accumulation - the AUDIO leg of the 20/50/100ms
    /// family (cumulative: a 100ms gap counts in all three). The video socket
    /// already tracked inter-arrival gaps; this completes the trio so "all
    /// sockets gapped together" (NIC doze) vs "one path stalled" is a single
    /// NDJSON-row query instead of a three-source manual cross-correlation.
    /// Cost per datagram (~200/s at 5ms packets): one monotonic clock read +
    /// one compare - far below the 5ms audio budget (the ~1s metrics fold pays
    /// its own read; merging the two would mean restructuring its call
    /// signature for a ~40ns saving). The counters' locked add fires only on a
    /// >20ms gap, i.e. only after the socket just sat idle that long.
    /// recvQueue-confined; always-live, read only when telemetry is on.
    private func noteAudioArrivalGap() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastDatagramArrivalNanos != 0 {
            let gap = now &- lastDatagramArrivalNanos
            if gap > 20_000_000 {
                let counters = TelemetryCounters.shared
                counters.audioGapOver20msTotal.increment()
                if gap > 50_000_000 { counters.audioGapOver50msTotal.increment() }
                if gap > 100_000_000 { counters.audioGapOver100msTotal.increment() }
            }
            // FLOW-RESUME edge: past the pair-anchor freshness horizon (2s -
            // AudioVideoSkewStore.freshnessNanos' rationale) the silence was a
            // host-idle stretch, not jitter; this first datagram back is a
            // segment boundary. Tell the sink so stale playout anchors don't
            // span it (drift re-anchor + cushion rebuild; no-op when the drain
            // edge already latched). Same recvQueue, one virtual call, only on
            // a ≥2s-idle edge.
            if gap >= Self.flowResumeGapNanos {
                sink?.notePacketFlowResumed(afterGapMs: Double(gap) / 1_000_000)
            }
        }
        lastDatagramArrivalNanos = now
    }
}
