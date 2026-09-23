//
//  AppModel+Power.swift
//
//  Wake and Connect: Wake-on-LAN packets for a PC, a wait for Sunshine, then a
//  launch, or a notification when another app is in front. Per-PC "Wake on LAN"
//  gates it; the state the button reads (waking, last failure) lives here.
//

import AppKit
import Foundation
import UserNotifications

/// How one wake went. `sent` is a send that wasn't asked to wait for Sunshine.
enum WakeOutcome: Equatable {
    case noMac, couldNotSend, sent, answered, noAnswer

    var failureReason: AppModel.WakeFailureReason? {
        switch self {
        case .couldNotSend: .couldNotSend
        case .noAnswer: .noAnswer
        case .noMac, .sent, .answered: nil
        }
    }
}

extension AppModel.WakeFailureReason {
    /// Under Wake and Connect after a failed wake, in the launcher and the menu bar.
    var line: String {
        switch self {
        case .couldNotSend: "Couldn't send the wake signal. Check this Mac's network."
        case .noAnswer: "No answer. \(AppModel.wakeNoAnswerHint)"
        }
    }
}

extension AppModel {
    private static var wakeTask: Task<Void, Never>?
    static let wakeBudgetSeconds: Double = 90
    /// The launcher and `glimmer wake` both say this when a wake gets no answer.
    static let wakeNoAnswerHint = "Wake on LAN works on your home network; over Tailscale it can't reach the PC."

    /// The PC opted in and Sunshine has told us its network address.
    func canWake(_ host: Host) -> Bool {
        host.wakeOnLAN && WakeOnLAN.normalizeMac(host.macAddress) != nil
    }

    func isWaking(_ host: Host) -> Bool { wakingHostID == host.id }

    /// Wake and Connect with the button's state around it. The stream starts as soon as
    /// the PC answers, unless another app is in front and Glimmer may notify: then a
    /// notification reports the result instead of a stream opening over that app.
    func wakeHost(_ host: Host, thenConnect: Bool) {
        guard WakeOnLAN.normalizeMac(host.macAddress) != nil else { return }
        Self.wakeTask?.cancel()
        wakingHostID = host.id
        wakeFailedHostID = nil
        wakeFailureReason = nil
        hostStatusTask?.cancel()
        hostStatusTask = nil
        WakeNotifier.shared.prepare(for: self, host: host)
        Self.wakeTask = Task { @MainActor in
            defer {
                if wakingHostID == host.id { wakingHostID = nil }
                restartHostStatusPolling()
            }
            let outcome = await sendWakeAndWait(host, waitSeconds: Self.wakeBudgetSeconds)
            guard !Task.isCancelled else { return }
            if let reason = outcome.failureReason {
                wakeFailedHostID = host.id
                wakeFailureReason = reason
                if !NSApp.isActive { WakeNotifier.shared.postFailed(host, reason: reason) }
            } else if outcome == .answered, thenConnect, selectedHost?.id == host.id, !isStreaming {
                // A notice the user won't see would drop the connect they asked for.
                if !NSApp.isActive, await WakeNotifier.canPost() {
                    WakeNotifier.shared.postAwake(host)
                } else if !Task.isCancelled {
                    streamHeroApp()
                }
            }
        }
    }

    /// Three bursts a second apart cover a NIC that misses the first packet, then
    /// Sunshine gets `waitSeconds` to answer (nil sends only). A first burst that sent
    /// nothing means this Mac can't reach the network, so there's nothing to wait for.
    func sendWakeAndWait(_ host: Host, waitSeconds: Double?,
                         send: @escaping @Sendable (String, [String?]) -> Int = WakeOnLAN.send) async -> WakeOutcome {
        guard let mac = WakeOnLAN.normalizeMac(host.macAddress) else { return .noMac }
        let addresses = [host.localAddress, host.manualAddress]
        for burst in 0..<3 {
            let sent = await Task.detached(priority: .userInitiated) { send(mac, addresses) }.value
            Diag.notice("Wake on LAN: burst \(burst + 1), \(sent) packets for \(host.displayName)", "Power")
            if sent == 0 {
                if burst == 0 { return .couldNotSend }
                break
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return .sent }
        }
        guard let waitSeconds else { return .sent }
        guard await waitForSunshine(host: host, budgetSeconds: waitSeconds) else {
            if !Task.isCancelled {
                Diag.notice("Wake on LAN: \(host.displayName) did not answer within \(Int(waitSeconds)) s", "Power")
            }
            return .noAnswer
        }
        Diag.notice("Wake on LAN: \(host.displayName) is answering", "Power")
        return .answered
    }

    /// Drops our wait only; the packets are already on the wire.
    func cancelWake(_ host: Host) {
        guard wakingHostID == host.id else { return }
        Diag.notice("Wake on LAN: stopped waiting for \(host.displayName)", "Power")
        Self.wakeTask?.cancel()
        Self.wakeTask = nil
        wakingHostID = nil
        restartHostStatusPolling()
    }

    /// Sunshine's /serverinfo every 3 s until it answers or the budget ends; this polls
    /// the app, not the power state. mDNS runs alongside in case the PC came back on a
    /// new DHCP address, and each try dials the latest saved address.
    private func waitForSunshine(host: Host, budgetSeconds: Double) async -> Bool {
        let search = Task { await healAddress(of: host, within: budgetSeconds) }
        defer { search.cancel() }
        let deadline = Date().addingTimeInterval(budgetSeconds)
        while Date() < deadline {
            let current = hosts.first { $0.id == host.id } ?? host
            let client = NetworkClient(server: nativeServerInfo(for: current))
            let answered = (try? await client.fetchServerInfo()) != nil
            await client.shutdown()
            if answered { return true }
            do { try await Task.sleep(for: .seconds(3)) } catch { return false }
        }
        return false
    }
}

/// Reports a wake while another app is in front, so a stream never opens over it.
/// Becomes the notification center's delegate on first use; Connect and Try Again
/// come back through here.
@MainActor
final class WakeNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WakeNotifier()
    private weak var model: AppModel?
    private static let awakeCategory = "wake.awake"
    private static let failedCategory = "wake.failed"
    private static let connectAction = "wake.connect"
    private static let tryAgainAction = "wake.tryAgain"

    /// Runs on the Wake and Connect click, so any permission prompt follows it.
    func prepare(for model: AppModel, host: Host) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(host)])
        guard center.delegate !== self else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.awakeCategory, actions: [
                UNNotificationAction(identifier: Self.connectAction, title: "Connect", options: .foreground)
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.failedCategory, actions: [
                UNNotificationAction(identifier: Self.tryAgainAction, title: "Try Again", options: .foreground)
            ], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notifications are allowed with a visible style; declined, not yet answered or
    /// set to None in System Settings is a no.
    static func canPost() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return shows(settings.authorizationStatus, style: settings.alertStyle)
    }

    nonisolated static func shows(_ status: UNAuthorizationStatus, style: UNAlertStyle) -> Bool {
        status == .authorized && style != .none
    }

    func postAwake(_ host: Host) {
        post(host, title: "\(host.displayName) is awake", body: "Connect to start streaming.", category: Self.awakeCategory)
    }

    func postFailed(_ host: Host, reason: AppModel.WakeFailureReason) {
        let body = switch reason {
        case .couldNotSend: reason.line
        case .noAnswer: "No answer within \(Int(AppModel.wakeBudgetSeconds)) seconds. "
            + "Wake on LAN works on your home network, not over Tailscale."
        }
        post(host, title: "\(host.displayName) didn't wake up", body: body, category: Self.failedCategory)
    }

    private static func identifier(_ host: Host) -> String { "wake.\(host.id)" }

    private func post(_ host: Host, title: String, body: String, category: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["hostID": host.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.identifier(host), content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let hostID = content.userInfo["hostID"] as? String
        Task { @MainActor in self.respond(action: action, category: category, hostID: hostID) }
        completionHandler()
    }

    /// Clicking an awake notification itself also connects; a failure's body click, or
    /// any click on a notice left over once a stream is up, only brings Glimmer forward.
    private func respond(action: String, category: String, hostID: String?) {
        guard let model, !model.isStreaming, let host = model.hosts.first(where: { $0.id == hostID }) else { return }
        let connect = action == Self.connectAction
            || (category == Self.awakeCategory && action == UNNotificationDefaultActionIdentifier)
        guard connect || action == Self.tryAgainAction else { return }
        if model.selectedHost?.id != host.id { model.selectHost(host) }
        if connect { model.streamHeroApp() } else { model.wakeHost(host, thenConnect: true) }
    }
}
