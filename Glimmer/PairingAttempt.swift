import Foundation

struct PairingAttempt: Equatable, Sendable {
    let id = UUID()
    let address: String

    func accepts(_ attempt: PairingAttempt?, address: String, cancelled: Bool) -> Bool {
        !cancelled && self == attempt && self.address == address
    }
}
