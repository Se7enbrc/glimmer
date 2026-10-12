// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import GlimmerEngine

extension AudioFecDecoder {
    /// The fixed audio matrix has at most two erasures. Solve its one/two equations directly into
    /// pooled shards, reusing GF256 arithmetic without the general solver's matrix allocations.
    func recover(_ block: RtpAudioQueue.FecBlock) -> Bool {
        var first = -1
        var second = -1
        for index in 0..<Self.dataShards where block.marks[index] != 0 {
            if first < 0 { first = index } else if second < 0 { second = index } else { return false }
        }
        guard first >= 0 else { return true }
        let row = block.marks[Self.dataShards] == 0 ? 0 : 1
        guard block.marks[Self.dataShards + row] == 0 else { return false }
        let coefficient = Self.parity[row * Self.dataShards + first]
        if second < 0 {
            let inverse = GF256.inv[Int(coefficient)]
            for byte in 0..<block.blockSize {
                let residual = residual(block, row: row, byte: byte)
                block.dataShards[first][byte] = GF256.mul(residual, inverse)
            }
            return true
        }
        guard block.marks[Self.dataShards] == 0, block.marks[Self.dataShards + 1] == 0 else { return false }
        let upperFirst = Self.parity[first], upperSecond = Self.parity[second]
        let lowerFirst = Self.parity[Self.dataShards + first], lowerSecond = Self.parity[Self.dataShards + second]
        let determinant = GF256.mul(upperFirst, lowerSecond) ^ GF256.mul(upperSecond, lowerFirst)
        guard determinant != 0 else { return false }
        let inverse = GF256.inv[Int(determinant)]
        for byte in 0..<block.blockSize {
            let upper = residual(block, row: 0, byte: byte)
            let lower = residual(block, row: 1, byte: byte)
            block.dataShards[first][byte] = GF256.mul(
                GF256.mul(upper, lowerSecond) ^ GF256.mul(lower, upperSecond), inverse)
            block.dataShards[second][byte] = GF256.mul(
                GF256.mul(lower, upperFirst) ^ GF256.mul(upper, lowerFirst), inverse)
        }
        return true
    }

    private func residual(_ block: RtpAudioQueue.FecBlock, row: Int, byte: Int) -> UInt8 {
        var value = block.parityShards[row][byte]
        for index in 0..<Self.dataShards where block.marks[index] == 0 {
            value ^= GF256.mul(Self.parity[row * Self.dataShards + index], block.dataShards[index][byte])
        }
        return value
    }
}
