// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// RFC 6716 section 3 and Appendix B define lengths independently of compressed frame contents.
struct OpusEnvelope {
    var consumed: Int
    var delimiter: Range<Int>
    var duration48k: Int

    static func inspect(_ bytes: UnsafeRawBufferPointer, from start: Int, delimited: Bool) -> Self? {
        guard bytes.count <= 10_208, start >= 0, start < bytes.count else { return nil }
        var reader = FramingCursor(bytes: bytes, position: start + 1)
        let toc = bytes[start]
        let code = toc & 3
        var count = code == 0 ? 1 : 2
        var variable = code == 2
        var padding = 0
        if code == 3 {
            guard let control = reader.byte() else { return nil }
            count = Int(control & 63)
            variable = control & 128 != 0
            guard let amount = control & 64 == 0 ? 0 : reader.padding() else { return nil }
            padding = amount
        }
        let duration = frameDuration(toc) * count
        guard count > 0, duration <= 5_760 else { return nil }
        var explicitBytes = 0
        if variable {
            for _ in 1..<count {
                guard let length = reader.length() else { return nil }
                explicitBytes += length
            }
        }
        let fieldStart = reader.position
        let lastSize: Int
        if delimited {
            guard let length = reader.length() else { return nil }
            lastSize = length
        } else {
            let remaining = bytes.count - reader.position - padding - explicitBytes
            guard remaining >= 0, variable || remaining % count == 0 else { return nil }
            lastSize = variable ? remaining : remaining / count
        }
        guard lastSize <= 1_275 else { return nil }
        let payloadSize = variable ? explicitBytes + lastSize : count * lastSize
        let end = reader.position + payloadSize + padding
        guard end <= bytes.count else { return nil }
        return Self(consumed: end, delimiter: fieldStart..<reader.position, duration48k: duration)
    }

    private static func frameDuration(_ toc: UInt8) -> Int {
        let configuration = Int(toc >> 3)
        if configuration >= 16 { return 120 << (configuration & 3) }
        if configuration >= 12 { return 480 << (configuration & 1) }
        let mode = configuration & 3
        return mode == 3 ? 2_880 : 480 << mode
    }
}

private struct FramingCursor {
    let bytes: UnsafeRawBufferPointer
    var position: Int

    mutating func byte() -> UInt8? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func padding() -> Int? {
        var total = 0
        while let amount = byte() {
            total += amount == 255 ? 254 : Int(amount)
            guard total <= bytes.count else { return nil }
            if amount != 255 { return total }
        }
        return nil
    }

    mutating func length() -> Int? {
        guard let first = byte() else { return nil }
        if first < 252 { return Int(first) }
        guard let second = byte() else { return nil }
        return Int(first) + 4 * Int(second)
    }
}
