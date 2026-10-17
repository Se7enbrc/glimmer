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

    @Test func pcSymbolExistsInSystemSymbolSet() {
        #expect(UIImage(systemName: LauncherView.pcSymbol) != nil)
    }

    @Test func appDeclaresDiscoveryControllersAndHighRefresh() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSBonjourServices"] as? [String] == ["_nvstream._tcp", "_nvstream-tcp._tcp"])
        #expect(info["NSLocalNetworkUsageDescription"] as? String ==
                "Glimmer finds and connects to the PC on your local network.")
        #expect(info["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
        let profiles = info["GCSupportedGameControllers"] as? [[String: String]]
        #expect(profiles == [["ProfileName": "ExtendedGamepad"]])
        #expect(info["GCRequiresControllerUserInteraction"] as? Bool == false)
        let orientations = info["UISupportedInterfaceOrientations"] as? [String] ?? []
        let landscape = ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        #expect(orientations == landscape)
        // Bundle resolves device-qualified keys for this device; inspect the packaged iPad declaration directly.
        let plistURL = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let packaged = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(packaged["UISupportedInterfaceOrientations~ipad"] as? [String] ==
                ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"] + landscape)
        #expect(packaged["UIRequiresFullScreen"] == nil)
        #expect(AppDelegate.orientationMask == .landscape)
        #expect(AppDelegate().application(.shared, supportedInterfaceOrientationsFor: nil) == .landscape)
        #expect(info["LSSupportsGameMode"] as? Bool == true)
        #expect(info["UIViewControllerBasedStatusBarAppearance"] as? Bool == true)
    }
}
