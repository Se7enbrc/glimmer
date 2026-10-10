// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  Shims.swift
//
//  Inert Linux stand-ins for the app's logging and telemetry, which need `os`,
//  so the parsers under test compile unchanged. Plus the stream harnesses' framing.
//

import Foundation

/// Splits a fuzz input into datagrams: [clock step][length, 2 bytes BE][bytes].
func datagrams(_ input: UnsafeRawBufferPointer) -> [(stepUs: UInt64, bytes: [UInt8])] {
    var out: [(UInt64, [UInt8])] = []
    var cursor = 0
    while cursor + 3 <= input.count {
        let step = UInt64(input[cursor]) * 100
        let length = min(Int(input[cursor + 1]) << 8 | Int(input[cursor + 2]), input.count - cursor - 3)
        out.append((step, Array(input[(cursor + 3)..<(cursor + 3 + length)])))
        cursor += 3 + length
    }
    return out
}

enum Diag {
    static func debug(_ message: String, _ category: String) {}
    static func info(_ message: String, _ category: String) {}
    static func notice(_ message: String, _ category: String) {}
    static func warn(_ message: String, _ category: String) {}
    static func error(_ message: String, _ category: String) {}
}

/// Every `TelemetryCounters.shared.<name>Total` resolves to one no-op counter.
@dynamicMemberLookup
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()

    struct Counter {
        func increment(by amount: UInt64 = 1) {}
    }

    struct PacketGapSnapshot {
        var p50Us: Double, p95Us: Double, maxUs: Double
    }

    struct FecHealthSnapshot {
        var fecPercentage: Int, parityMargin: Int?
    }

    struct ReorderDisplacementSnapshot {
        var maxMs: Double, maxPackets: Int, holdMs: Double
    }

    subscript(dynamicMember name: String) -> Counter { Counter() }
    func setRecvJitterMs(_ value: Double) {}
    func setPacketGap(_ snapshot: PacketGapSnapshot) {}
    func setFecHealth(_ snapshot: FecHealthSnapshot) {}
    func setReorderDisplacement(_ snapshot: ReorderDisplacementSnapshot) {}
}

/// Off, as it is unless a telemetry session runs.
final class FrameTimingTracker: Sendable {
    struct Stage {
        func observe(_ value: Double) {}
    }

    static let shared: FrameTimingTracker? = nil
    let reorderDisplacementMs = Stage()
    let reorderDisplacementPackets = Stage()
}

enum TelemetryExporter {
    static func recordLiveEvent(_ fields: [String]) {}
}

enum TelemetryRenderer {
    static func jsonNumber(_ value: Double) -> String { "\(value)" }
}

/// Named by StreamingBackend; the audio receiver that defines it needs Network.
public protocol NativeAudioSink: AnyObject, Sendable {}

final class EnvSignalController: Sendable {
    static let shared = EnvSignalController()
    let streamLink = "unknown"
}
