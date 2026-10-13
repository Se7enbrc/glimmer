// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryListenerTests.swift
//  The /metrics listener on an ephemeral loopback port, scraped with plain HTTP requests.
//

import GlimmerEngine
import Darwin
import Foundation
import Network
import Testing
@testable import Glimmer

// Serialized: start() installs the process-wide event sink and latency tracker.
// A class, so the scratch directory goes in deinit whether the test passed or not.
@Suite(.serialized)
final class TelemetryListenerTests {

    private let dir: URL
    private let http: URLSession

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryListenerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        http = URLSession(configuration: config)
    }

    deinit {
        http.invalidateAndCancel()
        try? FileManager.default.removeItem(at: dir)
    }

    static func source() -> TelemetrySource {
        TelemetrySource(
            videoStats: { StreamStatsSnapshot() }, decoderDrops: { 0 }, backpressureDrops: { 0 },
            presentationLateDrops: { 0 }, presentationGaps: { 0 }, estimatedRtt: { nil },
            enetHealth: { nil }, pacingLiveness: { nil }, inFlightDecodeBacklog: { 0 },
            refreshWindow: { nil }, displayProbe: { nil }, displayMode: "window",
            stream: StreamTelemetryConfig(width: 1920, height: 1080, fps: 60, codec: "HEVC", bitrate: nil))
    }

    private func startedExporter() async throws -> (TelemetryExporter, UInt16) {
        TelemetryExporter.captureBaselines = TelemetryExporter.CaptureBaselines()
        let exporter = TelemetryExporter(
            source: Self.source(), serverName: "Den PC", outputDirectory: dir,
            counters: TelemetryCounters(), port: 0, listenOnLAN: false)
        exporter.start()
        return (exporter, try await Self.readyPort(exporter))
    }

    /// Waits for `.ready` on the work queue (where state updates land), then reads the bound port.
    static func readyPort(_ exporter: TelemetryExporter) async throws -> UInt16 {
        let listener = try #require(exporter.workQueue.sync { exporter.listener })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            exporter.workQueue.async {
                if case .ready = listener.state { done.resume(); return }
                let original = listener.stateUpdateHandler
                listener.stateUpdateHandler = { state in
                    original?(state)
                    switch state {
                    case .ready, .failed, .cancelled:
                        listener.stateUpdateHandler = original
                        done.resume()
                    default: break
                    }
                }
            }
        }
        return try #require(exporter.workQueue.sync { listener.port?.rawValue })
    }

    private func get(_ path: String, host: String = "127.0.0.1", port: UInt16) async throws
        -> (HTTPURLResponse, String) {
        let url = try #require(URL(string: "http://\(host):\(port)\(path)"))
        let (data, response) = try await http.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        return (http, try #require(String(bytes: data, encoding: .utf8)))
    }

    /// The Mac's first non-loopback IPv4 address, if it has one.
    private static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.ifa_flags) & IFF_LOOPBACK) == 0,
                  (Int32(entry.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Scrapes

    @Test func scrapeBeforeTheFirstSampleSaysSo() async throws {
        let (exporter, port) = try await startedExporter()
        defer { exporter.stop() }
        #expect(port != 0 && port != TelemetryExporter.port)
        let (response, body) = try await get("/metrics", port: port)
        #expect(response.statusCode == 200)
        #expect(body == "# no sample yet\n")
    }

    @Test func scrapeServesThePrometheusRenderingOfTheLatestSample() async throws {
        let (exporter, port) = try await startedExporter()
        defer { exporter.stop() }
        exporter.workQueue.sync { exporter.capture() }
        let sample = try #require(exporter.workQueue.sync { exporter.latestSample })
        let (response, body) = try await get("/metrics", port: port)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/plain; version=0.0.4; charset=utf-8")
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(body.utf8.count)")
        #expect(body == TelemetryRenderer.prometheus(sample.0, extras: sample.1))
        #expect(body.contains("glimmer_session_uptime_seconds"))
        #expect(body.contains("session=\"\(exporter.sessionId)\""))
        #expect(!body.contains("Den PC"))
    }

    @Test func anyOtherPathIsNotFound() async throws {
        let (exporter, port) = try await startedExporter()
        defer { exporter.stop() }
        let (response, body) = try await get("/", port: port)
        #expect(response.statusCode == 404)
        #expect(body == "404 not found - try GET /metrics\n")
    }

    @Test func eachScrapeIsItsOwnClosedConnection() async throws {
        let (exporter, port) = try await startedExporter()
        defer { exporter.stop() }
        for _ in 0..<3 {
            let (response, _) = try await get("/metrics", port: port)
            #expect(response.value(forHTTPHeaderField: "Connection") == "close")
        }
    }

    // MARK: - Bind scope and teardown

    @Test func listenerIsLoopbackOnly() async throws {
        let (exporter, port) = try await startedExporter()
        defer { exporter.stop() }
        let listener = try #require(exporter.workQueue.sync { exporter.listener })
        #expect(listener.parameters.requiredInterfaceType == .loopback)
        let ipOptions = listener.parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        #expect(ipOptions?.version == .v4)
        guard let lan = Self.lanAddress() else { return }
        await #expect(throws: (any Error).self) { _ = try await self.get("/metrics", host: lan, port: port) }
        let (response, _) = try await get("/metrics", port: port)
        #expect(response.statusCode == 200)
    }

    @Test func stopClosesThePort() async throws {
        let (exporter, port) = try await startedExporter()
        _ = try await get("/metrics", port: port)
        exporter.stop()
        #expect(exporter.workQueue.sync { exporter.listener } == nil)
        await #expect(throws: (any Error).self) { _ = try await self.get("/metrics", port: port) }
        exporter.stop()
    }
}
