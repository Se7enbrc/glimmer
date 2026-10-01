//
//  PEM.swift
//
//  The client identity's PEM files to and from Security types, in memory only, and the slice of
//  DER that takes: bounds-checked reads, and the few encoders a self-signed certificate needs.
//

import Foundation
import Security

enum PEM {

    /// The DER inside a single PEM block, or nil when there is none.
    static func der(_ pem: String) -> Data? {
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
        return der
    }

    /// `der` as a PEM block under `label`, in OpenSSL's 64-column layout.
    static func encode(_ der: [UInt8], label: String) -> String {
        let body = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }

    static func certificate(_ pem: String) -> SecCertificate? {
        der(pem).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    /// An RSA private key from PKCS#8, the form Glimmer and moonlight-qt write, or PKCS#1.
    static func privateKey(_ pem: String) -> SecKey? {
        guard let der = der(pem) else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        return SecKeyCreateWithData((DER.rsaKey(fromPKCS8: der) ?? der) as CFData, attributes as CFDictionary, nil)
    }
}

enum DER {

    // MARK: Reading

    /// One element at `index`, which moves past it; nil when the bytes run out.
    static func element(_ bytes: [UInt8], at index: inout Int) -> (tag: UInt8, body: Range<Int>)? {
        guard index >= 0, bytes.count - index >= 2 else { return nil }
        let tag = bytes[index]
        var length = Int(bytes[index + 1])
        index += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.count - index >= count else { return nil }
            length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard length <= bytes.count - index else { return nil }
        defer { index += length }
        return (tag, index..<(index + length))
    }

    /// The PKCS#1 key inside PKCS#8: SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING key }.
    static func rsaKey(fromPKCS8 der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        guard let outer = element(bytes, at: &index), outer.tag == 0x30 else { return nil }
        index = outer.body.lowerBound
        guard element(bytes, at: &index)?.tag == 0x02, element(bytes, at: &index)?.tag == 0x30,
              let key = element(bytes, at: &index), key.tag == 0x04 else { return nil }
        return Data(bytes[key.body])
    }

    /// A certificate's signed part, header included, and its signatureValue: the BIT STRING's bytes
    /// past its unused-bits count, which is what OpenSSL's X509_get0_signature hands Sunshine.
    static func certificateParts(_ der: Data) -> (tbs: Data, signature: Data)? {
        let bytes = [UInt8](der)
        var index = 0
        guard let outer = element(bytes, at: &index), outer.tag == 0x30 else { return nil }
        index = outer.body.lowerBound
        let tbsStart = index
        guard let tbs = element(bytes, at: &index), tbs.tag == 0x30,
              element(bytes, at: &index)?.tag == 0x30,
              let signature = element(bytes, at: &index), signature.tag == 0x03,
              index == outer.body.upperBound, signature.body.count > 1,
              bytes[signature.body.lowerBound] == 0 else { return nil }
        return (Data(bytes[tbsStart..<tbs.body.upperBound]),
                Data(bytes[(signature.body.lowerBound + 1)..<signature.body.upperBound]))
    }

    // MARK: Writing

    static let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let sha256WithRSA: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let commonName: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
    static let null: [UInt8] = [0x05, 0x00]

    static func encode(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        guard body.count >= 0x80 else { return [tag, UInt8(body.count)] + body }
        let length = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Array($0) }.drop { $0 == 0 }
        return [tag, 0x80 | UInt8(length.count)] + length + body
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] { encode(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { encode(0x31, parts.flatMap { $0 }) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { encode(0x04, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { encode(0x03, [0] + bytes) }
    static func utf8String(_ text: String) -> [UInt8] { encode(0x0C, Array(text.utf8)) }

    /// A non-negative INTEGER in its shortest two's-complement form.
    static func integer(_ value: UInt64) -> [UInt8] {
        var bytes = Array(withUnsafeBytes(of: value.bigEndian) { Array($0) }.drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(0x02, bytes)
    }

    /// UTCTime through 2049 and GeneralizedTime after, the choice X.509 and OpenSSL make.
    static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: formatter.timeZone, from: date).year ?? 0
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return encode(year < 2050 ? 0x17 : 0x18, Array(formatter.string(from: date).utf8))
    }
}
