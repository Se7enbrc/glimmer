//
//  StreamingState.swift
//
//  Typed phase enums used by `AppModel` to drive UI affordances
//  during pairing and streaming. Pre-refactor the same information was
//  carried by stringly-typed `String?` published properties; the UI then
//  string-matched for "✓" / "Streaming" to recover the phase. The enums
//  here name those states directly so the UI can switch on them.
//

import Foundation

// MARK: - PairingPhase

/// Lifecycle of an in-flight pairing handshake with a Sunshine/GFE host.
/// Drives the PairSheet's spinner and result banner; the view words each case.
enum PairingPhase: Equatable {
    case idle
    case connecting     // reaching the PC's /serverinfo
    case awaitingPin    // handshake open, waiting for the code on the PC
    case success
    case failure(PairingFailure)
}

/// Why a pairing attempt ended. A wrong PIN and a bad host signature share
/// `.rejected` and its wording; `.busy` is Sunshine holding another open request.
enum PairingFailure: Error, Equatable {
    case invalidAddress
    case unreachable
    case timedOut
    case busy
    case rejected

    static let addressHint = "Enter a PC name like tower.local or an IP address like 192.168.1.10."

    func message(pc: String) -> String {
        switch self {
        case .invalidAddress: return Self.addressHint
        case .unreachable: return AppModel.unreachableMessage(pc)
        case .timedOut: return "The code wasn't entered on \(pc) in time. Choose Try Again to get a new code."
        case .busy:
            return "\(pc) is busy with another pairing request. "
                + "Cancel it on Sunshine's PIN page or wait a few minutes, then choose Try Again."
        case .rejected: return "\(pc) didn't accept the pairing. Choose Try Again to get a new code."
        }
    }
}

// MARK: - StreamPhase

/// Lifecycle of a live stream session. Backed by connection events from the
/// native backend (`stageStarting`, `connectionEstablished`,
/// `connectionTerminated`, ...) plus our own intent transitions (the user
/// pressed Stream → `connecting`, the user is exiting → `disconnecting`).
///
/// `connecting(stage:)` carries the engineering-jargon stage string from
/// the backend callback verbatim ("Starting RTSP handshake", "Initializing the
/// connection") so the UI can show progress without forcing every stage
/// into a closed enum case. The connect-banner translates that into a
/// user-friendly "Connecting to <host>..." itself.
enum StreamPhase: Equatable {
    case idle
    case connecting(stage: String)
    case streaming
    case disconnecting
    case error(String)
}
