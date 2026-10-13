// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AudioToolbox
import GlimmerEngine

extension IOSAudioOutput {
    func makeUnit(type: OSType, subtype: OSType) throws -> AudioUnit {
        let description = AudioComponentDescription(componentType: type, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let unit = try calls.create(description)
        units.append(unit)
        return unit
    }

    func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                scope: AudioUnitScope = kAudioUnitScope_Global, value: T) throws {
        var value = value
        try withUnsafePointer(to: &value) {
            try check(calls.set(unit, property, scope, 0, $0, UInt32(MemoryLayout<T>.size)))
        }
    }

    func read<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                 scope: AudioUnitScope = kAudioUnitScope_Global, initial: T) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { try check(calls.get(unit, property, scope, 0, $0, &size)) }
        return value
    }

    func setFormat(_ unit: AudioUnit, scope: AudioUnitScope, rate: Double, channels: UInt32) throws {
        let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
        try set(unit, kAudioUnitProperty_StreamFormat, scope: scope, value: format)
    }

    func connect(_ source: AudioUnit, to destination: AudioUnit) throws {
        let connection = AudioUnitConnection(sourceAudioUnit: source, sourceOutputNumber: 0, destInputNumber: 0)
        try set(destination, kAudioUnitProperty_MakeConnection, scope: kAudioUnitScope_Input, value: connection)
    }

    func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioOutput.Failure(status: status) }
    }
}
