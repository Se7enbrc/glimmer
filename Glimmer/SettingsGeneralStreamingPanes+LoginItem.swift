//
//  SettingsGeneralStreamingPanes+LoginItem.swift
//
//  `LoginItemManager` - the SMAppService login-item lifecycle behind the
//  General pane's two launch toggles, plus the reconcile that AppModel+Lifecycle
//  runs at launch and the General pane runs when it shows. Split out of
//  SettingsGeneralStreamingPanes.swift to keep that file under the length
//  limit: this is registration plumbing, not a pane, and it has a caller
//  outside Settings.
//

import Foundation
import ServiceManagement

/// Owns the SMAppService login-item lifecycle, shared by the General toggles
/// and the reconcile. Registration is keyed by the user's saved
/// intent (UserDefaults `launchAtLogin` / `launchMinimized`):
///   * minimized → register the HELPER (relaunches the main app suppressed)
///   * not minimized → register the main app (normal open at login)
enum LoginItemManager {
    static let helperBundleID = "io.ugfugl.Glimmer.LoginHelper"
    /// The app build (path + CFBundleVersion) the last successful register ran from.
    private static let registeredBuildKey = "loginItemRegisteredBuild"

    /// What reconcile does about the saved "Open at login" intent.
    enum Reconcile: Equatable {
        case keep, reregister, userRemoved
    }

    /// The service that backs the user's current intent.
    private static func activeService(minimized: Bool) -> SMAppService {
        minimized ? SMAppService.loginItem(identifier: helperBundleID) : SMAppService.mainApp
    }

    /// This copy of the app, as far as a login-item registration cares.
    private static func currentBuild() -> String {
        "\(Bundle.main.bundlePath)#\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")"
    }

    /// Gone from Login Items while the app wasn't moved or updated means the
    /// user removed it; after a move or update (or with no record, from builds
    /// that kept none) it's an invalidated registration to heal.
    static func reconcileAction(status: SMAppService.Status, registeredBuild: String?,
                                currentBuild: String) -> Reconcile {
        switch status {
        case .enabled, .requiresApproval:
            return .keep
        case .notRegistered, .notFound:
            return registeredBuild == currentBuild ? .userRemoved : .reregister
        @unknown default:
            return .reregister
        }
    }

    /// Apply the desired state, returning the resulting status so the caller can
    /// prompt for approval. Surfaces failures to the in-app log (the old code
    /// swallowed them into os_log, which is why a broken registration looked
    /// fine until the next reboot never happened).
    @discardableResult
    static func apply(launchAtLogin: Bool, minimized: Bool) -> SMAppService.Status {
        let helper = SMAppService.loginItem(identifier: helperBundleID)
        let mainApp = SMAppService.mainApp
        do {
            guard launchAtLogin else {
                if helper.status == .enabled { try helper.unregister() }
                if mainApp.status == .enabled { try mainApp.unregister() }
                UserDefaults.standard.removeObject(forKey: registeredBuildKey)
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            if minimized {
                if mainApp.status == .enabled { try mainApp.unregister() }
                try helper.register()
                Diag.notice("login item registered (helper) → \(statusLabel(helper.status))", "LoginItem")
            } else {
                if helper.status == .enabled { try helper.unregister() }
                try mainApp.register()
                Diag.notice("login item registered (main app) → \(statusLabel(mainApp.status))", "LoginItem")
            }
            UserDefaults.standard.set(currentBuild(), forKey: registeredBuildKey)
            return activeService(minimized: minimized).status
        } catch {
            Diag.error("login item registration FAILED: \(error.localizedDescription)", "LoginItem")
            return .notFound
        }
    }

    /// Square the saved intent with macOS, at launch and when the General pane
    /// shows: a registration invalidated by an update or move self-heals (the
    /// "doesn't start after reboot" fix); one the user removed turns the toggle
    /// off. Returns the login item's status, nil when Open at login is off.
    @discardableResult
    static func reconcile() -> SMAppService.Status? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "launchAtLogin") else { return nil }
        let minimized = defaults.bool(forKey: "launchMinimized")
        let status = activeService(minimized: minimized).status
        switch reconcileAction(status: status, registeredBuild: defaults.string(forKey: registeredBuildKey),
                               currentBuild: currentBuild()) {
        case .keep:
            // A live registration belongs to this build, including one made
            // before builds kept a record, so a later removal is recognized.
            defaults.set(currentBuild(), forKey: registeredBuildKey)
            if status == .requiresApproval {
                Diag.notice("login item needs approval in System Settings › General › Login Items", "LoginItem")
            } else {
                Diag.info("login item enabled (\(minimized ? "helper" : "main app"))", "LoginItem")
            }
            return status
        case .reregister:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            return apply(launchAtLogin: true, minimized: minimized)
        case .userRemoved:
            Diag.notice("login item removed in System Settings - Open at login is off", "LoginItem")
            defaults.set(false, forKey: "launchAtLogin")
            defaults.removeObject(forKey: registeredBuildKey)
            return nil
        }
    }

    static func statusLabel(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
