import Foundation

struct HIDGamepadElement: Sendable, Equatable {
    enum Kind: Sendable { case axis, button, hat, battery }
    let cookie: UInt32
    let page: UInt32
    let usage: UInt32
    let kind: Kind

    static func classify(page: UInt32, usage: UInt32) -> Kind? {
        if page == 1 && (0x30...0x38).contains(usage) { return .axis }
        if page == 2 && [0xBA, 0xBB, 0xC4, 0xC5].contains(usage) { return .axis }
        if page == 1 && usage == 0x39 { return .hat }
        if page == 9 || page == 12 { return .button }
        if page == 6 && usage == 0x20 { return .battery }
        if page == 0x85 && usage == 0x64 { return .battery }
        return nil
    }

    static func ordered(_ elements: [Self], kind: Kind) -> [Self] {
        var seen: Set<UInt32> = []
        return elements.enumerated().filter { $0.element.kind == kind && seen.insert($0.element.cookie).inserted }
            .sorted {
                $0.element.usage == $1.element.usage ? $0.offset < $1.offset : $0.element.usage < $1.element.usage
            }.map(\.element)
    }

    static func hat(value: Int, minimum: Int, maximum: Int) -> UInt8 {
        guard value >= minimum, value <= maximum else { return 0 }
        let range = maximum - minimum + 1
        guard range == 4 || range == 8 else { return 0 }
        return [1, 3, 2, 6, 4, 12, 8, 9][(value - minimum) * (range == 4 ? 2 : 1)]
    }

    struct AxisRange {
        var minimum: Int
        var maximum: Int
        mutating func scale(_ value: Int) -> Int16 {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            guard maximum > minimum else { return Int16(clamping: value) }
            if value == minimum { return -32768 }
            if value == maximum { return 32767 }
            let scaled = Float(value - minimum) * 65535 / Float(maximum - minimum) - 32768
            return Int16(clamping: Int(scaled))
        }
    }
}

extension HIDGamepadMapping {
    static func heuristic(elements: [HIDGamepadElement]) -> Self {
        let axes = HIDGamepadElement.ordered(elements, kind: .axis)
        let buttons = HIDGamepadElement.ordered(elements, kind: .button)
        var bindings: [String: Input] = [:]
        let outputs = ["a", "b", "x", "y", "leftshoulder", "rightshoulder", "lefttrigger", "righttrigger",
                       "back", "start", "leftstick", "rightstick"]
        for (index, output) in outputs.enumerated() where index < buttons.count { bindings[output] = .button(index) }
        let stickUsages: [(String, UInt32)] = [("leftx", 0x30), ("lefty", 0x31), ("rightx", 0x32), ("righty", 0x35)]
        for (output, usage) in stickUsages {
            if let index = axes.firstIndex(where: { $0.page == 1 && $0.usage == usage }) {
                bindings[output] = .axis(index, half: 0, inverted: false)
            }
        }
        for (output, desktop, simulation): (String, UInt32, UInt32) in
            [("lefttrigger", 0x33, 0xC5), ("righttrigger", 0x34, 0xC4)] {
            let index = axes.firstIndex { $0.page == 2 && $0.usage == simulation }
                ?? axes.firstIndex { $0.page == 1 && $0.usage == desktop }
            if let index { bindings[output] = .axis(index, half: 0, inverted: false) }
        }
        if !HIDGamepadElement.ordered(elements, kind: .hat).isEmpty {
            for (output, mask): (String, UInt8) in [("dpup", 1), ("dpright", 2), ("dpdown", 4), ("dpleft", 8)] {
                bindings[output] = .hat(0, mask: mask)
            }
        }
        return Self(name: "heuristic", bindings: bindings)
    }
}
