// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Synchronization

// Owned by one OpusDecoder under AudioDecoder's state lock, never by the render callback.
final class NativeOpusLane {
    let width: Int
    let output: AVAudioPCMBuffer
    private let rate: Int32
    private var converter: AVAudioConverter
    private var packetSource: OpusConversionInput
    private(set) var framesPerPacket: Int

    init?(rate: Int32, width: Int, capacity: Int) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                         channels: AVAudioChannelCount(width), interleaved: true),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
              let (converter, source) = Self.decoder(rate: rate, width: width, frames: capacity, to: format) else {
            return nil
        }
        self.width = width
        self.rate = rate
        self.output = output
        self.converter = converter
        packetSource = source
        framesPerPacket = capacity
    }

    // Apple's Opus decoder emits its format's frames per packet, whatever the packet holds,
    // so the declared size must follow the stream's real packet duration.
    private static func decoder(rate: Int32, width: Int, frames: Int,
                                to format: AVAudioFormat) -> (AVAudioConverter, OpusConversionInput)? {
        var source = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(width), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &source),
              let converter = AVAudioConverter(from: input, to: format) else { return nil }
        converter.primeMethod = .none
        return (converter, OpusConversionInput(format: input))
    }

    func convert(_ bytes: UnsafeRawBufferPointer?, span: Range<Int>, removing: Range<Int>, frames: Int) -> Int? {
        if frames != framesPerPacket {
            guard let (replacement, source) = Self.decoder(rate: rate, width: width, frames: frames,
                                                           to: output.format) else { return nil }
            converter = replacement
            packetSource = source
            framesPerPacket = frames
        }
        guard packetSource.prepare(bytes, span: span, removing: removing, frames: frames) else { return nil }
        output.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [packetSource] _, state in
            packetSource.take(status: state)
        }
        guard status != .error, error == nil else { return nil }
        return Int(output.frameLength)
    }

    func reset() { converter.reset() }
}

// AudioDecoder's state lock serializes preparation and synchronous conversion.
// The buffer stays immutable until conversion returns; callbacks only read it.
// An atomic claim permits exactly one callback to supply each prepared packet.
private final class OpusConversionInput: @unchecked Sendable {
    private let compressed: AVAudioCompressedBuffer
    private let available = Atomic<Bool>(false)

    init(format: AVAudioFormat) {
        compressed = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 10_208)
    }

    func prepare(_ bytes: UnsafeRawBufferPointer?, span: Range<Int>, removing: Range<Int>, frames: Int) -> Bool {
        let size = span.count - removing.count
        if let bytes {
            guard let source = bytes.baseAddress else { return false }
            compressed.data.copyMemory(from: source.advanced(by: span.lowerBound),
                                       byteCount: removing.lowerBound - span.lowerBound)
            compressed.data.advanced(by: removing.lowerBound - span.lowerBound).copyMemory(
                from: source.advanced(by: removing.upperBound), byteCount: span.upperBound - removing.upperBound)
        }
        compressed.byteLength = UInt32(size)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: UInt32(frames), mDataByteSize: UInt32(size))
        available.store(true, ordering: .releasing)
        return true
    }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard available.exchange(false, ordering: .acquiring) else {
            status.pointee = .noDataNow
            return nil
        }
        status.pointee = .haveData
        return compressed
    }
}
