import AppKit
import ServiceManagement
import SwiftUI

/// Captures SwiftUI's `openWindow` action and parks it on AppDelegate so the
/// AppKit reopen handler can spawn the main window when SwiftUI's `Window`
/// scene has destroyed its instance after an X-close. Hosted on the
/// `MenuBarExtra` content (NOT the main window) so the captured closure's
/// SwiftUI environment outlives the launcher window - closing the launcher
/// leaves the menu bar item alive, so this view stays alive, so the closure
/// stays callable.
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.openMainWindow = { openWindow(id: "main") }
            }
    }
}

/// Sentinel arg passed by Glimmer Login Helper when it relaunches the main
/// app at login. Read once at App.init and used to gate `.defaultLaunchBehavior`
/// so the main window stays suppressed on login launches but auto-shows on
/// every user-initiated launch (Spotlight / Finder / Dock). No heuristics -
/// we control both sides of the launch.
private let launchedAtLogin = ProcessInfo.processInfo.arguments.contains("--launched-at-login")

@main
struct GlimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var moonlight: MoonlightManager

    init() {
        let mgr = MoonlightManager()
        _moonlight = State(wrappedValue: mgr)
        AppDelegate.boundManager = mgr
    }

    var body: some Scene {
        // `Window` (single-instance) over `WindowGroup` - `openWindow(id:)`
        // brings the existing one to front instead of spawning a duplicate.
        Window("Glimmer", id: "main") {
            MainWindow()
                .environment(moonlight)
                // Honest minimums: the hero caps at 520pt + 64pt surface
                // padding (~584), and the empty state's copy wraps at 440 -
                // 720×500 keeps every layout intact with no truncation.
                .frame(minWidth: 720, idealWidth: 860, minHeight: 500, idealHeight: 540)
                // Liquid Glass: on macOS 26 `.regularMaterial` resolves to
                // the system material; future SDKs may expose a dedicated
                // `.glassBackground` shape style for window containers.
                .containerBackground(.regularMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        // Tighter default than the old 920×580 - the launcher is one hero
        // card + a button, not a document; the hero geometry trim (248pt
        // card) keeps the composition centred at this size.
        .defaultSize(width: 780, height: 540)
        // Opt OUT of window state restoration so a previously-X-closed
        // launcher always re-spawns fresh next launch (the bug that made
        // first Dock click do nothing pre-restoration-fix).
        .restorationBehavior(.disabled)
        // Suppress the auto-shown window when we were launched by the
        // login helper. User-initiated launches don't carry the sentinel
        // arg, so the Window scene spawns normally.
        .defaultLaunchBehavior(launchedAtLogin ? .suppressed : .automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            #if canImport(Sparkle)
            // Standard macOS "Check for Updates..." under the app menu (after the
            // About item). Sparkle drives the rest: a check on every open
            // (applicationDidFinishLaunching) plus a daily background check and
            // the update panels. Mirrored in the menu-bar dropdown for the
            // accessory (no-window) case - see MenuBarContent.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: UpdaterController.shared.updater)
            }
            #endif
        }

        Settings {
            SettingsRoot()
                .environment(moonlight)
                .frame(minWidth: 720, minHeight: 480)
                // Settings reads a notch lighter than the main window so
                // the sidebar / content materials layer cleanly on top.
                .containerBackground(.thinMaterial, for: .window)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(moonlight)
                .background(OpenWindowCapture())
        } label: {
            if let symbol = moonlight.menuBarSystemImageName {
                Image(systemName: symbol)
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hand-off slot set by `GlimmerApp.init` so AppDelegate can reach the
    /// manager before any SwiftUI view body runs.
    nonisolated(unsafe) static var boundManager: MoonlightManager?

    /// Captured SwiftUI `openWindow(id: "main")` invocation. Set by
    /// `OpenWindowCapture` the first time MainWindow appears; used by
    /// applicationShouldHandleReopen when the X-closed Window scene needs
    /// to be respawned (NSApp.windows no longer contains it, but SwiftUI
    /// will rebuild from the WindowGroup on openWindow).
    nonisolated(unsafe) static var openMainWindow: (@MainActor () -> Void)?

    weak var moonlight: MoonlightManager?

    /// NSWindow open/close observers wired in applicationWillFinishLaunching
    /// to toggle `NSApp.activationPolicy` between `.regular` (Dock icon
    /// visible) when the main window is open and `.accessory` (no Dock
    /// icon) when only the menu bar is alive. Tracked so deinit can detach.
    private var windowVisibilityObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Version + build + commit on the FIRST log line, so any pasted log
        // (bug report, telemetry session) identifies the exact build with no
        // back-and-forth - the issue template asks; the log now answers.
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Diag.notice("app launching - Glimmer \(version) (\(build)) commit \(BuildInfo.commit) "
            + "built \(BuildInfo.date) (launchedAtLogin=\(launchedAtLogin))", "Launch")

        // Default-ON prefs (registered, not written - the user's explicit choice
        // still overrides). disableMouseAccelWhileStreaming linearizes the system
        // pointer acceleration while the stream window is focused so forwarded
        // mouse deltas are raw 1:1; the non-UI gate reads it via UserDefaults.bool,
        // which needs the registered default to read `true` before first toggle.
        UserDefaults.standard.register(defaults: [
            MouseAccelerationControl.enabledDefaultsKey: true
        ])
        // Crash recovery: if a prior session died mid-stream with the pointer
        // acceleration linearized, restore the user's saved value now (no-op in
        // the clean case). Runs before any window/stream can re-engage capture.
        MouseAccelerationControl.restoreOrphanedOverride()

        if let mgr = Self.boundManager {
            self.moonlight = mgr
            mgr.attach(appDelegate: self)
            Task { await mgr.bootstrap() }
        }

        // Login-launched? Start as `.accessory` so the Dock icon never
        // appears alongside an invisible window. didBecomeKey on a
        // subsequent user-triggered window open flips us back to
        // `.regular` via the recheck observer.
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
            Diag.info("login launch → activation policy .accessory (menu-bar only)", "Launch")
        }

        let nc = NotificationCenter.default
        // Re-evaluate activation policy on any becomeKey / willClose. We
        // don't read `note.object` because Swift 6 strict concurrency
        // refuses to send the non-Sendable Notification across the
        // assumeIsolated boundary; instead we look up the main window's
        // current visibility from NSApp.windows on each tick.
        let recheck: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                // willClose fires while the window is still in NSApp.windows,
                // so defer one runloop tick to see the post-close state.
                DispatchQueue.main.async {
                    let mainOpen = NSApp.windows.contains {
                        $0.identifier?.rawValue == "main" && $0.isVisible
                    }
                    NSApp.setActivationPolicy(mainOpen ? .regular : .accessory)
                }
            }
        }
        windowVisibilityObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { _ in recheck() })
        windowVisibilityObservers.append(nc.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { _ in recheck() })
    }

    #if canImport(Sparkle)
    /// Check for updates on every user-initiated open, in addition to Sparkle's
    /// daily scheduled check - a cold start should surface a newer release right
    /// away instead of waiting up to a day. `checkForUpdatesInBackground` is
    /// silent unless an update is actually available. Skipped on login launches
    /// (the user didn't open it; the daily scheduled check covers that session).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launchedAtLogin else { return }
        UpdaterController.shared.updater.checkForUpdatesInBackground()
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the menu bar item alive when all windows close.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        moonlight?.shutdown()
        return .terminateNow
    }

    /// Dock-click handler. Fires on Dock-icon click, `open -a Glimmer`, and
    /// Launchpad reopen - NOT on every app activation (Cmd-Tab, in-app
    /// window clicks).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if moonlight?.isStreaming == true {
            moonlight?.resumeStreamWindow()
            return false
        }
        NSApp.activate()
        // 1. Hidden-but-alive window: orderFront it (covers the launchMinimized
        //    path where we orderOut'd a still-living window object).
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // 2. Destroyed window (X-close): respawn via the captured SwiftUI
        //    openWindow action. AppKit's default reopen doesn't reliably
        //    rebuild SwiftUI Window scenes.
        if let opener = Self.openMainWindow {
            opener()
            return false
        }
        return true
    }
}
