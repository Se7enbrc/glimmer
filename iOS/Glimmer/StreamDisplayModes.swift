// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

enum StreamDisplayModes {
    static let bundled: [StreamFormat] = {
        guard let url = Bundle.main.url(forResource: "iphone-ipad", withExtension: "xml"),
              let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }()

    static func parse(_ data: Data) -> [StreamFormat] {
        let reader = DisplayModeReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.valid, !reader.modes.isEmpty, reader.modes.count <= 90,
              Set(reader.modes).count == reader.modes.count else { return [] }
        return reader.modes
    }

    static func closest(to size: CGSize, maximumFPS: Int) -> StreamFormat? {
        let aspect = size.width / size.height
        return bundled.filter { $0.fps <= maximumFPS }.min { left, right in
            func rank(_ mode: StreamFormat) -> (Double, Double, Int) {
                let ratio = (Double(mode.width) / Double(mode.height)) / aspect
                let cropped = 1 - min(ratio, 1 / ratio)
                let widthError = abs(log(Double(mode.width) / size.width))
                let heightError = abs(log(Double(mode.height) / size.height))
                // A tiny aspect gain must not turn a small window into a full-panel decode request.
                return (max(widthError, heightError), cropped, -mode.fps)
            }
            return rank(left) < rank(right)
        }
    }
}

private final class DisplayModeReader: NSObject, XMLParserDelegate {
    var modes: [StreamFormat] = []
    var valid = true
    private var path: [String] = []
    private var text = ""
    private var width = 0
    private var height = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        path.append(elementName)
        text = ""
        if elementName == "resolution" { width = 0; height = 0 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { path.removeLast(); text = "" }
        guard path.dropLast() == ["vdd_settings", "resolutions", "resolution"] else { return }
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            valid = false
            return
        }
        switch elementName {
        case "width": width = value
        case "height": height = value
        case "refresh_rate":
            guard StreamSizeBounds.width.contains(width), StreamSizeBounds.height.contains(height),
                  width.isMultiple(of: 2), height.isMultiple(of: 2), [60, 120].contains(value) else {
                valid = false
                return
            }
            modes.append(StreamFormat(width: width, height: height, fps: value))
        default: valid = false
        }
    }
}
