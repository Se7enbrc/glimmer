// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

//
//  AudioFecDecoder.swift
//
//  Fixed RS(4,2) erasure decoder for the AUDIO receive path (recovers up to 2 of
//  4 data shards). LOAD-BEARING: audio uses Nvidia's HARDCODED non-Cauchy parity
//  matrix (RtpAudioQueue.c:52-58), NOT the generated Cauchy one - feeding Cauchy
//  here decodes to SILENT GARBAGE (no error). Thin wrapper that pins that matrix,
//  delegating the shared GF(256) solver to ReedSolomon's explicit-matrix init.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

import Foundation

/// Fixed RS(4,2) erasure decoder using Nvidia's hardcoded audio parity matrix.
/// Thin wrapper over `ReedSolomon`, which owns the shared GF(256) erasure solver.
struct AudioFecDecoder {
    static let dataShards = 4
    static let fecShards = 2
    static let totalShards = 6

    /// Nvidia's hardcoded audio parity matrix, 2x4 row-major (RtpAudioQueue.c:57).
    /// m[row * dataShards + col]: row in [0,2) = parity shard, col in [0,4) = data shard.
    private static let parity: [UInt8] = [0x77, 0x40, 0x38, 0x0e,
                                          0xc7, 0xa7, 0x0d, 0x6c]

    private let rs: ReedSolomon

    init() {
        // Geometry and matrix are compile-time constants (ds=4, ps=2,
        // matrix.count == 8 == ps*ds), so this init never returns nil. The guard
        // states that invariant explicitly instead of trapping through a `!`.
        guard let rs = ReedSolomon(matrix: Self.parity,
                                   dataShards: Self.dataShards,
                                   parityShards: Self.fecShards) else {
            preconditionFailure("audio RS(4,2) parity matrix is a compile-time constant "
                + "(2x4, matching dataShards/fecShards) and must always construct")
        }
        self.rs = rs
    }

    /// Reconstruct erased data shards in place; see `ReedSolomon.decode`. `shards`:
    /// 6 buffers of `blockSize` (0..<4 data, 4..<6 parity). `marks`: length 6,
    /// non-zero == missing. Returns false if unrecoverable (too few parity shards).
    func decode(shards: inout [[UInt8]], marks: [UInt8], blockSize: Int) -> Bool {
        rs.decode(shards: &shards, marks: marks.map { $0 != 0 }, bs: blockSize)
    }

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
