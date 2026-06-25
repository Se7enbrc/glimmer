import Foundation

@objc public protocol GlimmerHelperProtocol {
    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void)
    func currentStatus(reply: @escaping (Bool, Date?) -> Void)
    func ping(reply: @escaping (String) -> Void)
    /// How many times macOS re-raised awdl0 this stream (the contention/whack-a-mole rate).
    func reSuppressCount(reply: @escaping (UInt64) -> Void)
}

public let GlimmerHelperMachServiceName = "io.ugfugl.glimmer.helper"
