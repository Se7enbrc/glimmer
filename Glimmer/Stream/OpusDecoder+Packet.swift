// RFC 6716 Appendix B adds one frame length to each stream except the last.
// Remove that length before giving a stream to AudioToolbox's ordinary Opus decoder.

import Foundation

struct OpusPacket {
    let end: Int
    let lengthField: Range<Int>
    let samplesAt48kHz: Int

    static func parse(_ data: UnsafeRawBufferPointer, at start: Int, selfDelimited: Bool) -> OpusPacket? {
        guard data.indices.contains(start) else { return nil }
        let toc = data[start]
        var cursor = start + 1
        guard let header = readHeader(toc, data: data, cursor: &cursor) else { return nil }
        let (count, cbr, padding) = header
        let samples = count * samplesPerFrame(toc)
        guard count > 0, samples <= 5_760 else { return nil }
        var payload = 0
        if !cbr {
            for _ in 0..<(count - 1) {
                guard let size = readSize(data, cursor: &cursor) else { return nil }
                payload += size
            }
        }
        let lengthStart = cursor
        if selfDelimited {
            guard let size = readSize(data, cursor: &cursor) else { return nil }
            payload += cbr ? size * count : size
        } else {
            let available = data.count - cursor - padding
            guard available >= payload else { return nil }
            if cbr {
                guard available % count == 0, available / count <= 1_275 else { return nil }
            } else {
                guard available - payload <= 1_275 else { return nil }
            }
            payload = available
        }
        let end = cursor + payload + padding
        guard end <= data.count else { return nil }
        return OpusPacket(end: end, lengthField: lengthStart..<cursor, samplesAt48kHz: samples)
    }

    private static func readHeader(_ toc: UInt8, data: UnsafeRawBufferPointer,
                                   cursor: inout Int) -> (count: Int, cbr: Bool, padding: Int)? {
        switch toc & 3 {
        case 0: return (1, true, 0)
        case 1: return (2, true, 0)
        case 2: return (2, false, 0)
        default:
            guard cursor < data.count else { return nil }
            let flags = data[cursor]
            cursor += 1
            let padding: Int
            if flags & 0x40 != 0 {
                guard let bytes = readPadding(data, cursor: &cursor) else { return nil }
                padding = bytes
            } else {
                padding = 0
            }
            return (Int(flags & 0x3F), flags & 0x80 == 0, padding)
        }
    }

    private static func readSize(_ data: UnsafeRawBufferPointer, cursor: inout Int) -> Int? {
        guard cursor < data.count else { return nil }
        let first = Int(data[cursor])
        cursor += 1
        if first < 252 { return first }
        guard cursor < data.count else { return nil }
        let size = first + 4 * Int(data[cursor])
        cursor += 1
        return size
    }

    private static func readPadding(_ data: UnsafeRawBufferPointer, cursor: inout Int) -> Int? {
        var padding = 0
        while cursor < data.count {
            let byte = data[cursor]
            cursor += 1
            padding += byte == 255 ? 254 : Int(byte)
            guard padding <= data.count - cursor else { return nil }
            if byte != 255 { return padding }
        }
        return nil
    }

    private static func samplesPerFrame(_ toc: UInt8) -> Int {
        if toc & 0x80 != 0 { return 120 << Int((toc >> 3) & 3) }
        if toc & 0x60 == 0x60 { return toc & 8 != 0 ? 960 : 480 }
        let shift = Int((toc >> 3) & 3)
        return shift == 3 ? 2_880 : 480 << shift
    }
}
