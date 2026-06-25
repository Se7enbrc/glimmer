import Foundation
import Security
import os.log

final class HelperService: NSObject, NSXPCListenerDelegate, GlimmerHelperProtocol {
    private let suppressor: AWDLSuppressor
    private let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "XPC")

    // The connecting process must satisfy this code requirement before we'll
    // accept its XPC messages. Glimmer ships Developer-ID signed (Team
    // 5T7M4RH3F8), so we pin both the bundle identifier AND the Apple-anchored
    // Developer-ID certificate chain: a process can drive this root helper only
    // if it is genuinely our signed app, not merely something claiming our id.
    private static let designatedRequirement =
        "identifier \"io.ugfugl.Glimmer\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"5T7M4RH3F8\""

    init(suppressor: AWDLSuppressor) {
        self.suppressor = suppressor
        super.init()
    }

    // MARK: Listener

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isPeerTrusted(newConnection) else {
            os_log("Rejecting XPC peer pid=%d (code-signature/identifier mismatch)",
                   log: log, type: .error, newConnection.processIdentifier)
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
        newConnection.exportedObject = self
        // Fail-safe: if the controlling app vanishes (quit/crash/lost connection)
        // without releasing, restore awdl0 rather than leave it parked.
        newConnection.invalidationHandler = { [suppressor] in
            suppressor.setSuppressing(false, reason: "app-disconnected")
        }
        newConnection.resume()
        return true
    }

    /// Verify the connecting process's code signature against our designated
    /// requirement. This is what makes the bundle's filesystem permissions
    /// irrelevant for security: even if /Applications/Glimmer.app is writable
    /// and someone swaps the main app binary, the OS-level signature check
    /// here will reject the connection.
    private func isPeerTrusted(_ connection: NSXPCConnection) -> Bool {
        // Prefer the audit token (TOCTOU-safe) via KVC — NSXPCConnection has
        // the property but Apple hasn't promoted it to a public Swift API yet.
        // Fall back to PID if KVC fails. Both go through SecCode's APIs, so the
        // signature check is identical.
        var attrs: [String: Any] = [:]
        if let tokenData = connection.value(forKey: "auditToken") as? Data {
            attrs[kSecGuestAttributeAudit as String] = tokenData
        } else {
            attrs[kSecGuestAttributePid as String] = NSNumber(value: connection.processIdentifier)
        }

        var staticCode: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &staticCode)
        guard copyStatus == errSecSuccess, let code = staticCode else {
            os_log("SecCodeCopyGuestWithAttributes failed: %d", log: log, type: .error, copyStatus)
            return false
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            Self.designatedRequirement as CFString, [], &requirement
        )
        guard reqStatus == errSecSuccess, let req = requirement else {
            os_log("SecRequirementCreateWithString failed: %d", log: log, type: .error, reqStatus)
            return false
        }

        let validity = SecCodeCheckValidity(code, [], req)
        if validity != errSecSuccess {
            os_log("SecCodeCheckValidity rejected peer: %d", log: log, type: .error, validity)
            return false
        }
        return true
    }

    // MARK: GlimmerHelperProtocol

    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void) {
        // Defensively bound the reason string. The XPC peer is untrusted on a
        // single-user Mac in the strict sense — anything can connect — so don't
        // let a hostile caller fill the log with megabytes of garbage.
        let bounded = String(reason.prefix(128)).replacingOccurrences(of: "\n", with: " ")
        suppressor.setSuppressing(down, reason: bounded)
        reply(true)
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
