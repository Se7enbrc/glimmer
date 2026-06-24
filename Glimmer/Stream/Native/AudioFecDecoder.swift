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
        // Force-unwrap is safe: geometry and matrix are compile-time constants
        // (ds=4, ps=2, matrix.count == 8 == ps*ds), so this init never returns nil.
        rs = ReedSolomon(matrix: Self.parity,
                         dataShards: Self.dataShards,
                         parityShards: Self.fecShards)!
    }

    /// Reconstruct erased data shards in place; see `ReedSolomon.decode`. `shards`:
    /// 6 buffers of `blockSize` (0..<4 data, 4..<6 parity). `marks`: length 6,
    /// non-zero == missing. Returns false if unrecoverable (too few parity shards).
    func decode(shards: inout [[UInt8]], marks: [UInt8], blockSize: Int) -> Bool {
        rs.decode(shards: &shards, marks: marks.map { $0 != 0 }, bs: blockSize)
    }
}
