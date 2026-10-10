// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  LoginItemReconcileTests.swift
//
//  Open at login: a login item gone while the app is unchanged is the user's
//  removal and is respected; after an update or move, or with its launchd job
//  removed, it is re-registered.
//

import ServiceManagement
import Synchronization
import Testing
@testable import Glimmer

struct LoginItemReconcileTests {

    private enum RegistrationError: Error {
        case rejected
    }

    private let build = "/Applications/Glimmer.app#2026.9.7"

    private func action(_ status: SMAppService.Status, registered: String?) -> LoginItemManager.Reconcile {
        LoginItemManager.reconcileAction(status: status, registeredBuild: registered, currentBuild: build)
    }

    @Test func registeredIncludesPendingApproval() {
        #expect(LoginItemManager.isRegistered(.requiresApproval))
        #expect(LoginItemManager.isRegistered(.enabled))
        #expect(!LoginItemManager.isRegistered(.notRegistered))
        #expect(!LoginItemManager.isRegistered(.notFound))
    }

    @Test func registrationFailureGetsAnActionableWarning() {
        #expect(LoginItemManager.registrationIssue(for: .notFound) == .failed)
        #expect(LoginItemManager.registrationIssue(for: .requiresApproval) == .approval)
        #expect(LoginItemManager.registrationIssue(for: .enabled) == nil)
        #expect(LoginItemManager.registrationIssue(for: .notRegistered) == nil)
        #expect(LoginItemManager.registrationIssue(for: nil) == nil)
    }

    @Test func enabledOrAwaitingApprovalIsLeftAlone() {
        #expect(action(.enabled, registered: build) == .keep)
        #expect(action(.enabled, registered: nil) == .keep)
        #expect(action(.requiresApproval, registered: "/Applications/Glimmer.app#2026.9.6") == .keep)
    }

    @Test func enabledWithNoLaunchdJobIsResubmitted() {
        let resubmit = LoginItemManager.reconcileAction(status: .enabled, registeredBuild: build,
                                                        currentBuild: build, jobLoaded: false)
        #expect(resubmit == .resubmit)
        #expect(LoginItemManager.reconcileAction(status: .requiresApproval, registeredBuild: build,
                                                 currentBuild: build, jobLoaded: false) == .keep)
    }

    @Test func inconclusiveJobProbeKeepsTheRegistration() {
        #expect(LoginItemManager.reconcileAction(status: .enabled, registeredBuild: build,
                                                 currentBuild: build, jobLoaded: nil) == .keep)
    }

    @Test func onlyTheExactMissingGUIServicePermitsResubmission() {
        let missing = "Could not find service \"\(LoginItemManager.helperBundleID)\" in domain for user gui: 501"
        #expect(LoginItemManager.jobLoaded(status: 113, error: "Bad request.\n\(missing)\n", userID: 501) == false)
        #expect(LoginItemManager.jobLoaded(status: 0, error: "", userID: 501) == true)
        #expect(LoginItemManager.jobLoaded(status: nil, error: missing, userID: 501) == nil)
        #expect(LoginItemManager.jobLoaded(status: 1, error: missing, userID: 501) == nil)
        #expect(LoginItemManager.jobLoaded(status: 113, error: "Operation not permitted", userID: 501) == nil)
        #expect(LoginItemManager.jobLoaded(status: 113, error: missing, userID: 502) == nil)
        #expect(LoginItemManager.jobLoaded(status: 113, error: missing + "1", userID: 501) == nil)
        let other = missing.replacingOccurrences(of: LoginItemManager.helperBundleID, with: "other.service")
        #expect(LoginItemManager.jobLoaded(status: 113, error: other, userID: 501) == nil)
    }

    @Test func delayedProbeCannotRepairAfterRegistrationOrIntentChanges() {
        let snapshot = LoginItemManager.RegistrationSnapshot(revision: 7, minimized: true, status: .enabled)
        #expect(LoginItemManager.acceptsProbe(snapshot, current: snapshot, cancelled: false))
        #expect(!LoginItemManager.acceptsProbe(snapshot, current: nil, cancelled: false))
        #expect(!LoginItemManager.acceptsProbe(snapshot, current: snapshot, cancelled: true))
        let changed: [LoginItemManager.RegistrationSnapshot] = [
            .init(revision: 8, minimized: true, status: .enabled),
            .init(revision: 7, minimized: false, status: .enabled),
            .init(revision: 7, minimized: true, status: .requiresApproval)
        ]
        for current in changed {
            #expect(!LoginItemManager.acceptsProbe(snapshot, current: current, cancelled: false))
        }
    }

    @MainActor
    @Test func hungJobProbeHasADeadlineWithoutBlockingTheMainActor() async {
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        let factoryOffMain = Mutex(false)
        // EOF is withheld until the probe returns; this failsafe prevents a broken deadline from hanging the suite.
        let cleanup = DispatchWorkItem { @Sendable in try? input.fileHandleForWriting.close() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5), execute: cleanup)
        defer { cleanup.cancel() }

        let outcome = await LoginItemManager.helperJobLoaded(timeout: .milliseconds(50)) {
            factoryOffMain.withLock { $0 = !Thread.isMainThread }
            return process
        }
        try? input.fileHandleForWriting.close()
        if process.processIdentifier > 0 {
            await Task.detached { process.waitUntilExit() }.value
        }
        #expect(factoryOffMain.withLock { $0 })
        #expect(process.processIdentifier > 0)
        #expect(outcome == nil)
        #expect(!process.isRunning)
    }

    @Test func failedJobProbeLaunchIsUnknown() async {
        let result = await LoginItemManager.helperJobLoaded {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/nonexistent/glimmer-job-probe")
            return process
        }
        #expect(result == nil)
    }

    @Test func removedFromTheSameBuildTurnsTheToggleOff() {
        #expect(action(.notRegistered, registered: build) == .userRemoved)
        #expect(action(.notFound, registered: build) == .userRemoved)
    }

    @Test func anUpdateOrMoveReRegisters() {
        #expect(action(.notRegistered, registered: "/Applications/Glimmer.app#2026.9.6") == .reregister)
        #expect(action(.notFound, registered: "/Applications/Games/Glimmer.app#2026.9.7") == .reregister)
    }

    @Test func noRecordFromAnOlderBuildReRegisters() {
        #expect(action(.notRegistered, registered: nil) == .reregister)
    }

    @Test func failedRegistrationRetriesWithoutTurningOffIntent() throws {
        let suiteName = "LoginItemReconcileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin")
        defaults.set(build, forKey: "loginItemRegisteredBuild")

        do {
            try register { throw RegistrationError.rejected }
        } catch {
            LoginItemManager.registrationFailed(error, defaults: defaults)
        }

        #expect(defaults.bool(forKey: "launchAtLogin"))
        #expect(defaults.string(forKey: "loginItemRegisteredBuild") == nil)
        #expect(action(.notRegistered, registered: defaults.string(forKey: "loginItemRegisteredBuild")) == .reregister)
    }

    private func register(_ operation: () throws -> Void) throws {
        try operation()
    }
}
