// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine

enum StreamSessionFailureCopy {
    static func quit(_ error: Error, app: String, pc: String) -> String {
        if error is TakeoverRequired { return StreamFailureCopy.runningAppChanged(pc) }
        if error is RunningAppFailure { return StreamFailureCopy.quitUnconfirmed(app, pc: pc) }
        switch StreamFailure.connection(error) {
        case .launchRefused, .launchFailed: return StreamFailureCopy.quitRefused(pc)
        case .hostTimedOut: return StreamFailureCopy.quitUnconfirmed(app, pc: pc)
        default: return connection(StreamFailure.connection(error), pcName: pc)
        }
    }

    static func connection(_ reason: StreamFailure.ConnectionReason, pcName: String) -> String {
        switch reason {
        case .portsBlocked(let proto, let port):
            StreamFailureCopy.portsBlockedMessage(pcName, proto: proto, port: port)
        case .sunshineRequired:
            StreamFailureCopy.needsSunshineMessage(pcName)
        case .pairing, .pairingRejected, .pairingRequired:
            "Couldn't use the saved pairing with \(pcName). In Settings → PCs, forget the PC and pair again."
        case .unreachable:
            "Couldn't reach \(pcName). Make sure it's awake and on the same network."
        case .hostTimedOut:
            "\(pcName) took too long to start the app. Check the PC's screen, then try again."
        case .launchRefused, .launchFailed, .takeoverRequired:
            "\(pcName) couldn't start the app. Check the PC's screen, then try again."
        case .sessionFailed, .sunshineNeedsRestart:
            "\(pcName) answered, but the stream couldn't start. Restart Sunshine on the PC, then try again."
        case .decoderFailed:
            "Couldn't start the video decoder for \(pcName). Close the stream and try again."
        case .audioFailed:
            "Couldn't start audio for \(pcName). Check this device's sound output, then try again."
        case .security, .invalidSessionKey:
            "A security error stopped the connection to \(pcName). Try again, and pair again if it keeps happening."
        case .cancelled:
            "Disconnected from \(pcName)."
        case .alreadyStarted, .invalidConfiguration:
            "Couldn't connect to \(pcName). Check Sunshine on the PC and try again."
        }
    }

    static func termination(_ reason: StreamFailure.TerminationReason, pcName: String) -> String {
        switch reason {
        case .protectedContent:
            StreamFailureCopy.protectedContentMessage(pcName)
        case .videoDidNotResume:
            "\(pcName) didn't start sending video. Try again."
        case .noVideoTraffic:
            "No video from \(pcName) reached this device. Make sure the PC's firewall allows UDP port 47998."
        case .noDecodedVideo:
            "Video from \(pcName) arrived but couldn't be decoded. Restart Sunshine on the PC, then try again."
        case .connectionLost:
            "Lost the connection to \(pcName). Check the network, then try again."
        case .frameConversion:
            "\(pcName)'s graphics driver couldn't hand frames to the encoder. "
                + "Update the PC's graphics driver, then try again."
        case .unexpected:
            "The connection to \(pcName) ended. Check the PC and reconnect when you're ready."
        }
    }
}
