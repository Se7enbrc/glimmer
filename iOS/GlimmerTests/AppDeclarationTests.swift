// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

@MainActor
struct AppDeclarationTests {
    @Test func developmentKeepsLauncherAwakeButAllowsInactiveAndBackgroundAutoLock() {
        var writes: [Bool] = []
        let activity = AppDisplayActivity(development: true) { writes.append($0) }
        activity.update(.active, streamActive: false)
        activity.update(.inactive, streamActive: true)
        activity.update(.active, streamActive: true)
        activity.update(.background, streamActive: true)
        activity.update(.active, streamActive: false)
        #expect(writes == [true, false, true, false, true])
    }

    @Test func productionKeepsOnlyAnActiveStreamAwake() {
        var writes: [Bool] = []
        let activity = AppDisplayActivity(development: false) { writes.append($0) }
        activity.update(.active, streamActive: false)
        activity.update(.active, streamActive: true)
        activity.update(.inactive, streamActive: true)
        activity.update(.background, streamActive: true)
        activity.update(.active, streamActive: true)
        activity.update(.active, streamActive: false)
        #expect(writes == [false, true, false, false, true, false])
    }

    @Test func controllersCanNavigateTheSystemInterface() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "GCSupportsControllerUserInteraction") as? Bool == true)
    }

    @Test func streamHandsControllerEventsBackToSystemControls() async {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {})
        controller.loadViewIfNeeded()
        #expect(controller.controllerUserInteractionEnabled)
        model.start(surface: controller.surface)
        model.receive(fixture.update(.firstFrame))
        #expect(!controller.controllerUserInteractionEnabled)
        model.showControls()
        #expect(controller.controllerUserInteractionEnabled)
        model.resumeInput()
        #expect(!controller.controllerUserInteractionEnabled)
        model.stop()
        await model.waitUntilStopped()
        #expect(controller.controllerUserInteractionEnabled)
    }

    @Test func pcSymbolExistsInSystemSymbolSet() {
        #expect(UIImage(systemName: LauncherView.pcSymbol) != nil)
    }

    @Test func packagedPrivacyManifestCoversAppAndLinkedEngine() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let trackingDomains = try #require(manifest["NSPrivacyTrackingDomains"] as? [String])
        #expect(trackingDomains.isEmpty)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.isEmpty)
        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for entry in accessed {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            let declared = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            #expect(reasons[category] == nil, "Each required-reason category must be declared once.")
            reasons[category] = Set(declared)
        }
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]
        ])
    }

    @Test func onlyAnIPhoneWindowContainingTheStreamLocksLandscape() async throws {
        let scene = try await testWindowScene()
        let menu = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = menu
        window.addSubview(menu.view)
        let allowed = AppDelegate.menuOrientations(for: window.traitCollection.userInterfaceIdiom)
        #expect(AppDelegate.orientationMask(for: window) == allowed)
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            throw StreamProfile.Failure.displayUnavailable
        })
        let stream = StreamViewController(model: model, close: {})
        menu.addChild(stream)
        menu.view.addSubview(stream.view)
        stream.didMove(toParent: menu)
        stream.beginAppearanceTransition(true, animated: false)
        stream.endAppearanceTransition()
        let streaming: UIInterfaceOrientationMask = window.traitCollection.userInterfaceIdiom == .pad
            ? .all : .landscape
        #expect(AppDelegate.orientationMask(for: window) == streaming)
        #expect(stream.supportedInterfaceOrientations == streaming)
        let other = UIWindow(windowScene: scene)
        other.frame = window.frame
        other.rootViewController = UIViewController()
        defer { window.rootViewController = nil; other.rootViewController = nil }
        #expect(AppDelegate.orientationMask(for: other)
            == AppDelegate.menuOrientations(for: other.traitCollection.userInterfaceIdiom))
        stream.beginAppearanceTransition(false, animated: false)
        stream.endAppearanceTransition()
        #expect(AppDelegate.orientationMask(for: window) == allowed)
        stream.willMove(toParent: nil)
        stream.view.removeFromSuperview()
        stream.removeFromParent()
        #expect(AppDelegate.orientationMask(for: window) == allowed)
    }

    @Test func appDeclaresDiscoveryControllersAndHighRefresh() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSBonjourServices"] as? [String] == ["_nvstream._tcp", "_nvstream-tcp._tcp"])
        #expect(info["NSLocalNetworkUsageDescription"] as? String ==
                "Glimmer finds and connects to the PC on your local network.")
        #expect(info["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
        let profiles = info["GCSupportedGameControllers"] as? [[String: String]]
        #expect(profiles == [["ProfileName": "ExtendedGamepad"]])
        // Absent means not required or recommended; App Store Connect rejects the key (90039, 90991)
        // unless it is a platform dictionary with GCSupportsControllerUserInteraction set to true.
        #expect(info["GCRequiresControllerUserInteraction"] == nil)
        // Only Apple's platform cryptography (TLS, CryptoKit): App Store Connect skips the compliance prompt.
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        let orientations = info["UISupportedInterfaceOrientations"] as? [String] ?? []
        let landscape = ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        let portraits = UIDevice.current.userInterfaceIdiom == .pad
            ? ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"]
            : ["UIInterfaceOrientationPortrait"]
        #expect(orientations == portraits + landscape)
        // Bundle resolves device-qualified keys for this device; inspect the packaged iPad declaration directly.
        let plistURL = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let packaged = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(packaged["UISupportedInterfaceOrientations~ipad"] as? [String] ==
                ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"] + landscape)
        #expect(packaged["UIRequiresFullScreen"] == nil)
        #expect(AppDelegate.menuOrientations(for: .phone) == .allButUpsideDown)
        #expect(AppDelegate.menuOrientations(for: .pad) == .all)
        #expect(AppDelegate().application(.shared, supportedInterfaceOrientationsFor: nil)
            == AppDelegate.menuOrientations(for: UIDevice.current.userInterfaceIdiom))
        #expect(info["LSSupportsGameMode"] as? Bool == true)
        #expect(info["UIViewControllerBasedStatusBarAppearance"] as? Bool == true)
    }
}
