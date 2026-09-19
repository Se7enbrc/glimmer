import Foundation
import ForceFeedback
import IOKit

@MainActor
final class HIDGamepadRumble {
    let available: Bool
    private let service: io_service_t
    private var device: FFDeviceObjectReference?
    private var effect: FFEffectObjectReference?
    private var nextAttempt: TimeInterval = 0
    private var playing = false

    init(service: io_service_t) {
        self.service = service
        available = service != 0 && FFIsForceFeedback(service) == FF_OK
    }

    func set(low: UInt16, high: UInt16) {
        guard available else { return }
        let magnitude = UInt32(max(low, high)) * 10000 / 65535
        if magnitude == 0 { stop(); return }
        guard ProcessInfo.processInfo.systemUptime >= nextAttempt else { return }
        if device == nil {
            guard FFCreateDevice(service, &device) == FF_OK, let device else { failed(); return }
            _ = FFDeviceSendForceFeedbackCommand(device, FFCommandFlag(FFSFFC_SETACTUATORSON))
        }
        guard let device else { return }
        var definition = FFEFFECT()
        definition.dwSize = DWORD(MemoryLayout<FFEFFECT>.size)
        definition.dwFlags = DWORD(FFEFF_OBJECTOFFSETS) | DWORD(FFEFF_CARTESIAN)
        definition.dwDuration = UInt32.max
        definition.dwGain = 10000
        definition.dwTriggerButton = UInt32.max
        definition.cAxes = 2
        var axes: [DWORD] = [0, 4]
        var directions: [LONG] = [0, 0]
        var periodic = FFPERIODIC(dwMagnitude: magnitude, lOffset: 0, dwPhase: 0, dwPeriod: 100000)
        definition.cbTypeSpecificParams = DWORD(MemoryLayout<FFPERIODIC>.size)
        // kFFEffectType_Sine_ID is a C macro that Swift cannot import.
        let sineID = CFUUIDGetConstantUUIDWithBytes(nil, 0xE5, 0x59, 0xC4, 0x63, 0xC5, 0xCD, 0x11, 0xD6,
                                                  0x8A, 0x1C, 0x00, 0x03, 0x93, 0x53, 0xBD, 0x00)
        let result = axes.withUnsafeMutableBufferPointer { axisBuffer in
            directions.withUnsafeMutableBufferPointer { directionBuffer in
                withUnsafeMutablePointer(to: &periodic) { parameters in
                    definition.rgdwAxes = axisBuffer.baseAddress
                    definition.rglDirection = directionBuffer.baseAddress
                    definition.lpvTypeSpecificParams = UnsafeMutableRawPointer(parameters)
                    if let effect {
                        return FFEffectSetParameters(effect, &definition, FFEffectParameterFlag(FFEP_TYPESPECIFICPARAMS))
                    }
                    return FFDeviceCreateEffect(device, sineID, &definition, &effect)
                }
            }
        }
        guard result == FF_OK, let effect else { failed(); return }
        if !playing {
            guard FFEffectStart(effect, 1, 0) == FF_OK else { failed(); return }
            playing = true
        }
    }

    func stop() {
        if let effect { _ = FFEffectStop(effect) }
        playing = false
    }

    func close() {
        stop()
        if let effect, let device { _ = FFDeviceReleaseEffect(device, effect) }
        effect = nil
        if let device { _ = FFReleaseDevice(device) }
        device = nil
    }

    private func failed() {
        close()
        nextAttempt = ProcessInfo.processInfo.systemUptime + 1
        Diag.info("HID force feedback failed; retrying on next rumble after 1s", "Controller")
    }
}
