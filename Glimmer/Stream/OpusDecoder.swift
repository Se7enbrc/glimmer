//
//  OpusDecoder.swift
//
//  Sunshine's Opus on AudioToolbox's decoder. The layout goes in as an RFC 7845 OpusHead cookie, and a
//  lost packet is marked in-band with an empty frame per stream: a zero-byte packet ends the stream.
//

import AudioToolbox
import Foundation

/// One session's Opus decoder. Not thread-safe: AudioDecoder calls it under its state lock.
final class OpusDecoder {
    let channels: Int
    let samplesPerFrame: Int
    private let streams: Int
    private let converter: AudioConverterRef
    private let input = UnsafeMutableRawPointer.allocate(byteCount: maxPacketBytes, alignment: 16)
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var inputBytes = 0
    private var inputPending = false
    /// The last real packet's TOC with its frame-count code cleared, the template for lost packets.
    private var toc: UInt8?

    /// Room for a full packet from every stream (RFC 6716 caps a frame at 1275 bytes).
    static let maxPacketBytes = 8 * 1_276
    /// What the input callback returns once its one packet is spent.
    private static let inputSpent: OSStatus = 0x6E65_6564   // 'need'

    init?(sampleRate: Int32, channels: Int, streams: Int, coupledStreams: Int,
          mapping: [UInt8], samplesPerFrame: Int) {
        guard sampleRate > 0, (1...8).contains(channels), mapping.count == channels, (1...8).contains(streams),
              (0...streams).contains(coupledStreams), samplesPerFrame > 0 else { return nil }
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&inFormat, &outFormat, &made) == noErr, let made else { return nil }
        var cookie = Self.opusHead(sampleRate: sampleRate, channels: channels, streams: streams,
                                   coupledStreams: coupledStreams, mapping: mapping)
        guard AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie,
                                        UInt32(cookie.count), &cookie) == noErr else {
            AudioConverterDispose(made)
            return nil
        }
        converter = made
        self.channels = channels
        self.streams = streams
        self.samplesPerFrame = samplesPerFrame
    }

    deinit {
        AudioConverterDispose(converter)
        input.deallocate()
        description.deallocate()
    }

    /// Decodes one packet into `pcm` (interleaved, room for `samplesPerFrame` frames), or conceals one lost
    /// frame when `packet` is nil. Returns the frames written: the first packet yields fewer, its encoder
    /// lookahead trimmed once, and a loss before any packet has arrived yields none.
    func decode(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        if let packet {
            guard let base = packet.baseAddress, !packet.isEmpty, packet.count <= Self.maxPacketBytes else { return 0 }
            let first = packet[0]
            if toc == nil { Diag.info("Opus on AudioToolbox, \(Self.mode(first)) frames", "Stream.Audio") }
            toc = first & 0xFC
            input.copyMemory(from: base, byteCount: packet.count)
            inputBytes = packet.count
        } else {
            guard let toc else { return 0 }
            let lost = Self.lostPacket(toc: toc, streams: streams)
            lost.withUnsafeBytes { if let base = $0.baseAddress { input.copyMemory(from: base, byteCount: lost.count) } }
            inputBytes = lost.count
        }
        inputPending = true
        var frames = UInt32(samplesPerFrame)
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(samplesPerFrame * channels * 4), mData: pcm))
        let status = AudioConverterFillComplexBuffer(converter, { _, count, data, packetDescription, context in
            guard let context else { return OpusDecoder.inputSpent }
            let decoder = Unmanaged<OpusDecoder>.fromOpaque(context).takeUnretainedValue()
            guard decoder.inputPending else {
                count.pointee = 0
                return OpusDecoder.inputSpent
            }
            decoder.inputPending = false
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(decoder.channels),
                                                mDataByteSize: UInt32(decoder.inputBytes), mData: decoder.input)
            decoder.description.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(decoder.inputBytes))
            packetDescription?.pointee = decoder.description
            count.pointee = 1
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &frames, &output, nil)
        guard status == noErr || status == Self.inputSpent else { return 0 }
        return Int(frames)
    }

    // MARK: - Wire forms

    /// RFC 7845's identification header: mapping family 0 for one stereo or mono stream, 1 for Sunshine's
    /// multistream surround, no pre-skip (Sunshine sends none) and unity gain.
    static func opusHead(sampleRate: Int32, channels: Int, streams: Int, coupledStreams: Int,
                         mapping: [UInt8]) -> [UInt8] {
        var head = Array("OpusHead".utf8) + [1, UInt8(channels), 0, 0]
        head += withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init) + [0, 0]
        if channels <= 2 && streams == 1 { return head + [0] }
        return head + [1, UInt8(streams), UInt8(coupledStreams)] + mapping
    }

    /// An empty code-0 frame per stream, self-delimited for all but the last: Opus's own way to say
    /// "lost", which the decoder conceals as it would a missing packet.
    static func lostPacket(toc: UInt8, streams: Int) -> [UInt8] {
        Array(repeating: [toc, 0], count: streams - 1).flatMap { $0 } + [toc]
    }

    /// The coding mode a TOC byte names (RFC 6716 section 3.1).
    static func mode(_ toc: UInt8) -> String {
        switch toc >> 3 {
        case 0..<12: "SILK"
        case 12..<16: "hybrid"
        default: "CELT"
        }
    }
}
