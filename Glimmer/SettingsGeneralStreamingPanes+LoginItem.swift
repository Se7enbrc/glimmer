//
//  SettingsGeneralStreamingPanes+LoginItem.swift
//
//  `LoginItemManager` - the SMAppService login-item lifecycle behind the
//  General pane's two launch toggles, plus the launch-time reconcile
//  AppModel+Lifecycle calls. Split out of SettingsGeneralStreamingPanes.swift
//  to keep that file under the length limit: this is registration plumbing, not
//  a pane, and it has a caller outside Settings.
//

import Foundation
import ServiceManagement

/// Owns the SMAppService login-item lifecycle, shared by the General toggles
/// and the launch-time reconcile. Registration is keyed by the user's saved
/// intent (UserDefaults `launchAtLogin` / `launchMinimized`):
///   * minimized → register the HELPER (relaunches the main app suppressed)
///   * not minimized → register the main app (normal open at login)
enum LoginItemManager {
    static let helperBundleID = "io.ugfugl.Glimmer.LoginHelper"

    /// The service that backs the user's current intent.
    private static func activeService(minimized: Bool) -> SMAppService {
        minimized ? SMAppService.loginItem(identifier: helperBundleID) : SMAppService.mainApp
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
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            if minimized {
                if mainApp.status == .enabled { try mainApp.unregister() }
                try helper.register()
                Diag.notice("login item registered (helper) → \(statusLabel(helper.status))", "LoginItem")
                return helper.status
            } else {
                if helper.status == .enabled { try helper.unregister() }
                try mainApp.register()
                Diag.notice("login item registered (main app) → \(statusLabel(mainApp.status))", "LoginItem")
                return mainApp.status
            }
        } catch {
            Diag.error("login item registration FAILED: \(error.localizedDescription)", "LoginItem")
            return .notFound
        }
    }

    /// Re-assert the saved intent at launch so a registration invalidated by an
    /// app update / move self-heals - the root cause of "doesn't start after
    /// reboot". Runs only when the user wants launch-at-login, and only
    /// re-registers when the actual status has drifted from enabled.
    static func reconcile() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        let minimized = UserDefaults.standard.bool(forKey: "launchMinimized")
        let status = activeService(minimized: minimized).status
        switch status {
        case .enabled:
            Diag.info("login item enabled (\(minimized ? "helper" : "main app"))", "LoginItem")
        case .requiresApproval:
            Diag.notice("login item needs approval in System Settings ▸ General ▸ Login Items", "LoginItem")
        default:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            apply(launchAtLogin: true, minimized: minimized)
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
