import AppKit
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StatsOverlayVisibilityTests {

    @Test func bitrateAndCodecShareOneRow() throws {
        var snapshot = StreamStatsSnapshot()
        snapshot.measuredBitrateMbps = 46.2
        snapshot.negotiatedBitrateMbps = 362
        snapshot.videoCodec = "AV1"
        let source = snapshot.rows(enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        let rows = StatsOverlayLayer.combinedRows(source)
        #expect(rows.map(\.kind) == [.renderFps, .latency, .bitrate])
        let bitrate = try #require(rows.first { $0.kind == .bitrate })
        #expect(bitrate.label == "Bitrate")
        #expect(bitrate.value == "46.2 / 362 Mbps · AV1")
        #expect(bitrate.health == .neutral)
        #expect(rows.filter { $0.kind != .bitrate } == source.filter { $0.kind != .bitrate && $0.kind != .codec })
    }

    @Test func customRowsKeepIndependentBitrateAndCodecChoices() {
        var snapshot = StreamStatsSnapshot()
        snapshot.videoCodec = "HEVC"
        let enabledSets: [Set<StatsRow.Kind>] = [[.bitrate], [.codec], [], [.latency, .audio]]
        for enabled in enabledSets {
            let source = snapshot.rows(enabled: enabled, targetFps: 60)
            #expect(StatsOverlayLayer.combinedRows(source) == source)
        }
    }

    @Test func combiningRowsKeepsMissingValuesAndEveryDetailedMetric() throws {
        let snapshot = StreamStatsSnapshot()
        let source = snapshot.rows(enabled: Set(StatsRow.Kind.allCases), targetFps: 60)
        let rows = StatsOverlayLayer.combinedRows(source)
        let bitrate = try #require(source.first { $0.kind == .bitrate })
        #expect(rows.first { $0.kind == .bitrate }?.value == "\(bitrate.value) · -")
        #expect(rows.filter { $0.kind != .bitrate } == source.filter { $0.kind != .bitrate && $0.kind != .codec })
        #expect(rows.count == StatsRow.Kind.allCases.count - 1)
    }

    @Test func changingValuesReusesLayersAndKeepsPanelWidthStable() throws {
        let overlay = StatsOverlayLayer()
        let video = CALayer()
        video.bounds = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        overlay.attach(to: video)
        var snapshot = StreamStatsSnapshot()
        snapshot.measuredBitrateMbps = 46.2
        snapshot.negotiatedBitrateMbps = 362
        snapshot.videoCodec = "AV1"
        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        let originalFrame = overlay.layer.frame
        let originalLayers = try #require(overlay.layer.sublayers)
        snapshot.measuredBitrateMbps = 9.1
        overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
        #expect(overlay.layer.frame == originalFrame)
        let updatedLayers = try #require(overlay.layer.sublayers)
        #expect(originalLayers.count == updatedLayers.count)
        #expect(zip(originalLayers, updatedLayers).allSatisfy { $0 === $1 })
        overlay.update(snapshot: snapshot, enabled: [.renderFps, .latency, .bitrate], targetFps: 60)
        #expect(overlay.layer.bounds.width == 160)
        #expect(overlay.layer.bounds.height == 180)
        #expect(overlay.layer.backgroundColor == nil)
        #expect(overlay.layer.borderWidth == 0)
    }

    @Test func steadyStackFormatsValuesAndRetainsCustomRows() throws {
        var snapshot = StreamStatsSnapshot()
        snapshot.measuredBitrateMbps = 52
        snapshot.negotiatedBitrateMbps = 362
        snapshot.videoCodec = "AV1"
        snapshot.rttMs = 3.54
        snapshot.jitterMs = 0.1
        let rows = StatsOverlayLayer.displayRows(snapshot: snapshot, enabled: Set(StatsRow.Kind.allCases),
                                                 targetFps: 60, thresholds: .default)
        #expect(Array(rows.prefix(3)).map(\.kind) == [.renderFps, .latency, .bitrate])
        #expect(rows.first { $0.kind == .bitrate }?.value == "52.0 Mbps · AV1")
        #expect(rows.first { $0.kind == .latency }?.value == "3.54 ms")
        #expect(rows.count == StatsRow.Kind.allCases.count - 1)
        let overlay = StatsOverlayLayer()
        let video = CALayer()
        video.bounds = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        overlay.attach(to: video)
        overlay.update(snapshot: snapshot, enabled: Set(StatsRow.Kind.allCases), targetFps: 60)
        #expect(overlay.rowViews.count == rows.count)
        for row in rows {
            let sub = try #require(overlay.rowViews[row.kind])
            #expect(sub.lastRender == row)
            #expect(sub.valueLayer.preferredFrameSize().width <= sub.valueLayer.bounds.width)
        }
        overlay.update(snapshot: snapshot, enabled: [.codec], targetFps: 60)
        #expect(overlay.rowViews[.codec]?.lastRender?.value == "AV1")
        #expect(overlay.rowViews[.bitrate] == nil)
    }

    @Test func inkHysteresisHoldsInTheDeadBandAndRejectsInvalidSamples() {
        for value in [0.48, 0.55, 0.62] {
            #expect(!StatsOverlayLayer.shouldUseDarkInk(luminance: value, currentlyDark: false))
            #expect(StatsOverlayLayer.shouldUseDarkInk(luminance: value, currentlyDark: true))
        }
        #expect(StatsOverlayLayer.shouldUseDarkInk(luminance: 0.621, currentlyDark: false))
        #expect(!StatsOverlayLayer.shouldUseDarkInk(luminance: 0.479, currentlyDark: true))
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            #expect(!StatsOverlayLayer.shouldUseDarkInk(luminance: value, currentlyDark: false))
            #expect(StatsOverlayLayer.shouldUseDarkInk(luminance: value, currentlyDark: true))
        }
        let overlay = StatsOverlayLayer()
        #expect(!overlay.usesDarkInk)
        overlay.updateBackdropLuminance(1)
        #expect(overlay.usesDarkInk)
        overlay.updateBackdropLuminance(0.55)
        #expect(overlay.usesDarkInk)
        overlay.updateBackdropLuminance(0)
        #expect(!overlay.usesDarkInk)
    }

    @Test func traceHistoryWrapsWithoutGrowingAndLeavesMissingReadingsAsGaps() {
        var history = StatsTraceHistory()
        #expect(history.isEmpty)
        #expect(history.mean == nil)
        for index in 0..<100 {
            history.append(value: Double(index), severity: index == 99 ? .caution : .none, time: Double(index) / 4)
        }
        #expect(history.count == 41)
        #expect(history[0].value == 59)
        #expect(history[40].value == 99)
        #expect(history[40].time - history[0].time == 10)
        #expect(history.mean == 79)
        #expect(history[40].severity == .caution)
        history.append(value: .nan, severity: .critical, time: 25)
        #expect(history[40].value == nil)
        #expect(history[40].severity == .none)
        history.append(value: nil, severity: .none, time: 25.25)
        #expect(history[40].value == nil)
        history.append(value: 60, severity: .none, time: 30)
        #expect(history.count == 1)
        #expect(history[0].value == 60)
        history.reset()
        #expect(history.isEmpty)
    }

    @Test func dropsAreJudgedAgainstTheRunningAverageAndColourBothEdges() {
        let render = StatsTrace.Metric.render
        #expect(render.severity(value: 190, reference: 192, latencyWarning: 50) == .none)
        #expect(render.severity(value: 95, reference: 192, latencyWarning: 50) == .caution)
        #expect(render.severity(value: 57, reference: 192, latencyWarning: 50) == .critical)
        #expect(render.severity(value: 10, reference: nil, latencyWarning: 50) == .none)
        let bitrate = StatsTrace.Metric.bitrate
        #expect(bitrate.severity(value: 24, reference: 50, latencyWarning: 50) == .caution)
        #expect(bitrate.severity(value: 14, reference: 50, latencyWarning: 50) == .critical)
        #expect(bitrate.severity(value: 30, reference: 50, latencyWarning: 50) == .none)
        let latency = StatsTrace.Metric.latency
        #expect(latency.severity(value: 8, reference: 3.5, latencyWarning: 50) == .caution)
        #expect(latency.severity(value: 51, reference: nil, latencyWarning: 50) == .caution)
        #expect(latency.severity(value: 4, reference: 3.5, latencyWarning: 50) == .none)
        for metric in [render, latency, bitrate] {
            #expect(metric.severity(value: nil, reference: 50, latencyWarning: 50) == .none)
            #expect(metric.severity(value: .nan, reference: 50, latencyWarning: 50) == .none)
        }
        let healthy = StatsTraceHistory.Sample(value: 60)
        let caution = StatsTraceHistory.Sample(value: 25, severity: .caution)
        let critical = StatsTraceHistory.Sample(value: 10, severity: .critical)
        let missing = StatsTraceHistory.Sample()
        #expect(StatsTraceHistory.segmentSeverity(from: healthy, to: caution) == .caution)
        #expect(StatsTraceHistory.segmentSeverity(from: caution, to: critical) == .critical)
        #expect(StatsTraceHistory.segmentSeverity(from: healthy, to: healthy) == .none)
        #expect(StatsTraceHistory.segmentSeverity(from: missing, to: critical) == .none)
    }

    @Test func sampleRectTracksEveryCornerAndLetterboxOnBothAxes() {
        let overlay = StatsOverlayLayer()
        #expect(overlay.backdropSampleRect == .zero)
        let video = CALayer()
        video.bounds = CGRect(x: 20, y: 30, width: 1_440, height: 900)
        overlay.attach(to: video)
        var snapshot = StreamStatsSnapshot()
        snapshot.negotiatedBitrateMbps = 362
        let pictures = [CGSize(width: 1_920, height: 1_080), CGSize(width: 1_200, height: 900)]
        for picture in pictures {
            overlay.videoSize = picture
            overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
            let available = StatsOverlayLayer.availableRect(in: video.bounds, videoSize: picture, safeArea: NSEdgeInsets())
            for corner in StatsOverlayCorner.allCases {
                overlay.corner = corner
                let rect = overlay.backdropSampleRect
                let expectedX: CGFloat
                switch corner {
                case .topLeft, .bottomLeft: expectedX = 16 / available.width
                case .topCenter, .bottomCenter: expectedX = (available.width - 160) / 2 / available.width
                case .topRight, .bottomRight: expectedX = (available.width - 176) / available.width
                }
                let isTop = [.topLeft, .topCenter, .topRight].contains(corner)
                let expectedY = (isTop ? 16 : available.height - 196) / available.height
                #expect(abs(rect.minX - expectedX) < 0.0001)
                #expect(abs(rect.minY - expectedY) < 0.0001)
                #expect(abs(rect.width - 160 / available.width) < 0.0001)
                #expect(abs(rect.height - 180 / available.height) < 0.0001)
                #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect))
            }
        }
    }

    @Test func eachCornerUsesTheSameInset() {
        let size = CGSize(width: 240, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let positions: [(StatsOverlayCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: 16, y: 704)), (.topRight, CGPoint(x: 1_024, y: 704)),
            (.bottomLeft, CGPoint(x: 16, y: 16)), (.bottomRight, CGPoint(x: 1_024, y: 16))
        ]
        for (corner, origin) in positions {
            #expect(StatsOverlayLayer.panelFrame(size: size, in: bounds, corner: corner)
                    == CGRect(origin: origin, size: size))
        }
    }

    @Test func eachCornerRespectsSafeInsetsAndBoundsOrigin() {
        let bounds = CGRect(x: 20, y: 30, width: 1_280, height: 800)
        let available = StatsOverlayLayer.availableRect(
            in: bounds, videoSize: bounds.size,
            safeArea: NSEdgeInsets(top: 38, left: 10, bottom: 6, right: 14))
        let size = CGSize(width: 240, height: 80)
        let positions: [(StatsOverlayCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: 46, y: 696)), (.topRight, CGPoint(x: 1_030, y: 696)),
            (.bottomLeft, CGPoint(x: 46, y: 52)), (.bottomRight, CGPoint(x: 1_030, y: 52))
        ]
        for (corner, origin) in positions {
            #expect(StatsOverlayLayer.panelFrame(size: size, in: available, corner: corner)
                    == CGRect(origin: origin, size: size))
        }
    }

    @Test func letterboxAndNotchInsetsDoNotStack() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let available = StatsOverlayLayer.availableRect(
            in: bounds, videoSize: CGSize(width: 1_920, height: 1_080),
            safeArea: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0))
        #expect(available == CGRect(x: 0, y: 45, width: 1_440, height: 810))
        let size = CGSize(width: 240, height: 80)
        #expect(StatsOverlayLayer.panelFrame(size: size, in: available, corner: .topLeft).minY == 759)
        #expect(StatsOverlayLayer.panelFrame(size: size, in: available, corner: .bottomRight).minY == 61)
    }

    @Test func pillarboxAndSmallPlayersKeepTheWholePanelInsideThePicture() {
        let available = StatsOverlayLayer.availableRect(
            in: CGRect(x: 0, y: 0, width: 1_600, height: 900),
            videoSize: CGSize(width: 1_200, height: 900), safeArea: NSEdgeInsets())
        #expect(available == CGRect(x: 200, y: 0, width: 1_200, height: 900))
        let small = CGRect(x: 200, y: 0, width: 300, height: 180)
        for corner in StatsOverlayCorner.allCases {
            let frame = StatsOverlayLayer.panelFrame(size: CGSize(width: 360, height: 480), in: small, corner: corner)
            #expect(small.insetBy(dx: 16, dy: 16).contains(frame))
            #expect(abs(frame.width / frame.height - 0.75) < 0.001)
        }
    }

    @Test func positionDefaultsToTopLeftAndRestoresSavedChoices() throws {
        let domain = "io.ugfugl.Glimmer.tests.stats-position"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(StatsOverlayCorner.persisted(defaults: defaults) == .topLeft)
        for corner in StatsOverlayCorner.allCases {
            defaults.set(corner.rawValue, forKey: "streamStatsCorner")
            #expect(StatsOverlayCorner.persisted(defaults: defaults) == corner)
        }
        defaults.set("unknown", forKey: "streamStatsCorner")
        #expect(StatsOverlayCorner.persisted(defaults: defaults) == .topLeft)
    }

    @Test func batteryCacheExpiresAfterTenSeconds() {
        #expect(MacSystemStats.batteryCacheIsStale(sampledAt: nil, now: 0))
        #expect(!MacSystemStats.batteryCacheIsStale(sampledAt: 5, now: 14.999))
        #expect(MacSystemStats.batteryCacheIsStale(sampledAt: 5, now: 15))
    }

    /// Born hidden, and says so.
    @Test func startsHidden() {
        let overlay = StatsOverlayLayer()
        #expect(overlay.isVisible == false)
        #expect(overlay.layer.isHidden)
        #expect(overlay.layer.opacity == 0)
    }

    /// Hide then show in one run-loop turn (StreamWindow.init, then the session's
    /// seed) must leave the panel shown; the show used to return early.
    @Test func showRightAfterHideWins() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        overlay.setVisible(true)
        #expect(overlay.isVisible)
        #expect(overlay.layer.isHidden == false)
        #expect(overlay.layer.opacity == 1)
    }

    /// A hide completion that a later show overtook must not hide the panel.
    @Test func staleHideCompletionDoesNotHideAReshownPanel() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        let staleGeneration = overlay.visibilityGeneration
        overlay.setVisible(true)
        overlay.finishHide(generation: staleGeneration)
        #expect(overlay.isVisible)
        #expect(overlay.layer.isHidden == false)
    }

    /// The current hide completion hides the layer.
    @Test func currentHideCompletionHidesTheLayer() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        overlay.finishHide(generation: overlay.visibilityGeneration)
        #expect(overlay.isVisible == false)
        #expect(overlay.layer.isHidden)
    }
}
