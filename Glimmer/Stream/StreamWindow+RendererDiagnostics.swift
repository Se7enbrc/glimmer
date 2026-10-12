// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import AVFoundation
import QuartzCore

extension StreamWindow {
    func logRendererTransition(_ transition: RendererPathTransition, hdrInput: Bool) {
        Diag.notice("Renderer path: \(transition.summary) \(rendererDiagnosticSnapshot(hdrInput: hdrInput))",
                    "Stream.Window")
    }

    func rendererDiagnosticSnapshot(hdrInput: Bool) -> String {
        let screen = window.screen
        let displayID = screen?.cgDirectDisplayID.map(String.init) ?? "none"
        let currentEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let hdrOutput = VideoColorDescription.hdrDisplayOutput(inputHDR: hdrInput, currentEDR: Double(currentEDR))
        let windowState = "level=\(window.level.rawValue) occlusion=\(window.occlusionState.rawValue) "
            + "visible=\(window.isVisible) key=\(window.isKeyWindow) alpha=\(window.alphaValue) "
            + "fullscreen=\(rendererFullscreenMode)"
        // AppKit has no supported global cursor-visibility query. Record our counted hide ownership explicitly.
        let cursor = "cursorVisible=\(!didHideCursor) cursorSource=owned hideCount=\(cursorHideCount)"
        let overlays = rendererVisibleOverlays().joined(separator: ";")
        let child = statsOverlayWindow.window
        let statsWindow = "statsWindow={attached=\(child.parent === window),visible=\(child.isVisible),"
            + "size=\(child.frame.width)x\(child.frame.height),level=\(child.level.rawValue)}"
        return "\(windowState) \(cursor) \(statsWindow) overlays=[\(overlays)] "
            + "video={\(Self.rendererLayerState(displayLayer))} "
            + "currentEDR=\(currentEDR) potentialEDR=\(potentialEDR) hdrInput=\(hdrInput) hdrOutput=\(hdrOutput) "
            + "dynamicRange=\(displayLayer.preferredDynamicRange.rawValue) displayID=\(displayID)"
    }

    private var rendererFullscreenMode: String {
        if window.styleMask.contains(.fullScreen) { return "space" }
        if isMiniPlayer { return "miniPlayer" }
        return isBorderlessCover ? "borderless" : "window"
    }

    func rendererVisibleOverlays() -> [String] {
        var result: [String] = []
        for (index, child) in (displayLayer.sublayers ?? []).enumerated() {
            appendRendererOverlay(child, path: "video/\(index)", to: &result)
        }
        // AppKit may put siblings above the video root; include those at every ancestor level too.
        var branch: CALayer = displayLayer
        var depth = 0
        while let parent = branch.superlayer {
            let siblings = parent.sublayers ?? []
            let branchIndex = siblings.firstIndex { $0 === branch } ?? 0
            for (index, sibling) in siblings.enumerated() where sibling !== branch {
                if sibling.zPosition > branch.zPosition
                    || (sibling.zPosition == branch.zPosition && index > branchIndex) {
                    appendRendererOverlay(sibling, path: "ancestor\(depth)/\(index)", to: &result)
                }
            }
            branch = parent
            depth += 1
        }
        return result
    }

    private func appendRendererOverlay(_ layer: CALayer, path: String, to result: inout [String]) {
        let presented = layer.presentation() ?? layer
        guard !presented.isHidden, presented.opacity > 0 else { return }
        // Fixed roles and runtime classes are public-safe; arbitrary layer names and text contents are not.
        let roles = [(statsOverlay.layer, "stats"), (reconnectBanner.layer, "reconnect"),
                     (networkBanner.layer, "network"), (leaveHintBanner.layer, "leaveHint"),
                     (captureHintBanner.layer, "captureHint")]
        let role = roles.first { $0.0 === layer }?.1 ?? "unnamed"
        result.append("\(path):\(role)/\(String(describing: type(of: layer)))"
            + "{opacity=\(layer.opacity),hidden=\(layer.isHidden),animated=\(Self.rendererHasAnimations(layer)),"
            + "pOpacity=\(presented.opacity),pHidden=\(presented.isHidden)}")
        for (index, child) in (layer.sublayers ?? []).enumerated() {
            appendRendererOverlay(child, path: "\(path)/\(index)", to: &result)
        }
    }

    static func rendererLayerState(_ layer: CALayer) -> String {
        let presented = layer.presentation() ?? layer
        let mask = layer.mask.map { String(describing: type(of: $0)) } ?? "none"
        let filters = (layer.filters ?? []).map { String(describing: type(of: $0)) }.joined(separator: ",")
        let background = (layer.backgroundFilters ?? []).map { String(describing: type(of: $0)) }
            .joined(separator: ",")
        let compositing = layer.compositingFilter.map { String(describing: type(of: $0)) } ?? "none"
        return "opacity=\(layer.opacity),hidden=\(layer.isHidden),animated=\(rendererHasAnimations(layer)),"
            + "pOpacity=\(presented.opacity),pHidden=\(presented.isHidden),mask=\(mask),"
            + "masksToBounds=\(layer.masksToBounds),cornerRadius=\(layer.cornerRadius),"
            + "transform=\(rendererTransform(layer.transform)),pTransform=\(rendererTransform(presented.transform)),"
            + "filters=[\(filters)],backgroundFilters=[\(background)],compositingFilter=\(compositing),"
            + "rasterize=\(layer.shouldRasterize)"
    }

    private static func rendererHasAnimations(_ layer: CALayer) -> Bool {
        !(layer.animationKeys()?.isEmpty ?? true)
    }

    private static func rendererTransform(_ value: CATransform3D) -> String {
        guard !CATransform3DIsIdentity(value) else { return "identity" }
        let elements = [value.m11, value.m12, value.m13, value.m14, value.m21, value.m22, value.m23, value.m24,
                        value.m31, value.m32, value.m33, value.m34, value.m41, value.m42, value.m43, value.m44]
        return "[" + elements.map { String(Double($0)) }.joined(separator: ",") + "]"
    }
}
