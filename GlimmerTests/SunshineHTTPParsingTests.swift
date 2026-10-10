//
//  SunshineHTTPParsingTests.swift
//
//  The control channel's offline half: Sunshine's XML replies parsed and checked, the /launch
//  query values, the request helpers, and what the diagnostic dumps redact before logging.
//

import Foundation
import Testing
@testable import Glimmer

struct SunshineHTTPParsingTests {

    private static func xml(_ body: String) throws -> Glimmer.XMLNode {
        try XMLTreeBuilder.parse(data: Data(body.utf8))
    }

    /// A busy Sunshine's /serverinfo, trimmed to the tags the client reads, plus one it must ignore.
    static let busyServerInfo = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>TOWER</hostname><appversion>7.1.431.-1</appversion>
        <GfeVersion>3.23.0.74</GfeVersion><uniqueid>5A3C-host</uniqueid><HttpsPort>47990</HttpsPort>
        <mac>a1:b2:c3:d4:e5:f6</mac><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC>
        <ServerCodecModeSupport>197377</ServerCodecModeSupport><PairStatus>1</PairStatus>
        <currentgame>881448767</currentgame><state>SUNSHINE_SERVER_BUSY</state>
        <PlainCert>-----BEGIN CERTIFICATE-----AAAA</PlainCert></root>
        """

    // MARK: - /serverinfo

    @Test func serverInfoHydratesEveryFieldTheClientUses() async throws {
        let client = NetworkClient(server: ServerInfo(address: "192.0.2.10", uniqueId: "", serverName: ""))
        await client.hydrateServerInfo(from: try Self.xml(Self.busyServerInfo), fetchedOverPaired: false)
        let info = await client.server
        #expect(info.serverName == "TOWER")
        #expect(info.uniqueId == "5A3C-host")
        #expect(info.appVersion == "7.1.431.-1")
        #expect(info.macAddress == "a1:b2:c3:d4:e5:f6")
        #expect(info.httpsPort == 47990)
        #expect(info.maxLumaPixelsHEVC == 1_869_449_984)
        #expect(info.serverCodecModeRaw == 0x30301)
        #expect(info.serverCodecSupport == [.h264, .hevc, .hevcMain10, .av1, .av1Main10])
        #expect(info.isBusy)
        #expect(!info.isRealGFE)
        #expect(info.currentGameID == 881_448_767)
        #expect(info.pairStatus == .unpaired)
        #expect(info.serverCertPEM == nil)
    }

    @Test func aPartialReplyKeepsWhatWasAlreadyKnown() async throws {
        var seed = ServerInfo(address: "192.0.2.10", uniqueId: "5A3C-host", serverName: "TOWER")
        seed.macAddress = "a1:b2:c3:d4:e5:f6"
        seed.currentGameID = 7
        let client = NetworkClient(server: seed)
        let reply = #"<root status_code="200"><hostname></hostname><mac></mac><state>SUNSHINE_SERVER_FREE</state></root>"#
        await client.hydrateServerInfo(from: try Self.xml(reply), fetchedOverPaired: true)
        let info = await client.server
        #expect(info.serverName == "TOWER")
        #expect(info.uniqueId == "5A3C-host")
        #expect(info.macAddress == "a1:b2:c3:d4:e5:f6")
        #expect(info.currentGameID == 7)
        #expect(!info.isBusy)
        #expect(info.pairStatus == .paired)
    }

    @Test func codecModeBitsMapToTheFormatsTheClientOffers() {
        #expect(NetworkClient.decodeCodecMode(0) == [.h264])
        #expect(NetworkClient.decodeCodecMode(1 << 8) == [.h264, .hevc])
        #expect(NetworkClient.decodeCodecMode(1 << 9) == [.h264, .hevcMain10])
        #expect(NetworkClient.decodeCodecMode(1 << 16 | 1 << 17) == [.h264, .av1, .av1Main10])
        // 4:4:4 bits ride only in the raw mask the RTSP stage reads.
        #expect(NetworkClient.decodeCodecMode(0x0004_0000 | 0x0008_0000) == [.h264])
    }

    // MARK: - Status

    @Test func status200Passes() throws {
        try NetworkClient.verifyStatus(try Self.xml(#"<root status_code="200"/>"#))
    }

    @Test func status401ReadsAsUnpaired() throws {
        let error = #expect(throws: StreamError.self) {
            try NetworkClient.verifyStatus(try Self.xml(#"<root status_code="401" status_message="The client is not authorized"/>"#))
        }
        guard case .hostUnreachable(let detail) = error else {
            Issue.record("expected hostUnreachable, got \(String(describing: error))")
            return
        }
        #expect(detail == "Host requires pairing (The client is not authorized)")
    }

    @Test(arguments: [("4294967295", -1), ("503", 503), ("junk", -1), ("-2", -2)])
    func otherStatusesAreRefusalsWithSunshinesMessage(raw: String, code: Int) throws {
        let body = "<root status_code=\"\(raw)\" status_message=\"Busy\"/>"
        let error = #expect(throws: StreamError.self) { try NetworkClient.verifyStatus(try Self.xml(body)) }
        guard case .hostRefused(let message, let refused) = error else {
            Issue.record("expected hostRefused, got \(String(describing: error))")
            return
        }
        #expect(message == "Busy")
        #expect(refused == code)
    }

    @Test func aReplyWithoutRootOrMessageIsStillWorded() throws {
        #expect(throws: StreamError.self) { try NetworkClient.verifyStatus(try Self.xml("<html>proxy</html>")) }
        let error = #expect(throws: StreamError.self) {
            try NetworkClient.verifyStatus(try Self.xml(#"<root status_code="500"/>"#))
        }
        guard case .hostRefused(let message, _) = error else {
            Issue.record("expected hostRefused, got \(String(describing: error))")
            return
        }
        #expect(message == "Status 500")
    }

    // MARK: - XML

    @Test func xmlSkipsLeadingJunkAndReadsCDATA() throws {
        let doc = try XMLTreeBuilder.parse(data: Data("\u{FEFF}junk<root><a> 12 </a><b><![CDATA[x<y]]></b></root>".utf8))
        #expect(doc.name == "#document")
        #expect(doc.int(forChild: "a") == 12)
        #expect(doc.string(forChild: "b") == "x<y")
        #expect(doc.string(forChild: "missing") == nil)
    }

    @Test func xmlFindsNestedAppsAndReadsGameStreamBooleans() throws {
        let doc = try Self.xml("""
            <root><App><AppTitle>Desktop</AppTitle><ID>1</ID><IsHdrSupported>1</IsHdrSupported></App>
            <App><AppTitle>Steam</AppTitle><ID>2</ID><IsHdrSupported>true</IsHdrSupported></App></root>
            """)
        let apps = doc.descendants(named: "App")
        #expect(apps.map { $0.string(forChild: "AppTitle") } == ["Desktop", "Steam"])
        #expect(apps.map { $0.bool(forChild: "IsHdrSupported") } == [true, false])
        #expect(apps[0].bool(forChild: "IsHiddenGame") == nil)
        #expect(apps[1].int(forChild: "AppTitle") == nil)
    }

    @Test(arguments: ["", "no markup at all", "<root><a></root>", "<root>"])
    func malformedXMLIsRefused(body: String) {
        #expect(throws: (any Error).self) { try XMLTreeBuilder.parse(data: Data(body.utf8)) }
    }

    // MARK: - Request helpers

    @Test func hexDecodeTakesTheWireFormAndRefusesAnythingElse() {
        #expect(NetworkClient.hexDecode("00ff10") == Data([0x00, 0xFF, 0x10]))
        #expect(NetworkClient.hexDecode(" 0A0b\n") == Data([0x0A, 0x0B]))
        #expect(NetworkClient.hexDecode("") == Data())
        #expect(NetworkClient.hexDecode("abc") == nil)
        #expect(NetworkClient.hexDecode("zz") == nil)
        #expect(NetworkClient.hexDecode("0x10") == nil)
    }

    @Test func rikeyIDIsTheIVsFirstFourBytesSignedBigEndian() {
        #expect(NetworkClient.bigEndianInt32(from: Data([0x80, 0, 0, 1, 0xAA])) == Int32.min + 1)
        #expect(NetworkClient.bigEndianInt32(from: Data([0x01, 0x02, 0x03, 0x04])) == 0x0102_0304)
        #expect(NetworkClient.bigEndianInt32(from: Data([0xFF, 0xFF, 0xFF])) == 0)
        let slice = Data([0x00, 0x00, 0x12, 0x34, 0x56, 0x78]).dropFirst(2)
        #expect(NetworkClient.bigEndianInt32(from: slice) == 0x1234_5678)
    }

    @Test func eachRequestNonceIsFreshLowercaseHex() {
        let first = NetworkClient.requestNonce()
        #expect(first.count == 32)
        #expect(first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(NetworkClient.requestNonce() != first)
        #expect(NetworkClient.randomBytes(16).count == 16)
    }

    @Test func launchQueryCarriesTheModeKeyAndApp() {
        let config = StreamConfig(width: 2560, height: 1440, fps: 120, bitrateKbps: 50_000)
        let launch = NetworkClient.launchQuery(config: config, riKeyHex: "00112233", riKeyID: -5, appID: 881)
        #expect(launch["mode"] == "2560x1440x120")
        #expect(launch["rikey"] == "00112233")
        #expect(launch["rikeyid"] == "-5")
        #expect(launch["appid"] == "881")
        #expect(launch["additionalStates"] == "1")
        #expect(launch["surroundAudioInfo"] == "\(config.audio.surroundAudioInfo)")
        // /resume names no app: the PC resumes the one it has paused.
        let resume = NetworkClient.launchQuery(config: config, riKeyHex: "00112233", riKeyID: -5, appID: nil)
        #expect(resume["appid"] == nil)
        #expect(Set(launch.keys).subtracting(resume.keys) == ["appid"])
    }

    // MARK: - Redaction

    @Test func everySessionSecretTheProtocolCarriesIsListedAsSensitive() {
        #expect(NetworkClient.sensitiveQueryKeys == [
            "rikey", "rikeyid", "gcmkey", "gcmkeyid", "uuid", "uniqueid", "sessionurl0"
        ])
        let config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        let keys = NetworkClient.launchQuery(config: config, riKeyHex: "00", riKeyID: 0, appID: 1).keys
        #expect(Set(keys.map { $0.lowercased() }).intersection(NetworkClient.sensitiveQueryKeys) == ["rikey", "rikeyid"])
    }

    @Test func redactedDumpHidesSecretsAtAnyDepthAndInAnyCase() throws {
        let secret = "00112233445566778899aabbccddeeff"
        let doc = try Self.xml("""
            <root status_code="200"><GCMKEY>\(secret)</GCMKEY><nested><RiKeyId>\(secret)</RiKeyId>
            <uniqueid>\(secret)</uniqueid></nested><uuid></uuid><gamesession>1</gamesession></root>
            """)
        let dump = NetworkClient.dumpXMLRedacted(doc)
        #expect(!dump.contains(secret))
        #expect(dump.contains("<GCMKEY=<redacted>>"))
        #expect(dump.contains("<RiKeyId=<redacted>>"))
        #expect(dump.contains("<uniqueid=<redacted>>"))
        #expect(dump.contains("<uuid>"))
        #expect(dump.contains("<gamesession=1>"))
        // The unredacted dump is the same walk, values cut at 60 characters.
        let plain = NetworkClient.dumpXML(doc)
        #expect(plain.contains("<GCMKEY=\(secret)>"))
        let long = try Self.xml("<root><note>\(String(repeating: "a", count: 80))</note></root>")
        #expect(NetworkClient.dumpXML(long) == "<root> <note=\(String(repeating: "a", count: 60))>")
    }
}
