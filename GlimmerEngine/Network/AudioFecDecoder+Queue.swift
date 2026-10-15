// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

extension AudioFecDecoder {
    // Borrow the pool without copying shards; the byte loop stays beside GF256 in the engine.
    func recover(_ block: RtpAudioQueue.FecBlock) -> Bool {
        block.dataShards.withUnsafeMutableBufferPointer { data in
            recover(data: data, parity: block.parityShards, marks: block.marks, blockSize: block.blockSize)
        }
    }
}
