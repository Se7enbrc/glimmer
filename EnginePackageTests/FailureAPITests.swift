// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing

struct FailureAPITests {
    @Test func refusalClassificationPreservesPayloadAndRejectsBlankDetails() {
        let payload = "  Encoder unavailable?\n"
        #expect(StreamFailure.connection(StreamError.hostRefused(message: payload, code: 500)) == .launchRefused(payload))
        #expect(StreamFailure.connection(StreamError.hostRefused(message: " \n\t", code: 500)) == .launchFailed)
        #expect(StreamFailure.connection(StreamError.hostCertChanged(payload)) == .pairing(payload))
        #expect(StreamFailure.connection(StreamError.sunshineNeedsRestart(payload)) == .sunshineNeedsRestart(payload))
        #expect(StreamFailure.connection(StreamError.gameStreamHost).category == .pairing)
        #expect(StreamFailure.connection(StreamError.streamPortsBlocked(proto: "UDP", port: 47998))
            == .portsBlocked(proto: "UDP", port: 47998))
    }

    @Test func publicStartFailuresRemainDistinctFromUnreachableHost() {
        #expect(StreamFailure.connection(StreamConnection.Failure.invalidConfiguration) == .invalidConfiguration)
        #expect(StreamFailure.connection(StreamConnection.Failure.invalidSessionKey) == .invalidSessionKey)
        #expect(StreamFailure.connection(StreamConnection.Failure.pairingRequired) == .pairingRequired)
        #expect(StreamFailure.connection(StreamConnection.Failure.alreadyStarted) == .alreadyStarted)
        #expect(StreamFailure.connection(StreamConnection.Failure.pairingRequired).category == .pairing)
        #expect(StreamFailure.connection(CancellationError()) == .cancelled)
        #expect(StreamFailure.connection(URLError(.cannotConnectToHost)) == .unreachable)
    }

    @Test func completedStartIsNotReclassifiedAsCancelled() {
        #expect(!StreamFailure.connectionWasCancelled(by: nil, cancelRequested: true))
        #expect(StreamFailure.connectionWasCancelled(by: CancellationError(), cancelRequested: false))
        #expect(StreamFailure.connectionWasCancelled(by: StreamError.hostTimedOut, cancelRequested: true))
        #expect(!StreamFailure.connectionWasCancelled(by: StreamError.hostTimedOut, cancelRequested: false))
    }

    @Test func terminationUsesVideoHistoryOnlyForMissingTraffic() {
        #expect(StreamFailure.termination(code: -100) == .noVideoTraffic)
        #expect(StreamFailure.termination(code: -100, hasReceivedVideo: true) == .videoDidNotResume)
        #expect(StreamFailure.termination(code: -101, hasReceivedVideo: true) == .noDecodedVideo)
        #expect(StreamFailure.termination(code: -1) == .connectionLost)
        #expect(StreamFailure.termination(code: Int32(bitPattern: 0x800E_9302)) == .protectedContent)
        #expect(StreamFailure.termination(code: Int32(bitPattern: 0x800E_9403)) == .frameConversion)
        #expect(StreamFailure.termination(code: 12345, hasReceivedVideo: true) == .unexpected)
    }
}
