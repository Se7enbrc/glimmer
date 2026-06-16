//
//  AudioFecDecoder.swift
//
//  Fixed-geometry Reed-Solomon RS(4,2) ERASURE decoder for the Swift-native
//  AUDIO receive path. Recovers up to 2 lost data shards from a 4-data + 2-parity
//  FEC block (recovers iff >= 4 of the 6 shards are present).
//
//  WHY A SEPARATE DECODER (and not ReedSolomon.swift):
//  ReedSolomon.swift builds a GENERATED Cauchy parity matrix `INV[(ps+i)^j]`,
//  which is correct for the VIDEO FEC. AUDIO does NOT use that matrix. For
//  reasons documented in RtpAudioQueue.c:52-58, Nvidia's audio FEC uses a
//  DIFFERENT, HARDCODED parity matrix (the one OpenFEC generates):
//      { 0x77, 0x40, 0x38, 0x0e, 0xc7, 0xa7, 0x0d, 0x6c }
//  laid out 2x4 row-major (ps=2 rows, ds=4 cols):
//      row0 = [0x77, 0x40, 0x38, 0x0e]   (parity shard 0)
//      row1 = [0xc7, 0xa7, 0x0d, 0x6c]   (parity shard 1)
//  Using the Cauchy matrix here would decode to SILENT GARBAGE (no error). So we
//  keep a dedicated decoder that hardcodes this matrix and reuses ONLY
//  `enum GF256` (mul / log / exp / inv tables, poly 0x11D) from ReedSolomon.swift.
//
//  Ports nanors reed_solomon_decode + invert_mat (rs.c:42-76, 128-170) reduced to
//  the constant (ds=4, ps=2) audio case, scalar GF only.
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md.

import Foundation

/// Fixed RS(4,2) erasure decoder using Nvidia's hardcoded audio parity matrix.
/// Reuses `GF256` (from ReedSolomon.swift) for all field arithmetic.
struct AudioFecDecoder {
    static let dataShards = 4
    static let fecShards = 2
    static let totalShards = 6

    /// Nvidia's hardcoded audio parity matrix, 2x4 row-major (RtpAudioQueue.c:57).
    /// p[row * dataShards + col]: row in [0,2) = parity shard, col in [0,4) = data shard.
    private static let parity: [UInt8] = [0x77, 0x40, 0x38, 0x0e,
                                          0xc7, 0xa7, 0x0d, 0x6c]

    // MARK: - GF row ops (rs.c axpy / scal, scalar OBLAS_TINY path)

    /// a[i] ^= coeff * b[i]  (GF mul-add). coeff==0 → no-op; coeff==1 → XOR.
    @inline(__always)
    private static func axpy(_ a: inout [UInt8], _ b: [UInt8], _ coeff: UInt8, _ k: Int) {
        if coeff == 0 { return }
        if coeff == 1 {
            for i in 0..<k { a[i] ^= b[i] }
        } else {
            let lu = Int(GF256.log[Int(coeff)])
            for i in 0..<k {
                let bv = b[i]
                if bv != 0 {
                    a[i] ^= GF256.exp[lu + Int(GF256.log[Int(bv)])]
                }
            }
        }
    }

    /// a[i] = coeff * a[i]. coeff < 2 → no-op (rs.c scal).
    @inline(__always)
    private static func scal(_ a: inout [UInt8], _ coeff: UInt8, _ k: Int) {
        if coeff < 2 { return }
        let lu = Int(GF256.log[Int(coeff)])
        for i in 0..<k {
            let av = a[i]
            if av != 0 {
                a[i] = GF256.exp[lu + Int(GF256.log[Int(av)])]
            }
        }
    }

    /// Matrix-element variant for the small unknowns×unknowns work matrix.
    @inline(__always)
    private static func axpyRange(_ a: inout [UInt8], _ aOff: Int,
                                  _ b: [UInt8], _ bOff: Int, _ coeff: UInt8, _ k: Int) {
        if coeff == 0 { return }
        if coeff == 1 {
            for i in 0..<k { a[aOff + i] ^= b[bOff + i] }
        } else {
            let lu = Int(GF256.log[Int(coeff)])
            for i in 0..<k {
                let bv = b[bOff + i]
                if bv != 0 {
                    a[aOff + i] ^= GF256.exp[lu + Int(GF256.log[Int(bv)])]
                }
            }
        }
    }

    @inline(__always)
    private static func scalRange(_ a: inout [UInt8], _ off: Int, _ coeff: UInt8, _ k: Int) {
        if coeff < 2 { return }
        let lu = Int(GF256.log[Int(coeff)])
        for i in 0..<k {
            let av = a[off + i]
            if av != 0 {
                a[off + i] = GF256.exp[lu + Int(GF256.log[Int(av)])]
            }
        }
    }

    // MARK: - Decode (rs.c reed_solomon_decode + invert_mat)

    /// Reconstruct erased DATA shards in place.
    ///
    /// - `shards`: exactly 6 buffers, each `blockSize` bytes. Indices 0..<4 are
    ///   data shards (the opus payload bytes, header-stripped), 4..<6 are the two
    ///   parity shards. Erased data slots may contain any content; this method
    ///   overwrites them with the recovered bytes.
    /// - `marks`: length 6; non-zero == shard MISSING/erased (matches the C
    ///   `block->marks` array, 1 == missing). Only the 4 data slots are recovered;
    ///   parity recovery is never requested.
    /// - `blockSize`: bytes per shard.
    ///
    /// Returns `true` on success (erased data shards now valid), `false` if
    /// unrecoverable (fewer present parity shards than gaps). Mirrors rs.c:128-170.
    func decode(shards: inout [[UInt8]], marks: [UInt8], blockSize: Int) -> Bool {
        let ds = Self.dataShards
        let total = Self.totalShards
        guard shards.count >= total, marks.count >= total else { return false }

        // Collect erased DATA shard indices (rs.c:145-147).
        var erasures = [Int]()
        erasures.reserveCapacity(ds)
        for i in 0..<ds where marks[i] != 0 {
            erasures.append(i)
        }
        let gaps = erasures.count
        if gaps == 0 { return true } // all data shards present; nothing to recover

        // colperm: first (ds-gaps) = surviving data indices in order, last gaps =
        // the erased indices (rs.c:148-154).
        var colperm = [Int](repeating: 0, count: ds)
        do {
            var j = 0
            for i in 0..<(ds - gaps) {
                while marks[j] != 0 { j += 1 }
                colperm[i] = j
                j += 1
            }
        }
        for i in 0..<gaps {
            colperm[(ds - gaps) + i] = erasures[i]
        }

        // rowperm: for each gap find a PRESENT parity shard (j>=ds, marks[j]==0),
        // record its index relative to ds, and seed the erased data slot by
        // copying that parity shard's bytes into it (rs.c:156-166).
        var rowperm = [Int](repeating: 0, count: gaps)
        do {
            var j = ds
            var i = 0
            while i < gaps {
                while j < total && marks[j] != 0 { j += 1 }
                if j >= total { break }
                rowperm[i] = j - ds
                // Seed: data[erasures[i]] = data[j]  (load-bearing copy).
                shards[erasures[i]] = shards[j]
                i += 1
                j += 1
            }
            if i < gaps {
                // Not enough present parity shards to recover.
                return false
            }
        }

        invertMat(shards: &shards, survBase: ds - gaps, dataCount: ds,
                  shardSize: blockSize, colPerm: colperm, rowPerm: rowperm)
        return true
    }

    /// invert_mat (rs.c:42-76). Gaussian elimination over GF(256) to solve for the
    /// missing data shards. `survBase` = surviving-data count, `dataCount` = ds=4,
    /// `shardSize` = blockSize, `colPerm`/`rowPerm` = the C colperm/rowperm.
    private func invertMat(shards: inout [[UInt8]], survBase: Int, dataCount: Int,
                           shardSize: Int, colPerm: [Int], rowPerm: [Int]) {
        let parityMatrix = Self.parity
        let unknowns = dataCount - survBase   // == gaps

        // (1) Build unknowns×unknowns submatrix `wrk` from p rows=rowPerm, cols =
        // erased columns (colPerm[survBase..]) (rs.c:46-49).
        var wrk = [UInt8](repeating: 0, count: unknowns * unknowns)
        for i in 0..<unknowns {
            let dr = rowPerm[i] * dataCount
            for j in 0..<unknowns {
                wrk[i * unknowns + j] = parityMatrix[dr + colPerm[survBase + j]]
            }
        }

        // (2) Subtract contribution of the known (surviving) data shards from each
        // seeded unknown shard (rs.c:51-57).
        var col = survBase
        while col < dataCount {
            let dr = rowPerm[col - survBase] * dataCount
            for row in 0..<survBase {
                let coeff = parityMatrix[dr + colPerm[row]]
                if coeff != 0 {
                    var target = shards[colPerm[col]]
                    Self.axpy(&target, shards[colPerm[row]], coeff, shardSize)
                    shards[colPerm[col]] = target
                }
            }
            col += 1
        }

        // (3) Gauss-Jordan forward elimination on wrk, applying the same row ops to
        // the unknown data shards (rs.c:58-67).
        for x in 0..<unknowns {
            let pivot = wrk[x * unknowns + x]
            let coeff = GF256.inv[Int(pivot)]
            // Scale only the in-row remainder [x, unknowns); cols [0, x) are
            // already 0 so this is byte-identical to the C (which intentionally
            // overruns into harmless scratch), without an out-of-bounds write.
            Self.scalRange(&wrk, x * unknowns + x, coeff, unknowns - x)
            do {
                var target = shards[colPerm[survBase + x]]
                Self.scal(&target, coeff, shardSize)
                shards[colPerm[survBase + x]] = target
            }
            if x + 1 < unknowns {
                for row in (x + 1)..<unknowns {
                    let rowCoeff = wrk[row * unknowns + x]
                    Self.axpyRange(&wrk, row * unknowns, wrk, x * unknowns, rowCoeff, unknowns)
                    var target = shards[colPerm[survBase + row]]
                    Self.axpy(&target, shards[colPerm[survBase + x]], rowCoeff, shardSize)
                    shards[colPerm[survBase + row]] = target
                }
            }
        }

        // (4) Back-substitution (rs.c:68-74).
        var x = unknowns - 1
        while x >= 0 {
            let from = shards[colPerm[survBase + x]]
            for row in 0..<x {
                let coeff = wrk[row * unknowns + x]
                var target = shards[colPerm[survBase + row]]
                Self.axpy(&target, from, coeff, shardSize)
                shards[colPerm[survBase + row]] = target
            }
            x -= 1
        }
    }
}
