// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Resolve test storage before any singleton can open the installation's files or preferences.
public enum PersistentStorage {
    public static let isTesting: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["GLIMMER_TESTING"] != nil || environment["GLIMMER_UI_TESTING"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
    }()

    public static let testRoot: URL? = {
        guard isTesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimmer-tests-" + UUID().uuidString, isDirectory: true)
    }()

    public static var home: URL { testRoot ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    public static var applicationSupport: URL {
        testRoot?.appendingPathComponent("Library/Application Support", isDirectory: true)
            ?? URL.applicationSupportDirectory
    }
    public static var caches: URL {
        testRoot?.appendingPathComponent("Library/Caches", isDirectory: true) ?? URL.cachesDirectory
    }
    public static var logs: URL { home.appendingPathComponent("Library/Logs/Glimmer", isDirectory: true) }

    public static var defaults: UserDefaults {
        guard let testRoot else { return .standard }
        guard let defaults = UserDefaults(suiteName: testRoot.lastPathComponent) else {
            preconditionFailure("Could not isolate test preferences")
        }
        return defaults
    }

    public static func supportRoot(base: URL? = nil) -> URL {
        checked(base ?? applicationSupport)
    }

    /// Reject explicit production roots too, including symlinks that escape a test fixture.
    public static func checked(_ url: URL) -> URL {
        if isTesting {
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            precondition(url.resolvingSymlinksInPath().path.hasPrefix(temporary),
                         "Tests must keep persistent storage in a temporary directory")
        }
        return url
    }
}
