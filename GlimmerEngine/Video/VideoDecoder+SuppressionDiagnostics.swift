// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension VideoDecoder {
    /// Only scalar visibility inputs and fixed reasons may enter shareable suppression diagnostics.
    public struct PresentationVisibility: Sendable {
        public enum Reason: String, Sendable {
            case unspecified
            case occlusionChanged = "occlusion_changed"
            case miniaturized, deminiaturized, backgrounded, foregrounded
            case firstFrameRevealCompleted = "first_frame_reveal_completed"
            case coverReturnCompleted = "cover_return_completed"
            case fullScreenSettled = "full_screen_settled"
            case miniPlayerChanged = "mini_player_changed"
            case sceneAvailability = "scene_availability"
        }

        public enum FullScreenTransition: String, Sendable { case idle, entering, exiting }

        public var reason: Reason
        public var windowVisible: Bool?
        public var minimized: Bool?
        public var occlusionVisible: Bool?
        public var occlusionState: UInt64?
        public var revealing: Bool?
        public var alphaZero: Bool?
        public var miniPlayer: Bool?
        public var appActive: Bool?
        public var fullScreen: Bool?
        public var fullScreenTransition: FullScreenTransition?
        public var background: Bool?
        public var protectedDataAvailable: Bool?
        public var returnedInTime: Bool?

        public init(reason: Reason = .unspecified) { self.reason = reason }
    }

    func recordSuppressionEdge(_ suppressed: Bool, visibility: PresentationVisibility, sessionGeneration: UUID?) {
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        let fields = Self.suppressionFields(suppressed, visibility: visibility,
            sessionGeneration: sessionGeneration ?? suppressionSessionGeneration,
            presentationGeneration: rendererPresentationState.generation, uptimeNanos: now())
        Diag.notice("Presentation suppression: {\(fields.joined(separator: ","))}", "Stream")
        TelemetryExporter.recordEvent(fields)
        #endif
    }

    #if os(macOS) || GLIMMER_DIAGNOSTICS
    nonisolated static func suppressionFields(_ suppressed: Bool, visibility: PresentationVisibility,
                                              sessionGeneration: UUID, presentationGeneration: UInt64,
                                              uptimeNanos: UInt64) -> [String] {
        var row = TelemetryRenderer.NDJSONBuilder()
        row.addString("event", "presentation_suppression")
        row.addBool("suppressed", suppressed)
        row.addString("reason", visibility.reason.rawValue)
        row.addString("session_generation", sessionGeneration.uuidString)
        row.addCount("presentation_generation", presentationGeneration)
        row.add("t_ms", Double(uptimeNanos) / 1_000_000)
        row.addBool("window_visible", visibility.windowVisible)
        row.addBool("minimized", visibility.minimized)
        row.addBool("occlusion_visible", visibility.occlusionVisible)
        row.addCount("occlusion_state", visibility.occlusionState)
        row.addBool("revealing", visibility.revealing)
        row.addBool("alpha_zero", visibility.alphaZero)
        row.addBool("mini_player", visibility.miniPlayer)
        row.addBool("app_active", visibility.appActive)
        row.addBool("full_screen", visibility.fullScreen)
        if let transition = visibility.fullScreenTransition { row.addString("full_screen_transition", transition.rawValue) }
        row.addBool("background", visibility.background)
        row.addBool("protected_data_available", visibility.protectedDataAvailable)
        row.addBool("returned_in_time", visibility.returnedInTime)
        return row.fields
    }
    #endif
}
