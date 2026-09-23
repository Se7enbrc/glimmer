//
//  LauncherWindowTests.swift
//
//  Launcher window: the connect-failure banner's action, the readiness
//  chip's running wording, and the takeover dialog's title.
//

import Foundation
import SwiftUI
import Testing
@testable import Glimmer

/// Driven by the real producers (the connect path's banner copy and the
/// paired-path classifier), so a copy change breaks a test here instead of
/// quietly downgrading the banner's button.
@MainActor
struct ConnectBannerActionTests {

    private func action(for error: Error, canWake: Bool = true) -> ConnectBannerAction {
        ConnectBannerAction.forError(AppModel.connectFailureBanner(for: error, hostName: "Tower"), canWake: canWake)
    }

    private func pairedPath(_ detail: String) -> StreamError {
        NetworkClient.classifyPairedPathFailure(detail, hostName: "Tower")
    }

    @Test func genuineReachFailuresOfferWake() {
        let errors: [Error] = [
            StreamError.hostUnreachable("control write failed"),
            StreamError.sessionFailed(-1),
            StreamError.binaryNotFound,
            StreamError.truncatedRead("recv timed out"),
            CancellationError()
        ]
        for error in errors {
            #expect(action(for: error) == .wakeAndConnect, "\(error)")
            #expect(action(for: error, canWake: false) == .tryAgain, "\(error)")
        }
    }

    @Test func everyPairingAndTrustFailureOffersPairAgain() {
        let errors: [StreamError] = [
            pairedPath("Host requires pairing (401)"),
            pairedPath("TLS handshake to tower:47984 failed (SSL_connect)"),
            pairedPath("pinned host cert mismatch"),
            pairedPath("host presented no certificate"),
            .pairingFailed("host returned status 400"),
            .pairingRejected
        ]
        for error in errors {
            #expect(action(for: error) == .pairAgain, "\(error)")
            #expect(action(for: error, canWake: false) == .pairAgain, "\(error)")
        }
    }

    @Test func awakePCWithAStuckSecurePortNeverOffersWake() {
        // The PC demonstrably answered on its plain port, so Wake would be a
        // lie, and it isn't a pairing problem either.
        #expect(action(for: pairedPath("connect to tower:47984 failed or timed out")) == .tryAgain)
        #expect(action(for: pairedPath("empty HTTP response")) == .tryAgain)
    }

    @Test func failuresAfterThePCAnsweredTryAgain() {
        let errors: [StreamError] = [
            .launchFailed("busy"), .decoderFailed("hevc"), .audioFailed("opus"), .crypto("aes")
        ]
        for error in errors {
            #expect(action(for: error) == .tryAgain, "\(error)")
        }
    }
}

struct ReadinessChipRunningLabelTests {

    @Test func appRunningReplacesTheSomeoneElseStreamingWording() {
        let chip = ChipPresentation.streamingElsewhere(appName: "Helldivers 2")
        #expect(chip.label == "Helldivers 2 running")
        #expect(chip.accessibility == "Helldivers 2 is running on this PC")
    }

    @Test func runningColorIsNeutralNotBlue() {
        #expect(ChipPresentation.streamingElsewhere(appName: "x").dotColor == Color.secondary)
    }

    @Test func longNameStillTruncatesInsideTheRunningLabel() {
        // The chip must stay narrow: truncate to 14 chars (with an ellipsis)
        // before appending " running", not after - the old code truncated
        // the same way ahead of its "Streaming " prefix.
        let chip = ChipPresentation.streamingElsewhere(appName: "A Very Long Game Title Indeed")
        #expect(chip.label == "A Very Long G… running")
    }

    @Test func certMismatchIsUnaffectedByTheRunningRewording() {
        #expect(ChipPresentation.certMismatch.label == "Trust needed")
        #expect(ChipPresentation.certMismatch.dotColor == Color.orange)
    }

    @Test func appMissingFromTheCachedListReadsInSentenceCase() {
        let chip = ChipPresentation.streamingElsewhere(appName: nil)
        #expect(chip.label == "App running")
        #expect(chip.accessibility == "An app is running on this PC")
    }
}

struct TakeoverDialogCopyTests {

    @Test func capitalizesARealAppName() {
        #expect(TakeoverDialogCopy.title(occupantApp: "Helldivers 2", hostName: "Tower")
            == "Helldivers 2 is running on Tower.")
    }

    @Test func capitalizesTheAnotherAppFallback() {
        // occupant(of:) and the TakeoverRequired path both fall back to the
        // lowercase phrase "another app" - the dialog title must still read
        // as a sentence.
        #expect(TakeoverDialogCopy.title(occupantApp: "another app", hostName: "Tower")
            == "Another app is running on Tower.")
    }
}
