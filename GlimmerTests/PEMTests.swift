//
//  PEMTests.swift
//
//  PEM armor parsing and the DER reader and writer the client identity relies on,
//  including truncated, oversized and wrongly shaped input.
//

import Foundation
import Testing
@testable import Glimmer

struct PEMTests {

    // MARK: - Armor

    @Test func derStripsArmorAndJoinsLinesAcrossLineEndings() {
        let bytes: [UInt8] = Array(0..<100)
        let armored = PEM.encode(bytes, label: "CERTIFICATE")
        #expect(PEM.der(armored) == Data(bytes))
        #expect(PEM.der(armored.replacingOccurrences(of: "\n", with: "\r\n")) == Data(bytes))
        #expect(PEM.der(Data(bytes).base64EncodedString()) == Data(bytes))
    }

    @Test func derRejectsEmptyAndNonBase64Bodies() {
        #expect(PEM.der("") == nil)
        #expect(PEM.der("-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n") == nil)
        #expect(PEM.der("-----BEGIN CERTIFICATE-----\n!!not base64!!\n-----END CERTIFICATE-----\n") == nil)
        #expect(PEM.certificate("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n") == nil)
        #expect(PEM.privateKey("garbage") == nil)
    }

    @Test func encodeWrapsAtSixtyFourColumnsUnderTheLabel() {
        let pem = PEM.encode([UInt8](repeating: 0xAB, count: 100), label: "RSA PRIVATE KEY")
        let lines = pem.split(separator: "\n").map(String.init)
        #expect(lines.map(\.count) == [31, 64, 64, 8, 29])
        #expect(lines.first == "-----BEGIN RSA PRIVATE KEY-----")
        #expect(lines.last == "-----END RSA PRIVATE KEY-----")
        #expect(pem.hasSuffix("-----END RSA PRIVATE KEY-----\n"))
    }

    @Test func generatedIdentityRoundTripsAndRejectsGarbage() async throws {
        let identity = try await EphemeralCryptoIdentity.make(bits: 2048)
        _ = try PEM.identity(certPEM: identity.certPEM, keyPEM: identity.keyPEM)
        #expect(throws: StreamError.self) { try PEM.identity(certPEM: "bad", keyPEM: identity.keyPEM) }
        #expect(throws: StreamError.self) { try PEM.identity(certPEM: identity.certPEM, keyPEM: "bad") }
        let key = try #require(PEM.privateKey(identity.keyPEM))
        try PEM.requireStrongRSA(key, context: "test")
    }

    // MARK: - DER reading

    @Test func elementReadsShortAndLongFormLengthsAndAdvances() throws {
        let long = DER.encode(0x04, [UInt8](repeating: 7, count: 300))
        #expect(Array(long.prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
        var index = 0
        let element = try #require(DER.element(long, at: &index))
        #expect(element.tag == 0x04)
        #expect(element.body == 4..<304)
        #expect(index == 304)

        let two: [UInt8] = [0x02, 0x01, 0x05, 0x04, 0x00]
        index = 0
        #expect(DER.element(two, at: &index)?.body == 2..<3)
        #expect(DER.element(two, at: &index)?.tag == 0x04)
        #expect(index == 5)
    }

    @Test func elementRefusesTruncatedOversizedAndIndefiniteInput() {
        let cases: [[UInt8]] = [
            [], [0x30], [0x30, 0x05, 0x01],
            [0x30, 0x81], [0x30, 0x82, 0x01],
            [0x30, 0x80, 0x00, 0x00],
            [0x30, 0x85, 0, 0, 0, 0, 1, 0]
        ]
        for bytes in cases {
            var index = 0
            #expect(DER.element(bytes, at: &index) == nil, "\(bytes)")
        }
        var negative = -1
        #expect(DER.element([0x30, 0x00], at: &negative) == nil)
    }

    @Test func pkcs8UnwrapsToThePkcs1KeyAndRejectsOtherShapes() {
        let key: [UInt8] = [1, 2, 3, 4]
        let algorithm = DER.sequence(DER.rsaEncryption, DER.null)
        let wrapped = DER.sequence(DER.integer(0), algorithm, DER.octetString(key))
        #expect(DER.rsaKey(fromPKCS8: Data(wrapped)) == Data(key))
        #expect(DER.rsaKey(fromPKCS8: Data(DER.sequence(algorithm, DER.integer(0), DER.octetString(key)))) == nil)
        #expect(DER.rsaKey(fromPKCS8: Data(DER.sequence(DER.integer(0), algorithm, DER.integer(5)))) == nil)
        #expect(DER.rsaKey(fromPKCS8: Data(DER.octetString(key))) == nil)
        #expect(DER.rsaKey(fromPKCS8: Data()) == nil)
    }

    @Test func certificatePartsSplitTheSignedBlockFromTheSignatureBits() throws {
        let tbs = DER.sequence(DER.integer(1))
        let algorithm = DER.sequence(DER.sha256WithRSA, DER.null)
        let certificate = DER.sequence(tbs, algorithm, DER.bitString([0xDE, 0xAD]))
        let parts = try #require(DER.certificateParts(Data(certificate)))
        #expect(parts.tbs == Data(tbs))
        #expect(parts.signature == Data([0xDE, 0xAD]))

        #expect(DER.certificateParts(Data(DER.sequence(tbs, algorithm, DER.bitString([1]), DER.null))) == nil)
        #expect(DER.certificateParts(Data(DER.sequence(tbs, algorithm, DER.encode(0x03, [3, 0xDE])))) == nil)
        #expect(DER.certificateParts(Data(DER.sequence(tbs, algorithm, DER.encode(0x03, [0])))) == nil)
        #expect(DER.certificateParts(Data(DER.sequence(tbs, algorithm))) == nil)
    }

    // MARK: - DER writing

    @Test func encodeSwitchesToLongFormAtOneHundredTwentyEightBytes() {
        #expect(DER.encode(0x04, [UInt8](repeating: 0, count: 127)).prefix(2) == [0x04, 0x7F])
        #expect(DER.encode(0x04, [UInt8](repeating: 0, count: 128)).prefix(3) == [0x04, 0x81, 0x80])
        #expect(DER.encode(0x04, [UInt8](repeating: 0, count: 256)).prefix(4) == [0x04, 0x82, 0x01, 0x00])
    }

    @Test func integersUseTheShortestNonNegativeForm() {
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(127) == [0x02, 0x01, 0x7F])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.integer(256) == [0x02, 0x02, 0x01, 0x00])
        #expect(DER.integer(UInt64.max) == [0x02, 0x09, 0x00] + [UInt8](repeating: 0xFF, count: 8))
    }

    @Test func timeIsUTCThroughTheYear2049ThenGeneralized() {
        #expect(DER.time(Date(timeIntervalSince1970: 0)) == [0x17, 13] + Array("700101000000Z".utf8))
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_607_999)) == [0x17, 13] + Array("491231235959Z".utf8))
        #expect(DER.time(Date(timeIntervalSince1970: 2_524_608_000)) == [0x18, 15] + Array("20500101000000Z".utf8))
    }

    @Test func stringsAndSetsWrapTheirBodies() {
        #expect(DER.utf8String("Hi") == [0x0C, 0x02, 0x48, 0x69])
        #expect(DER.set([0x05, 0x00]) == [0x31, 0x02, 0x05, 0x00])
        #expect(DER.bitString([0xFF]) == [0x03, 0x02, 0x00, 0xFF])
    }
}
