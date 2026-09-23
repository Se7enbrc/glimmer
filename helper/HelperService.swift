import Foundation

final class HelperService: NSObject, NSXPCListenerDelegate, GlimmerHelperProtocol {
    private let suppressor: AWDLSuppressor

    // Every XPC peer must be our bundle id AND Apple-anchored Developer ID (Team
    // 5T7M4RH3F8). main.swift hands this to the listener, so the OS rejects any
    // other process before it can reach this root helper.
    static let designatedRequirement =
        "identifier \"io.ugfugl.Glimmer\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"5T7M4RH3F8\""

    init(suppressor: AWDLSuppressor) {
        self.suppressor = suppressor
        super.init()
    }

    // MARK: Listener

    // Only peers that already passed the listener's code-signing requirement
    // (set in main.swift) are ever offered here.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: GlimmerHelperProtocol

    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void) {
        // Defensively bound the reason string so even a verified peer can't
        // fill the log with megabytes of garbage.
        let bounded = String(reason.prefix(128)).replacingOccurrences(of: "\n", with: " ")
        // Fail-safe: if the peer holding awdl0 down vanishes (quit/crash/lost
        // connection) without releasing, restore it. Only that peer's exit counts,
        // so another client that connects and leaves can't cut a stream short.
        NSXPCConnection.current()?.invalidationHandler = down ? { [suppressor] in
            suppressor.setSuppressing(false, reason: "app-disconnected")
        } : nil
        suppressor.setSuppressing(down, reason: bounded)
        // Park: report verified state so the app's `suppressing` flag can't
        // claim a still-up radio (the heartbeat reconfirms as the async down
        // lands). Release just acks - restore success isn't the signal.
        reply(down ? !suppressor.isInterfaceUp() : true)
    }

    func currentStatus(reply: @escaping (Bool, Date?) -> Void) {
        reply(suppressor.suppressing, suppressor.suppressionSince)
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("glimmer-helper-ok")
    }

    func reSuppressCount(reply: @escaping (UInt64) -> Void) {
        reply(suppressor.reSuppressCount)
    }
}
