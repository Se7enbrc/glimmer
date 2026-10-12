// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Sunshine wire constants crossing the StreamingBackend boundary, grouped by Limelight.h section
// so their ABI values can be audited against the protocol rather than inferred from app types.

import Foundation

/// Mirror of the Limelight.h protocol constants. A pure namespace of `Int32`
/// values (the C macros are `#define`d ints). Grouped by the C section they
/// come from for auditability.
package enum StreamProtocol {

    // MARK: Decoder-renderer return codes (Limelight.h:301-302)
    /// Decode unit accepted.
    package static let DR_OK: Int32 = 0
    /// Decode unit could not be decoded; host should send a fresh IDR.
    package static let DR_NEED_IDR: Int32 = -1

    // MARK: Generic Li* error codes (Limelight.h:613)
    /// Host does not support the requested entry point. (NativeBackend now
    /// reaches "connected"; native A/V receive lands in a later increment.)
    package static let LI_ERR_UNSUPPORTED: Int32 = -5501

    // MARK: Colorspace (Limelight.h:24-26)
    package static let COLORSPACE_REC_601: Int32 = 0
    package static let COLORSPACE_REC_709: Int32 = 1
    package static let COLORSPACE_REC_2020: Int32 = 2

    // MARK: Color range (Limelight.h:29-30)
    package static let COLOR_RANGE_LIMITED: Int32 = 0
    package static let COLOR_RANGE_FULL: Int32 = 1

    // MARK: Encryption flags (Limelight.h:33-36)
    package static let ENCFLG_NONE: Int32 = 0x0000_0000
    package static let ENCFLG_AUDIO: Int32 = 0x0000_0001
    package static let ENCFLG_VIDEO: Int32 = 0x0000_0002
    package static let ENCFLG_ALL: Int32 = Int32(bitPattern: 0xFFFF_FFFF)

    // MARK: Streaming-remotely config (Limelight.h:38-40)
    package static let STREAM_CFG_LOCAL: Int32 = 0
    package static let STREAM_CFG_REMOTE: Int32 = 1
    package static let STREAM_CFG_AUTO: Int32 = 2

    // MARK: PLENTRY buffer types (Limelight.h:111-114)
    package static let BUFFER_TYPE_PICDATA: Int32 = 0x00
    package static let BUFFER_TYPE_SPS: Int32 = 0x01
    package static let BUFFER_TYPE_PPS: Int32 = 0x02
    package static let BUFFER_TYPE_VPS: Int32 = 0x03

    // MARK: Frame types (Limelight.h:132/141)
    package static let FRAME_TYPE_PFRAME: Int32 = 0x00
    package static let FRAME_TYPE_IDR: Int32 = 0x01

    // MARK: Video formats (Limelight.h:225-234)
    package static let VIDEO_FORMAT_H264: Int32 = 0x0001
    package static let VIDEO_FORMAT_H264_HIGH8_444: Int32 = 0x0004
    package static let VIDEO_FORMAT_H265: Int32 = 0x0100
    package static let VIDEO_FORMAT_H265_MAIN10: Int32 = 0x0200
    package static let VIDEO_FORMAT_H265_REXT8_444: Int32 = 0x0400
    package static let VIDEO_FORMAT_H265_REXT10_444: Int32 = 0x0800
    package static let VIDEO_FORMAT_AV1_MAIN8: Int32 = 0x1000
    package static let VIDEO_FORMAT_AV1_MAIN10: Int32 = 0x2000
    package static let VIDEO_FORMAT_AV1_HIGH8_444: Int32 = 0x4000
    package static let VIDEO_FORMAT_AV1_HIGH10_444: Int32 = 0x8000

    // MARK: Video-format masks (Limelight.h:237-241)
    package static let VIDEO_FORMAT_MASK_H264: Int32 = 0x000F
    package static let VIDEO_FORMAT_MASK_H265: Int32 = 0x0F00
    package static let VIDEO_FORMAT_MASK_AV1: Int32 = 0xF000
    package static let VIDEO_FORMAT_MASK_10BIT: Int32 = 0xAA00
    package static let VIDEO_FORMAT_MASK_YUV444: Int32 = 0xCC04

    // MARK: Decoder capabilities (Limelight.h:252/256/277)
    package static let CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC: Int32 = 0x2
    package static let CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC: Int32 = 0x4
    package static let CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1: Int32 = 0x40

    // MARK: Server codec-mode support - RAW SCM_* bitmask (Limelight.h:506-515)

    // *** LANDMINE *** This is a DIFFERENT bit layout from VIDEO_FORMAT_*. e.g. SCM_AV1_MAIN10 (0x20000) vs
    // VIDEO_FORMAT_AV1_MAIN10 (0x2000). serverCodecModeSupport takes the RAW SCM_* value; confusing it with the
    // VIDEO_FORMAT_* layout silently drops AV1 Main10 (no HDR).
    package static let SCM_H264: Int32 = 0x0000_0001
    package static let SCM_HEVC: Int32 = 0x0000_0100
    package static let SCM_HEVC_MAIN10: Int32 = 0x0000_0200
    package static let SCM_AV1_MAIN8: Int32 = 0x0001_0000
    package static let SCM_AV1_MAIN10: Int32 = 0x0002_0000
    package static let SCM_H264_HIGH8_444: Int32 = 0x0004_0000
    package static let SCM_HEVC_REXT8_444: Int32 = 0x0008_0000
    package static let SCM_HEVC_REXT10_444: Int32 = 0x0010_0000
    package static let SCM_AV1_HIGH8_444: Int32 = 0x0020_0000
    package static let SCM_AV1_HIGH10_444: Int32 = 0x0040_0000

    // MARK: Keyboard actions + modifiers (Limelight.h:697-702)
    package static let KEY_ACTION_DOWN: Int32 = 0x03
    package static let KEY_ACTION_UP: Int32 = 0x04
    package static let MODIFIER_SHIFT: Int32 = 0x01
    package static let MODIFIER_CTRL: Int32 = 0x02
    package static let MODIFIER_ALT: Int32 = 0x04
    package static let MODIFIER_META: Int32 = 0x08

    // MARK: Mouse button actions (Limelight.h:685-686)
    package static let BUTTON_ACTION_PRESS: Int32 = 0x07
    package static let BUTTON_ACTION_RELEASE: Int32 = 0x08

    // MARK: Mouse buttons (Limelight.h:688-694)
    package static let BUTTON_LEFT: Int32 = 0x01
    package static let BUTTON_MIDDLE: Int32 = 0x02
    package static let BUTTON_RIGHT: Int32 = 0x03
    package static let BUTTON_X1: Int32 = 0x04
    package static let BUTTON_X2: Int32 = 0x05

    // MARK: Gamepad button flags (Limelight.h:715-737)
    package static let A_FLAG: Int32 = 0x1000
    package static let B_FLAG: Int32 = 0x2000
    package static let X_FLAG: Int32 = 0x4000
    package static let Y_FLAG: Int32 = Int32(bitPattern: 0x0000_8000)
    package static let UP_FLAG: Int32 = 0x0001
    package static let DOWN_FLAG: Int32 = 0x0002
    package static let LEFT_FLAG: Int32 = 0x0004
    package static let RIGHT_FLAG: Int32 = 0x0008
    package static let LB_FLAG: Int32 = 0x0100
    package static let RB_FLAG: Int32 = 0x0200
    package static let PLAY_FLAG: Int32 = 0x0010
    package static let BACK_FLAG: Int32 = 0x0020
    package static let LS_CLK_FLAG: Int32 = 0x0040
    package static let RS_CLK_FLAG: Int32 = 0x0080
    package static let SPECIAL_FLAG: Int32 = 0x0400
    package static let PADDLE1_FLAG: Int32 = 0x01_0000
    package static let PADDLE2_FLAG: Int32 = 0x02_0000
    package static let PADDLE3_FLAG: Int32 = 0x04_0000
    package static let PADDLE4_FLAG: Int32 = 0x08_0000
    package static let TOUCHPAD_FLAG: Int32 = 0x10_0000
    package static let MISC_FLAG: Int32 = 0x20_0000

    // MARK: Controller type (Limelight.h:772-775)
    package static let LI_CTYPE_UNKNOWN: Int32 = 0x00
    package static let LI_CTYPE_XBOX: Int32 = 0x01
    package static let LI_CTYPE_PS: Int32 = 0x02
    package static let LI_CTYPE_NINTENDO: Int32 = 0x03

    // MARK: Controller capabilities (Limelight.h:776-784)
    package static let LI_CCAP_ANALOG_TRIGGERS: Int32 = 0x01
    package static let LI_CCAP_RUMBLE: Int32 = 0x02
    package static let LI_CCAP_TRIGGER_RUMBLE: Int32 = 0x04
    package static let LI_CCAP_TOUCHPAD: Int32 = 0x08
    package static let LI_CCAP_ACCEL: Int32 = 0x10
    package static let LI_CCAP_GYRO: Int32 = 0x20
    package static let LI_CCAP_BATTERY_STATE: Int32 = 0x40
    package static let LI_CCAP_RGB_LED: Int32 = 0x80
    package static let LI_CCAP_DUAL_TOUCHPAD: Int32 = 0x100

    // MARK: Controller motion types (Limelight.h, LiSendControllerMotionEvent)

    // Units are part of the wire contract: ACCEL reports m/s^2 INCLUSIVE of
    // gravitational acceleration, GYRO reports deg/s; x/y/z follow SDL's
    // sensor axis convention (+X right, +Y up, +Z toward the player).
    package static let LI_MOTION_TYPE_ACCEL: Int32 = 0x01
    package static let LI_MOTION_TYPE_GYRO: Int32 = 0x02

    // MARK: Controller battery (Limelight.h, LiSendControllerBatteryEvent)

    // Wire states for the SS_CONTROLLER_BATTERY uplink. GameController maps
    // onto a subset (full/charging/discharging/unknown); NOT_PRESENT and
    // NOT_CHARGING exist for clients whose pad APIs can distinguish them.
    package static let LI_BATTERY_STATE_UNKNOWN: Int32 = 0x00
    package static let LI_BATTERY_STATE_NOT_PRESENT: Int32 = 0x01
    package static let LI_BATTERY_STATE_DISCHARGING: Int32 = 0x02
    package static let LI_BATTERY_STATE_CHARGING: Int32 = 0x03
    package static let LI_BATTERY_STATE_NOT_CHARGING: Int32 = 0x04
    package static let LI_BATTERY_STATE_FULL: Int32 = 0x05
    /// Sentinel percentage when the charge level can't be read.
    package static let LI_BATTERY_PERCENTAGE_UNKNOWN: Int32 = 0xFF

    // MARK: Touch events (Limelight.h:651-658)
    package static let LI_TOUCH_EVENT_HOVER: Int32 = 0x00
    package static let LI_TOUCH_EVENT_DOWN: Int32 = 0x01
    package static let LI_TOUCH_EVENT_UP: Int32 = 0x02
    package static let LI_TOUCH_EVENT_MOVE: Int32 = 0x03
    package static let LI_TOUCH_EVENT_CANCEL: Int32 = 0x04
    package static let LI_TOUCH_EVENT_BUTTON_ONLY: Int32 = 0x05
    package static let LI_TOUCH_EVENT_HOVER_LEAVE: Int32 = 0x06
    package static let LI_TOUCH_EVENT_CANCEL_ALL: Int32 = 0x07
}

// MARK: - Connection-stage names

// Mirror of the protocol's LiGetStageName table. Lives here so the native backend produces numerically + textually
// stable stage names for UI / signposts without touching Limelight.h; `stageName(_:)` indexes this table directly.

// Values match Connection.c STAGE_* (Limelight.h:373-385).
package enum StreamStageNames {
    /// 0 STAGE_NONE ... 12 STAGE_MAX. Index == the stage int.
    package static let table: [String] = [
        "none",                              // 0  STAGE_NONE
        "platform initialization",           // 1  STAGE_PLATFORM_INIT
        "name resolution",                   // 2  STAGE_NAME_RESOLUTION
        "audio stream initialization",       // 3  STAGE_AUDIO_STREAM_INIT
        "RTSP handshake",                    // 4  STAGE_RTSP_HANDSHAKE
        "control stream initialization",     // 5  STAGE_CONTROL_STREAM_INIT
        "video stream initialization",       // 6  STAGE_VIDEO_STREAM_INIT
        "input stream initialization",       // 7  STAGE_INPUT_STREAM_INIT
        "control stream establishment",      // 8  STAGE_CONTROL_STREAM_START
        "video stream establishment",        // 9  STAGE_VIDEO_STREAM_START
        "audio stream establishment",        // 10 STAGE_AUDIO_STREAM_START
        "input stream establishment"         // 11 STAGE_INPUT_STREAM_START
    ]

    package static func name(for stage: Int32) -> String {
        let i = Int(stage)
        if i >= 0 && i < table.count { return table[i] }
        return "Stage \(stage)"
    }
}
