// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import Foundation
import GlimmerEngine
import Testing
@testable import Glimmer

// Session hooks and queued notifications access fixture state only under its lock.
final class AudioSessionFixture: @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var activationFails = false
        var route = IOSAudioSession.Route(label: "Test output", uid: "test-output", sampleRate: 44_100,
                                          channels: 2, latency: 0.02, bufferDuration: 0.01, volume: 0.5)
    }
    let lock = NSLock()
    var state = State()
    let center = NotificationCenter()
    let queue = DispatchQueue(label: "AudioSessionTests.callback")

    func read<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }

    func makeSession(activationFinished: @escaping @Sendable () -> Void = {}) -> IOSAudioSession {
        var calls = IOSAudioSession.Calls()
        calls.configure = { rate in self.read { $0.calls.append("configure:\(Int(rate))") } }
        calls.activate = {
            defer { activationFinished() }
            let fail = self.read { $0.calls.append("activate"); return $0.activationFails }
            if fail { throw AudioOutput.Failure(status: -50) }
        }
        calls.deactivate = { self.read { $0.calls.append("deactivate") } }
        calls.route = { self.read { $0.route } }
        return IOSAudioSession(calls: calls, notifications: center)
    }

    func observe(_ session: IOSAudioSession) {
        session.installRouteListener(queue: queue, id: "test") { _ in self.read { $0.calls.append("route") } }
        session.installDeviceListeners(queue: queue) { _ in self.read { $0.calls.append("device") } }
    }

    func post(_ name: Notification.Name, to session: IOSAudioSession, info: [AnyHashable: Any]? = nil) {
        center.post(name: name, object: nil, userInfo: info)
        session.events.sync {}
        queue.sync {}
    }

    func close(_ session: IOSAudioSession) {
        session.removeRouteListener(id: "test")
        session.removeDeviceListeners()
    }
}

// The engine may invoke output hooks on its route queue; all recordings and fake C handles are lock protected.
final class AudioUnitFixture: @unchecked Sendable {
    struct State {
        var handles: [AudioUnit] = []
        var created: [OSType] = []
        var initialized: [AudioUnit] = []
        var disposed: [AudioUnit] = []
        var stopped: [AudioUnit] = []
        var formats: [AudioStreamBasicDescription] = []
        var callbackContexts: [UnsafeMutableRawPointer?] = []
        var observerContexts: [UnsafeMutableRawPointer?] = []
        var running = true
        var failStart = false
        var failInitialization = false
        var failDisposal = false
        var hardwareRate: Double = 44_100
        var hardwareChannels: UInt32 = 1
    }
    let lock = NSLock()
    var state = State()

    func read<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }

    func calls() -> IOSAudioOutput.Calls {
        var calls = IOSAudioOutput.Calls()
        calls.create = { description in
            try self.read {
                let handle = try #require(AudioUnit(bitPattern: 4096 + $0.handles.count * 16))
                $0.handles.append(handle)
                $0.created.append(description.componentSubType)
                return handle
            }
        }
        calls.set = { _, property, _, _, value, _ in
            self.read {
                if property == kAudioUnitProperty_StreamFormat {
                    $0.formats.append(value.load(as: AudioStreamBasicDescription.self))
                } else if property == kAudioUnitProperty_SetRenderCallback {
                    $0.callbackContexts.append(value.load(as: AURenderCallbackStruct.self).inputProcRefCon)
                }
            }
            return noErr
        }
        calls.get = { _, property, _, _, value, _ in
            self.read {
                switch property {
                case kAudioUnitProperty_StreamFormat:
                    var format = AudioStreamBasicDescription()
                    format.mSampleRate = $0.hardwareRate
                    format.mChannelsPerFrame = $0.hardwareChannels
                    value.storeBytes(of: format, as: AudioStreamBasicDescription.self)
                case kAudioOutputUnitProperty_IsRunning:
                    value.storeBytes(of: UInt32($0.running ? 1 : 0), as: UInt32.self)
                case kAudioUnitProperty_Latency: value.storeBytes(of: Float64(0.001), as: Float64.self)
                case kAudioUnitProperty_MaximumFramesPerSlice: value.storeBytes(of: UInt32(4096), as: UInt32.self)
                default: value.storeBytes(of: UInt32(1), as: UInt32.self)
                }
            }
            return noErr
        }
        calls.parameter = { _, _, _, _, _, _ in noErr }
        calls.observe = { _, _, context in self.read { $0.observerContexts.append(context) }; return noErr }
        calls.initialize = { unit in
            self.read { $0.initialized.append(unit); return $0.failInitialization ? -50 : noErr }
        }
        calls.start = { _ in
            self.read { $0.running = !$0.failStart; return $0.failStart ? -50 : noErr }
        }
        calls.stop = { unit in self.read { $0.stopped.append(unit) }; return noErr }
        calls.uninitialize = { _ in noErr }
        calls.dispose = { unit in
            self.read { $0.disposed.append(unit); return $0.failDisposal ? -50 : noErr }
        }
        return calls
    }
}
