// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import VideoToolbox

extension VideoDecoder {
    /// Leave codec threading to VideoToolbox; the optional thread-count hint does not promise ordering.
    nonisolated func configureDecompressionSession(_ session: VTDecompressionSession) {
        #if os(macOS)
        let fields = Self.configureSessionProperties(
            set: { key, value in VTSessionSetProperty(session, key: key, value: value) },
            supported: {
                var dictionary: CFDictionary?
                let status = VTSessionCopySupportedPropertyDictionary(
                    session, supportedPropertyDictionaryOut: &dictionary)
                let keys = (dictionary as? [String: Any]).map { Set($0.keys) }
                return (status, keys)
            },
            read: { Self.readSessionNumber(session, key: $0) })
        Diag.notice("Decoder configuration: \(fields.joined(separator: ","))", "Stream.VideoDecoder")
        TelemetryExporter.recordEvent(fields)
        #else
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        #endif
    }

    #if os(macOS)
    /// Injectable property access keeps configuration coverage independent of hardware availability.
    nonisolated static func configureSessionProperties(
        set: (CFString, CFBoolean) -> OSStatus,
        supported: () -> (OSStatus, Set<String>?),
        read: (CFString) -> (OSStatus, NSNumber?)
    ) -> [String] {
        let (supportStatus, supportedKeys) = supported()
        var fields = ["\"event\":\"decoder_configuration\"", "\"thread_policy\":\"platform_default\"",
                      "\"support_query_status\":\(supportStatus)"]
        let properties: [(name: String, key: CFString, requested: CFBoolean?)] = [
            ("realtime", kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue),
            ("power_efficiency", kVTDecompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse),
            ("thread_count", kVTDecompressionPropertyKey_ThreadCount, nil),
            ("hardware", kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, nil)
        ]
        for property in properties {
            if supportStatus == noErr, let supportedKeys {
                fields.append("\"\(property.name)_supported\":\(supportedKeys.contains(property.key as String))")
            }
            if let requested = property.requested {
                fields.append("\"\(property.name)_requested\":\(CFBooleanGetValue(requested))")
                let status = set(property.key, requested)
                fields.append("\"\(property.name)_set_status\":\(status)")
            }
            let (readStatus, value) = read(property.key)
            fields.append("\"\(property.name)_read_status\":\(readStatus)")
            if readStatus == noErr, let value {
                if property.name == "thread_count" {
                    fields.append("\"thread_count_value\":\(value.int64Value)")
                } else {
                    fields.append("\"\(property.name)_value\":\(value.boolValue)")
                }
            }
        }
        return fields
    }

    /// VT returns a retained CF object through a void pointer; only whitelisted numeric values leave this helper.
    private nonisolated static func readSessionNumber(
        _ session: VTDecompressionSession, key: CFString
    ) -> (OSStatus, NSNumber?) {
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: $0)
        }
        let number = value?.takeRetainedValue() as? NSNumber
        return (status, number)
    }
    #endif
}
