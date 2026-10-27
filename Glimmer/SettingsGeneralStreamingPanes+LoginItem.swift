// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SettingsGeneralStreamingPanes+LoginItem.swift
//
//  `LoginItemManager` - the SMAppService login-item lifecycle behind the
//  General pane's two launch toggles, and the reconcile that launch and the
//  General pane run. Registration plumbing, not a pane, so it lives apart.
//

import GlimmerEngine
import AppKit
import Foundation
import ServiceManagement
import Synchronization

/// Registration follows the saved intent (`launchAtLogin` / `launchMinimized`):
/// minimized registers the HELPER, which relaunches the main app suppressed;
/// otherwise the main app itself opens at login.
enum LoginItemManager {
    static let helperBundleID = "io.ugfugl.Glimmer.LoginHelper"
    /// The app build (path + CFBundleVersion) the last successful register ran from.
    private static let registeredBuildKey = "loginItemRegisteredBuild"
    @MainActor private static var registrationRevision: UInt = 0

    struct RegistrationSnapshot: Equatable {
        let revision: UInt
        let minimized: Bool
        let status: SMAppService.Status
    }

    /// The system side of registration, keyed by helper (true) or main app (false).
    struct Services {
        var status: @MainActor (_ helper: Bool) -> SMAppService.Status
        var register: @MainActor (_ helper: Bool) throws -> Void
        var unregister: @MainActor (_ helper: Bool) throws -> Void
        var helperJobLoaded: @MainActor () async -> Bool?
        var defaults: UserDefaults
        var currentBuild: () -> String

        static var live: Services {
            Services(status: { service(helper: $0).status }, register: { try service(helper: $0).register() },
                     unregister: { try service(helper: $0).unregister() },
                     helperJobLoaded: { await LoginItemManager.helperJobLoaded() },
                     defaults: PersistentStorage.defaults, currentBuild: LoginItemManager.currentBuild)
        }
    }

    @MainActor private static func registrationSnapshot(_ services: Services) -> RegistrationSnapshot? {
        let defaults = services.defaults
        guard defaults.bool(forKey: "launchAtLogin") else { return nil }
        let minimized = defaults.bool(forKey: "launchMinimized")
        return RegistrationSnapshot(revision: registrationRevision, minimized: minimized,
                                    status: services.status(minimized))
    }

    static func acceptsProbe(_ snapshot: RegistrationSnapshot, current: RegistrationSnapshot?, cancelled: Bool) -> Bool {
        !cancelled && snapshot == current
    }

    /// What reconcile does about the saved "Open at login" intent.
    enum Reconcile: Equatable {
        case keep, reregister, resubmit, userRemoved
    }

    /// Minimized launches register the helper; otherwise the main app opens itself.
    private static func service(helper: Bool) -> SMAppService {
        helper ? SMAppService.loginItem(identifier: helperBundleID) : SMAppService.mainApp
    }

    static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    enum RegistrationIssue: Equatable {
        case approval, failed
    }

    static func registrationIssue(for status: SMAppService.Status?) -> RegistrationIssue? {
        switch status {
        case .requiresApproval: .approval
        case .notFound: .failed
        default: nil
        }
    }

    static func registrationFailed(_ error: Error, defaults: UserDefaults = PersistentStorage.defaults) {
        defaults.removeObject(forKey: registeredBuildKey)
        Diag.error("login item registration FAILED: \(error.localizedDescription, privacy: .private)", "LoginItem")
    }

    /// This copy of the app, as far as a login-item registration cares.
    private static func currentBuild() -> String {
        "\(Bundle.main.bundlePath)#\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")"
    }

    /// Gone from Login Items while the app wasn't moved or updated means the
    /// user removed it; after a move or update it's an invalidated registration to
    /// heal. Enabled with no launchd job (a Homebrew upgrade removes it) is resubmitted.
    static func reconcileAction(status: SMAppService.Status, registeredBuild: String?,
                                currentBuild: String, jobLoaded: Bool? = true) -> Reconcile {
        switch status {
        case .enabled:
            return jobLoaded == false ? .resubmit : .keep
        case .requiresApproval:
            return .keep
        case .notRegistered, .notFound:
            return registeredBuild == currentBuild ? .userRemoved : .reregister
        @unknown default:
            return .reregister
        }
    }

    /// Keep saved intent and expose registration failures to the caller and in-app log.
    @MainActor
    @discardableResult
    static func apply(launchAtLogin: Bool, minimized: Bool, services: Services = .live) -> SMAppService.Status {
        registrationRevision &+= 1
        do {
            guard launchAtLogin else {
                if isRegistered(services.status(true)) { try services.unregister(true) }
                if isRegistered(services.status(false)) { try services.unregister(false) }
                services.defaults.removeObject(forKey: registeredBuildKey)
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            // Only one item may open Glimmer at login.
            if isRegistered(services.status(!minimized)) { try services.unregister(!minimized) }
            try services.register(minimized)
            let label = statusLabel(services.status(minimized))
            Diag.notice("login item registered (\(minimized ? "helper" : "main app")) → \(label)", "LoginItem")
            services.defaults.set(services.currentBuild(), forKey: registeredBuildKey)
            return services.status(minimized)
        } catch {
            registrationFailed(error, defaults: services.defaults)
            return .notFound
        }
    }

    /// Square the saved intent with macOS: an update or move self-heals (the
    /// "doesn't start after reboot" fix), a removal turns the toggle off.
    /// Returns the login item's status, nil when Open at login is off.
    @MainActor @discardableResult
    static func reconcile(services: Services = .live) async -> SMAppService.Status? {
        let defaults = services.defaults
        guard let snapshot = registrationSnapshot(services) else { return nil }
        let minimized = snapshot.minimized
        let status = snapshot.status
        var jobLoaded: Bool? = true
        if minimized, status == .enabled {
            jobLoaded = await services.helperJobLoaded()
            let current = registrationSnapshot(services)
            guard acceptsProbe(snapshot, current: current, cancelled: Task.isCancelled) else { return current?.status }
        }
        switch reconcileAction(status: status, registeredBuild: defaults.string(forKey: registeredBuildKey),
                               currentBuild: services.currentBuild(), jobLoaded: jobLoaded) {
        case .keep:
            // A live registration belongs to this build, including one made
            // before builds kept a record, so a later removal is recognized.
            defaults.set(services.currentBuild(), forKey: registeredBuildKey)
            if status == .requiresApproval {
                Diag.notice("login item needs approval in System Settings › General › Login Items", "LoginItem")
            } else {
                Diag.info("login item enabled (\(minimized ? "helper" : "main app"))", "LoginItem")
            }
            return status
        case .reregister:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            return apply(launchAtLogin: true, minimized: minimized, services: services)
        case .resubmit:
            Diag.notice("login helper enabled but launchd has no job - re-registering", "LoginItem")
            return resubmitHelper(minimized: minimized, services: services)
        case .userRemoved:
            Diag.notice("login item removed in System Settings - Open at login is off", "LoginItem")
            defaults.set(false, forKey: "launchAtLogin")
            defaults.removeObject(forKey: registeredBuildKey)
            return nil
        }
    }

    /// Keep unregister and apply atomic after the asynchronous probe's stale-result check.
    @MainActor private static func resubmitHelper(minimized: Bool, services: Services) -> SMAppService.Status {
        try? services.unregister(true)
        return apply(launchAtLogin: true, minimized: minimized, services: services)
    }

    /// Unknown results preserve registration; only launchd's exact missing-service result permits repair.
    static func helperJobLoaded(timeout: Duration = .seconds(2),
                                makeProcess: @escaping @Sendable () -> Process = makeJobProbe) async -> Bool? {
        await Task.detached(priority: .utility) {
            await withCheckedContinuation { continuation in
                let once = SingleResume(continuation)
                let expired = Mutex(false)
                let process = makeProcess()
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                process.terminationHandler = { process in
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    once.resume(jobLoaded(status: process.terminationStatus,
                                          error: String(data: data, encoding: .utf8) ?? ""))
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    if once.resume(nil) {
                        expired.withLock { $0 = true }
                        if process.isRunning { process.terminate() }
                    }
                }
                do {
                    try process.run()
                    if expired.withLock({ $0 }), process.isRunning { process.terminate() }
                } catch {
                    once.resume(nil)
                }
            }
        }.value
    }

    private static func makeJobProbe() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(helperBundleID)"]
        return process
    }

    static func jobLoaded(status: Int32?, error: String, userID: uid_t = getuid()) -> Bool? {
        if status == 0 { return true }
        let missing = "Could not find service \"\(helperBundleID)\" in domain for user gui: \(userID)"
        return status == 113 && error.components(separatedBy: .newlines).contains(missing) ? false : nil
    }

    /// Open at login's own item starts Glimmer (menu-bar only when asked), so macOS's
    /// reopen-at-login must not start it first as a plain launch with its window up.
    @MainActor private static var relaunchDisabled = false

    @MainActor
    static func syncRelaunchOnLogin(_ launchAtLogin: Bool) {
        guard launchAtLogin != relaunchDisabled else { return }
        relaunchDisabled = launchAtLogin
        if launchAtLogin { NSApp.disableRelaunchOnLogin() } else { NSApp.enableRelaunchOnLogin() }
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
