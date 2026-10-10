//
//  fec.swift
//
//  The Reed-Solomon erasure solver behind video and audio FEC, with the geometry,
//  block size and erasure pattern the PC's packet headers control.
//

/// [data shards][parity shards][block size][erasure bits...][shard bytes...]; a parity
/// count of 0 picks the fixed RS(4,2) audio decoder.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzFec(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    guard size >= 3 else { return 0 }
    let input = UnsafeRawBufferPointer(start: data, count: size)
    let audio = input[1] == 0
    let ds = audio ? AudioFecDecoder.dataShards : Int(input[0])
    let total = audio ? AudioFecDecoder.totalShards : ds + Int(input[1])
    let bs = Int(input[2])
    let markBytes = (total + 7) / 8
    guard size >= 3 + markBytes else { return 0 }
    let marks = (0..<total).map { input[3 + $0 / 8] & (1 << ($0 % 8)) != 0 }
    let body = input[(3 + markBytes)...]
    var shards = (0..<total).map { shard in
        (0..<bs).map { body.isEmpty ? 0 : body[body.startIndex + (shard * bs + $0) % body.count] }
    }
    if audio {
        _ = AudioFecDecoder().decode(shards: &shards, marks: marks.map { $0 ? 1 : 0 }, blockSize: bs)
    } else if let rs = ReedSolomon(dataShards: ds, parityShards: total - ds) {
        _ = rs.decode(shards: &shards, marks: marks, bs: bs)
    }
    precondition(shards.count == total && shards.allSatisfy { $0.count == bs })
    return 0
}
