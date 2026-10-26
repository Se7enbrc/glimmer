// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// The takeover question, in the launcher's dialog and the menu bar's alert.
/// App names show exactly as typed ("iRacing"); nil is an app the PC didn't name.
enum TakeoverDialogCopy {
    static func title(occupantApp: String?, targetApp: String) -> String {
        "Quit \(occupantApp ?? "the running app") and start \(targetApp)?"
    }

    static let message = "Unsaved progress may be lost. Other streams from this PC will stop."
}
