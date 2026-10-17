// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

extension AudioFecDecoder {
    /// The fixed audio matrix has at most two erasures. Solve its one/two equations directly into
    /// pooled shards, reusing GF256 arithmetic without the general solver's matrix allocations.
    package func recover(data: UnsafeMutableBufferPointer<[UInt8]>, parity: [[UInt8]],
                         marks: [UInt8], blockSize: Int) -> Bool {
        guard data.count == Self.dataShards, parity.count == Self.fecShards,
              marks.count == Self.totalShards, blockSize >= 0,
              data.allSatisfy({ $0.count >= blockSize }),
              parity.allSatisfy({ $0.count >= blockSize }) else { return false }
        var first = -1
        var second = -1
        for index in 0..<Self.dataShards where marks[index] != 0 {
            if first < 0 { first = index } else if second < 0 { second = index } else { return false }
        }
        guard first >= 0 else { return true }
        let row = marks[Self.dataShards] == 0 ? 0 : 1
        guard marks[Self.dataShards + row] == 0 else { return false }
        let coefficient = Self.parity[row * Self.dataShards + first]
        if second < 0 {
            let inverse = GF256.inv[Int(coefficient)]
            for byte in 0..<blockSize {
                let residual = residual(data: data, parity: parity, marks: marks, row: row, byte: byte)
                data[first][byte] = GF256.mul(residual, inverse)
            }
            return true
        }
        guard marks[Self.dataShards] == 0, marks[Self.dataShards + 1] == 0 else { return false }
        let upperFirst = Self.parity[first], upperSecond = Self.parity[second]
        let lowerFirst = Self.parity[Self.dataShards + first], lowerSecond = Self.parity[Self.dataShards + second]
        let determinant = GF256.mul(upperFirst, lowerSecond) ^ GF256.mul(upperSecond, lowerFirst)
        guard determinant != 0 else { return false }
        let inverse = GF256.inv[Int(determinant)]
        for byte in 0..<blockSize {
            let upper = residual(data: data, parity: parity, marks: marks, row: 0, byte: byte)
            let lower = residual(data: data, parity: parity, marks: marks, row: 1, byte: byte)
            data[first][byte] = GF256.mul(
                GF256.mul(upper, lowerSecond) ^ GF256.mul(lower, upperSecond), inverse)
            data[second][byte] = GF256.mul(
                GF256.mul(lower, upperFirst) ^ GF256.mul(upper, lowerFirst), inverse)
        }
        return true
    }

    @inline(__always)
    private func residual(data: UnsafeMutableBufferPointer<[UInt8]>, parity: [[UInt8]],
                          marks: [UInt8], row: Int, byte: Int) -> UInt8 {
        var value = parity[row][byte]
        for index in 0..<Self.dataShards where marks[index] == 0 {
            value ^= GF256.mul(Self.parity[row * Self.dataShards + index], data[index][byte])
        }
        return value
    }
}
