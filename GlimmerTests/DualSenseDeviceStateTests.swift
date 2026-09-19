import Testing
@testable import Glimmer

struct DualSenseDeviceStateTests {
    @Test(arguments: [UInt32(0x01), UInt32(0x31)], [true, false])
    func faceButtonsRespectTransportAndReportPrefix(reportID: UInt32, includesID: Bool) throws {
        let lxIndex = (includesID ? 1 : 0) + (reportID == 0x31 ? 1 : 0)
        for button in DualSenseFaceButton.allCases {
            for hat: UInt8 in 0...8 {
                var bytes = [UInt8](repeating: 0, count: 64)
                if includesID { bytes[0] = UInt8(reportID) }
                bytes[lxIndex + 7] = button.rawValue | hat
                bytes[lxIndex + 8] = 0x33
                bytes[lxIndex + 9] = 0x05
                bytes[lxIndex + 52] = 0x15
                let decoded = try #require(bytes.withUnsafeBufferPointer {
                    DualSenseHID.decodeInputReport(reportID: reportID, bytes: $0)
                })
                #expect(decoded.faceButtons == [button])
                #expect(decoded.buttons == DualSenseExtraButtons(
                    options: true, create: true, ps: true, mute: true, l1: true, r1: true))
                #expect(decoded.battery == DualSenseBattery(percent: 55, charging: true))
            }
        }
    }

    @Test func allFacesAndNoFaces() throws {
        for mask: UInt8 in [0, 0xF0] {
            var bytes = [UInt8](repeating: 0, count: 64)
            bytes[8] = mask | 8
            bytes[0] = 0x01
            let report = try #require(bytes.withUnsafeBufferPointer {
                DualSenseHID.decodeInputReport(reportID: 0x01, bytes: $0)
            })
            #expect(report.faceButtons == (mask == 0 ? [] : Set(DualSenseFaceButton.allCases)))
        }
    }

    @Test func shortAndUnknownReportsStayIgnored() {
        for reportID: UInt32 in [0x01, 0x31, 0x05] {
            var bytes = [UInt8](repeating: 0, count: 10)
            bytes[0] = UInt8(reportID)
            #expect(bytes.withUnsafeBufferPointer {
                DualSenseHID.decodeInputReport(reportID: reportID, bytes: $0)
            } == nil)
        }
    }

    @Test func independentSnapshotsAndPressEdges() {
        var states = [
            1: DualSenseDeviceState(identity: .serial("first"), transport: "USB"),
            2: DualSenseDeviceState(identity: .registry(42), transport: "Bluetooth")
        ]
        let report = DualSenseDecodedReport(buttons: DualSenseExtraButtons(options: true),
                                           battery: DualSenseBattery(percent: 55, charging: true),
                                           faceButtons: [.cross])
        #expect(states[1]?.apply(report) == [.cross])
        #expect(states[1]?.apply(report).isEmpty == true)
        #expect(states[1]?.reportCount == 2)
        #expect(states[2]?.buttons == DualSenseExtraButtons())
        #expect(states[2]?.battery == nil)
        #expect(states[2]?.reportCount == 0)
        #expect(states[1]?.identity == .serial("first"))
        #expect(states[2]?.identity == .registry(42))
        let release = DualSenseDecodedReport(buttons: DualSenseExtraButtons(), battery: nil)
        #expect(states[1]?.apply(release).isEmpty == true)
        #expect(states[1]?.battery == report.battery)
        #expect(states[1]?.apply(report) == [.cross])
    }
}
