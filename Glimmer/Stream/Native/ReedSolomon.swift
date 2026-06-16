//
//  ReedSolomon.swift
//
//  GF(256) Reed-Solomon erasure decoder for the Swift-native video receive
//  path. Ports nanors (nanors/rs.c) plus the scalar GF math from
//  nanors/deps/obl/oblas_lite.c, reduced to the subset RtpVideoQueue.c actually
//  invokes (erasure DECODE only; never encode, never SIMD).
//
//  Transport ported from moonlight-common-c (GPLv3); see CREDITS.md. The
//  Reed-Solomon algorithm and GF math originate from the nanors project by
//  Joseph Calderon (MIT License, Copyright (c) 2021 Joseph Calderon),
//  including its vendored deps/obl scalar GF(256) routines — notice preserved
//  in CREDITS.md as the MIT license requires.
//
//  WHY pure-Swift instead of vendoring the C: the actual algorithm is rs.c
//  (~190 lines) + a 256-entry GF log/exp/inv table. The rest of nanors
//  (rswrapper.c, oblas_lite.c SIMD multiversioning) exists only for multi-ISA
//  SIMD dispatch we don't need — FEC runs only on packet loss, a few hundred
//  ~1.1KB shards per frame, far below the per-frame budget for scalar GF mul.
//  Keeping it in Swift avoids a new C target / pbxproj C-compile flags / the
//  "clean wipes the C lib" gotcha, and keeps all native code under
//  Glimmer/Stream/Native/ as the task mandates.
//
//  FIELD: GF(2^8) with polynomial 0x11D (285) — the standard AES/QR field.
//  We GENERATE the log/exp/inv tables at first use from the polynomial; this
//  yields byte-identical tables to nanors/deps/obl/gf2_8_tables.h (verified
//  poly 285). gfMul(a,b) = (a==0||b==0) ? 0 : EXP[LOG[a]+LOG[b]] (EXP doubled
//  to length 512 so the sum never needs a modulo).
//
//  MATRIX: a ps×ds Cauchy matrix over GF(256): p[j*ds + i] = INV[(ps + i) ^ j]
//  for parity row j in [0,ps), data col i in [0,ds). This is the EXACT
//  generator from rs.c:98-102 — the single most load-bearing constant. Note the
//  base is (ps + i), NOT (ds + i): using the wrong base makes a non-invertible
//  matrix and decode returns wrong bytes with NO error.

import Foundation

/// GF(2^8) arithmetic tables (poly 0x11D), generated once and shared.
enum GF256 {
    /// log table: LOG[a] = discrete log of a (LOG[0] is unused/255 sentinel).
    static let log: [UInt8] = tables.log
    /// exp table, DOUBLED to length 512 so EXP[LOG[a]+LOG[b]] needs no modulo.
    static let exp: [UInt8] = tables.exp
    /// multiplicative inverse: INV[0]=0, INV[1]=1, INV[a]=a^(254).
    static let inv: [UInt8] = tables.inv

    private static let tables: (log: [UInt8], exp: [UInt8], inv: [UInt8]) = {
        var logT = [UInt8](repeating: 0, count: 256)
        var expT = [UInt8](repeating: 0, count: 512)
        // Generator x = 2 (0x02) is primitive for poly 0x11D.
        var x: Int = 1
        for i in 0..<255 {
            expT[i] = UInt8(x)
            logT[x] = UInt8(i)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        // Double the exp table so indices up to 254+254 = 508 are valid.
        for i in 255..<512 {
            expT[i] = expT[i - 255]
        }
        // LOG[0] is undefined; nanors uses 255 as the sentinel (never indexed
        // for a==0 because gfMul short-circuits on zero). Keep parity.
        logT[0] = 255

        var invT = [UInt8](repeating: 0, count: 256)
        invT[0] = 0
        for a in 1..<256 {
            // a^(-1) = a^(254) = EXP[255 - LOG[a]] in GF(2^8).
            let la = Int(logT[a])
            invT[a] = expT[255 - la]
        }
        return (logT, expT, invT)
    }()

    /// GF(256) multiply.
    @inline(__always)
    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }
}

/// Reed-Solomon erasure decoder over GF(256). One instance per (ds, ps); the
/// Cauchy parity matrix is built at init.
struct ReedSolomon {
    let ds: Int          // data shards
    let ps: Int          // parity shards
    private let matrix: [UInt8]  // ps*ds Cauchy generator

    /// Mirrors reed_solomon_new / reed_solomon_new_static (rs.c:82-105).
    /// Returns nil for invalid geometry (matches the C NULL return).
    init?(dataShards ds: Int, parityShards ps: Int) {
        guard ds > 0, ps > 0, ds + ps <= 255 else { return nil }
        self.ds = ds
        self.ps = ps
        var cauchy = [UInt8](repeating: 0, count: ps * ds)
        for j in 0..<ps {
            for i in 0..<ds {
                // p[j][i] = INV[(ps + i) ^ j]  (rs.c:101)
                cauchy[j * ds + i] = GF256.inv[(ps + i) ^ j]
            }
        }
        self.matrix = cauchy
    }

    // MARK: - GF row ops (rs.c axpy/scal)

    /// a[i] ^= coeff * b[i]  (GF mul-add). coeff==0 → no-op; coeff==1 → XOR.
    @inline(__always)
    private static func axpy(_ a: inout [UInt8], _ aOff: Int,
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

    /// shard a[i] ^= coeff * shard b[i]. Variant operating on the [[UInt8]]
    /// shard array used during the data-shard back-substitution.
    @inline(__always)
    private static func axpyShard(_ a: inout [UInt8], _ b: [UInt8], _ coeff: UInt8, _ k: Int) {
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

    /// a[i] = coeff * a[i]. coeff<2 → no-op (rs.c scal).
    @inline(__always)
    private static func scal(_ a: inout [UInt8], _ off: Int, _ coeff: UInt8, _ k: Int) {
        if coeff < 2 { return }
        let lu = Int(GF256.log[Int(coeff)])
        for i in 0..<k {
            let av = a[off + i]
            if av != 0 {
                a[off + i] = GF256.exp[lu + Int(GF256.log[Int(av)])]
            }
        }
    }

    @inline(__always)
    private static func scalShard(_ a: inout [UInt8], _ coeff: UInt8, _ k: Int) {
        if coeff < 2 { return }
        let lu = Int(GF256.log[Int(coeff)])
        for i in 0..<k {
            let av = a[i]
            if av != 0 {
                a[i] = GF256.exp[lu + Int(GF256.log[Int(av)])]
            }
        }
    }

    // MARK: - Decode (rs.c reed_solomon_decode + invert_mat)

    /// Reconstruct erased DATA shards in place.
    ///
    /// - `shards`: ds+ps buffers, each exactly `bs` bytes (zero-padded for short
    ///   packets). Indices 0..<ds are data, ds..<ds+ps are parity. Erased data
    ///   slots may be any content; this method overwrites them.
    /// - `marks`: length ds+ps; `true` == shard MISSING/erased. Only the first
    ///   ds entries are recovered (parity recovery is never requested).
    /// - `bs`: block size = StreamConfig.packetSize + MAX_RTP_HEADER_SIZE(16).
    ///
    /// Returns `true` on success (erased data shards now valid), `false` if
    /// unrecoverable (fewer present parity shards than gaps). Mirrors rs.c:128.
    func decode(shards: inout [[UInt8]], marks: [Bool], bs: Int) -> Bool {
        let totalShards = ds + ps
        guard shards.count >= totalShards, marks.count >= totalShards else { return false }

        // Collect erased DATA shard indices (rs.c:145-147).
        var erasures = [Int]()
        erasures.reserveCapacity(ds)
        for i in 0..<ds where marks[i] {
            erasures.append(i)
        }
        let gaps = erasures.count
        if gaps == 0 { return true } // nothing to recover

        // colperm: first (ds-gaps) = surviving data indices in order, last gaps
        // = the erased indices (rs.c:148-154).
        var colperm = [Int](repeating: 0, count: ds)
        do {
            var j = 0
            for i in 0..<(ds - gaps) {
                while marks[j] { j += 1 }
                colperm[i] = j
                j += 1
            }
        }
        for i in 0..<gaps {
            colperm[(ds - gaps) + i] = erasures[i]
        }

        // rowperm: for each gap find a PRESENT parity shard (j>=ds, !marks[j]),
        // record its index relative to ds, and seed the erased data slot by
        // copying that parity shard's bytes into it (rs.c:156-166).
        var rowperm = [Int](repeating: 0, count: gaps)
        do {
            var j = ds
            var i = 0
            while i < gaps {
                while j < totalShards && marks[j] { j += 1 }
                if j >= totalShards { break }
                rowperm[i] = j - ds
                // Seed: data[erasures[i]] = data[j]  (load-bearing memcpy)
                shards[erasures[i]] = shards[j]
                i += 1
                j += 1
            }
            if i < gaps {
                // Not enough present parity shards to recover.
                return false
            }
        }

        invertMat(shards: &shards, survBase: ds - gaps, dataCount: ds, shardSize: bs,
                  colPerm: colperm, rowPerm: rowperm)
        return true
    }

    /// invert_mat (rs.c:42-76). Gaussian elimination over GF to solve for the
    /// missing data shards. `survBase` = surviving-data count, `dataCount` = ds,
    /// `shardSize` = bs, `colPerm`/`rowPerm` = the C colperm/rowperm.
    private func invertMat(shards: inout [[UInt8]], survBase: Int, dataCount: Int,
                           shardSize: Int, colPerm: [Int], rowPerm: [Int]) {
        let unknowns = dataCount - survBase   // == gaps

        // (1) Build unknowns×unknowns submatrix `wrk` from p rows=rowPerm, cols
        // = erased (colPerm[survBase..]) (rs.c:46-49).
        var wrk = [UInt8](repeating: 0, count: unknowns * unknowns)
        for i in 0..<unknowns {
            let dr = rowPerm[i] * dataCount
            for j in 0..<unknowns {
                wrk[i * unknowns + j] = matrix[dr + colPerm[survBase + j]]
            }
        }

        // (2) Subtract contribution of the known (surviving) data shards from
        // each seeded unknown shard (rs.c:51-57).
        var col = survBase
        while col < dataCount {
            let dr = rowPerm[col - survBase] * dataCount
            for row in 0..<survBase {
                let coeff = matrix[dr + colPerm[row]]
                if coeff != 0 {
                    var target = shards[colPerm[col]]
                    Self.axpyShard(&target, shards[colPerm[row]], coeff, shardSize)
                    shards[colPerm[col]] = target
                }
            }
            col += 1
        }

        // (3) Gauss-Jordan forward elimination on wrk, applying the same row ops
        // to the unknown data shards (rs.c:58-67).
        for x in 0..<unknowns {
            let pivot = wrk[x * unknowns + x]
            let coeff = GF256.inv[Int(pivot)]
            // C does `scal(wrk + x*W + x, u, W)` which intentionally overruns the
            // logical W×W matrix into harmless adjacent scratch (nanors allocates
            // a larger buffer); we scale only the in-row remainder [x, W) — cols
            // [0, x) are already 0 so this is byte-identical for every value that
            // is ever read, without the out-of-bounds write.
            Self.scal(&wrk, x * unknowns + x, coeff, unknowns - x)
            do {
                var target = shards[colPerm[survBase + x]]
                Self.scalShard(&target, coeff, shardSize)
                shards[colPerm[survBase + x]] = target
            }
            if x + 1 < unknowns {
                for row in (x + 1)..<unknowns {
                    let rowCoeff = wrk[row * unknowns + x]
                    Self.axpy(&wrk, row * unknowns, wrk, x * unknowns, rowCoeff, unknowns)
                    var target = shards[colPerm[survBase + row]]
                    Self.axpyShard(&target, shards[colPerm[survBase + x]], rowCoeff, shardSize)
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
                Self.axpyShard(&target, from, coeff, shardSize)
                shards[colPerm[survBase + row]] = target
            }
            x -= 1
        }
    }
}
