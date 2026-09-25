//
//  LogPrivacyTests.swift
//
//  Diag's two renderings (the full line for the viewer and session file, the
//  redacted line LogStore hands os_log) and the launch-response XML redactor.
//

import Foundation
import Testing
@testable import Glimmer

struct DiagMessageTests {

    @Test func plainLiteralRendersOnce() {
        let message: DiagMessage = "stream connected"
        #expect(message.text == "stream connected")
        #expect(message.systemLogText == "stream connected")
    }

    @Test func publicValuesReachBothRenderings() {
        let port = 47_989
        let message: DiagMessage = "RTSP port \(port, privacy: .public) ready"
        #expect(message.text == "RTSP port 47989 ready")
        #expect(message.systemLogText == "RTSP port 47989 ready")
    }

    @Test func defaultPrivacyIsPublic() {
        let codec = "HEVC Main10"
        let message: DiagMessage = "negotiated \(codec) at \(120) Hz"
        #expect(message.text == "negotiated HEVC Main10 at 120 Hz")
        #expect(message.systemLogText == message.text)
    }

    @Test func privateValuesStayOutOfTheSystemLog() {
        let address = "192.0.2.10"
        let message: DiagMessage = "Connecting to \(address, privacy: .private)"
        #expect(message.text == "Connecting to 192.0.2.10")
        #expect(message.systemLogText == "Connecting to <private>")
    }

    @Test func mixedPrivacyRedactsOnlyThePrivateValues() {
        let name = "Tower"
        let address = "192.0.2.10"
        let message: DiagMessage =
            "\(name, privacy: .private) at \(address, privacy: .private):\(48_010) replied in \(12) ms"
        #expect(message.text == "Tower at 192.0.2.10:48010 replied in 12 ms")
        #expect(message.systemLogText == "<private> at <private>:48010 replied in 12 ms")
    }

    @Test func verbatimStringKeepsFormatCharacters() {
        let reason = "50% of %@ lost <b>"
        let open: DiagMessage = "\(reason)"
        let hidden: DiagMessage = "\(reason, privacy: .private)"
        #expect(open.text == reason)
        #expect(open.systemLogText == reason)
        #expect(hidden.text == reason)
        #expect(hidden.systemLogText == "<private>")
    }

    @Test func wrappedLinesKeepEachPiecesPrivacy() {
        let error = "Connection refused"
        let message: DiagMessage = "RTSP failed after \(3) retries: "
            + "\(error, privacy: .private)" + " - giving up"
        #expect(message.text == "RTSP failed after 3 retries: Connection refused - giving up")
        #expect(message.systemLogText == "RTSP failed after 3 retries: <private> - giving up")
        let plain: DiagMessage = "no " + "secrets"
        #expect(plain.systemLogText == "no secrets")
    }

    @Test func nestedMessageKeepsItsPrivateValues() {
        let why: DiagMessage = "decrypt failed: \("bad tag", privacy: .private)"
        let message: DiagMessage = "rejected (\(why)) after \(2) tries"
        #expect(message.text == "rejected (decrypt failed: bad tag) after 2 tries")
        #expect(message.systemLogText == "rejected (decrypt failed: <private>) after 2 tries")
        let plain: DiagMessage = "rejected (\("runt" as DiagMessage))"
        #expect(plain.text == "rejected (runt)")
        #expect(plain.systemLogText == plain.text)
        let whole: DiagMessage = "reason \(plain, privacy: .private)"
        #expect(whole.text == "reason rejected (runt)")
        #expect(whole.systemLogText == "reason <private>")
    }

    @Test func viewerKeepsTheFullText() {
        let marker = UUID().uuidString
        Diag.info("\(marker) at \("192.0.2.10", privacy: .private)", "Tests")
        #expect(LogStore.shared.snapshot().contains { $0.message == "\(marker) at 192.0.2.10" })
    }
}

struct LaunchResponseRedactionTests {

    @Test func sessionURLIsRedactedButItsTagSurvives() throws {
        let body = "<root status_code=\"200\"><sessionUrl0>rtsp://192.0.2.10:48010</sessionUrl0>"
            + "<gcmkey>00112233</gcmkey><gamesession>1</gamesession></root>"
        let dump = NetworkClient.dumpXMLRedacted(try XMLTreeBuilder.parse(data: Data(body.utf8)))
        #expect(dump.contains("<sessionUrl0=<redacted>>"))
        #expect(dump.contains("<gcmkey=<redacted>>"))
        #expect(dump.contains("<gamesession=1>"))
        #expect(!dump.contains("192.0.2.10"))
    }
}
