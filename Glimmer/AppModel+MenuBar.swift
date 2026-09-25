//
//  AppModel+MenuBar.swift
//
//  What the menu bar reads and the few actions only it needs: icon state, the
//  first row, the selected PC as the launcher reads it, the pads, Connection
//  Details (refreshed while the menu is open), stop, overlay, pairing, takeover.
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
            phase: streamPhase, reconnecting: isReconnecting, host: menuBarHost, heroApp: heroTargetAppName)
    }

    /// The selected PC with the launcher's chip and power state; nil when none is paired.
    var menuBarHost: MenuBarHost? {
        guard let host = selectedHost else { return nil }
        return MenuBarHost(chip: polledChip(for: host), canWake: canWake(host), waking: isWaking(host))
    }

    var menuBarModeLine: String {
        MenuBarPresentation.modeLine(width: effectiveWidth, height: effectiveHeight, fps: effectiveFPS, hdr: nativeHDRActive)
    }

    var menuBarMetrics: [MenuBarMetric] {
        MenuBarPresentation.metrics(snapshot: menuDetails, link: MenuBarPresentation.linkLabel(hostRoute.routeClass))
    }

    /// The header while connecting: the phase's own stage copy.
    var menuBarConnectingLine: String? {
        if case .connecting(let stage) = streamPhase { return stage }
        return nil
    }

    /// The menu bar row and the chord land in the same place.
    func toggleMiniPlayer() {
        Task { [weak self] in await self?.nativeSession?.toggleMiniPlayer() }
    }

    /// Ends the stream at once; the row reads "Stopping…" until cleanup lands.
    func stopStreamFromMenu(source: String = "the menu bar") {
        guard let session = nativeSession, !menuStopInProgress else { return }
        menuStopInProgress = true
        Diag.notice("Stop Streaming from \(source)", "Stream")
        Task { await session.stop() }
    }

    func toggleStatsOverlayFromMenu() {
        guard let session = nativeSession else { return }
        let next = !statsOverlayShown
        statsOverlayShown = next
        Task { await session.setStatsOverlay(next) }
    }

    /// Opens the launcher's pair sheet: Pair Again… for `host`, or Pair a PC… for nil.
    func requestPairing(for host: Host?) {
        pairSheetHost = host
        pairSheetShown = true
    }

    /// Refresh Connection Details about once a second while the menu is open.
    func startMenuBarRefresh() {
        stopMenuBarRefresh()
        setHIDDiscovery(true, for: .menuBar)
        refreshMenuBarDetails()
        if isStreaming, let session = nativeSession { Task { await session.setCursorHidden(false) } }
        menuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBarDetails() }
        }
    }

    func stopMenuBarRefresh() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        setHIDDiscovery(false, for: .menuBar)
    }

    private func refreshMenuBarDetails() {
        let pads = readMenuBarControllers()
        if pads != menuBarControllers { menuBarControllers = pads }
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

    /// Every pad the Mac sees, with a battery reading where one exists. Reads
    /// the raw-HID list without touching its attach and detach hooks.
    private func readMenuBarControllers() -> [MenuBarController] {
        let pads = GCController.controllers().map { controller in
            let name = controller.vendorName ?? "Controller"
            if let hid = DualSenseHID.shared.state(for: ObjectIdentifier(controller))?.battery {
                return MenuBarController(name: name, percent: hid.percent, charging: hid.charging)
            }
            let reading = controller.battery.flatMap(ControllerBattery.uiReading)
            return MenuBarController(name: name, percent: reading?.percent, charging: reading?.charging == true)
        }
        let raw = HIDGamepadManager.shared.devices.values.sorted { $0.id < $1.id }.map {
            MenuBarController(name: $0.name, percent: $0.batteryPercentage.map(Int.init), charging: false)
        }
        return MenuBarPresentation.controllers(gameController: pads, rawHID: raw)
    }

    /// The takeover question has to reach the user even with the launcher
    /// closed (a launch from the menu bar); the launcher's own dialog handles
    /// the visible case.
    func presentTakeoverAlertIfNeeded() {
        guard let pending = pendingTakeover, !mainWindowVisible else { return }
        let alert = NSAlert()
        alert.messageText = TakeoverDialogCopy.title(occupantApp: pending.occupantApp, hostName: pending.host.displayName)
        alert.informativeText = TakeoverDialogCopy.message
        alert.addButton(withTitle: "Quit and Stream").hasDestructiveAction = true
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

    /// Some of the launcher can be seen. `isVisible` stays true behind a sleeping
    /// display, a locked screen or on another Space, where nobody sees the chip.
    var mainWindowOnScreen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.occlusionState.contains(.visible) }
    }
}
