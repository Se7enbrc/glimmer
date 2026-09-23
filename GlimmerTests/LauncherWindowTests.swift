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

/// Driven by the real producers (the connect path's failure kind and the
/// paired-path classifier), so a change there breaks a test here instead of
/// quietly downgrading the banner's button.
@MainActor
struct ConnectBannerActionTests {

    private func action(for error: Error, canWake: Bool = true, pc: String = "Tower") -> ConnectBannerAction {
        ConnectBannerAction(kind: AppModel.connectFailure(for: error, hostName: pc).kind, canWake: canWake)
    }

    private func pairedPath(_ detail: String) -> StreamError {
        NetworkClient.classifyPairedPathFailure(detail, hostName: "Tower")
    }

    @Test func genuineReachFailuresOfferWake() {
        let errors: [Error] = [
            StreamError.hostUnreachable("control write failed"),
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
            .launchFailed("busy"), .decoderFailed("hevc"), .audioFailed("opus"), .crypto("aes"),
            .sessionFailed(-1), .streamPortsBlocked(proto: "UDP", port: 47999), .hostTimedOut
        ]
        for error in errors {
            #expect(action(for: error) == .tryAgain, "\(error)")
        }
    }

    /// The PC's name can't change the recovery: "Repair Rig" is asleep, not unpaired.
    @Test func aPCNamedLikePairingStillOffersWake() {
        #expect(action(for: StreamError.hostUnreachable("control write failed"), pc: "Repair Rig") == .wakeAndConnect)
        #expect(action(for: StreamError.launchFailed("busy"), pc: "Repair Rig") == .tryAgain)
    }

    /// A reconnect's failed stage leaves the banner alone; the give-up terminate
    /// records its kind alongside the sentence.
    @Test func engineFailuresRecordTheirKind() {
        let model = AppModel()
        let rig = Host(id: "pc-1", name: "rig", customName: "Repair Rig", localAddress: "192.0.2.10", manualAddress: nil,
                       apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.nativeStreamErrorKind = .pairing
        model.handleNativeEvent(.stageFailed(name: "RTSP handshake", errorCode: -1), host: rig)
        #expect(model.nativeStreamError == nil && model.nativeStreamErrorKind == .pairing)
        model.handleNativeEvent(.connectionTerminated(errorCode: -1), host: rig)
        #expect(model.nativeStreamError == "Lost the connection to Repair Rig.")
        #expect(model.nativeStreamErrorKind == .other)
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
        #expect(ChipPresentation.certMismatch.accessibility == ChipPresentation.certMismatch.label)
        #expect(ChipPresentation.certMismatch.dotColor == Color.orange)
    }

    @Test func appMissingFromTheCachedListReadsInSentenceCase() {
        let chip = ChipPresentation.streamingElsewhere(appName: nil)
        #expect(chip.label == "App running")
        #expect(chip.accessibility == "An app is running on this PC")
    }
}

@MainActor
struct TakeoverDialogCopyTests {

    @Test func keepsARealAppNameAsTyped() {
        #expect(TakeoverDialogCopy.title(occupantApp: "Helldivers 2", hostName: "Tower")
            == "Helldivers 2 is running on Tower.")
        #expect(TakeoverDialogCopy.title(occupantApp: "iRacing", hostName: "Tower")
            == "iRacing is running on Tower.")
        #expect(TakeoverDialogCopy.title(occupantApp: "eFootball", hostName: "Tower")
            == "eFootball is running on Tower.")
    }

    @Test func anAppThePCDidntNameReadsAsAnotherApp() throws {
        let unnamed = try #require(AppModel.occupant(of: .streamingUnknownApp(id: 9)))
        #expect(unnamed == nil)
        #expect(TakeoverDialogCopy.title(occupantApp: unnamed, hostName: "Tower")
            == "Another app is running on Tower.")
        #expect(AppModel.occupant(of: .idle) == nil)
    }
}

/// Every Pair Again… lands on the one launcher sheet, which names the PC.
@MainActor
struct PairAgainSheetTests {

    @Test func pairAgainCarriesThePCToTheSheet() {
        let model = AppModel()
        let tower = Host(id: "pc-1", name: "tower", customName: "Tower", localAddress: nil, manualAddress: "192.0.2.10",
                         apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.requestPairing(for: tower)
        #expect(model.pairSheetShown && model.pairSheetHost == tower)
        model.requestPairing(for: nil)
        #expect(model.pairSheetShown && model.pairSheetHost == nil)
    }

    @Test func aRePairIsTitledWithThePCsName() {
        #expect(PairSheet.title(paired: false, chosen: true, rePairName: "Tower") == "Pair Tower again")
        #expect(PairSheet.title(paired: false, chosen: true, rePairName: nil) == "Pair a new PC")
        #expect(PairSheet.title(paired: false, chosen: false, rePairName: nil) == "Choose a PC")
        #expect(PairSheet.title(paired: true, chosen: true, rePairName: "Tower") == "Paired")
    }
}
