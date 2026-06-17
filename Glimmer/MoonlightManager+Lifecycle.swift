//
//  MoonlightManager+Lifecycle.swift
//
//  App-delegate attach, launch bootstrap, the live host-refresh loop, custom-bitrate auto-tracking, and shutdown. Split out of MoonlightManager.swift to keep each unit focused.
//

import Foundation
import AppKit
import AudioToolbox
import CoreAudio
import GameController
import SwiftUI
import Observation
import ServiceManagement
import os.log

extension MoonlightManager {

    func attach(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        appDelegate.moonlight = self
    }

    func bootstrap() async {
        // Self-heal the login item: if the user wants launch-at-login but the
        // registration drifted (invalidated by an app update / move), re-assert
        // it now. This is the fix for "doesn't start after reboot" - the next
        // reboot picks up the freshly-reconciled registration.
        LoginItemManager.reconcile()
        log.info("Glimmer stream engine: Swift-native")
        // Install step: build the client SecIdentity once, into Glimmer's own
        // keychain, so streams don't prompt the user for keychain access.
        await IdentityManager.shared.preflight()
        migrateFromMoonlightQtIfNeeded()
        loadHosts()
        // First-launch: if the user has never set custom values, seed them
        // with display native.
        if UserDefaults.standard.object(forKey: "customWidth") == nil {
            snapCustomToDisplay()
        }
        persistQualitySettings()
        startLiveRefresh()
        restartHostStatusPolling()
    }

    func startLiveRefresh() {
        // Under @Observable, tracking is property-granular and SwiftUI
        // only rebuilds views that read changed properties. The only
        // value that depends on non-observed state is
        // `currentDisplayDescription` (reads NSScreen.main, a global);
        // the screen-parameter-change observer below bumps
        // `displayInfoRevision` to force its readers to recompute.
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Dock / undock / external display plugged in. Re-derive smart
            // defaults for the new primary display. Skip if streaming -
            // yanking the resolution mid-stream would be disruptive.
            Task { @MainActor in
                guard let self, !self.isStreaming else { return }
                self.persistQualitySettings()
                // Bump the sentinel so any view that read
                // `currentDisplayDescription` rebuilds. @Observable can't
                // see through NSScreen.main on its own.
                self.displayInfoRevision &+= 1
            }
        })
        notificationTokens.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.loadHosts()
                // Refresh the host status poller on activation so the chip
                // updates within one RTT of the user returning, rather than
                // waiting out the current 10s interval. This is no longer a
                // "resume" - polling now runs continuously regardless of focus
                // (see restartHostStatusPolling); restarting here just resets
                // the streak and fires an immediate probe for snappy feedback.
                self.restartHostStatusPolling()
                // If a DualSense is connected and the user hasn't decided on
                // the raw-HID feature, offer it now (e.g. they returned to the
                // launcher after plugging it in mid-stream).
                self.maybeOfferRawHID()
                // Cmd-Tab back into Glimmer while a stream is parked in the
                // background should bring the stream forward - but ONLY for a
                // keyboard-style reactivation (Cmd-Tab). If the user clicked
                // the launcher window (or its menu) to reach Settings, leave
                // them there. StreamWindow.swift deliberately avoids a blanket
                // didBecomeActive resume for this exact reason; we gate on the
                // triggering event NOT being a mouse click so the launcher
                // stays reachable mid-stream.
                guard self.isStreaming, self.nativeStreamBackgrounded else { return }
                // Resume on Cmd-Tab, not a window click. currentEvent is nil for both,
                // so the mouse button is the tell: a click-to-activate still has it down.
                let evType = NSApp.currentEvent?.type
                let mouseEvent = evType == .leftMouseDown || evType == .leftMouseUp
                    || evType == .rightMouseDown || evType == .otherMouseDown
                let viaClick = mouseEvent || NSEvent.pressedMouseButtons != 0
                if !viaClick {
                    self.resumeStreamWindow()
                }
            }
        })
        // NOTE: there is intentionally no `didResignActiveNotification` handler
        // cancelling the host-status poller. We used to pause polling whenever
        // Glimmer lost focus, on the theory "the chip can't be seen" - but the
        // chip is plainly visible when Glimmer's window sits behind another app,
        // and cancelling on resign stranded it on "Checking..." the instant the
        // user clicked away (last sample aged past HostLiveStatus.stale). The
        // poller now runs continuously while on the launcher (matching
        // Moonlight) and only pauses for an active stream or no selected host.
        // Proactively offer the raw-HID DualSense feature the moment a
        // DualSense connects while Glimmer is running (once), rather than
        // burying it in Settings. The same observers keep `controllerConnected`
        // live so the controller-permission UI shows/hides as pads come and go.
        //
        // Mid-stream invariant: plugging a pad in during a live stream must be
        // SILENT and NON-BLOCKING. This handler only updates
        // `controllerConnected` and calls `maybeOfferRawHID()`, which is
        // `!isStreaming`-gated - so the offer alert never fires mid-stream. Even
        // the "Enable" path (`enableRawHIDFromPrompt`) is now side-effect-free
        // (no IOHIDRequestAccess, no NSWorkspace.open), so nothing on this path
        // can block the present thread or flash a System Settings window. If
        // raw HID is already enabled + granted, the pad attaches silently via
        // `ControllerForwarder.retain()` - never from here.
        notificationTokens.append(nc.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.controllerConnected = !GCController.controllers().isEmpty
                self.maybeOfferRawHID()
            }
        })
        notificationTokens.append(nc.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            // GameController posts the disconnect BEFORE pruning its registry,
            // so the just-removed pad can still appear in `controllers()` here;
            // hop to the next runloop tick so the registry reflects reality.
            Task { @MainActor in
                self?.controllerConnected = !GCController.controllers().isEmpty
            }
        })
        // Catch a controller that was already connected at launch (covers both
        // the auto-offer and seeding `controllerConnected`).
        controllerConnected = !GCController.controllers().isEmpty
        maybeOfferRawHID()
    }

    /// Human-readable description of the current primary display, for the UI.
    ///
    /// Reads `NSScreen.main` (a global) so `@Observable`'s automatic
    /// tracking can't see when the value would change. We deliberately
    /// touch `displayInfoRevision` first so any view that read this
    /// property gets a tracking edge on the sentinel - when the
    /// screen-parameter notification bumps the sentinel, the view
    /// recomputes.
    var currentDisplayDescription: String {
        _ = displayInfoRevision      // register tracking on the sentinel
        let display = smartDefaultsForCurrentDisplay()
        return "\(Self.resolutionLabel(width: display.width, height: display.height)) · \(display.fps) Hz"
    }

    func autoUpdateCustomBitrate() {
        guard customBitrateAuto else { return }
        let kbps = bitrateKbps(width: customWidth, height: customHeight, fps: customFPS, preset: .matchDisplay)
        customBitrateMbps = max(5, kbps / 1000)
    }

    func shutdown() {
        // Native engine teardown is owned by StreamSession; bringing the app
        // down while a session is live triggers the session's cancellation
        // path via deinit / AsyncStream onTermination. Nothing privileged to
        // wind down here anymore.
    }
}
