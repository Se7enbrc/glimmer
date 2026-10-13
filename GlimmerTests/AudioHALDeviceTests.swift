// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import AVFAudio
import AudioToolbox
import CoreAudio
import Testing
@testable import Glimmer

struct AudioHALDeviceTests {
    @Test func currentDeviceCarriesItsRateLatencyAndPreferredLayout() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        var reads: [AudioObjectPropertySelector] = []
        let device = try AudioHALDevice.current(readUInt: { object, selector in
            reads.append(selector)
            #expect(object == (selector == kAudioHardwarePropertyDefaultOutputDevice ? 1 : 42))
            return selector == kAudioHardwarePropertyDefaultOutputDevice ? 42 : 1
        }, readRate: { device in
            #expect(device == 42)
            return 96_000
        }, latency: { device, rate in
            #expect(device == 42 && rate == 96_000)
            return 12.5
        }, preferred: { device in
            #expect(device == 42)
            return layout
        })
        #expect(reads == [kAudioHardwarePropertyDefaultOutputDevice, kAudioDevicePropertyDeviceIsAlive])
        #expect(device.id == 42 && device.rate == 96_000 && device.latencyMs == 12.5)
        #expect(device.channelLayout?.layoutTag == kAudioChannelLayoutTag_Stereo)
    }

    @Test(arguments: [0.0, -1, .infinity, .nan])
    func invalidRatesFailBeforeLatencyOrLayoutReads(rate: Double) {
        #expect(throws: AudioHALOutput.Failure.self) {
            try AudioHALDevice.current(readUInt: { _, _ in 1 }, readRate: { _ in rate }, latency: { _, _ in
                Issue.record("Invalid devices cannot negotiate output latency")
                return 0
            }, preferred: { _ in Issue.record("Invalid devices cannot negotiate a layout"); return nil })
        }
    }

    @Test(arguments: [false, true])
    func missingOrDeadDeviceFailsBeforeGraphSetup(missing: Bool) {
        #expect(throws: AudioHALOutput.Failure.self) {
            try AudioHALDevice.current(readUInt: { _, selector in
                selector == kAudioHardwarePropertyDefaultOutputDevice && !missing ? 42 : 0
            }, readRate: { _ in
                #expect(!missing)
                return 48_000
            }, latency: { _, _ in Issue.record("Dead device queried for latency"); return 0 }, preferred: { _ in nil })
        }
    }

    @Test func unavailableStreamsAndFailedPropertiesPropagateTheirStatus() throws {
        do {
            _ = try AudioHALDevice.outputLatencyMs(device: 42, rate: 48_000,
                                                   streams: { _ in nil }, readUInt: { _, _, _ in 0 })
            Issue.record("A missing stream list must fail")
        } catch let error as AudioHALOutput.Failure {
            #expect(error.status == kAudioHardwareBadStreamError)
        }
        do {
            _ = try AudioHALDevice.outputLatencyMs(device: 42, rate: 48_000, streams: { _ in [] },
                                                   readUInt: { _, _, _ in
                throw AudioHALOutput.Failure(status: kAudioHardwareBadObjectError)
            })
            Issue.record("A failed latency query must propagate")
        } catch let error as AudioHALOutput.Failure {
            #expect(error.status == kAudioHardwareBadObjectError)
        }
        let latency = try AudioHALDevice.outputLatencyMs(device: 42, rate: 96_000,
                                                         streams: { _ in [] }, readUInt: { _, _, _ in 96 })
        #expect(latency == 3)
    }

    @Test func unusualOutputCountsFallBackToMonoOrStereo() {
        for (channels, expected) in [(0, 1), (1, 1), (3, 2), (4, 2), (5, 2), (7, 2), (16, 2)] {
            #expect(AudioHALDevice.outputChannels(source: 8, route: .init(channels: channels)) == expected)
        }
        #expect(AudioHALDevice.layout(channels: 1) == kAudioChannelLayoutTag_Mono)
        #expect(AudioHALDevice.layout(channels: 3) == kAudioChannelLayoutTag_Stereo)
    }

    @Test func preferredLayoutValidatesStorageBeforeReadingDescriptions() {
        for (size, count, status, valid) in [(UInt32(12), UInt32(0), noErr, true),
                                            (12, 1, noErr, false), (12, 0, OSStatus(-1), false)] {
            let layout = AudioHALDevice.preferredLayout(42, dataSize: { device, address, bytes in
                #expect(device == 42)
                #expect(address.mSelector == kAudioDevicePropertyPreferredChannelLayout)
                #expect(address.mScope == kAudioDevicePropertyScopeOutput)
                bytes = size
                return noErr
            }, data: { _, _, bytes, storage in
                #expect(bytes == size)
                let words = storage.bindMemory(to: UInt32.self, capacity: 3)
                words[0] = kAudioChannelLayoutTag_Stereo
                words[1] = 0
                words[2] = count
                return status
            })
            #expect((layout != nil) == valid)
            if valid { #expect(layout?.channelCount == 2) }
        }
        for (size, status) in [(UInt32(8), noErr), (12, OSStatus(-1))] {
            let layout = AudioHALDevice.preferredLayout(42, dataSize: { _, _, bytes in
                bytes = size
                return status
            }, data: { _, _, _, _ in Issue.record("Invalid storage must not be read"); return noErr })
            #expect(layout == nil)
        }
    }

    @Test func propertyReadsUseTheRequestedScopeAndPropagateFailures() throws {
        let value = try AudioHALDevice.read(42, selector: kAudioDevicePropertyLatency,
                                           scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0),
                                           data: { device, address, size, storage in
            #expect(device == 42 && size == 4)
            #expect(address.mSelector == kAudioDevicePropertyLatency)
            #expect(address.mScope == kAudioDevicePropertyScopeOutput)
            storage.storeBytes(of: UInt32(480), as: UInt32.self)
            return noErr
        })
        #expect(value == 480)
        do {
            _ = try AudioHALDevice.read(42, selector: kAudioDevicePropertyLatency, initial: UInt32(0),
                                         data: { _, _, _, _ in kAudioHardwareBadObjectError })
            Issue.record("A HAL property failure must propagate")
        } catch let failure as AudioHALOutput.Failure {
            #expect(failure.status == kAudioHardwareBadObjectError)
        }
    }

    @Test func deviceListenersKeepExactAddressesAndKeysAndRemoveBeforeReplacing() {
        let decoder = MacAudio()
        var added: [(AudioObjectID, AudioObjectPropertyAddress, Int)] = []
        var removed: [Int] = []
        decoder.installDeviceListeners(defaultDevice: { 42 }, streams: { device in
            #expect(device == 42)
            return [71, 72]
        }, add: { object, address, _ in
            let key = added.count + 1
            added.append((object, address, key))
            return (key, noErr)
        })
        #expect(added.count == 16)
        #expect(decoder.deviceListeners.map { $0.2 } == Array(1...16))
        #expect(added.prefix(8).allSatisfy { $0.0 == 42 })
        #expect(added.suffix(8).map { $0.0 } == [71, 71, 71, 71, 72, 72, 72, 72])
        #expect(added.allSatisfy { $0.1.mElement == kAudioObjectPropertyElementMain })
        #expect(added.filter { $0.1.mScope == kAudioDevicePropertyScopeOutput }.count == 5)
        decoder.installDeviceListeners(defaultDevice: { nil }, streams: { _ in
            Issue.record("No device has streams")
            return nil
        }, add: { _, _, _ in
            Issue.record("No device may be observed")
            return (0, noErr)
        }, remove: { object, address, key in
            let original = added[key - 1]
            #expect(object == original.0 && address.mSelector == original.1.mSelector)
            #expect(address.mScope == original.1.mScope)
            removed.append(key)
            return noErr
        })
        #expect(removed == Array(1...16))
        #expect(decoder.deviceListeners.isEmpty)
    }

    @Test func listenerFailuresAreLoggedAndNeverRetainedAsInstalled() {
        let decoder = MacAudio()
        let before = LogStore.shared.snapshot().last?.id ?? 0
        var attempt = 0
        decoder.installDeviceListeners(defaultDevice: { 42 }, streams: { _ in nil }, add: { _, _, _ in
            attempt += 1
            return (attempt, attempt == 1 ? noErr : kAudioHardwareBadObjectError)
        })
        #expect(decoder.deviceListeners.count == 1)
        decoder.removeDeviceListeners { _, _, key in
            #expect(key == 1)
            return kAudioHardwareBadObjectError
        }
        #expect(decoder.deviceListeners.isEmpty)
        let messages = LogStore.shared.snapshot().filter { $0.id > before }.map(\.message)
        #expect(messages.filter { $0 == "audio device listener failed (OSStatus \(kAudioHardwareBadObjectError))" }
            .count == 7)
        #expect(messages.contains("audio device listener remove failed (OSStatus \(kAudioHardwareBadObjectError))"))
    }
}
