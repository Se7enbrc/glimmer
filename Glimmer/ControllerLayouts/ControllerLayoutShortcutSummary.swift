// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerLayoutShortcutSummary: View {
    var body: some View {
        LabeledContent("Stop streaming", value: "L1 + R1 + Start + Select")
        Text("Hold these four buttons together to stop streaming. This shortcut can't be changed.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
