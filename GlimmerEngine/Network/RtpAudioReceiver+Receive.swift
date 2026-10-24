// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// The socket loop only timestamps and queues datagrams; the decode worker owns RTP/FEC and startup state.
// Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

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
            let batch = DatagramBatch(capacity: 1, stride: bufSize)
            var timing = ReceiveTiming(telemetry: .audio)
            var foreignPeerNoted = false
            while let self, !self.interrupted.isSet {
                let count = batch.receiveOne(from: sock)
                let receiveError = count < 0 ? errno : 0
                guard !self.interrupted.isSet else { break }
                let received = count > 0 ? batch.datagram(0).length : -1
                if received >= 0, !batch.isExpectedPeer(at: 0, expected: self.destAddr,
                                                      expectedLength: self.destAddrLen) {
                    UdpPinger.noteForeignPeer(&foreignPeerNoted, stream: "Audio", category: Self.cat)
                    continue
                }
                if received >= 0 {
                    timing.note(batch, index: 0, count: 1, socket: sock, stream: "audio")
                }
                if received > 0 {
                    let arrival = DispatchTime.now().uptimeNanoseconds
                    self.noteAudioArrivalGap(now: arrival)
                    self.decodeWorker.enqueue(UnsafeRawBufferPointer(start: batch.storage, count: received),
                                              count: received, arrival: arrival)
                } else if received == 0 {
                    // Quiet socket after we've heard from the peer: no kernel
                    // backlog remains, so a pending startup-pacing measurement
                    // resolves to the live edge (AudioStream.c:276-288 clears
                    // its pendingDrops on the same evidence).
                    self.decodeWorker.enqueue([], count: 0, arrival: DispatchTime.now().uptimeNanoseconds)
                } else {
                    if !self.handleReceiveError(receiveError) { break }
                }
            }
        }
    }

    /// A signal interruption says nothing about backlog; only a receive timeout proves the socket was quiet.
    func handleReceiveError(_ error: Int32) -> Bool {
        switch receiveFailure.action(for: error) {
        case .quiet:
            decodeWorker.enqueue([], count: 0, arrival: DispatchTime.now().uptimeNanoseconds)
        case .interrupted:
            break
        case .pressure:
            if !loggedReceivePressure {
                loggedReceivePressure = true
                Diag.warn("NativeAudio receive buffer pressure errno \(error) (will keep trying)", Self.cat)
            }
            usleep(1_000)
        case .failed:
            Diag.error("NativeAudio receive failed errno \(error)", Self.cat)
            onReceiveFailed?(error)
            return false
        case .stopped:
            return false
        }
        return true
    }

    func handleDatagram(_ buf: [UInt8], count: Int, arrival: UInt64? = nil) {
        // Per-socket GAP-EVENT accumulation first (before the runt check - a runt
        // is still a socket arrival, and the counters measure the ARRIVAL process).
        if arrival == nil { noteAudioArrivalGap(now: DispatchTime.now().uptimeNanoseconds) }
        let packetArrival = arrival ?? DispatchTime.now().uptimeNanoseconds
        AudioPipelineTelemetry.shared.processedDatagrams.wrappingAdd(1, ordering: .relaxed)
        noteProcessedArrival(packetArrival)

        guard count >= RtpAudioQueue.fixedRtpHeaderSize, count <= buf.count, buf[0] == 0x80,
              buf[1] == RtpAudioQueue.payloadTypeAudio || buf[1] == RtpAudioQueue.payloadTypeFec else { return }
        if buf[1] == RtpAudioQueue.payloadTypeAudio,
           !acceptsAudioPayload(buf, count: count, arrival: packetArrival) { return }

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
                let nowUs = packetArrival / 1000
                let ttfpMs = Double(nowUs &- startUs) / 1000.0
                firstRtpPingToRtpMs = ttfpMs
                let pingCount = firstRtpPings
                AudioDiagnostics.notice("NativeAudio METRIC time-to-first-packet=\(String(format: "%.0f", ttfpMs))ms "
                    + "pings-until-first-RTP=\(pingCount) (target <1000ms; len=\(count))", Self.cat)
            } else {
                AudioDiagnostics.notice("NativeAudio first audio packet received (len=\(count))", Self.cat)
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
                updateStartupPacing(isData: packetType == RtpAudioQueue.payloadTypeAudio, now: packetArrival)
        }

        // Byteswap the multi-byte RTP fields BE→host (AudioStream.c:321-323). The
        // header + packetType bytes are single bytes (no swap).
        let packet = count == buf.count ? buf : Array(buf[0..<count])
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
            AudioDiagnostics.notice("NativeAudio first decoded RTP "
                + "(seq=\(rtp.sequenceNumber) type=\(rtp.packetType) len=\(count))", Self.cat)
        }

        let result = queue.addPacket(packet, rtp: rtp, arrival: packetArrival)
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
            drainQueuedPackets(dropForStartup: dropForStartup)
        case .packetReady:
            // Queue outputs lag the newest arrival by at most the OOS window,
            // so this batch shares its startup-gate verdict.
            drainQueuedPackets(dropForStartup: dropForStartup)
        case .none:
            break
        }
    }

    private func drainQueuedPackets(dropForStartup: Bool) {
        while let lost = queue.getQueuedPacket(into: &recoveredPacket) {
            if lost { audioLostInWindow += 1 }
            if dropForStartup {
                // Lost placeholders still count as loss; the startup gate discards their timeline too.
                startupDroppedPackets += 1
            } else if lost {
                sink?.decodeAndPlayPLC()
            } else {
                decodePacket(recoveredPacket)
            }
        }
    }

    /// Receive timestamps distinguish a socket stall from a delayed decoder. No sink work runs here.
    /// This is recvQueue-confined; startup/reorder state is owned by the worker.
    private func noteAudioArrivalGap(now: UInt64) {
        AudioPipelineTelemetry.shared.receivedDatagrams.wrappingAdd(1, ordering: .relaxed)
        let gap: UInt64? = lastDatagramArrivalNanos != 0 ? now &- lastDatagramArrivalNanos : nil
        if let gap {
            AudioPipelineTelemetry.shared.receiveGap.observe(Double(gap) / 1_000_000)
            if gap > 20_000_000 {
                let counters = TelemetryCounters.shared
                counters.audioGapOver20msTotal.increment()
                if gap > 50_000_000 { counters.audioGapOver50msTotal.increment() }
                if gap > 100_000_000 { counters.audioGapOver100msTotal.increment() }
            }
        }
        lastDatagramArrivalNanos = now
        TelemetryCounters.shared.audioArrivalGaps.noteArrival(at: now, gapNanos: gap)
    }

    private func noteProcessedArrival(_ now: UInt64) {
        defer { lastProcessedArrivalNanos = now }
        guard lastProcessedArrivalNanos != 0, now >= lastProcessedArrivalNanos else { return }
        let gap = now - lastProcessedArrivalNanos
        // Deliver flow edges in packet order, so a queued pre-gap packet cannot re-arm the new segment.
        if gap >= Self.flowResumeGapNanos {
            sink?.notePacketFlowResumed(afterGapMs: Double(gap) / 1_000_000)
        }
        sink?.noteArrivalGap(nanos: gap)
    }
}
