//
//  AppModel+StreamFailure.swift
//
//  What the launcher banner and the menu bar say when a stream fails to start
//  or ends badly, and which fix each failure asks for. Pure, so it's testable.
//

import Foundation

extension AppModel {

    /// Show a failure on the launcher banner and the menu bar.
    func showStreamFailure(_ failure: (message: String, kind: StreamErrorKind)) {
        nativeStreamError = failure.message
        nativeStreamErrorKind = failure.kind
    }

    /// A connect the user stopped (Cancel, the quit chord, the close button)
    /// ended by choice: no failure banner, no "Stream ended", no last-played stamp.
    nonisolated static func connectWasCancelled(by error: Error?, cancelRequested: Bool) -> Bool {
        cancelRequested || error is CancellationError
    }

    /// Every surface's words for a PC that never answered: the launcher, the
    /// pair sheet, `glimmer` and the Shortcuts actions.
    nonisolated static func unreachableMessage(_ pcName: String) -> String {
        "Couldn't reach \(pcName). Make sure it's awake and on the same network."
    }

    /// A start()-throw as the banner's sentence and the recovery it calls for.
    /// "Make sure it's awake" is only for a PC that never answered; once it has,
    /// the copy names what actually failed.
    nonisolated static func connectFailure(
        for error: Error, hostName: String
    ) -> (message: String, kind: StreamErrorKind) {
        let unreachable = (message: unreachableMessage(hostName), kind: StreamErrorKind.unreachable)
        // The control layer always throws StreamError; anything else is most likely a reach failure.
        guard let streamError = error as? StreamError else { return unreachable }
        switch streamError {
        case .hostUnreachable(let detail) where detail.contains("cert"):
            // The network layer's own sentence for a changed PC certificate.
            return (detail, .pairing)
        case .hostUnreachable(let detail) where detail.contains("Restart Sunshine"):
            // A wedged HTTPS listener (classifyPairedPathFailure): the PC is awake.
            return (detail, .other)
        case .hostUnreachable, .truncatedRead:
            return unreachable
        case .sessionFailed(RtspError.encryptedVideoRequiredCode):
            // The PC answered and refused us: its settings require encrypted video.
            return (RtspError.encryptedVideoRequired.description, .other)
        case .pairingFailed(let detail) where detail.contains("Pair Again…"):
            // classifyPairedPathFailure's host-named sentence (a 401 or a TLS rejection).
            return (detail, .pairing)
        case .pairingFailed, .pairingRejected:
            return ("Couldn't pair with \(hostName). Choose Pair Again… from the PC's ⋯ menu.", .pairing)
        case .streamPortsBlocked(let proto, let port):
            return ("\(hostName) answered, but the stream couldn't get through. "
                + "Check that the PC's firewall allows \(proto) \(port).", .other)
        case .hostTimedOut:
            return ("\(hostName) took too long to start the app.", .other)
        case .hostRefused(let message, _):
            return ("\(hostName) couldn't start the app: \(sentence(message))", .other)
        case .launchFailed:
            return ("\(hostName) couldn't start the app.", .other)
        case .sessionFailed, .binaryNotFound:
            // Only the connect leg throws these, after /launch succeeded: the PC is awake.
            return ("\(hostName) answered, but the stream couldn't start.", .other)
        case .decoderFailed:
            return ("Couldn't start the video decoder for \(hostName).", .other)
        case .audioFailed:
            return ("Couldn't start audio for \(hostName).", .other)
        case .crypto:
            return ("A security error stopped the connection to \(hostName).", .other)
        }
    }

    /// The toast for a stream that ended with a nonzero code. The watchdog's
    /// bring-up codes (see watchdogTerminationCode) each name their own fix.
    nonisolated static func streamEndedMessage(code: Int32, hostName: String) -> String {
        switch code {
        case StreamSession.noVideoTrafficTerminationCode:
            "No video from \(hostName) reached this Mac. Make sure the PC's firewall allows UDP port 47998."
        case StreamSession.noVideoFrameTerminationCode:
            "Video from \(hostName) arrived but couldn't be decoded. Try another codec from the PC's ⋯ menu."
        case StreamSession.deadPeerTerminationCode: "Lost the connection to \(hostName)."
        default: "Stream to \(hostName) ended unexpectedly."
        }
    }

    /// Sunshine's status text as a sentence: trimmed, with closing punctuation.
    private nonisolated static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".?!".contains(last) else { return trimmed }
        return trimmed + "."
    }
}
