// AudioToolbox decodes one mono/stereo Opus stream; surround uses several of these.

import AudioToolbox
import Foundation

final class OpusStreamDecoder {
    let channels: Int
    private let samplesPerFrame: Int
    private let converter: AudioConverterRef
    private let input: UnsafeMutableRawPointer
    private let description: UnsafeMutablePointer<AudioStreamPacketDescription>
    private var inputBytes = 0
    private var inputPending = false
    private var toc: UInt8?
    /// The last conversion's result (noErr on success), for the session's first-failure log.
    private(set) var lastStatus: OSStatus = noErr
    private static let inputSpent: OSStatus = 0x6E65_6564 // 'need'

    init?(sampleRate: Int32, channels: Int, samplesPerFrame: Int) {
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
        // Mapping family 0 describes exactly one stream, with no Sunshine pre-skip or gain.
        var cookie = Array("OpusHead".utf8) + [1, UInt8(channels), 0, 0]
        cookie += withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init) + [0, 0, 0]
        guard AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie,
                                        UInt32(cookie.count), &cookie) == noErr else {
            AudioConverterDispose(made)
            return nil
        }
        converter = made
        self.channels = channels
        self.samplesPerFrame = samplesPerFrame
        input = .allocate(byteCount: OpusDecoder.maxPacketBytes, alignment: 16)
        description = .allocate(capacity: 1)
    }

    deinit {
        AudioConverterDispose(converter)
        input.deallocate()
        description.deallocate()
    }

    func decode(_ packet: UnsafeRawBufferPointer?, start: Int, boundary: OpusPacket?,
                into pcm: UnsafeMutablePointer<Float>) -> Int {
        if let packet, let boundary, let base = packet.baseAddress {
            if boundary.lengthField.isEmpty {
                inputBytes = boundary.end - start
                input.copyMemory(from: base + start, byteCount: inputBytes)
            } else {
                let headerBytes = boundary.lengthField.lowerBound - start
                let payloadBytes = boundary.end - boundary.lengthField.upperBound
                input.copyMemory(from: base + start, byteCount: headerBytes)
                input.advanced(by: headerBytes).copyMemory(
                    from: base + boundary.lengthField.upperBound, byteCount: payloadBytes)
                inputBytes = headerBytes + payloadBytes
            }
            toc = packet[start] & 0xFC
        } else {
            guard let toc else { return 0 }
            // An empty frame signals packet loss; a zero-byte packet would end the stream.
            input.storeBytes(of: toc, as: UInt8.self)
            inputBytes = 1
        }
        inputPending = true
        var frames = UInt32(samplesPerFrame)
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(samplesPerFrame * channels * 4), mData: pcm))
        let status = AudioConverterFillComplexBuffer(converter, { _, count, data, packetDescription, context in
            guard let context else { return OpusStreamDecoder.inputSpent }
            let decoder = Unmanaged<OpusStreamDecoder>.fromOpaque(context).takeUnretainedValue()
            return decoder.supplyInput(count, data: data, packetDescription: packetDescription)
        }, Unmanaged.passUnretained(self).toOpaque(), &frames, &output, nil)
        lastStatus = status == Self.inputSpent ? noErr : status
        guard lastStatus == noErr else { return 0 }
        return Int(frames)
    }

    private func supplyInput(_ count: UnsafeMutablePointer<UInt32>, data: UnsafeMutablePointer<AudioBufferList>,
                             packetDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?)
        -> OSStatus {
        guard inputPending else {
            count.pointee = 0
            return Self.inputSpent
        }
        inputPending = false
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels),
                                           mDataByteSize: UInt32(inputBytes), mData: input)
        description.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(inputBytes))
        packetDescription?.pointee = description
        count.pointee = 1
        return noErr
    }
}
