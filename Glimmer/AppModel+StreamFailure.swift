//
//  AppModel+StreamFailure.swift
//
//  What the launcher banner and the menu bar say when a stream fails to start
//  or ends badly, and which fix each failure asks for. The mappings are pure
//  and tested; showStreamFailure is the one place they reach the UI.
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
    /// Only a start() throw counts; a stream that went live ended normally.
    nonisolated static func connectWasCancelled(by error: Error?, cancelRequested: Bool) -> Bool {
        guard let error else { return false }
        return cancelRequested || error is CancellationError
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
        case .hostUnreachable, .truncatedRead:
            return unreachable
        // The network layer's own PC-named sentences; the connect path throws no
        // other pairing failure (the pair sheet's steps word their own).
        case .hostCertChanged(let sentence), .pairingFailed(let sentence):
            return (sentence, .pairing)
        case .sunshineNeedsRestart(let sentence):
            return (sentence, .other)
        case .pairingRejected:
            return ("Couldn't pair with \(hostName). Choose Pair Again… from the PC's ⋯ menu.", .pairing)
        case .sessionFailed(RtspError.encryptedVideoRequiredCode):
            // The PC answered and refused us: its settings require encrypted video.
            return (RtspError.encryptedVideoRequired.description, .other)
        case .streamPortsBlocked(let proto, let port):
            return ("\(hostName) answered, but the stream couldn't get through. "
                + "Check that the PC's firewall allows \(proto) \(port).", .other)
        case .hostTimedOut:
            return ("\(hostName) took too long to start the app.", .other)
        case .hostRefused(let message, _) where !sentence(message).isEmpty:
            return ("\(hostName) couldn't start the app: \(sentence(message))", .other)
        case .hostRefused, .launchFailed:
            return ("\(hostName) couldn't start the app.", .other)
        case .sessionFailed, .binaryNotFound:
            // In practice the connect leg, after /launch succeeded: the PC is awake.
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
