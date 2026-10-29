// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Platform-neutral reasons; shells retain their wording, controls and presentation history.
public enum StreamFailure {
    public enum Category: Sendable, Equatable { case unreachable, pairing, other }

    /// Associated messages come from transport/server presentation inputs and may contain Mac wording.
    /// Consumers can select their own local copy from the reason without displaying those messages.
    public enum ConnectionReason: Sendable, Equatable {
        case unreachable, sunshineRequired, pairingRejected, hostTimedOut
        case pairing(String), sunshineNeedsRestart(String), launchRefused(String)
        case portsBlocked(proto: String, port: UInt16)
        case launchFailed, sessionFailed, decoderFailed, audioFailed, security, identityNeedsRestore
        case alreadyStarted, invalidConfiguration, pairingRequired, invalidSessionKey, cancelled
        case takeoverRequired(appID: Int)

        public var category: Category {
            switch self {
            case .unreachable: .unreachable
            case .pairing, .sunshineRequired, .pairingRejected, .pairingRequired: .pairing
            default: .other
            }
        }
    }

    public enum TerminationReason: Sendable, Equatable {
        case videoDidNotResume, noVideoTraffic, noDecodedVideo, connectionLost
        case protectedContent, frameConversion, unexpected
    }

    public static func connection(_ error: Error) -> ConnectionReason {
        if case IdentityStorageError.incompleteIdentity = error { return .identityNeedsRestore }
        if case IdentityStorageError.invalidIdentity = error { return .identityNeedsRestore }
        if error is CancellationError { return .cancelled }
        if let takeover = error as? TakeoverRequired { return .takeoverRequired(appID: takeover.appID) }
        if let failure = error as? StreamConnection.Failure {
            switch failure {
            case .alreadyStarted: return .alreadyStarted
            case .invalidConfiguration: return .invalidConfiguration
            case .pairingRequired: return .pairingRequired
            case .invalidSessionKey: return .invalidSessionKey
            }
        }
        guard let error = error as? StreamError else { return .unreachable }
        return connection(error)
    }

    private static func connection(_ error: StreamError) -> ConnectionReason {
        switch error {
        case .hostUnreachable, .truncatedRead: return .unreachable
        case .hostCertChanged(let message), .pairingFailed(let message): return .pairing(message)
        case .sunshineNeedsRestart(let message): return .sunshineNeedsRestart(message)
        case .gameStreamHost: return .sunshineRequired
        case .pairingRejected: return .pairingRejected
        case .streamPortsBlocked(let proto, let port): return .portsBlocked(proto: proto, port: port)
        case .hostTimedOut: return .hostTimedOut
        case .hostRefused(let message, _) where !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .launchRefused(message)
        case .hostRefused, .launchFailed: return .launchFailed
        case .sessionFailed, .binaryNotFound: return .sessionFailed
        case .decoderFailed: return .decoderFailed
        case .audioFailed: return .audioFailed
        case .crypto: return .security
        }
    }

    public static func termination(code: Int32, hasReceivedVideo: Bool = false) -> TerminationReason {
        switch code {
        case StreamSession.noVideoTrafficTerminationCode where hasReceivedVideo: .videoDidNotResume
        case StreamSession.noVideoTrafficTerminationCode: .noVideoTraffic
        case StreamSession.noVideoFrameTerminationCode: .noDecodedVideo
        case StreamSession.deadPeerTerminationCode: .connectionLost
        case StreamSession.protectedContentTerminationCode: .protectedContent
        case StreamSession.frameConversionTerminationCode: .frameConversion
        default: .unexpected
        }
    }

    /// Only a thrown start failure can be a cancelled start; a nil error represents a completed start.
    public static func connectionWasCancelled(by error: Error?, cancelRequested: Bool) -> Bool {
        guard let error else { return false }
        return cancelRequested || error is CancellationError
    }
}
