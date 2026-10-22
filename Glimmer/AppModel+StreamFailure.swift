// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Shared failure copy keeps the launcher, commands and menu bar consistent.

import GlimmerEngine
import Foundation

extension AppModel {

    /// A first decoded frame proves this PC's video path, unlike a handshake or last-played stamp.
    func noteVideoReceived(from host: Host) {
        guard hostPolling.videoReceivedFrom.insert(host.id).inserted else { return }
        var known = Set(hostsDefaults.stringArray(forKey: "glimmer.videoReceivedHosts") ?? [])
        if known.insert(host.id).inserted {
            hostsDefaults.set(known.sorted(), forKey: "glimmer.videoReceivedHosts")
        }
    }

    func hasReceivedVideo(from host: Host) -> Bool {
        hostPolling.videoReceivedFrom.contains(host.id)
            || (hostsDefaults.stringArray(forKey: "glimmer.videoReceivedHosts") ?? []).contains(host.id)
    }

    /// Show a failure on the launcher banner and the menu bar.
    func showStreamFailure(_ failure: (message: String, kind: StreamErrorKind), on host: Host) {
        nativeStreamError = failure.message
        nativeStreamErrorKind = failure.kind
        nativeStreamErrorHostID = host.id
    }

    /// A connect the user stopped (Cancel, the quit chord, the close button)
    /// ended by choice: no failure banner, no "Stream ended", no last-played stamp.
    /// Only a start() throw counts; a stream that went live ended normally.
    nonisolated static func connectWasCancelled(by error: Error?, cancelRequested: Bool) -> Bool {
        StreamFailure.connectionWasCancelled(by: error, cancelRequested: cancelRequested)
    }

    /// Every surface's words for a PC that never answered: the launcher, the
    /// pair sheet, `glimmer` and the Shortcuts actions.
    nonisolated static func unreachableMessage(_ pcName: String) -> String {
        "Couldn't reach \(pcName). Make sure it's awake and on the same network."
    }

    /// Every surface's words for a PC running NVIDIA GameStream, which Glimmer
    /// refuses at pairing and at stream start.
    nonisolated static func needsSunshineMessage(_ pcName: String) -> String {
        StreamFailureCopy.needsSunshineMessage(pcName)
    }

    /// A start()-throw as the banner's sentence and the recovery it calls for.
    /// "Make sure it's awake" is only for a PC that never answered; once it has,
    /// the copy names what actually failed.
    nonisolated static func connectFailure(
        for error: Error, hostName: String
    ) -> (message: String, kind: StreamErrorKind) {
        let unreachable = (message: unreachableMessage(hostName), kind: StreamErrorKind.unreachable)
        // The control layer always throws StreamError; anything else is most likely a reach failure.
        guard error is StreamError else { return unreachable }
        switch StreamFailure.connection(error) {
        case .unreachable:
            return unreachable
        // The network layer's own PC-named sentences; the connect path throws no
        // other pairing failure (the pair sheet's steps word their own).
        case .pairing(let sentence):
            return (sentence, .pairing)
        case .sunshineNeedsRestart(let sentence):
            return (sentence, .other)
        case .sunshineRequired:
            // Sunshine brings its own certificate, so the next step after installing it is pairing.
            return (needsSunshineMessage(hostName), .pairing)
        case .pairingRejected:
            return ("Couldn't pair with \(hostName). Choose Pair Again… to start over.", .pairing)
        case .portsBlocked(let proto, let port):
            return (StreamFailureCopy.portsBlockedMessage(hostName, proto: proto, port: port), .other)
        case .hostTimedOut:
            return ("\(hostName) took too long to start the app. Check the PC's screen, then try again.", .other)
        case .launchRefused(let message):
            return ("\(hostName) couldn't start the app: \(sentence(message))", .other)
        case .launchFailed:
            return ("\(hostName) couldn't start the app.", .other)
        case .sessionFailed:
            // In practice the connect leg, after /launch succeeded: the PC is awake.
            return ("\(hostName) answered, but the stream couldn't start. Restart Sunshine on the PC, then try again.",
                    .other)
        case .decoderFailed:
            return ("Couldn't start the video decoder for \(hostName). Try another codec from the PC's ⋯ menu.", .other)
        case .audioFailed:
            return ("Couldn't start audio for \(hostName). Check this Mac's sound output, then try again.", .other)
        case .security:
            return ("A security error stopped the connection to \(hostName). "
                + "Try again, and pair again if it keeps happening.", .other)
        case .alreadyStarted, .invalidConfiguration, .pairingRequired, .invalidSessionKey, .cancelled, .takeoverRequired:
            return unreachable
        }
    }

    /// The toast for a stream that ended with a nonzero code. The watchdog's bring-up codes (see
    /// watchdogTerminationCode) and Sunshine's own non-recoverable codes each name their fix.
    nonisolated static func streamEndedMessage(
        code: Int32, hostName: String, hasReceivedVideo: Bool = false
    ) -> String {
        switch StreamFailure.termination(code: code, hasReceivedVideo: hasReceivedVideo) {
        case .videoDidNotResume:
            "\(hostName) didn't start sending video. Try again."
        case .noVideoTraffic:
            "No video from \(hostName) reached this Mac. Make sure the PC's firewall allows UDP port 47998."
        case .noDecodedVideo:
            "Video from \(hostName) arrived but couldn't be decoded. Try another codec from the PC's ⋯ menu."
        case .connectionLost:
            "Lost the connection to \(hostName). Check the network, then try again."
        case .protectedContent:
            StreamFailureCopy.protectedContentMessage(hostName)
        case .frameConversion:
            "\(hostName)'s graphics driver couldn't hand frames to the encoder. "
                + "Update the PC's graphics driver, then try again."
        case .unexpected: "Stream to \(hostName) ended unexpectedly."
        }
    }

    /// Sunshine's status text as a sentence: trimmed, with closing punctuation.
    private nonisolated static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".?!".contains(last) else { return trimmed }
        return trimmed + "."
    }
}
