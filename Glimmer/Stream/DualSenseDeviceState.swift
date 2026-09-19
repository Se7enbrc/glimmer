import Foundation

struct DualSenseDeviceState: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        case serial(String)
        case registry(UInt64)
    }

    let identity: Identity
    let transport: String
    var buttons = DualSenseExtraButtons()
    var battery: DualSenseBattery?
    var reportCount = 0
    var faceButtons: Set<DualSenseFaceButton> = []

    mutating func apply(_ report: DualSenseDecodedReport) -> Set<DualSenseFaceButton> {
        let pressed = report.faceButtons.subtracting(faceButtons)
        buttons = report.buttons
        faceButtons = report.faceButtons
        if let nextBattery = report.battery { battery = nextBattery }
        reportCount += 1
        return pressed
    }
}
