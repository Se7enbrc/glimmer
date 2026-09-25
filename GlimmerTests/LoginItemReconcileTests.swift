//
//  LoginItemReconcileTests.swift
//
//  Open at login: a login item gone while the app is unchanged is the user's
//  removal and is respected; after an update or move it is re-registered.
//

import ServiceManagement
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

    @Test func enabledOrAwaitingApprovalIsLeftAlone() {
        #expect(action(.enabled, registered: build) == .keep)
        #expect(action(.enabled, registered: nil) == .keep)
        #expect(action(.requiresApproval, registered: "/Applications/Glimmer.app#2026.9.6") == .keep)
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
