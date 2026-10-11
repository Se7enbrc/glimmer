// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Open at login and the Wi-Fi helper against fake system services: which item
// is registered, what reconcile repairs, and what a failed registration shows.

import Foundation
import ServiceManagement
import Testing
@testable import Glimmer

@MainActor
final class LoginItemFake {
    static let build = "/Applications/Glimmer.app#2026.10.7"
    var statuses: [Bool: SMAppService.Status] = [true: .notRegistered, false: .notRegistered]
    var events: [String] = []
    var registerError: Error?
    var jobLoaded: Bool? = true
    let defaults: UserDefaults
    private let suite = "LoginItemApplyTests.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    var services: LoginItemManager.Services {
        LoginItemManager.Services(
            status: { self.statuses[$0] ?? .notRegistered },
            register: { helper in
                self.events.append("register \(helper ? "helper" : "app")")
                if let error = self.registerError { throw error }
                self.statuses[helper] = .enabled
            },
            unregister: { helper in
                self.events.append("unregister \(helper ? "helper" : "app")")
                self.statuses[helper] = .notRegistered
            },
            helperJobLoaded: { self.jobLoaded },
            defaults: defaults, currentBuild: { Self.build })
    }

    var registeredBuild: String? { defaults.string(forKey: "loginItemRegisteredBuild") }

    func wantsLogin(minimized: Bool, registered: String? = LoginItemFake.build) {
        defaults.set(true, forKey: "launchAtLogin")
        defaults.set(minimized, forKey: "launchMinimized")
        defaults.set(registered, forKey: "loginItemRegisteredBuild")
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
struct LoginItemApplyTests {
    private enum Rejected: Error { case byMacOS }

    @Test func minimizedRegistersTheHelperInPlaceOfTheApp() throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.statuses[false] = .enabled
        #expect(LoginItemManager.apply(launchAtLogin: true, minimized: true, services: fake.services) == .enabled)
        #expect(fake.events == ["unregister app", "register helper"])
        #expect(fake.registeredBuild == LoginItemFake.build)
    }

    @Test func turningItOffUnregistersBothAndForgetsTheBuild() throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.statuses = [true: .enabled, false: .requiresApproval]
        fake.wantsLogin(minimized: false)
        #expect(LoginItemManager.apply(launchAtLogin: false, minimized: false, services: fake.services) == .notRegistered)
        #expect(fake.events == ["unregister helper", "unregister app"])
        #expect(fake.registeredBuild == nil)
    }

    @Test func aRejectedRegistrationReadsAsFailed() throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.wantsLogin(minimized: false)
        fake.registerError = Rejected.byMacOS
        #expect(LoginItemManager.apply(launchAtLogin: true, minimized: false, services: fake.services) == .notFound)
        #expect(fake.registeredBuild == nil)
        #expect(fake.defaults.bool(forKey: "launchAtLogin"))
    }

    @Test func reconcileLeavesOpenAtLoginOffAlone() async throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        #expect(await LoginItemManager.reconcile(services: fake.services) == nil)
        #expect(fake.events.isEmpty)
    }

    @Test func reconcileRespectsARemovalInSystemSettings() async throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.wantsLogin(minimized: false)
        #expect(await LoginItemManager.reconcile(services: fake.services) == nil)
        #expect(!fake.defaults.bool(forKey: "launchAtLogin"))
        #expect(fake.events.isEmpty)
    }

    @Test func reconcileReRegistersAfterAnUpdate() async throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.wantsLogin(minimized: false, registered: "/Applications/Glimmer.app#2026.10.6")
        #expect(await LoginItemManager.reconcile(services: fake.services) == .enabled)
        #expect(fake.events == ["register app"])
        #expect(fake.registeredBuild == LoginItemFake.build)
    }

    @Test func reconcileResubmitsAHelperLaunchdLost() async throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.wantsLogin(minimized: true)
        fake.statuses[true] = .enabled
        fake.jobLoaded = false
        #expect(await LoginItemManager.reconcile(services: fake.services) == .enabled)
        #expect(fake.events == ["unregister helper", "register helper"])
    }

    @Test func reconcileKeepsAPendingApprovalAndClaimsIt() async throws {
        let fake = try LoginItemFake()
        defer { fake.cleanUp() }
        fake.wantsLogin(minimized: false, registered: nil)
        fake.statuses[false] = .requiresApproval
        #expect(await LoginItemManager.reconcile(services: fake.services) == .requiresApproval)
        #expect(fake.events.isEmpty)
        #expect(fake.registeredBuild == LoginItemFake.build)
    }
}

@MainActor
struct AWDLHelperEnableTests {
    private let suite = "AWDLHelperEnableTests.\(UUID().uuidString)"

    private func manager(_ defaults: UserDefaults, status: @escaping () -> SMAppService.Status,
                         register: @escaping () throws -> Void = {}) -> AWDLHelperManager {
        AWDLHelperManager(operations: .init(
            status: status, register: register, unregister: {}, setDown: { _, _ in true }, invalidate: {},
            reachable: { true }, count: { 0 }, sleep: { _ in }, telemetry: { _, _ in }), defaults: defaults)
    }

    /// Runs `enable()` until its register call has returned or thrown.
    private func enable(_ defaults: UserDefaults, register: @escaping () throws -> Void) async -> AWDLHelperManager {
        let (registered, signal) = AsyncStream<Void>.makeStream()
        var status = SMAppService.Status.notRegistered
        let helper = manager(defaults, status: { status }, register: {
            signal.yield()
            try register()
            status = .enabled
        })
        helper.enable()
        var waiter = registered.makeAsyncIterator()
        _ = await waiter.next()
        return helper
    }

    @Test func enablingRegistersAndRemembersTheChoice() async throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = await enable(defaults) {}
        #expect(helper.state == .enabled)
        #expect(helper.isEnabled)
        #expect(defaults.object(forKey: "awdlHelperEnabled") as? Bool == true)
    }

    @Test func aWedgedRecordPointsAtApplesGuide() async throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = await enable(defaults) { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
        #expect(helper.recoveryDocURL == AWDLHelperManager.loginItemsHelpURL)
        #expect(!helper.isEnabled)
        #expect(!helper.isRegistered)
    }

    @Test func anotherFailureShowsItsOwnErrorWithoutTheGuide() async throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = await enable(defaults) { throw NSError(domain: "SMAppServiceErrorDomain", code: 22) }
        guard case .unavailable(let why) = helper.state else {
            Issue.record("expected unavailable, got \(helper.state)")
            return
        }
        #expect(why.contains("SMAppServiceErrorDomain 22"))
        #expect(helper.recoveryDocURL == nil)
    }

    @Test func pendingApprovalCountsAsOnButNotEnabled() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = manager(defaults) { .requiresApproval }
        #expect(helper.isRegistered)
        #expect(!helper.isEnabled)
        #expect(helper.shouldPromptToEnable)
    }

    @Test func dontAskAgainIsKeptWithTheHelpersOwnDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = manager(defaults) { .notRegistered }
        #expect(helper.shouldPromptToEnable)
        helper.promptSuppressed = true
        #expect(defaults.bool(forKey: "awdlHelperPromptSuppressed"))
        #expect(!helper.shouldPromptToEnable)
    }
}
