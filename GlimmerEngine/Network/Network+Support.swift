// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation
import os.log

// Tests can pin launch entropy; production always generates fresh input-channel key material.

extension StreamRequest {
    /// Optional override for the AES key used on the remote-input channel.
    /// Tests pin this so they can replay captured launches.
    var remoteInputKey: Data? { nil }
    /// Optional override for the AES IV used on the remote-input channel.
    var remoteInputIV: Data? { nil }
}

// MARK: - XML parser

// Sunshine needs only this small XML tree, so no general parser dependency is warranted.

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
