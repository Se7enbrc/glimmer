// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

public enum StreamFailureCopy {
    public static func identityNeedsRestore(_ pc: String) -> String {
        "Couldn't read Glimmer's saved identity for \(pc). Restore Glimmer's identity from a backup, then try again."
    }

    public static func gameEnded(_ app: String, pc: String) -> String {
        "\(app) ended on \(pc)."
    }

    public static func runningAppChanged(_ pc: String) -> String {
        "The app running on \(pc) changed. Choose what to do next."
    }

    public static func quitUnconfirmed(_ app: String, pc: String) -> String {
        "Couldn't confirm that \(app) quit on \(pc). Refresh the PC before trying again."
    }

    public static func quitRefused(_ pc: String) -> String {
        "\(pc) wouldn't quit the app. If another device is streaming from it, stop that stream first."
    }

    public static func needsSunshineMessage(_ pcName: String) -> String {
        "Glimmer needs Sunshine on \(pcName), which is running NVIDIA GameStream."
    }

    public static func portsBlockedMessage(_ pcName: String, proto: String, port: UInt16) -> String {
        "\(pcName) answered, but the stream couldn't get through. "
            + "Check that the PC's firewall allows \(proto) \(port)."
    }

    public static func protectedContentMessage(_ pcName: String) -> String {
        "\(pcName) stopped the stream: the app is showing protected content, which can't be streamed. "
            + "Close it on the PC, then try again."
    }
}
