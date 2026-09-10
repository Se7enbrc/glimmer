//
//  StreamWindow+PointerAffordances.swift
//
//  The two things that make window-mode pointer capture discoverable: a
//  titlebar button that takes the pointer, and a transient hint that says how
//  to give it back. Both exist because the previous model - click to grab, a
//  chord to release - required the user to have memorised something, and a
//  window is a place where the pointer belongs to the Mac by default.
//
//  Window mode only. A fullscreen cover is borderless (no title bar to hang an
//  accessory on) and captures for the whole session (nothing to hint about),
//  so every entry point here is gated on `displayMode == .window` and the
//  fullscreen path never reaches them.
//

import AppKit

// MARK: - Hint budget

/// How many times the capture hint is worth showing. Pure so the rule is
/// testable without UserDefaults, and separate from the storage so the caller
/// owns the read/write.
enum CaptureHintPolicy {
    /// UserDefaults key holding the number of window captures that have shown
    /// the hint. An Int (not a Bool) because the hint earns a few repeats:
    /// once is easy to miss when a game grabs your attention the instant the
    /// pointer is captured.
    static let defaultsKey = "windowCaptureHintCount"

    /// After this many, the user knows. Teaching aids that never stop are
    /// nagging.
    static let maxShows = 3

    static func shouldShow(count: Int) -> Bool { count < maxShows }

    /// The count to persist after a show. Clamps a negative value (a hand-
    /// edited or corrupt default) up to zero first, so a nonsense count
    /// self-heals into the normal budget instead of showing forever.
    static func nextCount(after count: Int) -> Int { max(count, 0) + 1 }
}

// MARK: - Titlebar accessory

/// The titlebar button that captures and releases the pointer, and the
/// controller that hangs it off the window's title bar.
///
/// A view controller rather than a bare view because
/// `NSTitlebarAccessoryViewController` is the only supported way to put a
/// control in an AppKit title bar - and because it is an NSObject, so it can
/// be the button's target without a separate shim.
///
/// Note the button is unclickable while the pointer is CAPTURED: capture hides
/// the cursor and disassociates it, so there is nothing to click with. That is
/// expected and by design - a held Esc and the pointer chord are the ways out,
/// and the captured icon here is a status light rather than a control.
final class PointerCaptureAccessory: NSTitlebarAccessoryViewController {

    /// Fired when the button is clicked. The window owner routes it to the
    /// input forwarder's capture toggle.
    var onToggle: (@MainActor () -> Void)?

    private let button = NSButton()

    init(onToggle: (@MainActor () -> Void)?) {
        self.onToggle = onToggle
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PointerCaptureAccessory is created in code, never from a nib")
    }

    override func loadView() {
        button.frame = NSRect(x: 6, y: 3, width: 28, height: 22)
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggle(_:))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(button)
        view = container
        setCaptured(false)
    }

    /// Reflect the live capture state in the icon, the tooltip, and the
    /// accessibility label. Loading the view lazily is deliberate: AppKit only
    /// builds it when the accessory is actually added to a window, and reading
    /// `isViewLoaded` first keeps this callable before that happens.
    func setCaptured(_ captured: Bool) {
        guard isViewLoaded else { return }
        // `cursorarrow.motionlines` is a pointer trailing movement - relative
        // aim. `cursorarrow.slash` is a pointer that is not yours right now.
        let symbol = captured ? "cursorarrow.slash" : "cursorarrow.motionlines"
        let help = captured ? "Release pointer" : "Capture pointer for mouselook"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    @objc private func toggle(_ sender: NSButton) {
        onToggle?()
    }
}

// MARK: - StreamWindow

extension StreamWindow {

    /// Hang the capture button off the title bar. Idempotent - the windowed
    /// chrome is configured both at show() and again when a Path-B Space exit
    /// converts a fullscreen session into a window, and the second pass must
    /// not stack a duplicate button.
    func installPointerCaptureAccessory() {
        guard displayMode == .window, pointerCaptureAccessory == nil else { return }
        let accessory = PointerCaptureAccessory(onToggle: { [weak self] in
            self?.onTogglePointerCapture?()
        })
        window.addTitlebarAccessoryViewController(accessory)
        accessory.setCaptured(false)
        pointerCaptureAccessory = accessory
    }

    /// The first few captures explain the way out. Uses the same pill the
    /// one-time leave hint uses, so the two teaching toasts look like one
    /// idea, and stacks above it so they can never overlap.
    ///
    /// The budget is persisted, not session-scoped: the lesson only needs
    /// teaching once per person, not once per launch.
    func showCaptureHintIfBudgetAllows() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: CaptureHintPolicy.defaultsKey)
        guard CaptureHintPolicy.shouldShow(count: count) else { return }
        defaults.set(CaptureHintPolicy.nextCount(after: count), forKey: CaptureHintPolicy.defaultsKey)

        captureHintBanner.setText("Hold Esc to free the pointer")
        captureHintBanner.setVisible(true)
        // ~4s all in: 0.2s fade in, 3.6s legible, 0.2s fade out. The
        // generation stamp means a re-capture inside that window re-shows the
        // hint without the first show's timer cutting the second one short.
        captureHintGeneration &+= 1
        let generation = captureHintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self, self.captureHintGeneration == generation else { return }
            self.captureHintBanner.setVisible(false)
        }
    }

    /// Drop the hint the moment the pointer comes back - it is advice about
    /// being captured, and it would read as a lie hanging over a free pointer.
    func hideCaptureHint() {
        captureHintGeneration &+= 1
        captureHintBanner.setVisible(false)
    }
}
