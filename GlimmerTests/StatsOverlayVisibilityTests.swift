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
        #expect(overlay.layer.bounds.width < originalFrame.width)
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
