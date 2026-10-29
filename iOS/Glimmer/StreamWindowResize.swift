// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

@MainActor
final class StreamWindowResize {
    enum Result: Sendable { case applied, adapted(StreamFormat), deferred, rejected }
    typealias Request = @MainActor @Sendable (StreamFormat) async -> Result

    private let request: Request
    private let applied: (StreamFormat) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var current: StreamFormat
    private var desired: StreamFormat
    private var geometry: StreamFormat
    private var pendingGeometry = false
    private var available = false
    private var stopped = false
    private var applying = false
    private var task: Task<Void, Never>?

    init(format: StreamFormat, request: @escaping Request, applied: @escaping (StreamFormat) -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        current = format
        desired = format
        geometry = format
        self.request = request
        self.applied = applied
        self.sleep = sleep
    }

    func submit(_ format: StreamFormat) {
        guard !stopped, geometry != format else { return }
        geometry = format
        desired = format
        pendingGeometry = true
        if !applying { task?.cancel(); task = nil }
        schedule()
    }

    /// The stream started at a different listed size than prepared, such as Low Data Mode's.
    func adopt(_ format: StreamFormat) {
        current = format
        if !pendingGeometry { desired = format }
        schedule()
    }

    func setAvailable(_ value: Bool) {
        available = value
        if !value, !applying { task?.cancel(); task = nil }
        if value { schedule() }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    func waitForPendingChange() async { await task?.value }

    /// Applied only once the session reports the resize reached the renderer at this exact size.
    static func request(_ format: StreamFormat, session: StreamSession) async -> Result {
        let formats = StreamFormats(resizing: format)
        switch await session.request(width: format.width, height: format.height, sizes: formats.sizes) {
        case .rejected:
            guard let size = await session.requestedSize,
                  [formats.full, formats.lowData].contains(where: { ($0.width, $0.height) == size }) else {
                return .rejected
            }
            return .adapted(StreamFormat(width: size.width, height: size.height, fps: format.fps,
                                         changeResolution: format.changeResolution))
        case .deferred: return .deferred
        case .accepted:
            let report = await session.settledBitrateChange()
            guard let report, report.reason == .resize, report.outcome == .applied,
                  let width = report.width, let height = report.height,
                  [formats.full, formats.lowData].contains(where: { ($0.width, $0.height) == (width, height) }) else {
                return .deferred
            }
            return .adapted(StreamFormat(width: width, height: height, fps: format.fps,
                                         changeResolution: format.changeResolution))
        }
    }

    private func schedule() {
        guard !stopped, available, task == nil, pendingGeometry else { return }
        let target = desired
        task = Task { [weak self, sleep] in
            do { try await sleep(.milliseconds(750)) } catch { return }
            guard !Task.isCancelled, let self, !stopped, available, desired == target else { return }
            applying = true
            let result = await request(target)
            applying = false
            task = nil
            guard !Task.isCancelled, !stopped else { return }
            switch result {
            case .applied: current = target
            case .adapted(let format): current = format
            case .deferred, .rejected:
                if desired != target { schedule() }
                return
            }
            applied(current)
            if desired == target {
                pendingGeometry = false
                desired = current
            }
            // A deferred target waits for fresh lifecycle evidence, rather than polling the PC.
            if desired != target { schedule() }
        }
    }
}
