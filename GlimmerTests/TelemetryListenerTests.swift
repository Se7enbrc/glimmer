// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryListenerTests.swift
//  The /metrics listener on an ephemeral loopback port, scraped with plain HTTP requests.
//

@testable import GlimmerEngine
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

    private func exporter() -> TelemetryExporter {
        TelemetryExporter(source: Self.source(), serverName: "Den PC", outputDirectory: dir,
                          counters: TelemetryCounters(), port: 0, listenOnLAN: false)
    }

    private func startedExporter() async throws -> (TelemetryExporter, UInt16) {
        TelemetryExporter.captureBaselines = TelemetryExporter.CaptureBaselines()
        let exporter = exporter()
        exporter.start()
        do {
            return (exporter, try await Self.readyPort(exporter))
        } catch {
            exporter.stop()
            throw error
        }
    }

    static func readyPort(_ exporter: TelemetryExporter) async throws -> UInt16 {
        var iterator = listeningResult(exporter).makeAsyncIterator()
        let result = try #require(await iterator.next(), "Telemetry listener did not respond within five seconds")
        return try #require(result, "Telemetry listener failed or stopped before becoming ready")
    }

    /// A deadline must end the stream even if readiness is never delivered.
    private static func listeningResult(_ exporter: TelemetryExporter) -> AsyncStream<UInt16?> {
        AsyncStream { continuation in
            exporter.whenListening { port in
                continuation.yield(port)
                continuation.finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.finish() }
        }
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

    @Test func readinessReachesEarlyAndLateObservers() async throws {
        let exporter = exporter()
        defer { exporter.stop() }
        let early = Self.listeningResult(exporter)
        exporter.start()
        var iterator = early.makeAsyncIterator()
        let result = try #require(await iterator.next(), "Early readiness observer was not resumed")
        let port = try #require(result)
        #expect(try await Self.readyPort(exporter) == port)
        let (response, _) = try await get("/metrics", port: port)
        #expect(response.statusCode == 200)
    }

    @Test func stopResumesPendingAndLateReadinessObservers() async throws {
        let exporter = exporter()
        var early = Self.listeningResult(exporter).makeAsyncIterator()
        exporter.stop()
        let first = try #require(await early.next(), "Stop did not resume the pending observer")
        #expect(first == nil)
        #expect(await early.next() == nil)
        var late = Self.listeningResult(exporter).makeAsyncIterator()
        let second = try #require(await late.next(), "Stop did not resume the late observer")
        #expect(second == nil)
        exporter.start()
        #expect(exporter.workQueue.sync { exporter.listener == nil && exporter.captureTimer == nil })
    }

    @Test func stopOnWorkQueueFinishesWithoutWaitingForMainQueue() async {
        await #expect(processExitsWith: .success) {
            // A deadlock or dispatch precondition must fail only this child, never hang the test host.
            alarm(10)
            let fixture = try TelemetryListenerTests()
            let (exporter, _) = try await fixture.startedExporter()
            let finished = DispatchSemaphore(value: 0)
            await MainActor.run {
                exporter.workQueue.async {
                    exporter.stop()
                    exporter.stop()
                    finished.signal()
                }
                if finished.wait(timeout: .now() + 5) != .success { _exit(1) }
            }
            try #require(exporter.workQueue.sync { exporter.listener == nil && exporter.fileHandle == nil })
            alarm(0)
        }
    }

    @Test func stopOnMainQueueFinishes() async {
        await #expect(processExitsWith: .success) {
            alarm(10)
            let fixture = try TelemetryListenerTests()
            let (exporter, _) = try await fixture.startedExporter()
            await MainActor.run {
                exporter.stop()
                exporter.stop()
            }
            try #require(exporter.workQueue.sync { exporter.listener == nil && exporter.fileHandle == nil })
            alarm(0)
        }
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
