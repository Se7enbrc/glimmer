import Foundation

@objc public protocol GlimmerHelperProtocol {
    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping (Bool) -> Void)
    func currentStatus(reply: @escaping (Bool, Date?) -> Void)
    func ping(reply: @escaping (String) -> Void)
}

public let GlimmerHelperMachServiceName = "io.ugfugl.glimmer.helper"
