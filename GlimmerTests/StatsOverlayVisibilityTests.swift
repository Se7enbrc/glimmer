// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StatsOverlayVisibilityTests {
    @Test func macHUDKeeps2026_10_7SizeAtEveryWindowSize() {
        for size in [CGSize(width: 667, height: 375), CGSize(width: 1920, height: 1080), .zero,
                     CGSize(width: 7680, height: 4320)] {
            #expect(StatsOverlayLayer.viewportScale(in: size) == 1)
        }
        // 2026.10.7: three core rows of 54 pt with 3 pt gaps plus the 12 pt cap, 160 pt wide, never scaled up.
        var snapshot = StreamStatsSnapshot()
        snapshot.negotiatedBitrateMbps = 50
        for size in [CGSize(width: 1_920, height: 1_080), CGSize(width: 2_560, height: 1_440),
                     CGSize(width: 3_840, height: 2_160), CGSize(width: 5_120, height: 2_880)] {
            let overlay = StatsOverlayLayer()
            let video = CALayer()
            video.bounds = CGRect(origin: .zero, size: size)
            overlay.attach(to: video)
            overlay.videoSize = size
            overlay.update(snapshot: snapshot, enabled: StatsOverlayDefaults.minimalRows, targetFps: 60)
            #expect(overlay.layer.frame.size == CGSize(width: 160, height: 180), "\(size)")
            #expect(overlay.layer.frame.minX == 16 && overlay.layer.frame.maxY == size.height - 16, "\(size)")
            #expect(overlay.resolvedLabelFont.pointSize == NSFont.preferredFont(forTextStyle: .caption2).pointSize)
        }
        let area = CGRect(x: 0, y: 0, width: 320, height: 240)
        for corner in StatsOverlayCorner.allCases {
            let frame = StatsOverlayLayer.panelFrame(size: CGSize(width: 500, height: 600),
                                                     in: area, corner: corner, preferredScale: 1.6)
            #expect(area.insetBy(dx: 16, dy: 16).contains(frame))
        }
    }

    @Test func visibleMetricsExposeStableAccessibilityChildrenAndHideWithTheHUD() throws {
        let view = DisplayContainerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.wantsLayer = true
        let video = try #require(view.layer)
        let overlay = StatsOverlayLayer()
        overlay.displayView = view
        overlay.attach(to: video)
        var snapshot = StreamStatsSnapshot()
        snapshot.rttMs = 3.5
        overlay.update(snapshot: snapshot, enabled: [.latency], targetFps: 60)
        #expect((view.accessibilityChildren() ?? []).isEmpty)
        overlay.setVisible(true)
        let child = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(child.accessibilityLabel() == "Latency")
        #expect(child.accessibilityValue() as? String == "3.50 ms")
        snapshot.rttMs = 4.5
        overlay.update(snapshot: snapshot, enabled: [.latency], targetFps: 60)
        #expect(view.accessibilityChildren()?.first as? NSAccessibilityElement === child)
        #expect(child.accessibilityValue() as? String == "4.50 ms")
        overlay.setVisible(false)
        #expect((view.accessibilityChildren() ?? []).isEmpty)
    }

    @Test func visibilityUsesAnExplicitFadeAndInkChangesNeverSnapshotLiveValues() throws {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        let fade = try #require(overlay.layer.animation(forKey: "visibility") as? CABasicAnimation)
        #expect(fade.duration == Motion.short)
        #expect(fade.fromValue as? Float == 0)
        #expect(fade.toValue as? Int == 1)
        overlay.updateBackdropLuminance(1)
        #expect(overlay.layer.animation(forKey: "ink") == nil)
        overlay.setVisible(false)
        let hideGeneration = overlay.visibilityGeneration
        overlay.setVisible(true)
        overlay.finishHide(generation: hideGeneration)
        #expect(!overlay.layer.isHidden)
    }

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
            #expect(!StatsOverlayLayer.shouldUseDarkInk(luminance: pow(value, 2.4), currentlyDark: false))
            #expect(StatsOverlayLayer.shouldUseDarkInk(luminance: pow(value, 2.4), currentlyDark: true))
        }
        #expect(StatsOverlayLayer.shouldUseDarkInk(luminance: pow(0.621, 2.4), currentlyDark: false))
        #expect(!StatsOverlayLayer.shouldUseDarkInk(luminance: pow(0.479, 2.4), currentlyDark: true))
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
        #expect(render.severity(value: 190, reference: 192, thresholds: StatsThresholds()) == .none)
        #expect(render.severity(value: 95, reference: 192, thresholds: StatsThresholds()) == .caution)
        #expect(render.severity(value: 57, reference: 192, thresholds: StatsThresholds()) == .critical)
        #expect(render.severity(value: 10, reference: nil, thresholds: StatsThresholds()) == .none)
        let bitrate = StatsTrace.Metric.bitrate
        #expect(bitrate.severity(value: 24, reference: 50, thresholds: StatsThresholds()) == .caution)
        #expect(bitrate.severity(value: 14, reference: 50, thresholds: StatsThresholds()) == .critical)
        #expect(bitrate.severity(value: 30, reference: 50, thresholds: StatsThresholds()) == .none)
        let latency = StatsTrace.Metric.latency
        #expect(latency.severity(value: 8, reference: 3.5, thresholds: StatsThresholds()) == .caution)
        #expect(latency.severity(value: 51, reference: nil, thresholds: StatsThresholds()) == .caution)
        #expect(latency.severity(value: 4, reference: 3.5, thresholds: StatsThresholds()) == .none)
        #expect(latency.severity(value: 120, reference: 3.5, thresholds: StatsThresholds()) == .critical)
        let jitter = StatsTrace.Metric.jitter
        #expect(jitter.severity(value: 12, reference: nil, thresholds: StatsThresholds()) == .caution)
        #expect(jitter.severity(value: 30, reference: nil, thresholds: StatsThresholds()) == .critical)
        let drops = StatsTrace.Metric.drops
        #expect(drops.severity(value: 0.2, reference: nil, thresholds: StatsThresholds()) == .none)
        #expect(drops.severity(value: 3, reference: nil, thresholds: StatsThresholds()) == .critical)
        #expect(StatsTrace.Metric(kind: .hostFps) == .host)
        #expect(StatsTrace.Metric(kind: .networkFps)?.judgesDrops == true)
        #expect(StatsTrace.Metric(kind: .codec) == nil)
        for metric in [render, latency, bitrate, jitter, drops] {
            #expect(metric.severity(value: nil, reference: 50, thresholds: StatsThresholds()) == .none)
            #expect(metric.severity(value: .nan, reference: 50, thresholds: StatsThresholds()) == .none)
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

    @Test func baselineIsAMedianThatNeedsHistoryAndForgetsOldReadings() {
        var baseline = StatsBaseline()
        for _ in 0..<7 { baseline.add(190) }
        #expect(baseline.median() == nil)
        baseline.add(30)
        #expect(baseline.median() == 190)
        for _ in 0..<StatsBaseline.capacity { baseline.add(60) }
        #expect(baseline.count == StatsBaseline.capacity)
        #expect(baseline.median() == 60)
        baseline.reset()
        #expect(baseline.median() == nil)
    }

    @Test func everyRowFitsItsLabelValueAndTraceWithoutOverlap() {
        for kind in StatsRow.Kind.allCases {
            let bands = StatsOverlayLayer.rowBands(for: kind)
            #expect(bands.trace + bands.value + 13 <= bands.height, "\(kind) overlaps")
            #expect((bands.trace > 0) == (StatsTrace.Metric(kind: kind) != nil), "\(kind) trace band")
        }
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
            let (width, height): (CGFloat, CGFloat) = (160, 180)
            for corner in StatsOverlayCorner.allCases {
                overlay.corner = corner
                let rect = overlay.backdropSampleRect
                let expectedX: CGFloat
                switch corner {
                case .topLeft, .bottomLeft: expectedX = 16 / available.width
                case .topCenter, .bottomCenter: expectedX = (available.width - width) / 2 / available.width
                case .topRight, .bottomRight: expectedX = (available.width - width - 16) / available.width
                }
                let isTop = [.topLeft, .topCenter, .topRight].contains(corner)
                let expectedY = (isTop ? 16 : available.height - height - 16) / available.height
                #expect(abs(rect.minX - expectedX) < 0.0001)
                #expect(abs(rect.minY - expectedY) < 0.0001)
                #expect(abs(rect.width - width / available.width) < 0.0001)
                #expect(abs(rect.height - height / available.height) < 0.0001)
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

    @Test func tracesWaitForBoundsAndHistoryAndClearTheirPathsWhenCollapsed() {
        let trace = StatsTrace(metric: .render)
        trace.draw()
        let shapes = (trace.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        #expect(shapes.allSatisfy { $0.path == nil })
        trace.layer.bounds = CGRect(x: 0, y: 0, width: 160, height: 17)
        var snapshot = StreamStatsSnapshot()
        snapshot.renderedFps = 60
        for count in 1...StatsTrace.minimumHistory {
            trace.draw()
            #expect(shapes.allSatisfy { $0.path == nil }, "no stub before \(count) readings")
            trace.append(snapshot: snapshot, targetFps: 60, thresholds: .default)
        }
        trace.draw()
        #expect(shapes.allSatisfy { $0.path == nil }, "a perfectly steady reading draws no flat dash")
        snapshot.renderedFps = 58
        trace.append(snapshot: snapshot, targetFps: 60, thresholds: .default)
        trace.draw()
        #expect(shapes.contains { $0.path?.isEmpty == false })
        trace.layer.bounds = .zero
        trace.draw()
        #expect(shapes.allSatisfy { $0.path == nil })
    }

    @Test func sampleRectRecoversAcrossAttachmentVideoSizeAndRendererReplacement() {
        let overlay = StatsOverlayLayer()
        overlay.update(snapshot: StreamStatsSnapshot(), enabled: [.renderFps], targetFps: 60)
        overlay.setVisible(true)
        let video = CALayer()
        video.bounds = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        overlay.attach(to: video)
        #expect(overlay.backdropSampleRect == .zero)
        overlay.videoSize = CGSize(width: 1_920, height: 1_080)
        let initial = overlay.backdropSampleRect
        #expect(!initial.isEmpty)
        #expect(abs(initial.minY - 16 / 720) < 0.0001)
        overlay.layer.removeFromSuperlayer()
        #expect(overlay.backdropSampleRect == .zero)
        let replacement = CALayer()
        replacement.bounds = CGRect(x: 0, y: 0, width: 800, height: 1_280)
        overlay.attach(to: replacement)
        #expect(!overlay.backdropSampleRect.isEmpty)
        #expect(overlay.backdropSampleRect != initial)
        overlay.setVisible(false)
        overlay.setVisible(true)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(overlay.backdropSampleRect))
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
