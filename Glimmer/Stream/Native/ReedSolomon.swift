// Erasure decoding follows nanors; transport provenance and MIT notices are in CREDITS.md.
// Swift owns the field and Cauchy matrix; arm64 nibble kernels keep shard recovery
// from holding up the receive thread during packet loss.

import Foundation

/// GF(2^8) arithmetic tables (poly 0x11D), generated once and shared.
/// This polynomial matches nanors/deps/obl/gf2_8_tables.h for wire compatibility.
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

    // Cache both nibble tables per coefficient so shard operations allocate no tables.
    static let shardProducts: [UInt8] = {
        var products = [UInt8](repeating: 0, count: 256 * 32)
        for coefficient in 0..<256 {
            for nibble in 0..<16 {
                products[coefficient * 32 + nibble] = mul(UInt8(coefficient), UInt8(nibble))
                products[coefficient * 32 + 16 + nibble] = mul(UInt8(coefficient), UInt8(nibble << 4))
            }
        }
        return products
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
    // Cauchy uses INV[(ps + i) ^ j]; using ds as the base can make it singular.
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

    /// Build from an explicit row-major `m[j*ds + i]` parity matrix (fixed non-Cauchy
    /// profiles, e.g. the audio matrix; see AudioFecDecoder) instead of generating
    /// Cauchy. nil for bad geometry or `matrix.count != ps*ds`.
    init?(matrix: [UInt8], dataShards ds: Int, parityShards ps: Int) {
        guard ds > 0, ps > 0, ds + ps <= 255, matrix.count == ps * ds else { return nil }
        self.ds = ds
        self.ps = ps
        self.matrix = matrix
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
        if coeff == 0 || k == 0 { return }
        a.withUnsafeMutableBufferPointer { target in
            b.withUnsafeBufferPointer { source in
                guard let dst = target.baseAddress, let src = source.baseAddress else { return }
                if coeff == 1 {
                    for i in 0..<k { dst[i] ^= src[i] }
                } else {
                    GF256.shardProducts.withUnsafeBufferPointer { products in
                        guard let base = products.baseAddress else { return }
                        let lo = base + Int(coeff) * 32
                        gl_gf256_mul_add(dst, src, k, lo, lo + 16)
                    }
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
        if coeff < 2 || k == 0 { return }
        a.withUnsafeMutableBufferPointer { target in
            GF256.shardProducts.withUnsafeBufferPointer { products in
                guard let dst = target.baseAddress, let base = products.baseAddress else { return }
                let lo = base + Int(coeff) * 32
                gl_gf256_mul(dst, k, lo, lo + 16)
            }
        }
    }

    // MARK: - In-place shard mutation (copy-on-write avoidance)

    // Clearing the slot gives target sole ownership, avoiding a full shard copy
    // on each multiply-add or scale during loss bursts.

    @inline(__always)
    private static func axpyShardInPlace(_ shards: inout [[UInt8]], _ tIdx: Int,
                                         _ src: [UInt8], _ coeff: UInt8, _ k: Int) {
        var target = shards[tIdx]
        shards[tIdx] = []
        axpyShard(&target, src, coeff, k)
        shards[tIdx] = target
    }

    @inline(__always)
    private static func scalShardInPlace(_ shards: inout [[UInt8]], _ tIdx: Int,
                                         _ coeff: UInt8, _ k: Int) {
        var target = shards[tIdx]
        shards[tIdx] = []
        scalShard(&target, coeff, k)
        shards[tIdx] = target
    }

    // MARK: - Decode (rs.c reed_solomon_decode + invert_mat)

    /// Rebuilds the erased data shards in place (rs.c:128). `shards` holds ds data then ps
    /// parity buffers of `bs` bytes, the block's shard length; `marks[i]` is true when shard
    /// `i` is missing. Returns false when fewer parity shards survive than there are gaps.
    func decode(shards: inout [[UInt8]], marks: [Bool], bs: Int) -> Bool {
        let totalShards = ds + ps
        guard shards.count >= totalShards, marks.count >= totalShards else { return false }
        // GF row ops below index 0..<bs on every shard; reject short shards / a
        // negative bs rather than read out of bounds (don't trust the caller's padding).
        guard bs >= 0, shards.allSatisfy({ $0.count >= bs }) else { return false }

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
                    let src = shards[colPerm[row]]
                    Self.axpyShardInPlace(&shards, colPerm[col], src, coeff, shardSize)
                }
            }
            col += 1
        }

        // (3) Gauss-Jordan forward elimination on wrk, applying the same row ops
        // to the unknown data shards (rs.c:58-67).
        for x in 0..<unknowns {
            let pivot = wrk[x * unknowns + x]
            let coeff = GF256.inv[Int(pivot)]
            // Scale only the row remainder: earlier columns are already zero.
            // The C routine overruns into extra scratch; bounding the write here
            // preserves every value read without needing that extra allocation.
            Self.scal(&wrk, x * unknowns + x, coeff, unknowns - x)
            Self.scalShardInPlace(&shards, colPerm[survBase + x], coeff, shardSize)
            if x + 1 < unknowns {
                let src = shards[colPerm[survBase + x]]
                // Retain only the pivot row so each destination write keeps wrk unique.
                let pivotRow = Array(wrk[x * unknowns..<(x + 1) * unknowns])
                for row in (x + 1)..<unknowns {
                    let rowCoeff = wrk[row * unknowns + x]
                    Self.axpy(&wrk, row * unknowns, pivotRow, 0, rowCoeff, unknowns)
                    Self.axpyShardInPlace(&shards, colPerm[survBase + row], src, rowCoeff, shardSize)
                }
            }
        }

        // (4) Back-substitution (rs.c:68-74).
        var x = unknowns - 1
        while x >= 0 {
            let from = shards[colPerm[survBase + x]]
            for row in 0..<x {
                let coeff = wrk[row * unknowns + x]
                Self.axpyShardInPlace(&shards, colPerm[survBase + row], from, coeff, shardSize)
            }
            x -= 1
        }
    }
}
