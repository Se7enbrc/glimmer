//
//  Network+Support.swift
//
//  Supporting types for NetworkClient: the optional-knobs extension on
//  StreamConfig, the URLSession TLS delegate (client credential + server-cert
//  pinning), and the SAX XML tree builder. Split out of Network.swift to keep
//  each unit focused.
//

import Foundation
import Network
import os.log

// MARK: - Optional knobs on StreamConfig
//
// The shared StreamConfig type in Types.swift doesn't yet expose the
// remote-input AES key / IV — they're internal to the launch handshake and
// not something a caller should set. We extend it here with two computed
// Optional<Data> stubs so the launch path has a single, testable seam to
// override the entropy. In production both come back nil and we generate
// fresh randoms.

extension StreamConfig {
    /// Optional override for the AES key used on the remote-input channel.
    /// Tests pin this so they can replay captured launches.
    var remoteInputKey: Data? { nil }
    /// Optional override for the AES IV used on the remote-input channel.
    var remoteInputIV: Data? { nil }
}

// MARK: - URLSession TLS delegate
//
// All of this runs on URLSession's delegate queue — synchronous, non-actor
// context. The delegate is a class (URLSessionDelegate requires it) and
// stores its credentials behind a small lock. We can't make it an actor
// because URLSession won't await us.

final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var clientCredential: URLCredential?
    private var pinnedServerCert: SecCertificate?
    private var lastServerCert: SecCertificate?

    private let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Network.TLS")

    func setClientCredential(_ credential: URLCredential) {
        lock.lock(); defer { lock.unlock() }
        clientCredential = credential
    }

    func setPinnedServerCert(_ cert: SecCertificate) {
        lock.lock(); defer { lock.unlock() }
        pinnedServerCert = cert
    }

    func lastSeenServerCert() -> SecCertificate? {
        lock.lock(); defer { lock.unlock() }
        return lastServerCert
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace

        switch space.authenticationMethod {

        case NSURLAuthenticationMethodClientCertificate:
            // Host is asking us to prove who we are. Hand over the SecIdentity
            // we built from IdentityManager. If it isn't ready yet (very
            // first call before identity prep finished), drop to default —
            // URLSession will cancel and we surface that as a TLS error.
            lock.lock(); let cred = clientCredential; lock.unlock()
            if let cred {
                completionHandler(.useCredential, cred)
            } else {
                log.warning("Client-cert challenge with no credential available")
                completionHandler(.performDefaultHandling, nil)
            }

        case NSURLAuthenticationMethodServerTrust:
            // Threat model (C2):
            //
            //   - pin set, leaf matches:    accept, use credential.
            //   - pin set, leaf mismatches: REFUSE. This is the MITM gate.
            //     We do not log fingerprints at public privacy because that
            //     would let a hostile log scraper read the pinned cert; but
            //     we do log the mismatch so a real cert rotation is
            //     diagnosable from `log show` under our subsystem.
            //   - pin set, no leaf in chain: refuse — handshake is too
            //     broken to evaluate. Better to fail than to fall through
            //     to "accept blindly".
            //   - no pin set, leaf present: this is the unpaired first-
            //     contact path. Sunshine over HTTPS during /pair is the
            //     only path that hits this. We record the leaf so the
            //     actor can pin it after the RSA-validated pairing
            //     handshake — but we DO NOT auto-pin here.
            guard let trust = space.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            let leaf: SecCertificate? = {
                if #available(macOS 12.0, *) {
                    return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
                } else {
                    return SecTrustGetCertificateAtIndex(trust, 0)
                }
            }()

            if let leaf {
                lock.lock(); lastServerCert = leaf; lock.unlock()
            }

            lock.lock(); let pin = pinnedServerCert; lock.unlock()

            if let pin {
                // Pin set — only accept exact match.
                guard let leaf else {
                    log.error("Pinned host returned no leaf cert in chain — refusing")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                let pinData = SecCertificateCopyData(pin) as Data
                let leafData = SecCertificateCopyData(leaf) as Data
                if pinData == leafData {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    log.error("Pinned cert mismatch — refusing TLS handshake (possible MITM or host re-imaged)")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                // No pin yet. This is reachable only on the unpaired
                // discovery path (Pairing.swift's HTTPS pairchallenge
                // round-trip after the symmetric handshake). The cert is
                // recorded into `lastServerCert` but not yet binding;
                // the actor pins it only after the RSA signature in
                // pairing verifies, which is what gives "this is the real
                // host" its meaning.
                completionHandler(.useCredential, URLCredential(trust: trust))
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - XML parser
//
// Builds an in-memory XMLNode tree from raw bytes. We deliberately do this by
// hand on top of XMLParser instead of pulling in SWXMLHash or similar — the
// GameStream protocol is tiny and the dependency cost isn't worth it.

final class XMLTreeBuilder: NSObject, XMLParserDelegate {

    private var rootNode: XMLNode?
    private var stack: [XMLNode] = []
    private var parseError: Error?

    static func parse(data: Data) throws -> XMLNode {
        // Some GFE builds emit a Latin-1 fragment in front of the XML. Skip
        // anything before the first '<' before handing it to XMLParser so we
        // don't trip on stray BOMs.
        let cleaned: Data = {
            if let first = data.firstIndex(of: UInt8(ascii: "<")), first > 0 {
                return data.subdata(in: first..<data.endIndex)
            }
            return data
        }()

        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: cleaned)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw builder.parseError
                ?? parser.parserError
                ?? NSError(domain: "Glimmer.XML", code: -1)
        }

        // Wrap whatever we got into a synthetic document node so callers can
        // descend uniformly. The real Sunshine response IS a single <root>
        // element so this just gives us a parent to hang it off.
        if let root = builder.rootNode {
            return XMLNode(name: "#document", children: [root])
        }
        throw NSError(domain: "Glimmer.XML", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "Empty XML document"])
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        stack.append(XMLNode(name: elementName,
                             text: "",
                             attributes: attributeDict,
                             children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty,
              let decoded = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += decoded
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let finished = stack.popLast() else { return }
        if var parent = stack.popLast() {
            parent.children.append(finished)
            stack.append(parent)
        } else {
            rootNode = finished
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
