//
//  AppModel+MenuBar.swift
//
//  What the menu bar item reads and the few actions only it needs: the icon
//  state, the first row, controller readings, PC readiness, the Connection
//  Details snapshot (refreshed only while the menu is open), stop, overlay.
//

import AppKit
import Foundation
import GameController

extension AppModel {

    var menuBarIconState: MenuBarIconState {
        MenuBarPresentation.icon(phase: streamPhase, reconnecting: isReconnecting, error: nativeStreamError)
    }

    var menuBarAccessibilityLabel: String {
        MenuBarPresentation.accessibilityLabel(state: menuBarIconState, hostName: selectedHost?.displayName)
    }

    var menuBarPrimaryAction: MenuBarPrimaryAction {
        MenuBarPresentation.primaryAction(
            phase: streamPhase, hostSelected: selectedHost != nil, heroApp: heroTargetAppName)
    }

    /// Named battery readings for every connected pad that reports one.
    var menuBarControllers: [(name: String, percent: Int, charging: Bool)] {
        _ = controllerConnected
        return GCController.controllers().compactMap { controller in
            let name = controller.vendorName ?? "Controller"
            if let hid = DualSenseHID.shared.state(for: ObjectIdentifier(controller))?.battery {
                return (name, hid.percent, hid.charging)
            }
            guard let battery = controller.battery, let reading = ControllerBattery.uiReading(battery) else {
                return nil
            }
            return (name, reading.percent, reading.charging == true)
        }
    }

    /// One word for the selected PC from a fresh live status, else nil.
    var menuBarReadiness: String? {
        guard let host = selectedHost, let live = hostLiveStatus, live.hostID == host.id else { return nil }
        let fresh = Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale
        return MenuBarPresentation.readiness(live.state, fresh: fresh)
    }

    var menuBarHostAsleep: Bool {
        guard let host = selectedHost, let live = hostLiveStatus, live.hostID == host.id,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else { return false }
        return live.state == .asleep
    }

    var menuBarModeLine: String {
        MenuBarPresentation.modeLine(width: effectiveWidth, height: effectiveHeight, fps: effectiveFPS, hdr: nativeHDRActive)
    }

    var menuBarStateWord: String {
        MenuBarPresentation.stateWord(menuBarIconState, readiness: menuBarReadiness)
    }

    var menuBarReadinessTone: MenuBarReadinessTone {
        guard menuBarReadiness != nil, let live = hostLiveStatus else { return .off }
        return MenuBarPresentation.readinessTone(live.state)
    }

    var menuBarMetrics: [MenuBarMetric] {
        MenuBarPresentation.metrics(snapshot: menuDetails, link: MenuBarPresentation.linkLabel(hostRoute.routeClass))
    }

    /// The header while connecting: the phase's own stage copy.
    var menuBarConnectingLine: String? {
        if case .connecting(let stage) = streamPhase { return stage }
        return nil
    }

    /// Ends the stream at once; the row reads "Stopping…" until cleanup lands.
    func stopStreamFromMenu() {
        guard let session = nativeSession, !menuStopInProgress else { return }
        menuStopInProgress = true
        Diag.notice("Stop Streaming from the menu bar", "Stream")
        Task { await session.stop() }
    }

    func toggleStatsOverlayFromMenu() {
        guard let session = nativeSession else { return }
        let next = !statsOverlayShown
        statsOverlayShown = next
        Task { await session.setStatsOverlay(next) }
    }

    /// Refresh Connection Details about once a second while the menu is open.
    func startMenuBarRefresh() {
        stopMenuBarRefresh()
        refreshMenuBarDetails()
        if isStreaming, let session = nativeSession { Task { await session.setCursorHidden(false) } }
        menuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBarDetails() }
        }
    }

    func stopMenuBarRefresh() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private func refreshMenuBarDetails() {
        guard isStreaming, let session = nativeSession else { menuDetails = nil; return }
        Task { [weak self] in
            let details = await session.menuBarDetails()
            await MainActor.run {
                guard let self else { return }
                self.menuDetails = details?.snapshot
                if let overlay = details?.overlayShown { self.statsOverlayShown = overlay }
            }
        }
    }

    /// The takeover question has to reach the user even with the launcher
    /// closed (a launch from the menu bar); the launcher's own dialog handles
    /// the visible case.
    func presentTakeoverAlertIfNeeded() {
        guard let pending = pendingTakeover, !mainWindowVisible else { return }
        let alert = NSAlert()
        alert.messageText = "Take over the stream?"
        alert.informativeText = "\(pending.host.displayName) is already streaming \(pending.occupantApp). "
            + "Starting your stream will end that session."
        alert.addButton(withTitle: "Take Over")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            confirmPendingTakeover()
        } else {
            pendingTakeover = nil
        }
    }

    var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
    }
}
