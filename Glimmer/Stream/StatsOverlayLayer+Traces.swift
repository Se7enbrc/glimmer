import AppKit
import QuartzCore

/// Forty intervals at the overlay's 4 Hz cadence, with missing readings left as gaps.
struct StatsTraceHistory {
    struct Sample {
        var value: Double?
        var hiccup = false
        var time: Double = 0
    }

    static let capacity = 41
    private var storage = Array(repeating: Sample(), count: capacity)
    private var next = 0
    private(set) var count = 0
    var isEmpty: Bool { count < 1 }

    subscript(index: Int) -> Sample {
        storage[(next - count + index + Self.capacity) % Self.capacity]
    }

    var mean: Double? {
        var total = 0.0
        var readings = 0
        for index in 0..<count {
            if let value = self[index].value {
                total += value
                readings += 1
            }
        }
        return readings > 0 ? total / Double(readings) : nil
    }

    mutating func append(value: Double?, hiccup: Bool, time: Double) {
        if !isEmpty, time - self[count - 1].time > 1 || time < self[count - 1].time { reset() }
        let valid = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        storage[next] = Sample(value: valid, hiccup: valid != nil && hiccup, time: time)
        next = (next + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    mutating func reset() {
        next = 0
        count = 0
    }

    static func isHiccupSegment(from: Sample, to: Sample) -> Bool {
        from.value != nil && to.value != nil && (from.hiccup || to.hiccup)
    }
}

@MainActor
final class StatsTrace {
    enum Metric {
        case render, latency, bitrate

        init?(kind: StatsRow.Kind) {
            switch kind {
            case .renderFps: self = .render
            case .latency: self = .latency
            case .bitrate: self = .bitrate
            default: return nil
            }
        }

        func isHiccup(value: Double?, reference: Double?, targetFps: Double, latencyWarning: Double) -> Bool {
            guard let value, value.isFinite, value >= 0 else { return false }
            switch self {
            case .render: return targetFps > 0 && value < targetFps * 0.9
            case .latency:
                if value > latencyWarning { return true }
                guard let reference else { return false }
                return value > max(reference + 3, reference * 1.8)
            case .bitrate:
                guard let reference, reference > 0 else { return false }
                return value < reference * 0.75
            }
        }
    }

    let layer = CALayer()
    let metric: Metric
    private var history = StatsTraceHistory()
    private let baseline = CAShapeLayer()
    private let line = CAShapeLayer()
    private let hiccups = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var target = 60.0

    init(metric: Metric) {
        self.metric = metric
        layer.actions = StatsOverlayLayer.disabledActions
        for shape in [baseline, line, hiccups, dot] {
            shape.actions = StatsOverlayLayer.disabledActions
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
        }
        baseline.lineWidth = 0.5
        line.lineWidth = 1.1
        hiccups.lineWidth = 1.4
    }

    func applyInk(primary: NSColor, caution: NSColor, opaque: Bool) {
        baseline.strokeColor = primary.withAlphaComponent(opaque ? 0.4 : 0.18).cgColor
        line.strokeColor = primary.cgColor
        hiccups.strokeColor = caution.cgColor
        dot.fillColor = primary.cgColor
    }

    func append(snapshot: StreamStatsSnapshot, targetFps: Double, thresholds: StatsThresholds) {
        let now = CACurrentMediaTime()
        if !history.isEmpty, now - history[history.count - 1].time > 1 { history.reset() }
        let value: Double?
        switch metric {
        case .render: value = snapshot.hostFps ?? snapshot.renderedFps
        case .latency: value = snapshot.rttMs
        case .bitrate: value = snapshot.measuredBitrateMbps
        }
        target = targetFps.isFinite && targetFps > 0 ? targetFps : 60
        let hiccup = metric.isHiccup(value: value, reference: history.mean, targetFps: targetFps,
                                     latencyWarning: Double(thresholds.latencyWarningAbove))
        history.append(value: value, hiccup: hiccup, time: now)
    }

    private var scale: (lower: Double, upper: Double, reference: Double) {
        let reference = history.mean ?? 0
        switch metric {
        case .render: return (target * 0.7, target * 1.05, target)
        case .latency: return (0, max(12, reference * 3), reference)
        case .bitrate: return (max(0, reference * 0.4), max(1, reference * 1.4), reference)
        }
    }

    func draw() {
        let normalPath = CGMutablePath()
        let hiccupPath = CGMutablePath()
        let referencePath = CGMutablePath()
        let bounds = layer.bounds.insetBy(dx: 2, dy: 2)
        let scale = scale
        func y(_ value: Double) -> CGFloat {
            bounds.minY + CGFloat(min(1, max(0, (value - scale.lower) / (scale.upper - scale.lower)))) * bounds.height
        }
        referencePath.move(to: CGPoint(x: bounds.minX, y: y(scale.reference)))
        referencePath.addLine(to: CGPoint(x: bounds.maxX, y: y(scale.reference)))
        var previous: CGPoint?
        var latest: CGPoint?
        let endTime = !history.isEmpty ? history[history.count - 1].time : 0
        for index in 0..<history.count {
            let sample = history[index]
            guard let value = sample.value, endTime - sample.time <= 10 else {
                previous = nil
                latest = nil
                continue
            }
            let point = CGPoint(x: bounds.maxX - CGFloat((endTime - sample.time) / 10) * bounds.width, y: y(value))
            if let previous {
                let path = StatsTraceHistory.isHiccupSegment(from: history[index - 1], to: sample)
                    ? hiccupPath : normalPath
                path.move(to: previous)
                path.addLine(to: point)
            }
            previous = point
            latest = point
        }
        baseline.path = referencePath
        line.path = normalPath
        hiccups.path = hiccupPath
        dot.path = latest.map { CGPath(ellipseIn: CGRect(x: $0.x - 1.5, y: $0.y - 1.5, width: 3, height: 3), transform: nil) }
    }
}
