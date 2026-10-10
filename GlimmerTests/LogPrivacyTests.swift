// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  LogPrivacyTests.swift
//
//  Diag's two renderings (the full line for the viewer, the redacted line for os_log
//  and the session file), telemetry's name pseudonyms, and the launch-response redactor.
//

import CryptoKit
import Foundation
import Testing
@testable import Glimmer

struct ObjectiveCExceptionGuardTests {
    @Test func successfulOperationReturnsTrue() {
        var ran = false
        #expect(gl_objc_try { ran = true })
        #expect(ran)
    }

    @Test func exceptionReturnsFalse() {
        #expect(!gl_objc_try {
            NSException(name: .invalidArgumentException, reason: "private test payload", userInfo: nil).raise()
        })
    }
}

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

    /// The viewer shows the address; Copy, which people paste into issues, doesn't.
    @Test func copiedLinesAreRedacted() throws {
        let marker = UUID().uuidString
        Diag.info("\(marker) at \("192.0.2.10", privacy: .private)", "Tests")
        Diag.info("\(marker) plain", "Tests")
        let entries = LogStore.shared.snapshot().filter { $0.message.hasPrefix(marker) }
        let addressed = try #require(entries.first { $0.message.hasSuffix("192.0.2.10") })
        #expect(addressed.shareable.hasSuffix("\(marker) at <private>"))
        #expect(addressed.plain.hasSuffix("\(marker) at 192.0.2.10"))
        let plain = try #require(entries.first { $0.message.hasSuffix("plain") })
        #expect(plain.redactedMessage == nil && plain.shareable == plain.plain)
    }
}

struct SessionFilePrivacyTests {

    @Test func privateValuesNeverReachTheSessionFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = UUID().uuidString
        SessionLogFileSink.startIfEnabled(enabled: true, directory: dir)
        Diag.notice("\(marker) connecting to \("192.0.2.10", privacy: .private)", "Tests")
        SessionLogFileSink.stop()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(text.contains("\(marker) connecting to <private>"))
        #expect(!text.contains("192.0.2.10"))
        #expect(LogStore.shared.snapshot().contains { $0.message == "\(marker) connecting to 192.0.2.10" })
    }
}

struct TelemetryPseudonymTests {

    @Test func namesBecomeStableSaltedCodes() {
        let salt = SymmetricKey(size: .bits256)
        let code = TelemetryRenderer.pseudonym("Den PC", salt: salt)
        #expect(code.count == 8)
        #expect(code.filter(\.isHexDigit).count == 8)
        #expect(TelemetryRenderer.pseudonym("Den PC", salt: salt) == code)
        #expect(TelemetryRenderer.pseudonym("Office PC", salt: salt) != code)
        #expect(TelemetryRenderer.pseudonym("Den PC", salt: SymmetricKey(size: .bits256)) != code)
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
