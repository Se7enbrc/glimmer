// Independent field arithmetic pins wire compatibility for video and audio FEC.
// Round trips also exercise shard mutation and erasure geometry.

import Testing
@testable import Glimmer

struct ReedSolomonTests {

    private static func referenceMultiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        var multiplicand = UInt16(lhs)
        var multiplier = rhs
        var product: UInt16 = 0
        for _ in 0..<8 {
            if multiplier & 1 != 0 { product ^= multiplicand }
            multiplier >>= 1
            multiplicand <<= 1
            if multiplicand & 0x100 != 0 { multiplicand ^= 0x11D }
        }
        return UInt8(product)
    }

    private static let referenceInverse: [UInt8] = (0..<256).map { value in
        guard value != 0 else { return 0 }
        return (1...255).map { UInt8($0) }.first { referenceMultiply(UInt8(value), $0) == 1 } ?? 0
    }

    @Test func fieldKnownAnswers() {
        #expect(GF256.exp[8] == 0x1D)
        #expect(GF256.mul(0x80, 0x02) == 0x1D)
        #expect(GF256.mul(0x87, 0x02) == 0x13)
        #expect(GF256.inv[2] == 0x8E)
        for lhs in 0..<256 {
            for rhs in 0..<256 {
                #expect(GF256.mul(UInt8(lhs), UInt8(rhs)) == Self.referenceMultiply(UInt8(lhs), UInt8(rhs)))
            }
        }
    }

    @Test func cauchyKnownAnswer() throws {
        let data: [[UInt8]] = [[0, 1, 0x80, 0x87], [0xFF, 2, 0x1D, 0x13], [0x55, 0xAA, 0, 0xFF]]
        let parity: [[UInt8]] = [[0x07, 0xDF, 0x4B, 0xC1], [0xE0, 0xD7, 0x0B, 0xC9]]
        #expect(Self.cauchyParity(data: data, ds: 3, ps: 2, bs: 4) == parity)
        let decoder = try #require(ReedSolomon(dataShards: 3, parityShards: 2))
        var shards = [[UInt8](repeating: 0, count: 4), data[1], [UInt8](repeating: 0, count: 4)] + parity
        #expect(decoder.decode(shards: &shards, marks: [true, false, true, false, false], bs: 4))
        #expect(Array(shards.prefix(3)) == data)
    }

    @Test(arguments: [0, 1, 15, 16, 17, 1408, 1413])
    func decodeEveryCoefficient(bs: Int) throws {
        let data = makeDataShards(ds: 2, bs: bs)
        for value in 0..<256 {
            let coefficient = UInt8(value)
            let matrices: [[UInt8]] = value == 0 ? [[0, 1]] : [[coefficient, 1], [1, coefficient]]
            for matrix in matrices {
                let decoder = try #require(ReedSolomon(matrix: matrix, dataShards: 2, parityShards: 1))
                let parity = (0..<bs).map {
                    Self.referenceMultiply(matrix[0], data[0][$0]) ^ Self.referenceMultiply(matrix[1], data[1][$0])
                }
                var shards = [data[0], [UInt8](repeating: 0xEE, count: bs), parity]
                #expect(decoder.decode(shards: &shards, marks: [false, true, false], bs: bs))
                #expect(Array(shards.prefix(2)) == data)
                #expect(shards[2] == parity)
            }
        }
    }

    @Test(arguments: [1408, 1413])
    func decodeRecoversElevenErasures(bs: Int) throws {
        let ds = 71, ps = 15
        let decoder = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)
        var shards = data + parity
        var marks = [Bool](repeating: false, count: ds + ps)
        for index in [0, 2, 9, 16, 23, 30, 37, 44, 51, 62, 70] {
            shards[index] = [UInt8](repeating: 0xEE, count: bs)
            marks[index] = true
        }
        #expect(decoder.decode(shards: &shards, marks: marks, bs: bs))
        #expect(Array(shards.prefix(ds)) == data)
        #expect(Array(shards.suffix(ps)) == parity)
    }

    // MARK: - GF256 field sanity (the tables are load-bearing constants)

    @Test func gf256MultiplyByZeroAndOne() {
        for a in 0...255 {
            #expect(GF256.mul(UInt8(a), 0) == 0)
            #expect(GF256.mul(0, UInt8(a)) == 0)
            #expect(GF256.mul(UInt8(a), 1) == UInt8(a))
            #expect(GF256.mul(1, UInt8(a)) == UInt8(a))
        }
    }

    @Test func gf256InverseRoundTrip() {
        // a * inv(a) == 1 for every non-zero element.
        for a in 1...255 {
            let inv = GF256.inv[a]
            #expect(GF256.mul(UInt8(a), inv) == 1)
        }
        #expect(GF256.inv[0] == 0)
    }

    @Test func gf256MultiplyIsCommutative() {
        for a in 0...255 {
            for b in stride(from: 0, through: 255, by: 17) {
                #expect(GF256.mul(UInt8(a), UInt8(b)) == GF256.mul(UInt8(b), UInt8(a)))
            }
        }
    }

    // MARK: - Cauchy encode helper (mirrors ReedSolomon.init? p[j][i]=INV[(ps+i)^j])

    /// Compute the `ps` parity shards for `data` (ds shards of `bs` bytes each)
    /// using the exact Cauchy generator the decoder rebuilds internally.
    static func cauchyParity(data: [[UInt8]], ds: Int, ps: Int, bs: Int) -> [[UInt8]] {
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: bs), count: ps)
        for j in 0..<ps {
            for i in 0..<ds {
                let coeff = referenceInverse[(ps + i) ^ j]
                if coeff == 0 { continue }
                for b in 0..<bs {
                    parity[j][b] ^= referenceMultiply(coeff, data[i][b])
                }
            }
        }
        return parity
    }

    private func makeDataShards(ds: Int, bs: Int, seed: UInt8 = 1) -> [[UInt8]] {
        var data = [[UInt8]]()
        for i in 0..<ds {
            var shard = [UInt8](repeating: 0, count: bs)
            for b in 0..<bs {
                shard[b] = UInt8((Int(seed) + i * 31 + b * 7) & 0xFF)
            }
            data.append(shard)
        }
        return data
    }

    // MARK: - init? geometry guards

    @Test func initRejectsInvalidGeometry() {
        #expect(ReedSolomon(dataShards: 0, parityShards: 2) == nil)
        #expect(ReedSolomon(dataShards: 4, parityShards: 0) == nil)
        #expect(ReedSolomon(dataShards: 200, parityShards: 60) == nil) // 260 > 255
        #expect(ReedSolomon(dataShards: 4, parityShards: 2) != nil)
        #expect(ReedSolomon(dataShards: 251, parityShards: 4) != nil)   // 255 exactly
    }

    // MARK: - Video FEC erasure round-trips

    @Test func decodeRecoversSingleErasure() throws {
        let ds = 6, ps = 3, bs = 32
        let rs = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs, seed: 9)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)

        var shards = data + parity
        var marks = [Bool](repeating: false, count: ds + ps)
        // Erase data shard 2.
        shards[2] = [UInt8](repeating: 0, count: bs)
        marks[2] = true

        #expect(rs.decode(shards: &shards, marks: marks, bs: bs) == true)
        #expect(shards[2] == data[2])
    }

    @Test func decodeRecoversMaxErasures() throws {
        let ds = 5, ps = 3, bs = 48
        let rs = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs, seed: 42)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)

        var shards = data + parity
        var marks = [Bool](repeating: false, count: ds + ps)
        // Erase ps=3 data shards (the maximum recoverable).
        for idx in [0, 2, 4] {
            shards[idx] = [UInt8](repeating: 0xEE, count: bs)
            marks[idx] = true
        }

        #expect(rs.decode(shards: &shards, marks: marks, bs: bs) == true)
        for idx in [0, 2, 4] {
            #expect(shards[idx] == data[idx])
        }
    }

    @Test func decodeNoErasuresIsNoop() throws {
        let ds = 4, ps = 2, bs = 16
        let rs = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)
        var shards = data + parity
        let marks = [Bool](repeating: false, count: ds + ps)
        #expect(rs.decode(shards: &shards, marks: marks, bs: bs) == true)
        for i in 0..<ds { #expect(shards[i] == data[i]) }
    }

    @Test func decodeFailsWhenTooManyErasures() throws {
        let ds = 4, ps = 2, bs = 16
        let rs = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)

        var shards = data + parity
        var marks = [Bool](repeating: false, count: ds + ps)
        // Erase 3 data shards but only 2 parity present -> unrecoverable.
        for idx in [0, 1, 2] {
            shards[idx] = [UInt8](repeating: 0, count: bs)
            marks[idx] = true
        }
        #expect(rs.decode(shards: &shards, marks: marks, bs: bs) == false)
    }

    @Test func decodeRecoversWithSomeParityAlsoMissing() throws {
        // 2 data gaps, 1 parity also erased, but 2 parity still present == enough.
        let ds = 5, ps = 3, bs = 24
        let rs = try #require(ReedSolomon(dataShards: ds, parityShards: ps))
        let data = makeDataShards(ds: ds, bs: bs, seed: 3)
        let parity = Self.cauchyParity(data: data, ds: ds, ps: ps, bs: bs)

        var shards = data + parity
        var marks = [Bool](repeating: false, count: ds + ps)
        shards[1] = [UInt8](repeating: 0, count: bs); marks[1] = true
        shards[3] = [UInt8](repeating: 0, count: bs); marks[3] = true
        // Erase one parity shard (index ds+0); 2 parity remain for 2 gaps.
        marks[ds] = true

        #expect(rs.decode(shards: &shards, marks: marks, bs: bs) == true)
        #expect(shards[1] == data[1])
        #expect(shards[3] == data[3])
    }

    // MARK: - Audio FEC (fixed RS(4,2), Nvidia's hardcoded matrix)

    /// Nvidia's hardcoded audio parity matrix, 2x4 row-major (RtpAudioQueue.c:57).
    private static let audioParity: [UInt8] = [0x77, 0x40, 0x38, 0x0e,
                                               0xc7, 0xa7, 0x0d, 0x6c]

    private func audioEncode(data: [[UInt8]], blockSize: Int) -> [[UInt8]] {
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: blockSize), count: 2)
        for row in 0..<2 {
            for col in 0..<4 {
                let coeff = Self.audioParity[row * 4 + col]
                if coeff == 0 { continue }
                for b in 0..<blockSize {
                    parity[row][b] ^= Self.referenceMultiply(coeff, data[col][b])
                }
            }
        }
        return parity
    }

    @Test func audioDecodeRecoversSingleErasure() {
        let bs = 40
        let data = makeDataShards(ds: 4, bs: bs, seed: 5)
        let parity = audioEncode(data: data, blockSize: bs)
        var shards = data + parity
        var marks = [UInt8](repeating: 0, count: 6)
        shards[1] = [UInt8](repeating: 0, count: bs); marks[1] = 1

        let dec = AudioFecDecoder()
        #expect(dec.decode(shards: &shards, marks: marks, blockSize: bs) == true)
        #expect(shards[1] == data[1])
    }

    @Test func audioDecodeRecoversTwoErasures() {
        let bs = 64
        let data = makeDataShards(ds: 4, bs: bs, seed: 11)
        let parity = audioEncode(data: data, blockSize: bs)
        var shards = data + parity
        var marks = [UInt8](repeating: 0, count: 6)
        shards[0] = [UInt8](repeating: 0xAA, count: bs); marks[0] = 1
        shards[3] = [UInt8](repeating: 0xAA, count: bs); marks[3] = 1

        let dec = AudioFecDecoder()
        #expect(dec.decode(shards: &shards, marks: marks, blockSize: bs) == true)
        #expect(shards[0] == data[0])
        #expect(shards[3] == data[3])
    }

    @Test func audioDecodeNoErasuresIsNoop() {
        let bs = 32
        let data = makeDataShards(ds: 4, bs: bs)
        let parity = audioEncode(data: data, blockSize: bs)
        var shards = data + parity
        let marks = [UInt8](repeating: 0, count: 6)
        let dec = AudioFecDecoder()
        #expect(dec.decode(shards: &shards, marks: marks, blockSize: bs) == true)
        for i in 0..<4 { #expect(shards[i] == data[i]) }
    }

    @Test func audioDecodeFailsWithThreeErasures() {
        let bs = 16
        let data = makeDataShards(ds: 4, bs: bs)
        let parity = audioEncode(data: data, blockSize: bs)
        var shards = data + parity
        var marks = [UInt8](repeating: 0, count: 6)
        // 3 data gaps, only 2 parity -> unrecoverable.
        marks[0] = 1; marks[1] = 1; marks[2] = 1
        let dec = AudioFecDecoder()
        #expect(dec.decode(shards: &shards, marks: marks, blockSize: bs) == false)
    }
}
