import Foundation
import os.log

/// One-shot migration of user data orphaned by the sandbox→unsandbox flip.
///
/// While sandboxed, UserDefaults + FileIdentityStore lived under
/// `~/Library/Containers/io.ugfugl.Glimmer/Data/Library/…`. Unsandboxed, the
/// same APIs read `~/Library/…` directly, so an updating user silently loses
/// their paired-hosts list and regenerates identity (forcing a re-pair). This
/// copies the container's Preferences + Application Support into the host
/// locations exactly once, never overwriting anything already present.
enum ContainerMigration {

    static let didMigrateKey = "didMigrateFromContainer"
    private static let bundleID = "io.ugfugl.Glimmer"
    private static let log = Logger(subsystem: bundleID, category: "ContainerMigration")

    /// Run the migration if it hasn't run yet. Idempotent and a no-op when the
    /// old container is absent (fresh installs, already-migrated users).
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didMigrateKey) else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let containerLib = home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true)
        let hostLib = home.appendingPathComponent("Library", isDirectory: true)

        guard fm.fileExists(atPath: containerLib.path) else {
            // Nothing to migrate (fresh install / never sandboxed). Latch so we
            // never probe the container again.
            defaults.set(true, forKey: didMigrateKey)
            return
        }

        var copied = 0
        copied += copyTree(
            from: containerLib.appendingPathComponent("Application Support", isDirectory: true),
            to: hostLib.appendingPathComponent("Application Support", isDirectory: true))
        copied += copyTree(
            from: containerLib.appendingPathComponent("Preferences", isDirectory: true),
            to: hostLib.appendingPathComponent("Preferences", isDirectory: true))

        // Our prefs plist may have just landed under the host domain; drop
        // CFPreferences' in-memory cache for it so this launch reads the
        // migrated values instead of the empty domain it opened with.
        CFPreferencesAppSynchronize(bundleID as CFString)

        log.notice("container migration copied \(copied, privacy: .public) item(s) from the sandbox container")
        defaults.set(true, forKey: didMigrateKey)
    }

    /// Recursively copy `src` into `dst`, creating `dst` as needed and skipping
    /// any destination path that already exists (copy-not-move, never clobber).
    /// Returns the number of files/dirs created. Safe to call on a missing src.
    @discardableResult
    static func copyTree(from src: URL, to dst: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            guard !fm.fileExists(atPath: dst.path) else { return 0 }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            do { try fm.copyItem(at: src, to: dst); return 1 } catch { return 0 }
        }

        var made = 0
        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            made += 1
        }
        let entries = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            made += copyTree(from: entry, to: dst.appendingPathComponent(entry.lastPathComponent))
        }
        return made
    }
}
