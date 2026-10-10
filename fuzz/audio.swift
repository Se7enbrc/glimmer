//
//  audio.swift
//
//  Audio datagrams from the PC through RtpAudioQueue: RTP ordering, the RS(4,2)
//  FEC blocks and loss concealment placeholders.
//

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzAudio(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let queue = RtpAudioQueue(audioPacketDuration: 5)
    for datagram in datagrams(UnsafeRawBufferPointer(start: data, count: size)) {
        // The receiver drops runts before the queue sees them (RtpAudioReceiver+Receive).
        let packet = datagram.bytes
        guard packet.count >= RtpAudioQueue.fixedRtpHeaderSize else { continue }
        let rtp = RtpAudioQueue.RtpHeader(
            header: packet[0], packetType: packet[1],
            sequenceNumber: UInt16(packet[2]) << 8 | UInt16(packet[3]),
            timestamp: UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7]),
            ssrc: UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16 | UInt32(packet[10]) << 8 | UInt32(packet[11]))
        if queue.addPacket(packet, rtp: rtp) == .packetReady {
            while queue.getQueuedPacket() != nil {}
        }
    }
    return 0
}
