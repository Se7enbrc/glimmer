// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// A requested stream format, never evidence of the PC's physical display mode.
public struct ContinuationFormat: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var hdr: Bool
    public var changeResolution: Bool

    public init(width: Int, height: Int, fps: Int, hdr: Bool, changeResolution: Bool = true) {
        self.width = width
        self.height = height
        self.fps = fps
        self.hdr = hdr
        self.changeResolution = changeResolution
    }

    public var isValid: Bool {
        StreamSizeBounds.width.contains(width) && StreamSizeBounds.height.contains(height)
            && StreamSizeBounds.fps.contains(fps) && width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }

    public func supported(maximumWidth: Int, maximumHeight: Int, maximumFPS: Int,
                          supportsHDR: Bool) -> ContinuationFormat? {
        guard isValid, maximumWidth >= 640, maximumHeight >= 480, maximumFPS >= 30 else { return nil }
        var result = self
        let scale = min(1, Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height))
        if scale < 1 {
            result.width = Int(Double(width) * scale) / 2 * 2
            result.height = Int(Double(height) * scale) / 2 * 2
            result.changeResolution = false
        }
        result.fps = min(fps, maximumFPS)
        result.hdr = hdr && supportsHDR
        if result.fps != fps || result.hdr != hdr { result.changeResolution = false }
        return result.isValid ? result : nil
    }
    package func applying(to request: StreamRequest) -> StreamRequest {
        guard isValid else { return request }
        var result = request
        result.width = width
        result.height = height
        result.fps = fps
        result.changeResolution = changeResolution
        result.resumeResolutionChange = true
        if !hdr {
            result.videoFormats = result.videoFormats.subtracting([.hevcMain10, .hevcRext10_444, .av1Main10, .av1High10_444])
        }
        return result
    }
}

/// Local history is bounded and only updated on decoded video or an explicit picture decision.
@MainActor
public struct ContinuationHistory {
    private struct Entry: Codable {
        var pc: String
        var app: Int
        var format: ContinuationFormat
        var updated: Date
        var rejected: [Transition] = []
        var preferred: [Transition] = []
    }

    private struct Transition: Codable, Equatable {
        let source: ContinuationFormat
        let target: ContinuationFormat
    }

    private let defaults: UserDefaults
    private static let key = "continuationHistory"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func previous(pc: String, app: Int, now: Date = Date()) -> ContinuationFormat? {
        entries.first { $0.pc == pc && $0.app == app && now.timeIntervalSince($0.updated) >= 0
            && now.timeIntervalSince($0.updated) < 86_400 && $0.format.isValid }?.format
    }

    public func remember(_ format: ContinuationFormat, pc: String, app: Int, now: Date = Date()) {
        guard format.isValid, app > 0, pc.utf8.count <= 256 else { return }
        var values = entries
        let old = values.first { $0.pc == pc && $0.app == app }
        values.removeAll { $0.pc == pc && $0.app == app }
        values.append(Entry(pc: pc, app: app, format: format, updated: now,
                            rejected: old?.rejected ?? [], preferred: old?.preferred ?? []))
        save(Array(values.suffix(64)))
    }

    public func prefer(_ target: ContinuationFormat, previous: ContinuationFormat, pc: String, app: Int) {
        guard target.isValid, previous.isValid else { return }
        remember(previous, pc: pc, app: app)
        var values = entries
        guard let index = values.firstIndex(where: { $0.pc == pc && $0.app == app }) else { return }
        values[index].preferred.removeAll { $0.source == previous }
        values[index].preferred.append(Transition(source: previous, target: target))
        values[index].preferred = Array(values[index].preferred.suffix(8))
        save(values)
    }

    public func preferredStart(pc: String, app: Int, source: ContinuationFormat,
                               screen: ContinuationFormat) -> ContinuationFormat? {
        guard let entry = entries.first(where: { $0.pc == pc && $0.app == app }) else { return nil }
        return entry.preferred.first { $0.source == source && $0.target == screen && $0.target.isValid }?.target
    }

    public func invalidate(pc: String) {
        var values = entries
        let matching = values.indices.filter { values[$0].pc == pc && values[$0].updated != .distantPast }
        guard !matching.isEmpty else { return }
        for index in matching { values[index].updated = .distantPast }
        save(values)
    }

    public func reject(_ target: ContinuationFormat, previous: ContinuationFormat, pc: String, app: Int) {
        remember(previous, pc: pc, app: app)
        var values = entries
        guard let index = values.firstIndex(where: { $0.pc == pc && $0.app == app }) else { return }
        values[index].preferred.removeAll { $0.source == previous && $0.target == target }
        values[index].rejected.removeAll { $0.target == target && $0.source == previous }
        values[index].rejected.append(Transition(source: previous, target: target))
        values[index].rejected = Array(values[index].rejected.suffix(8))
        save(values)
    }

    public func rejected(_ target: ContinuationFormat, pc: String, app: Int) -> Bool {
        guard let entry = entries.first(where: { $0.pc == pc && $0.app == app }) else { return false }
        return entry.rejected.contains { $0.source == entry.format && $0.target == target }
    }

    private var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.key), data.count < 131_072,
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(decoded.suffix(64))
    }

    private func save(_ values: [Entry]) {
        var bounded = values
        while let data = try? JSONEncoder().encode(bounded) {
            if data.count < 131_072 { defaults.set(data, forKey: Self.key); return }
            guard !bounded.isEmpty else { return }
            bounded.removeFirst()
        }
    }
}
