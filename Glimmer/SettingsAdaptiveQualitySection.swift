// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

/// The Mac's copy of iPhone and iPad's Connection switch. The registered
/// default decides a fresh install; a saved choice always wins.
struct SettingsAdaptiveQualitySection: View {
    @AppStorage(AdaptiveBandwidth.defaultsKey, store: PersistentStorage.defaults) private var adaptiveBandwidth = false

    var body: some View {
        Section("Connection") {
            Toggle(isOn: $adaptiveBandwidth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adaptive stream quality").fontWeight(.medium)
                    Text("Lowers the bitrate when the connection struggles and raises it again once it recovers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Adaptive stream quality")
        }
    }
}
