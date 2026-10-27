// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Observation
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#endif
@testable import Glimmer

extension CleanRoomProbe {
    // Ops: "a=N"/"b=N"/"unrelated=N" mutate, "useB"/"useA" switch the read's dependency,
    // "settle" lets the main actor run, "cancel" cancels, "release" drops the model and checks it is freed.
    struct ObservationInput: Codable, Sendable {
        let ops: [String]
        let cancelInBodyAt: Int?
        let mutateInBodyAt: Int?
        let observers: Int
    }

    struct ObservationOutput: Codable, Equatable, Sendable {
        let events: [String]
    }

    @MainActor @Observable final class TrackedModel {
        var first = 0
        var second = 0
        var unrelated = 0
        var readsSecond = false
    }

    @MainActor final class EventLog {
        var lines: [String] = []
    }

    static let observation = area("observation") { (input: ObservationInput) -> ObservationOutput in
        await observeTracking(input)
    }

    @MainActor
    static func observeTracking(_ input: ObservationInput) async -> ObservationOutput {
        var model: TrackedModel? = TrackedModel()
        weak let probe = model
        let events = EventLog()
        let tasks = (0..<input.observers).map { observer in
            Task { @MainActor [weak probe] in
                guard let tracked = probe else { return }
                var deliveries = 0
                await forEachTrackedValue({ tracked.readsSecond ? tracked.second : tracked.first }, perform: { value in
                    deliveries += 1
                    events.lines.append("o\(observer) got \(value)")
                    if deliveries == input.mutateInBodyAt { tracked.first += 100 }
                    if deliveries == input.cancelInBodyAt { withUnsafeCurrentTask { $0?.cancel() } }
                })
                events.lines.append("o\(observer) finished")
            }
        }
        await settle()
        for op in input.ops {
            events.lines.append("> " + op)
            let parts = op.split(separator: "=")
            let value = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            switch parts.first {
            case "a": model?.first = value
            case "b": model?.second = value
            case "unrelated": model?.unrelated = value
            case "useB": model?.readsSecond = true
            case "useA": model?.readsSecond = false
            case "cancel": tasks.forEach { $0.cancel() }
            case "release":
                model = nil
                await settle()
                events.lines.append("released \(probe == nil)")
            default: await settle()
            }
        }
        tasks.forEach { $0.cancel() }
        await settle()
        return ObservationOutput(events: ordered(events.lines))
    }

    // Observers are independent tasks; keep each one's order between ops but not their interleaving.
    private static func ordered(_ lines: [String]) -> [String] {
        var result: [String] = []
        var run: [String] = []
        for line in lines + ["> end"] {
            guard line.hasPrefix(">") else { run.append(line); continue }
            result += run.enumerated().sorted { ($0.element.prefix(2), $0.offset) < ($1.element.prefix(2), $1.offset) }
                .map(\.element)
            run = []
            if line != "> end" { result.append(line) }
        }
        return result
    }

    // Enough main-actor turns for a yielded change to wake the reader, without a wall-clock wait.
    @MainActor
    static func settle() async {
        for _ in 0..<64 { await Task.yield() }
    }
}
