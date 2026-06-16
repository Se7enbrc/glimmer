//
//  RtpAudioReceiver+Socket.swift
//
//  The unconnected-UDP socket bring-up: bind a wildcard ephemeral local port
//  (NEVER connect() - the host sources RTP from a port != audioPort and aims
//  it at the ping's UDP source port, see the core file's header), tag it
//  NET_SERVICE_TYPE_VO for the Wi-Fi voice queue, size SO_RCVBUF, and set the
//  100ms SO_RCVTIMEO the receive loop's stop polling rides. Split out of
//  RtpAudioReceiver.swift - pure move, the FramePacer split idiom -
//  to keep that file under the length limit; the fd/destAddr socket state
//  stays declared on the receiver.
//

import Foundation
import Darwin

extension RtpAudioReceiver {

    func openSocket() throws {
        guard let (dest, destLen, family) = UdpPinger.makeSockaddr(for: host, port: audioPort) else {
            throw EnetError.socketFailure("could not build audio host address for \(host)")
        }
        destAddr = dest
        destAddrLen = destLen

        let sock = socket(family, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EnetError.socketFailure("socket() errno \(errno)") }

        // Wi-Fi QoS: tag the socket NET_SERVICE_TYPE_VO (Interactive Voice) - the
        // highest 802.11e WMM access category - so the radio dequeues audio ahead
        // of bulk/best-effort traffic. moonlight binds the audio socket
        // SOCK_QOS_TYPE_AUDIO → SO_NET_SERVICE_TYPE=NET_SERVICE_TYPE_VO
        // (PlatformSockets.c:250-251). This is the fragility fix for mobile Wi-Fi.
        var serviceType = Int32(NET_SERVICE_TYPE_VO)
        if setsockopt(sock, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                      &serviceType, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            Diag.warn("NativeAudio SO_NET_SERVICE_TYPE=VO failed errno \(errno) (non-fatal)", Self.cat)
        }
        // Sized receive buffer so a brief recv-loop stall (decoder hiccup) doesn't
        // drop audio at the socket. ~64 * MAX_PACKET_SIZE is comfortably larger
        // than any plausible backlog at 5ms packets.
        var rcvbuf = Int32(64 * Self.maxPacketSize)
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        // 100ms recv timeout so the receive loop polls `interrupted` and exits
        // (UDP_RECV_POLL_TIMEOUT_MS in Limelight-internal.h).
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to a wildcard ephemeral local port - UNCONNECTED, so recvfrom
        // accepts RTP from any source port. The host learns our return port from
        // the ping's UDP source.
        let bound: Bool
        if family == AF_INET {
            var ba = sockaddr_in()
            ba.sin_family = sa_family_t(AF_INET)
            ba.sin_addr.s_addr = 0 // INADDR_ANY
            ba.sin_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        } else {
            var ba = sockaddr_in6()
            ba.sin6_family = sa_family_t(AF_INET6)
            ba.sin6_addr = in6addr_any
            ba.sin6_port = 0
            bound = withUnsafePointer(to: &ba) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        guard bound else { close(sock); throw EnetError.socketFailure("bind() errno \(errno)") }

        fd = sock
        Diag.info("NativeAudio UDP socket ready (unconnected, recvfrom-any) → \(host):\(audioPort)",
                  Self.cat)
    }
}
