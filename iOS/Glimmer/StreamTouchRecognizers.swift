// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class StreamTapRecognizer: UITapGestureRecognizer {
    private(set) var eventTimestamp: TimeInterval?

    func captureTimestamp(_ timestamp: TimeInterval) { eventTimestamp = timestamp }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesCancelled(touches, with: event)
    }
}

@MainActor
final class StreamPanRecognizer: UIPanGestureRecognizer {
    private(set) var eventTimestamp: TimeInterval?

    func captureTimestamp(_ timestamp: TimeInterval) { eventTimestamp = timestamp }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        captureTimestamp(event.timestamp)
        super.touchesCancelled(touches, with: event)
    }
}
