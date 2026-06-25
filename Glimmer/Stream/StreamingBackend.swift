//
//  StreamingBackend.swift
//
//  THE streaming-engine abstraction boundary. Everything Glimmer needs from a
//  streaming engine is expressed here as ONE Swift protocol plus three
//  sink/delegate protocols and a set of Glimmer-owned value types. `NativeBackend`
//  (Glimmer/Stream/Native/*) is the sole conformer - a pure-Swift GameStream /
//  Sunshine client. The protocol keeps the rest of the app decoupled from the
//  transport internals.
//
//  The value types and method set mirror the GameStream protocol surface: the
//  outbound input methods map 1:1 to the LiSend* family the protocol defines
//  (the method names retain the Li* labels in their doc comments as spec
//  citations), INCLUDING the DualSense/DualShock touchpad path.
//
//  THREADING (load-bearing):
//   - Outbound input methods (sendKeyboard/.../sendControllerTouch) are called
//     from the @MainActor input forwarders; the native backend's send paths are
//     thread-safe, so main-actor calls are fine.
//   - Telemetry (estimatedRtt/hdrMetadata/launchUrlQueryParameters) is called
//     from the actor and/or the main-run-loop overlay timer.
//   - Inbound sink/event callbacks fire OFF the main actor on the native
//     backend's receive threads. The decoders already tolerate this
//     (decodeQueue.sync / stateLock / NSLock). `setHdrMode`'s main-queue FIFO
//     ordering is preserved by the ConnectionEvents concrete implementation in
//     StreamSession, NOT by the backend.
//
//  BRIDGE NOTE:
//   The `StreamBridgeContext` carries the event continuation + weak subsystem
//   refs and is retained for the connection lifetime (Unmanaged/refcon
//   lifecycle in StreamSession). The native backend drives it from its
//   RTP/control receive threads. The native backend wires its own Swift sinks;
//   the sink/event protocols below describe that boundary.

import Foundation

// MARK: - Glimmer-owned value types (no Limelight.h leakage)

/// Analog state for one controller frame (triggers + both sticks), grouped so
/// `sendMultiController` mirrors LiSendMultiControllerEvent without a 9-argument
/// signature.
public struct GamepadAnalog: Sendable {
    public var leftTrigger: UInt8
    public var rightTrigger: UInt8
    public var leftStickX: Int16
    public var leftStickY: Int16
    public var rightStickX: Int16
    public var rightStickY: Int16

    public init(leftTrigger: UInt8, rightTrigger: UInt8,
                leftStickX: Int16, leftStickY: Int16,
                rightStickX: Int16, rightStickY: Int16) {
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
    }
}

/// Server-identification inputs for `start`. Mirrors SERVER_INFORMATION.
public struct BackendServerInfo: Sendable {
    public var address: String
    public var appVersion: String
    public var gfeVersion: String
    public var rtspSessionUrl: String
    /// The RAW SCM_* bitmask straight from /serverinfo. NOT the VIDEO_FORMAT_*
    /// layout - see StreamProtocol.SCM_* landmine note.
    public var serverCodecModeRaw: Int32

    public init(
        address: String, appVersion: String, gfeVersion: String,
        rtspSessionUrl: String, serverCodecModeRaw: Int32
    ) {
        self.address = address
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.rtspSessionUrl = rtspSessionUrl
        self.serverCodecModeRaw = serverCodecModeRaw
    }
}

/// Stream-configuration inputs for `start`. Mirrors STREAM_CONFIGURATION.
/// `remoteInputAesKey`/`remoteInputAesIv` are the 16-byte per-session GCM
/// key/IV-id from the launch handshake (launch.gcmKey / launch.gcmKeyId).
public struct BackendStreamConfig: Sendable {
    public var width: Int32
    public var height: Int32
    public var fps: Int32
    public var bitrate: Int32
    public var packetSize: Int32
    public var streamingRemotely: Int32
    public var audioConfiguration: Int32
    public var supportedVideoFormats: Int32
    public var clientRefreshRateX100: Int32
    public var colorSpace: Int32
    public var colorRange: Int32
    public var encryptionFlags: Int32
    /// Exactly 16 bytes.
    public var remoteInputAesKey: [UInt8]
    /// Exactly 16 bytes.
    public var remoteInputAesIv: [UInt8]

    public init(
        width: Int32, height: Int32, fps: Int32, bitrate: Int32,
        packetSize: Int32, streamingRemotely: Int32, audioConfiguration: Int32,
        supportedVideoFormats: Int32, clientRefreshRateX100: Int32,
        colorSpace: Int32, colorRange: Int32, encryptionFlags: Int32,
        remoteInputAesKey: [UInt8], remoteInputAesIv: [UInt8]
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.packetSize = packetSize
        self.streamingRemotely = streamingRemotely
        self.audioConfiguration = audioConfiguration
        self.supportedVideoFormats = supportedVideoFormats
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.encryptionFlags = encryptionFlags
        self.remoteInputAesKey = remoteInputAesKey
        self.remoteInputAesIv = remoteInputAesIv
    }
}

/// One PLENTRY-equivalent buffer in a DecodeUnit's chain.
public struct DecodeBuffer: Sendable {
    public enum Kind: Sendable {
        case picData, sps, pps, vps
    }
    public var kind: Kind
    public var data: Data

    public init(kind: Kind, data: Data) {
        self.kind = kind
        self.data = data
    }
}

/// A video access unit. The native backend produces these and hands them to
/// VideoDecoder.
public struct DecodeUnit: Sendable {
    public var frameNumber: Int32
    public var frameType: Int32
    public var fullLength: Int32
    public var frameHostProcessingLatency: UInt16
    public var receiveTimeUs: UInt64
    public var enqueueTimeUs: UInt64
    public var presentationTimeUs: UInt64
    public var rtpTimestamp: UInt32
    public var hdrActive: Bool
    public var colorspace: Int32
    public var buffers: [DecodeBuffer]

    public init(
        frameNumber: Int32, frameType: Int32, fullLength: Int32,
        frameHostProcessingLatency: UInt16, receiveTimeUs: UInt64,
        enqueueTimeUs: UInt64, presentationTimeUs: UInt64,
        rtpTimestamp: UInt32, hdrActive: Bool, colorspace: Int32,
        buffers: [DecodeBuffer]
    ) {
        self.frameNumber = frameNumber
        self.frameType = frameType
        self.fullLength = fullLength
        self.frameHostProcessingLatency = frameHostProcessingLatency
        self.receiveTimeUs = receiveTimeUs
        self.enqueueTimeUs = enqueueTimeUs
        self.presentationTimeUs = presentationTimeUs
        self.rtpTimestamp = rtpTimestamp
        self.hdrActive = hdrActive
        self.colorspace = colorspace
        self.buffers = buffers
    }
}

/// Opus multistream configuration. Mirrors OPUS_MULTISTREAM_CONFIGURATION
/// (AudioDecoder.swift:80-100).
public struct OpusConfig: Sendable {
    public var sampleRate: Int32
    public var channelCount: Int32
    public var streams: Int32
    public var coupledStreams: Int32
    public var samplesPerFrame: Int32
    public var mapping: [UInt8]

    public init(
        sampleRate: Int32, channelCount: Int32, streams: Int32,
        coupledStreams: Int32, samplesPerFrame: Int32, mapping: [UInt8]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
    }
}

/// Flattened HDR10 static metadata. Primaries normalized to 50000, luminance
/// in nits / 1-10000 nit. The native engine fills it from the host's SDP HDR
/// mastering metadata.
public struct HdrMetadata: Sendable {
    public var displayPrimariesRX, displayPrimariesRY: UInt16
    public var displayPrimariesGX, displayPrimariesGY: UInt16
    public var displayPrimariesBX, displayPrimariesBY: UInt16
    public var whitePointX, whitePointY: UInt16
    public var maxDisplayLuminance, minDisplayLuminance: UInt16
    public var maxContentLightLevel, maxFrameAverageLightLevel: UInt16
    public var maxFullFrameLuminance: UInt16

    public init(
        displayPrimariesRX: UInt16, displayPrimariesRY: UInt16,
        displayPrimariesGX: UInt16, displayPrimariesGY: UInt16,
        displayPrimariesBX: UInt16, displayPrimariesBY: UInt16,
        whitePointX: UInt16, whitePointY: UInt16,
        maxDisplayLuminance: UInt16, minDisplayLuminance: UInt16,
        maxContentLightLevel: UInt16, maxFrameAverageLightLevel: UInt16,
        maxFullFrameLuminance: UInt16
    ) {
        self.displayPrimariesRX = displayPrimariesRX
        self.displayPrimariesRY = displayPrimariesRY
        self.displayPrimariesGX = displayPrimariesGX
        self.displayPrimariesGY = displayPrimariesGY
        self.displayPrimariesBX = displayPrimariesBX
        self.displayPrimariesBY = displayPrimariesBY
        self.whitePointX = whitePointX
        self.whitePointY = whitePointY
        self.maxDisplayLuminance = maxDisplayLuminance
        self.minDisplayLuminance = minDisplayLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
        self.maxFullFrameLuminance = maxFullFrameLuminance
    }
}

// MARK: - Inbound sink/event protocols

/// The connection-listener sink. The concrete implementation owns the
/// setHdrMode DispatchQueue.main FIFO ordering; the backend just invokes these
/// on its receive thread in order.
/// rumble (0x010b), rumbleTriggers (0x5500), setControllerLED (0x5502),
/// setMotionEventState (0x5501), and setAdaptiveTriggers (0x5503) are wired
/// (host control → the GameController actuator/sampler, or - for adaptive
/// triggers, which GameController can't drive - the DualSense raw-HID write);
/// the remaining controller-feedback slot (logMessage) is NULL today and given
/// a no-op default below.
public protocol ConnectionEvents: AnyObject, Sendable {
    func stageStarting(_ name: String)
    func stageComplete(_ name: String)
    func stageFailed(_ name: String, code: Int32)
    func connectionStarted()
    func connectionTerminated(code: Int32)
    /// poor == quality-degraded (status != 0).
    func connectionStatus(poor: Bool)
    /// INBOUND only. NOT an outbound LiSetHdrMode. Implementation MUST preserve
    /// DispatchQueue.main FIFO ordering.
    func setHdrMode(_ enabled: Bool)
    /// Host rumble event (SS_RUMBLE_DATA 0x010b). (0,0) is "motors off" and is
    /// forwarded like any other pair - actuators rely on it to idle the pad. A
    /// declared REQUIREMENT (not extension-default-only) so a conformer's
    /// implementation is reached through the witness table at any
    /// `any ConnectionEvents` call site instead of silently hitting the no-op
    /// default; the default below keeps actuator-less conformers
    /// source-compatible.
    func rumble(controller: UInt16, lowFreq: UInt16, highFreq: UInt16)
    /// Host trigger rumble (SS_RUMBLE_TRIGGERS 0x5500; Sunshine extension,
    /// only sent to pads that advertised LI_CCAP_TRIGGER_RUMBLE). Same
    /// contract as rumble - (0,0) means "trigger motors off" and is forwarded
    /// - and a declared REQUIREMENT for the same witness-table reason.
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16)
    /// Host light-bar color (SET_RGB_LED 0x5502; only sent to pads that
    /// advertised LI_CCAP_RGB_LED - Sunshine paints the slot color at session
    /// start and games may re-color at frame rate). A declared REQUIREMENT
    /// for the same witness-table reason as rumble.
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8)
    /// Host motion-sensor enable (SET_MOTION_EVENT 0x5501; only sent to pads
    /// that advertised LI_CCAP_ACCEL/GYRO). reportRateHz == 0 asks reporting
    /// to STOP (ConnListenerSetMotionEventState); motionType is
    /// StreamProtocol.LI_MOTION_TYPE_*. The conformer answers with
    /// sendControllerMotion samples at (close to) the requested rate. A
    /// declared REQUIREMENT for the same witness-table reason as rumble.
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16)
    /// Host adaptive-trigger update (SS_CONTROLLER_ADAPTIVE_TRIGGERS 0x5503;
    /// Sunshine extension, sent only to DualSense pads). eventFlags is the
    /// DS_EFFECT_RIGHT_TRIGGER 0x04 / DS_EFFECT_LEFT_TRIGGER 0x08 bitset for
    /// which trigger blocks to apply; typeLeft/typeRight are DualSense-native
    /// mode bytes and left/right the 10-byte param arrays (passed through to the
    /// raw-HID OUTPUT report). A declared REQUIREMENT for the same witness-table
    /// reason as rumble - so a conformer's implementation is reached through the
    /// witness table at any `any ConnectionEvents` call site instead of silently
    /// hitting the no-op default below. (GameController exposes no adaptive-
    /// trigger API, so unlike rumble/LED/motion the native conformer routes this
    /// to DualSenseHID's raw-HID write rather than the GC actuator.)
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8])
}

public extension ConnectionEvents {
    /// No-op defaults for the controller-feedback requirements: silence is
    /// correct for a conformer with no actuator/sampler behind it.
    func rumble(controller: UInt16, lowFreq: UInt16, highFreq: UInt16) {}
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {}
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {}
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {}
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {}
    // Future controller-feedback slots; NULL today, no-op for parity.
    func logMessage(_ message: String) {}
}

/// = DECODER_RENDERER_CALLBACKS (VideoDecoder.swift:409-419).
public protocol VideoSink: AnyObject, Sendable {
    /// Delivered first. Returns 0 on success, -1 to abort.
    func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32
    func start()
    func stop()
    func cleanup()
    /// Returns StreamProtocol.DR_OK / DR_NEED_IDR.
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32
    /// CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC | _AV1.
    var capabilities: Int32 { get }
}

/// = AUDIO_RENDERER_CALLBACKS (AudioDecoder.swift:43-60).
public protocol AudioSink: AnyObject, Sendable {
    /// Returns 0 on success, -1 on failure.
    func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32
    func cleanup()
    /// `samples` are raw post-FEC, post-decrypt Opus bytes.
    func decodeAndPlay(_ samples: UnsafeRawBufferPointer)
    var capabilities: Int32 { get }
}

// MARK: - StreamingBackend

/// The contract every streaming engine satisfies. `NativeBackend` is the sole
/// conformer - the pure-Swift GameStream / Sunshine engine.
///
/// `@unchecked Sendable` because the concrete backend carries state guarded by
/// actor isolation and its own serialization; it is passed across the
/// StreamSession actor boundary.
public protocol StreamingBackend: AnyObject, Sendable {

    // MARK: Lifecycle
    //
    // `startConnection` BLOCKS: it fires stage/media callbacks synchronously
    // while running and returns 0 on success, non-zero on failure (the caller
    // maps that to StreamError.sessionFailed).
    //
    // The native backend wires its own Swift sinks; `startConnection` takes the
    // already-resolved value types. The StreamBridgeContext (event continuation
    // + weak subsystem refs) is published on the session before startConnection
    // so early stage callbacks resolve through it.
    func startConnection(
        server: BackendServerInfo,
        config: BackendStreamConfig
    ) throws

    /// ASYNC actor-safe connect: same contract as `startConnection`, but awaits
    /// rather than blocking the caller, so an actor caller stays responsive
    /// (stop/cancel/telemetry) while a hanging host is brought up. Cancelling the
    /// awaiting task interrupts the in-flight connect. Defaults to running the
    /// blocking variant off the caller (a detached task) so non-native backends
    /// need no change.
    func startConnectionAsync(
        server: BackendServerInfo,
        config: BackendStreamConfig
    ) async throws

    /// Synchronous teardown; drains receive threads. = LiStopConnection().
    func stopConnection()

    /// Async abort of an in-progress startConnection. = LiInterruptConnection().
    func interruptConnection()

    // MARK: Sink wiring
    //
    // StreamSession injects the decoders as Swift sinks before startConnection.
    // The native engine drives them directly from its receive threads.
    /// Inject the video sink (the VideoDecoder).
    func attachVideoSink(_ sink: VideoSink)
    /// Inject the audio sink (the AudioDecoder).
    func attachAudioSink(_ sink: NativeAudioSink)

    // MARK: Telemetry / control
    /// = LiGetEstimatedRttInfo. nil when not connected. FRACTIONAL ms (Double):
    /// the native backend measures RTT from a high-res LOCAL monotonic clock, not
    /// the 16-bit-ms wire token, so the value carries sub-ms precision (the
    /// overlay's %.2f then renders e.g. "8.73 ms" instead of a whole-ms "9.00").
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)?
    /// Reliable control-stream health (ENet): outstanding reliable command
    /// count + oldest-unacked age + since-last-ack, in ms. nil when the backend
    /// has no control channel up. Surfaced ONLY by the opt-in telemetry
    /// exporter; the protocol default returns nil.
    func enetHealth() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)?
    /// = LiRequestIdrFrame.
    func requestIdrFrame()
    /// Host HDR10 mastering metadata. nil when unavailable.
    func hdrMetadata() -> HdrMetadata?
    /// = LiGetLaunchUrlQueryParameters. "" when the engine has none.
    func launchUrlQueryParameters() -> String
    /// = LiGetStageName. Human label for a connection stage int.
    func stageName(for stage: Int32) -> String

    // MARK: Input uplink - Int32 return; -2 == input stream not ready.
    func sendKeyboard(keyCode: Int16, action: Int8, modifiers: Int8, flags: Int8) -> Int32
    func sendMouseMove(dx: Int16, dy: Int16) -> Int32
    func sendMousePosition(x: Int16, y: Int16, refW: Int16, refH: Int16) -> Int32
    func sendMouseButton(action: Int8, button: Int32) -> Int32
    func sendScroll(_ amount: Int16) -> Int32
    func sendHScroll(_ amount: Int16) -> Int32
    func sendMultiController(num: Int16, mask: Int16, buttons: Int32, analog: GamepadAnalog) -> Int32
    func sendControllerArrival(
        num: UInt8, mask: UInt16, type: UInt8,
        supportedButtons: UInt32, caps: UInt16
    ) -> Int32
    /// = LiSendControllerTouchEvent2 - DualSense/DualShock touchpad finger
    /// down/move/up. (The 7th input symbol the design doc §2.1 omitted.)
    func sendControllerTouch(
        num: UInt8, eventType: UInt8, touchpadIndex: UInt8,
        pointerId: UInt32, x: Float, y: Float, pressure: Float
    ) -> Int32
    /// = LiSendControllerMotionEvent - one accel/gyro sample for a pad the
    /// host enabled via ConnectionEvents.setMotionEventState. Units/axes are
    /// the wire's contract (Limelight.h): accel m/s^2 INCLUSIVE of gravity,
    /// gyro deg/s, axes per SDL's sensor convention. motionType is
    /// StreamProtocol.LI_MOTION_TYPE_*.
    func sendControllerMotion(
        num: UInt8, motionType: UInt8, x: Float, y: Float, z: Float
    ) -> Int32
}

public extension StreamingBackend {
    /// Default: no control-stream health to report. Backends with an ENet
    /// control channel (NativeBackend) override this; a future C backend would
    /// inherit nil rather than be forced to fabricate the numbers.
    func enetHealth() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)? { nil }

    /// Default async connect: run the blocking `startConnection` on a detached task
    /// so the awaiting caller isn't parked. Cancelling the task interrupts the
    /// in-flight connect. The native backend overrides this with a continuation that
    /// drives its dedicated connect thread directly. The `self` capture is safe -
    /// `StreamingBackend` is `Sendable`.
    func startConnectionAsync(
        server: BackendServerInfo,
        config: BackendStreamConfig
    ) async throws {
        try await withTaskCancellationHandler {
            let task = Task.detached(priority: .userInitiated) {
                try self.startConnection(server: server, config: config)
            }
            try await task.value
        } onCancel: {
            interruptConnection()
        }
    }
}
