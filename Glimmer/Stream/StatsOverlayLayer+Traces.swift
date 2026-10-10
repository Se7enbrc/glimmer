import AppKit
import QuartzCore

/// Forty intervals at the overlay's 4 Hz cadence, with missing readings left as gaps.
struct StatsTraceHistory {
    /// Caution is orange, critical (the metric tanking) is red.
    enum Severity: Int, Comparable {
        case none, caution, critical
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Sample {
        var value: Double?
        var severity = Severity.none
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

    mutating func append(value: Double?, severity: Severity, time: Double) {
        if !isEmpty, time - self[count - 1].time > 1 || time < self[count - 1].time { reset() }
        let valid = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        storage[next] = Sample(value: valid, severity: valid != nil ? severity : .none, time: time)
        next = (next + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    mutating func reset() {
        next = 0
        count = 0
    }

    static func segmentSeverity(from: Sample, to: Sample) -> Severity {
        guard from.value != nil, to.value != nil else { return .none }
        return max(from.severity, to.severity)
    }
}

/// Thirty seconds of unflagged readings at 4 Hz. The median ignores a single bad
/// second, and leaving flagged readings out keeps a sustained dip from becoming normal.
struct StatsBaseline {
    static let capacity = 121
    static let minimumReadings = 8
    private var storage = Array(repeating: 0.0, count: capacity)
    private var scratch = Array(repeating: 0.0, count: capacity)
    private var next = 0
    private(set) var count = 0

    mutating func add(_ value: Double) {
        storage[next] = value
        next = (next + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    /// Nil until enough readings exist to call anything a dip.
    mutating func median() -> Double? {
        guard count >= Self.minimumReadings else { return nil }
        for index in 0..<count { scratch[index] = storage[index] }
        scratch[0..<count].sort()
        let middle = count / 2
        return count.isMultiple(of: 2) ? (scratch[middle - 1] + scratch[middle]) / 2 : scratch[middle]
    }

    mutating func reset() {
        next = 0
        count = 0
    }
}

@MainActor
final class StatsTrace {
    enum Metric {
        case render, host, network, latency, bitrate, jitter, drops

        init?(kind: StatsRow.Kind) {
            switch kind {
            case .renderFps: self = .render
            case .hostFps: self = .host
            case .networkFps: self = .network
            case .latency: self = .latency
            case .bitrate: self = .bitrate
            case .jitter: self = .jitter
            case .networkDrops: self = .drops
            default: return nil
            }
        }

        /// Rates that only matter when they fall are judged against their own median.
        var judgesDrops: Bool { [.render, .host, .network, .bitrate].contains(self) }

        func value(in snapshot: StreamStatsSnapshot) -> Double? {
            switch self {
            case .render: snapshot.renderedFps ?? snapshot.hostFps
            case .host: snapshot.hostFps
            case .network: snapshot.receivedFps
            case .latency: snapshot.rttMs
            case .bitrate: snapshot.measuredBitrateMbps
            case .jitter: snapshot.jitterMs
            case .drops: snapshot.networkDroppedPercent
            }
        }

        /// Drops compare with the running median, not the stream's target, so a steady
        /// 190 FPS on a 240 Hz stream stays calm. The rest reuse the text thresholds.
        func severity(value: Double?, reference: Double?, thresholds: StatsThresholds) -> StatsTraceHistory.Severity {
            guard let value, value.isFinite, value >= 0 else { return .none }
            func above(_ caution: Double, _ critical: Double) -> StatsTraceHistory.Severity {
                value > critical ? .critical : value > caution ? .caution : .none
            }
            switch self {
            case .render, .host, .network, .bitrate:
                guard let reference, reference > 0 else { return .none }
                if value < reference * 0.3 { return .critical }
                return value < reference * 0.5 ? .caution : .none
            case .latency:
                let level = above(Double(thresholds.latencyWarningAbove), Double(thresholds.latencyCriticalAbove))
                guard level == .none, let reference else { return level }
                return value > max(reference + 3, reference * 1.8) ? .caution : .none
            case .jitter: return above(Double(thresholds.jitterWarningAbove), Double(thresholds.jitterCriticalAbove))
            case .drops: return above(thresholds.dropsWarningAbove, thresholds.dropsCriticalAbove)
            }
        }
    }

    let layer = CALayer()
    let metric: Metric
    private var history = StatsTraceHistory()
    private var dipBaseline = StatsBaseline()
    private var reference: Double?
    private let baseline = CAShapeLayer()
    private let line = CAShapeLayer()
    private let cautions = CAShapeLayer()
    private let criticals = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var target = 60.0

    init(metric: Metric) {
        self.metric = metric
        layer.actions = StatsOverlayLayer.disabledActions
        for shape in [baseline, line, cautions, criticals, dot] {
            shape.actions = StatsOverlayLayer.disabledActions
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
        }
        baseline.lineWidth = 0.5
        line.lineWidth = 1.1
        cautions.lineWidth = 1.4
        criticals.lineWidth = 1.6
    }

    func applyInk(primary: NSColor, caution: NSColor, critical: NSColor, opaque: Bool) {
        baseline.strokeColor = primary.withAlphaComponent(opaque ? 0.4 : 0.18).cgColor
        line.strokeColor = primary.cgColor
        cautions.strokeColor = caution.cgColor
        criticals.strokeColor = critical.cgColor
        dot.fillColor = primary.cgColor
    }

    func append(snapshot: StreamStatsSnapshot, targetFps: Double, thresholds: StatsThresholds) {
        let now = CACurrentMediaTime()
        if !history.isEmpty, now - history[history.count - 1].time > 1 {
            history.reset()
            dipBaseline.reset()
        }
        let value = metric.value(in: snapshot)
        target = targetFps.isFinite && targetFps > 0 ? targetFps : 60
        reference = metric.judgesDrops ? dipBaseline.median() : history.mean
        let severity = metric.severity(value: value, reference: reference, thresholds: thresholds)
        history.append(value: value, severity: severity, time: now)
        if let value, value.isFinite, value >= 0, severity == .none { dipBaseline.add(value) }
    }

    private var scale: (lower: Double, upper: Double, reference: Double) {
        let reference = self.reference ?? history.mean ?? 0
        switch metric {
        case .render, .host, .network:
            let level = reference > 0 ? reference : target
            return (max(0, level * 0.2), max(level, target) * 1.08, level)
        case .latency: return (0, max(12, reference * 3), reference)
        case .bitrate: return (max(0, reference * 0.2), max(1, reference * 1.4), reference)
        case .jitter: return (0, max(12, reference * 3), reference)
        case .drops: return (0, max(2.5, reference * 3), reference)
        }
    }

    func draw() {
        let normalPath = CGMutablePath()
        let cautionPath = CGMutablePath()
        let criticalPath = CGMutablePath()
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
                let path = switch StatsTraceHistory.segmentSeverity(from: history[index - 1], to: sample) {
                case .none: normalPath
                case .caution: cautionPath
                case .critical: criticalPath
                }
                path.move(to: previous)
                path.addLine(to: point)
            }
            previous = point
            latest = point
        }
        baseline.path = referencePath
        line.path = normalPath
        cautions.path = cautionPath
        criticals.path = criticalPath
        dot.path = latest.map { CGPath(ellipseIn: CGRect(x: $0.x - 1.5, y: $0.y - 1.5, width: 3, height: 3), transform: nil) }
    }
}
