// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

@MainActor
struct AppDeclarationTests {
    @Test func pcSymbolExistsInSystemSymbolSet() {
        #expect(UIImage(systemName: LauncherView.pcSymbol) != nil)
    }

    @Test func appDeclaresDiscoveryControllersAndHighRefresh() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSBonjourServices"] as? [String] == ["_nvstream._tcp", "_nvstream-tcp._tcp"])
        #expect(info["NSLocalNetworkUsageDescription"] as? String ==
                "Glimmer finds and connects to the PC on your local network.")
        #expect(info["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
        let profiles = info["GCSupportedGameControllers"] as? [[String: String]]
        #expect(profiles == [["ProfileName": "ExtendedGamepad"]])
        #expect(info["GCRequiresControllerUserInteraction"] as? Bool == false)
        let orientations = info["UISupportedInterfaceOrientations"] as? [String] ?? []
        #expect(orientations.contains("UIInterfaceOrientationLandscapeLeft"))
        #expect(orientations.contains("UIInterfaceOrientationLandscapeRight"))
        #expect(info["UIViewControllerBasedStatusBarAppearance"] as? Bool == true)
    }
}
