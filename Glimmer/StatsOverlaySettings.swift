//
//  StatsOverlaySettings.swift
//
//  Settings-pane views for the in-stream stats overlay: the StatsThresholds
//  editor (warn / critical color thresholds for each metric). Lifted out of
//  SettingsView.swift to keep that file under the swiftlint file_length
//  ceiling - adding new overlay-config surfaces (additional metrics, new
//  health rules) lives here, not in the main Settings monolith.
//

import SwiftUI

/// One warn-or-critical threshold row: its label, the value binding, and the
/// unit suffix. Grouping the three together keeps the `metric` helpers under
/// the parameter-count ceiling without losing the per-row call-site clarity.
private struct ThresholdRow<Value> {
    let label: String
    let binding: Binding<Value>
    let unit: String
}

struct StatsThresholdsEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            metric(
                title: "Frame rate",
                warn: ThresholdRow(
                    label: "Warn below",
                    binding: Binding(
                        get: { model.statsThresholds.fpsWarningBelow },
                        set: { model.statsThresholds.fpsWarningBelow = $0 }),
                    unit: "FPS"),
                crit: ThresholdRow(
                    label: "Critical below",
                    binding: Binding(
                        get: { model.statsThresholds.fpsCriticalBelow },
                        set: { model.statsThresholds.fpsCriticalBelow = $0 }),
                    unit: "FPS"),
                range: 0...360, step: 1)

            metric(
                title: "Latency",
                warn: ThresholdRow(
                    label: "Warn above",
                    binding: uintBinding(\.latencyWarningAbove),
                    unit: "ms"),
                crit: ThresholdRow(
                    label: "Critical above",
                    binding: uintBinding(\.latencyCriticalAbove),
                    unit: "ms"),
                range: 0...500, step: 5)

            metric(
                title: "Jitter",
                warn: ThresholdRow(
                    label: "Warn above",
                    binding: uintBinding(\.jitterWarningAbove),
                    unit: "ms"),
                crit: ThresholdRow(
                    label: "Critical above",
                    binding: uintBinding(\.jitterCriticalAbove),
                    unit: "ms"),
                range: 0...200, step: 1)

            doubleMetric(
                title: "Drop rate",
                warn: ThresholdRow(
                    label: "Warn above",
                    binding: Binding(
                        get: { model.statsThresholds.dropsWarningAbove },
                        set: { model.statsThresholds.dropsWarningAbove = $0 }),
                    unit: "%"),
                crit: ThresholdRow(
                    label: "Critical above",
                    binding: Binding(
                        get: { model.statsThresholds.dropsCriticalAbove },
                        set: { model.statsThresholds.dropsCriticalAbove = $0 }),
                    unit: "%"),
                range: 0...100, step: 0.5)

            HStack {
                Spacer()
                Button("Restore defaults") {
                    model.statsThresholds = .default
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    /// Bridge a `Binding<UInt32>` keypath into AppModel's
    /// `statsThresholds` (Stepper needs a non-optional value type).
    private func uintBinding(_ keyPath: WritableKeyPath<StatsThresholds, UInt32>) -> Binding<Int> {
        Binding(
            get: { Int(model.statsThresholds[keyPath: keyPath]) },
            set: { model.statsThresholds[keyPath: keyPath] = UInt32(max(0, $0)) }
        )
    }

    @ViewBuilder
    private func metric(
        title: String,
        warn: ThresholdRow<Int>, crit: ThresholdRow<Int>,
        range: ClosedRange<Int>, step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            thresholdStepper(label: warn.label, value: warn.binding, unit: warn.unit, range: range, step: step)
            thresholdStepper(label: crit.label, value: crit.binding, unit: crit.unit, range: range, step: step)
        }
    }

    @ViewBuilder
    private func doubleMetric(
        title: String,
        warn: ThresholdRow<Double>, crit: ThresholdRow<Double>,
        range: ClosedRange<Double>, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            thresholdStepperD(label: warn.label, value: warn.binding, unit: warn.unit, range: range, step: step)
            thresholdStepperD(label: crit.label, value: crit.binding, unit: crit.unit, range: range, step: step)
        }
    }

    @ViewBuilder
    private func thresholdStepper(
        label: String, value: Binding<Int>, unit: String,
        range: ClosedRange<Int>, step: Int
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func thresholdStepperD(
        label: String, value: Binding<Double>, unit: String,
        range: ClosedRange<Double>, step: Double
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
