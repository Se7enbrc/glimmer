//
//  InputForwarder+CommandKeyUp.swift
//
//  AppKit never hands a keyUp to the first responder while ⌘ is held (the
//  keyDown went out as a key equivalent). GLFW and SDL re-dispatch those from
//  NSApplication.sendEvent; this is the same fix, scoped to the stream (#86).
//

import AppKit

extension InputForwarder {

    /// Catch ⌘-held key-ups before AppKit drops them and deliver them to the
    /// stream view, so the host sees the letter released instead of autorepeating.
    func installCommandKeyUpMonitor() {
        guard commandKeyUpMonitor == nil else { return }
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, let window = self.window, let view = self.inputView,
                  event.window === window, event.modifierFlags.contains(.command) else { return event }
            self.log.debug("Cmd-held keyUp rerouted keyCode=\(event.keyCode, privacy: .public)")
            view.keyUp(with: event)
            return nil
        }
    }

    func removeCommandKeyUpMonitor() {
        if let monitor = commandKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            commandKeyUpMonitor = nil
        }
    }

    /// True the second time the same physical key-up arrives (the responder
    /// chain and the monitor both delivered it); the first delivery wins.
    func isDuplicateKeyUp(_ event: NSEvent) -> Bool {
        let stamp = KeyUpStamp(timestamp: event.timestamp, keyCode: event.keyCode)
        if lastKeyUpStamp == stamp { return true }
        lastKeyUpStamp = stamp
        return false
    }

    struct KeyUpStamp: Equatable {
        let timestamp: TimeInterval
        let keyCode: UInt16
    }
}
