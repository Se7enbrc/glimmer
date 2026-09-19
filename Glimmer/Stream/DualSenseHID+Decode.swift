import Foundation

/// One decoded DualSense INPUT report: the button bits plus the battery field
/// when the report carries one (the 10-byte BT simple report does not).
struct DualSenseDecodedReport: Equatable, Sendable {
    var buttons: DualSenseExtraButtons
    var battery: DualSenseBattery?
    var faceButtons: Set<DualSenseFaceButton> = []
}

extension DualSenseHID {

    static func decodeInputReport(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> DualSenseDecodedReport? {
        let length = bytes.count
        let idPresent = length > 0 && (bytes[0] == 0x01 || bytes[0] == 0x31)
        let rid = idPresent ? UInt32(bytes[0]) : reportID
        guard rid == 0x01 || rid == 0x31 else { return nil }
        let lxIndex = (idPresent ? 1 : 0) + (rid == 0x31 ? 1 : 0)
        let b1Index = lxIndex + 8
        let b2Index = lxIndex + 9
        guard length > b2Index else { return nil }

        let b1 = bytes[b1Index]
        let b2 = bytes[b2Index]
        var buttons = DualSenseExtraButtons()
        buttons.l1 = (b1 & 0x01) != 0
        buttons.r1 = (b1 & 0x02) != 0
        buttons.create = (b1 & 0x10) != 0
        buttons.options = (b1 & 0x20) != 0
        buttons.ps = (b2 & 0x01) != 0
        buttons.mute = (b2 & 0x04) != 0

        var battery: DualSenseBattery?
        let statusIndex = lxIndex + 52
        if length > statusIndex {
            let status = bytes[statusIndex]
            let level = status & 0x0F
            if level != 0x0C {
                let charge = (status >> 4) & 0x0F
                let pct = (charge == 0x02) ? 100 : min(Int(level) * 10 + 5, 100)
                battery = DualSenseBattery(percent: pct, charging: charge == 0x01 || charge == 0x02)
            }
        }
        let faceButtons = Set(DualSenseFaceButton.allCases.filter { bytes[lxIndex + 7] & $0.rawValue != 0 })
        return DualSenseDecodedReport(buttons: buttons, battery: battery, faceButtons: faceButtons)
    }
}
