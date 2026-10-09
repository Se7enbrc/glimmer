import Foundation

// The owner and its suppression transition are protected together by ownerLock.
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let suppressor: AWDLSuppressor
    private let ownerLock = NSLock()
    private var owner: UUID?

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
        let token = UUID()
        newConnection.exportedInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        newConnection.exportedObject = HelperPeer(service: self, token: token)
        newConnection.invalidationHandler = { [weak self] in self?.peerInvalidated(token) }
        newConnection.resume()
        return true
    }

    // MARK: GlimmerHelperProtocol

    func setAWDLDown(_ down: Bool, reason: String, peer: UUID = UUID(), reply: @escaping @Sendable (Bool) -> Void) {
        // Defensively bound the reason string so even a verified peer can't
        // fill the log with megabytes of garbage.
        let bounded = String(reason.prefix(128)).replacingOccurrences(of: "\n", with: " ")
        // Claims and interface intent change under one lock. Explicit release
        // remains available to a replacement connection recovering a lost reply.
        ownerLock.lock()
        owner = down ? peer : nil
        suppressor.setSuppressing(down, reason: bounded)
        ownerLock.unlock()
        // Park: report verified state so the app's `suppressing` flag can't
        // claim a still-up radio (the heartbeat reconfirms as the async down
        // lands).
        if down {
            reply(!suppressor.isInterfaceUp())
        } else {
            suppressor.afterPendingChanges { [suppressor] in
                reply(!suppressor.suppressing && suppressor.isInterfaceUp())
            }
        }
    }

    func peerInvalidated(_ peer: UUID) {
        ownerLock.lock()
        defer { ownerLock.unlock() }
        guard owner == peer else { return }
        owner = nil
        suppressor.setSuppressing(false, reason: "app-disconnected")
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

private final class HelperPeer: NSObject, GlimmerHelperProtocol {
    private let service: HelperService
    private let token: UUID

    init(service: HelperService, token: UUID) {
        self.service = service
        self.token = token
    }

    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping @Sendable (Bool) -> Void) {
        service.setAWDLDown(down, reason: reason, peer: token, reply: reply)
    }

    func currentStatus(reply: @escaping (Bool, Date?) -> Void) { service.currentStatus(reply: reply) }
    func ping(reply: @escaping (String) -> Void) { service.ping(reply: reply) }
    func reSuppressCount(reply: @escaping (UInt64) -> Void) { service.reSuppressCount(reply: reply) }
}
