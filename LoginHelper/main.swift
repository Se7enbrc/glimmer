//
//  main.swift - Glimmer Login Helper
//
//  Auto-launched at login by the system (registered via
//  SMAppService.loginItem from the main app). Its only job is to relaunch
//  the main Glimmer.app with the `--launched-at-login` argument so the
//  main app knows to suppress its window auto-show, then exit.
//
//  This is the macOS-blessed pattern for "launch at login but stay in
//  menu bar" - Apple's own login items (iCloud Drive, etc.) work the same
//  way. The previous heuristic-based approach (systemUptime < 90s) was
//  unreliable for rapid manual relaunches after boot.
//

import AppKit
import Foundation

// Find the main app: walk up from the helper's bundle to the parent .app.
// Helper lives at: Glimmer.app/Contents/Library/LoginItems/Glimmer Login Helper.app
// Main app is 4 levels up.
let helperURL = Bundle.main.bundleURL
let mainAppURL = helperURL
    .deletingLastPathComponent()  // LoginItems
    .deletingLastPathComponent()  // Library
    .deletingLastPathComponent()  // Contents
    .deletingLastPathComponent()  // Glimmer.app

// Sanity check: only proceed if the resolved path actually points at a
// .app bundle. If something has moved the helper out of the standard
// embedded location we'd rather exit silently than launch the wrong app.
guard mainAppURL.pathExtension == "app",
      FileManager.default.fileExists(atPath: mainAppURL.path) else {
    NSLog("Glimmer Login Helper: couldn't resolve main app at \(mainAppURL.path) - exiting")
    exit(0)
}

let config = NSWorkspace.OpenConfiguration()
config.arguments = ["--launched-at-login"]
config.activates = false
config.addsToRecentItems = false
config.createsNewApplicationInstance = false

NSWorkspace.shared.openApplication(at: mainAppURL, configuration: config) { _, error in
    if let error {
        NSLog("Glimmer Login Helper: failed to launch main app: \(error)")
    }
    // Exit either way - the helper has no further job after this.
    DispatchQueue.main.async { exit(0) }
}

// Pump the run loop long enough for the openApplication completion to
// fire. 5 seconds is wildly generous; the launch usually completes in
// well under a second.
RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
exit(0)
