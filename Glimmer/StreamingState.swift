//
//  StreamingState.swift
//
//  Typed phase enums used by `MoonlightManager` to drive UI affordances
//  during pairing and streaming. Pre-refactor the same information was
//  carried by stringly-typed `String?` published properties; the UI then
//  string-matched for "✓" / "Streaming" to recover the phase. The enums
//  here name those states directly so the UI can switch on them.
//

import Foundation

// MARK: - PairingPhase

/// Lifecycle of an in-flight pairing handshake with a Sunshine/GFE host.
/// Drives the PairSheet's spinner, PIN field, and result banner.
///
/// Each non-`idle` case carries the localized status text we display while
/// in that phase — old call sites read this through the `pairingMessage`
/// computed shim on `MoonlightManager` (kept for back-compat during the
/// gradual UI migration). New call sites should switch on the phase
/// directly.
enum PairingPhase: Equatable {
    case idle
    case awaitingPin(String)
    case verifying(String)
    case success(String)
    case failure(String)
}

// MARK: - StreamPhase

/// Lifecycle of a live stream session. Backed by connection events from the
/// native backend (`stageStarting`, `connectionEstablished`,
/// `connectionTerminated`, …) plus our own intent transitions (the user
/// pressed Stream → `connecting`, the user is exiting → `disconnecting`).
///
/// `connecting(stage:)` carries the engineering-jargon stage string from
/// the backend callback verbatim ("Starting RTSP handshake", "Initializing the
/// connection") so the UI can show progress without forcing every stage
/// into a closed enum case. The connect-banner translates that into a
/// user-friendly "Connecting to <host>…" itself.
enum StreamPhase: Equatable {
    case idle
    case connecting(stage: String)
    case streaming
    case disconnecting
    case error(String)
}
