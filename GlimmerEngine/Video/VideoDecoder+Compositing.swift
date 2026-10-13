// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

extension VideoDecoder {
    package nonisolated var rendererPresentationState: RendererPresentationState {
        presentSuppressedLock.lock()
        defer { presentSuppressedLock.unlock() }
        return RendererPresentationState(generation: presentationGeneration, suppressed: _presentSuppressed)
    }
}
