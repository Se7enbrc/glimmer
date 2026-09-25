import Foundation

struct HIDGamepadSnapshot: Sendable {
    var axes: [Int16] = []
    var buttons: [Bool] = []
    var hats: [UInt8] = []
}

struct HIDGamepadMapping: Sendable {
    enum Input: Equatable, Sendable {
        case button(Int)
        case axis(Int, half: Int, inverted: Bool)
        case hat(Int, mask: UInt8)

        init?(_ text: String) {
            var token = text
            let half = token.first == "+" ? 1 : token.first == "-" ? -1 : 0
            if half != 0 { token.removeFirst() }
            let inverted = token.last == "~"
            if inverted { token.removeLast() }
            guard let kind = token.first else { return nil }
            token.removeFirst()
            if kind == "h", half == 0, !inverted {
                let parts = token.split(separator: ".")
                guard parts.count == 2, let index = Int(parts[0]), index >= 0,
                      let mask = UInt8(parts[1]), mask > 0, mask <= 15 else { return nil }
                self = .hat(index, mask: mask)
                return
            }
            guard let index = Int(token), index >= 0 else { return nil }
            switch kind {
            case "a": self = .axis(index, half: half, inverted: inverted)
            case "b" where half == 0 && !inverted: self = .button(index)
            default: return nil
            }
        }

        var isAxis: Bool { if case .axis = self { return true }; return false }

        func travel(_ snapshot: HIDGamepadSnapshot) -> Double? {
            switch self {
            case .button(let index):
                guard snapshot.buttons.indices.contains(index) else { return nil }
                return snapshot.buttons[index] ? 1 : 0
            case .hat(let index, let mask):
                guard snapshot.hats.indices.contains(index) else { return nil }
                return snapshot.hats[index] & mask == mask ? 1 : 0
            case .axis(let index, let half, let inverted):
                guard snapshot.axes.indices.contains(index) else { return nil }
                let value = Double(snapshot.axes[index])
                let start = half == 0 ? -32768.0 : 0
                let end = half < 0 ? -32768.0 : 32767.0
                let low = min(start, end), high = max(start, end)
                guard value >= low, value <= high else { return nil }
                let fraction = (value - start) / (end - start)
                return inverted ? 1 - fraction : fraction
            }
        }
    }

    let guid: String
    let identity: GameControllerDB.Identity?
    let name: String
    var bindings: [String: Input]
    var isHeuristic = false

    static let buttonFlags: [String: Int32] = [
        "a": StreamProtocol.A_FLAG, "b": StreamProtocol.B_FLAG,
        "x": StreamProtocol.X_FLAG, "y": StreamProtocol.Y_FLAG,
        "back": StreamProtocol.BACK_FLAG, "guide": StreamProtocol.SPECIAL_FLAG,
        "start": StreamProtocol.PLAY_FLAG, "leftstick": StreamProtocol.LS_CLK_FLAG,
        "rightstick": StreamProtocol.RS_CLK_FLAG, "leftshoulder": StreamProtocol.LB_FLAG,
        "rightshoulder": StreamProtocol.RB_FLAG, "dpup": StreamProtocol.UP_FLAG,
        "dpdown": StreamProtocol.DOWN_FLAG, "dpleft": StreamProtocol.LEFT_FLAG,
        "dpright": StreamProtocol.RIGHT_FLAG, "misc1": StreamProtocol.MISC_FLAG,
        "paddle1": StreamProtocol.PADDLE1_FLAG, "paddle2": StreamProtocol.PADDLE2_FLAG,
        "paddle3": StreamProtocol.PADDLE3_FLAG, "paddle4": StreamProtocol.PADDLE4_FLAG,
        "touchpad": StreamProtocol.TOUCHPAD_FLAG
    ]
    static let analogOutputs = ["leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger"]

    init?(line: String) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 3, let identity = GameControllerDB.identity(fields[0]) else { return nil }
        guid = fields[0]
        self.identity = identity
        name = fields[1]
        bindings = [:]
        for field in fields.dropFirst(2) {
            let pair = field.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let output = pair[0].first == "+" || pair[0].first == "-" ? String(pair[0].dropFirst()) : pair[0]
            guard Self.buttonFlags[output] != nil || Self.analogOutputs.contains(output) else { continue }
            if let input = Input(pair[1]) { bindings[pair[0]] = input }
        }
    }

    init(name: String, bindings: [String: Input]) {
        guid = ""
        identity = nil
        self.name = name
        self.bindings = bindings
        isHeuristic = true
    }

    var supportedButtons: UInt32 {
        UInt32(bitPattern: bindings.keys.reduce(Int32(0)) { $0 | (Self.buttonFlags[$1] ?? 0) })
    }

    var hasAnalogTriggers: Bool {
        bindings["lefttrigger"]?.isAxis == true || bindings["righttrigger"]?.isAxis == true
    }

    var controllerType: UInt8 {
        let label = name.lowercased()
        if label.contains("xbox") { return UInt8(StreamProtocol.LI_CTYPE_XBOX) }
        if ["ps", "playstation", "dualshock", "dualsense"].contains(where: label.contains) {
            return UInt8(StreamProtocol.LI_CTYPE_PS)
        }
        if ["nintendo", "switch", "joy-con"].contains(where: label.contains) {
            return UInt8(StreamProtocol.LI_CTYPE_NINTENDO)
        }
        return UInt8(StreamProtocol.LI_CTYPE_UNKNOWN)
    }

    func translate(_ snapshot: HIDGamepadSnapshot) -> (buttons: Int32, analog: GamepadAnalog) {
        let buttons = Self.buttonFlags.reduce(Int32(0)) { result, entry in
            result | ((bindings[entry.key]?.travel(snapshot) ?? 0) > 0.5 ? entry.value : 0)
        }
        func trigger(_ output: String) -> UInt8 {
            UInt8(((bindings[output]?.travel(snapshot) ?? 0) * 255).rounded(.towardZero))
        }
        func stick(_ output: String, flip: Bool = false) -> Int16 {
            var value = 0
            if let input = bindings[output], let travel = input.travel(snapshot) {
                value = input.isAxis ? Int(travel * 65535 - 32768) : Int(travel * 32767)
            }
            if let travel = bindings["+" + output]?.travel(snapshot) { value += Int(travel * 32767) }
            if let travel = bindings["-" + output]?.travel(snapshot) { value -= Int(travel * 32768) }
            // SDL Y points down; the host protocol points up. Saturate the asymmetric endpoint.
            return Int16(clamping: flip ? -value : value)
        }
        return (buttons, GamepadAnalog(leftTrigger: trigger("lefttrigger"), rightTrigger: trigger("righttrigger"),
                                      leftStickX: stick("leftx"), leftStickY: stick("lefty", flip: true),
                                      rightStickX: stick("rightx"), rightStickY: stick("righty", flip: true)))
    }
}

enum GameControllerDB {
    struct Identity: Equatable, Sendable {
        let bus: UInt16
        let vendor: UInt16
        let product: UInt16
        let version: UInt16
    }

    /// SDL's bus id for an IOKit transport string; the DB keys USB and Bluetooth
    /// layouts separately because some pads expose different reports per link.
    static func bus(forTransport transport: String) -> UInt16 {
        transport.lowercased().contains("bluetooth") ? 0x05 : 0x03
    }

    static func identity(_ guid: String) -> Identity? {
        guard guid.count == 32 else { return nil }
        let chars = Array(guid)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        func word(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        return Identity(bus: word(0), vendor: word(4), product: word(8), version: word(12))
    }

    static let mappings = macOSEntries.compactMap { HIDGamepadMapping(line: $0) }

    /// Best entry for a pad: same bus and version first, then same bus, then
    /// same version on any bus, then any bus (the CRC field is never compared).
    static func lookup(vendor: UInt16, product: UInt16, version: UInt16, bus: UInt16 = 0x03,
                       entries: [HIDGamepadMapping] = mappings) -> HIDGamepadMapping? {
        let candidates = entries.compactMap { entry -> (HIDGamepadMapping, Identity)? in
            guard let id = entry.identity, id.vendor == vendor, id.product == product else { return nil }
            return (entry, id)
        }
        let preferences: [(Identity) -> Bool] = [
            { $0.bus == bus && $0.version == version },
            { $0.bus == bus },
            { $0.version == version },
            { _ in true }
        ]
        for prefer in preferences {
            if let match = candidates.first(where: { prefer($0.1) }) { return match.0 }
        }
        return nil
    }

    static func lookup(guid: String, entries: [HIDGamepadMapping] = mappings) -> HIDGamepadMapping? {
        guard let id = identity(guid) else { return nil }
        return lookup(vendor: id.vendor, product: id.product, version: id.version, bus: id.bus, entries: entries)
    }
}
