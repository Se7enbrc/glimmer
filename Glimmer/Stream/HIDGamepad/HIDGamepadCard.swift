import SwiftUI

struct HIDGamepadCard: View {
    let pad: HIDGamepadDevice
    /// Timeline date; the pad is a plain reference, so this is what re-renders.
    let tick: Date

    var body: some View {
        let state = pad.state
        let analog = state.analog
        let pressed = HIDGamepadMapping.buttonFlags.keys.sorted().filter {
            state.buttons & (HIDGamepadMapping.buttonFlags[$0] ?? 0) != 0
        }
        VStack(alignment: .leading, spacing: 6) {
            Label(pad.name, systemImage: "gamecontroller.fill").fontWeight(.semibold)
            Text("HID · \(pad.hardwareID) · \(pad.transport) · Mapping: \(pad.mappingSource)")
            Text("Buttons: \(pressed.isEmpty ? "none" : pressed.joined(separator: ", "))")
            Text("L (\(analog.leftStickX), \(analog.leftStickY))  R (\(analog.rightStickX), \(analog.rightStickY))")
            Text("Triggers: L \(analog.leftTrigger)  R \(analog.rightTrigger) · Reports: \(pad.reportCount)")
            if let percentage = pad.batteryPercentage { Text("Battery: \(percentage)%") }
            if pad.reportCount == 0 && !HIDGamepadManager.accessGranted {
                Text("Waiting for Input Monitoring. Turn on Glimmer in System Settings › Privacy & Security › "
                    + "Input Monitoring, then choose Quit & Reopen when macOS asks.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
