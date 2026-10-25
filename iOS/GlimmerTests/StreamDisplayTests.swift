// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamDisplayTests {
    @Test func pictureIsNeverCroppedIncludingAfterRendererRecovery() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        #expect(surface.displayLayer.videoGravity == .resizeAspect)
        let original = surface.displayLayer
        let replacement = surface.replaceDisplayLayer { _ in }
        #expect(replacement !== original)
        #expect(replacement.videoGravity == .resizeAspect)
    }
}
