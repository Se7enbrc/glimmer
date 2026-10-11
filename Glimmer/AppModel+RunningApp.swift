// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI

extension AppModel {
    var quitInProgressMessage: String? {
        guard let quittingHostID else { return nil }
        let pc = hosts.first { $0.id == quittingHostID }?.displayName ?? "the PC"
        return "An app is quitting on \(pc). Try again when it finishes."
    }

    static func notStreamingMessage(_ pc: String) -> String { "Glimmer isn't streaming from \(pc)." }

    func runningApp(on host: Host) -> LibraryApp? {
        if isStreaming, let attempt = lastLaunchAttempt, attempt.host.id == host.id { return attempt.app }
        guard HostLiveStatus.isFresh(hostLiveStatus, for: host.id), let live = hostLiveStatus else { return nil }
        switch live.state {
        case .streamingApp(let name): return host.apps.first { $0.name == name }
        case .streamingUnknownApp(let id): return LibraryApp(id: id, name: "the running app", hdr: false, hidden: false)
        default: return nil
        }
    }

    func publishDisconnectedApp(_ app: LibraryApp, on host: Host) {
        guard RunningAppOwnership.load(pc: host.id, defaults: hostsDefaults)?.appID == app.id,
              selectedHost?.id == host.id else { return }
        hostLiveStatus = HostLiveStatus(hostID: host.id, state: .streamingApp(name: app.name),
                                       rttMs: nil, sunshineVersion: nil, capturedAt: Date())
    }

    func canResume(_ app: LibraryApp, on host: Host) -> Bool {
        runningApp(on: host)?.id == app.id
            && RunningAppOwnership.load(pc: host.id, defaults: hostsDefaults)?.appID == app.id
    }

    func streamActionTitle(_ app: LibraryApp, on host: Host) -> String {
        "\(canResume(app, on: host) ? "Resume" : "Stream") \(app.name)"
    }

    static func quitTitle(app: String, pc: String) -> String { "Quit \(app) on \(pc)?" }
    static let quitMessage = "Unsaved progress may be lost."

    /// A modal alert survives a menu bar dismissal or the stream-ended toast's expiry.
    func requestQuit(_ app: LibraryApp, on host: Host) {
        let alert = NSAlert()
        alert.messageText = Self.quitTitle(app: app.name, pc: host.displayName)
        alert.informativeText = Self.quitMessage
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit \(app.name)").hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do { try await quitRunningApp(on: host) } catch {
                let failure = NSAlert()
                failure.messageText = "Couldn't quit \(app.name) on \(host.displayName)."
                failure.informativeText = Self.quitFailureMessage(for: error, hostName: host.displayName)
                failure.runModal()
            }
        }
    }

    /// Disconnect first so the PC's response cannot trigger a reconnect that relaunches the app.
    func quitRunningApp(on host: Host) async throws {
        guard quittingHostID == nil else { throw StreamError.launchFailed("A quit is already in progress. Try again.") }
        quittingHostID = host.id
        defer { quittingHostID = nil; restartHostStatusPolling() }
        if pendingCommandStream?.hostID == host.id { cancelPendingCommandStream() }
        if streamingHostID == host.id {
            menuStopInProgress = true
            if let session = nativeSession { await session.stop() }
        }
        let client = makeNetwork(nativeServerInfo(for: host))
        let store = RunningAppOwnershipStore(hostsDefaults)
        do {
            try await StreamSession.launchMutations.cancel(pc: host.id) {
                try await client.cancel()
                RunningAppOwnership.clear(pc: host.id, defaults: store.defaults)
            }
            Diag.notice("Explicit quit /cancel succeeded", "Stream")
            if hostLiveStatus?.hostID == host.id { hostLiveStatus?.state = .idle }
            await client.shutdown()
        } catch StreamError.launchFailed, StreamError.hostRefused {
            Diag.notice("Explicit quit /cancel refused", "Stream")
            await client.shutdown()
            throw StreamError.launchFailed(
                "\(host.displayName) wouldn't quit the app. "
                + "If another device is streaming from it, stop that stream first.")
        } catch {
            Diag.notice("Explicit quit /cancel failed: \(error, privacy: .private)", "Stream")
            await client.shutdown()
            throw error
        }
    }
}

struct QuitRunningAppButton: View {
    let app: LibraryApp
    let host: Host
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Quit \(app.name)…") { model.requestQuit(app, on: host) }
            .disabled(model.quittingHostID != nil)
            .accessibilityHint("Asks before quitting \(app.name) on \(host.displayName)")
    }
}
