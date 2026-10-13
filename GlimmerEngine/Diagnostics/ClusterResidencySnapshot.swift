// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@usableFromInline package struct ClusterResidencySnapshot: Sendable {

    @usableFromInline package init(
        eClusterActive: Double? = nil,
        pClusterActive: Double? = nil,
        eClusterCount: Int = 0,
        pClusterCount: Int = 0,
        packagePowerW: Double? = nil,
        gpuResidencyPercent: Double? = nil,
        gpuPowerW: Double? = nil
    ) {
        self.eClusterActive = eClusterActive
        self.pClusterActive = pClusterActive
        self.eClusterCount = eClusterCount
        self.pClusterCount = pClusterCount
        self.packagePowerW = packagePowerW
        self.gpuResidencyPercent = gpuResidencyPercent
        self.gpuPowerW = gpuPowerW
    }

    /// E-cluster (efficiency cores) active residency this window, 0...1. The cluster
    /// the LOW-QoS / background work should land on; high here while the stream is
    /// quiet is fine, high here while P is idle during active play is a hint our
    /// hot work got demoted.
    @usableFromInline package var eClusterActive: Double?
    /// P-cluster (performance cores) active residency this window, 0...1. The cluster
    /// our `.userInteractive` decode/pacer/receive threads SHOULD drive; this is the
    /// SoC-side confirmation the hot path is actually on the fast cores.
    @usableFromInline package var pClusterActive: Double?
    /// Number of distinct E-cluster channels folded into `eClusterActive` (so a
    /// reader knows the average spans e.g. ECPU+ECPM). 0 = none seen.
    @usableFromInline package var eClusterCount: Int = 0
    /// Number of distinct P-cluster channels folded into `pClusterActive`.
    @usableFromInline package var pClusterCount: Int = 0
    /// CPU + GPU + ANE compute watts, matching powermetrics' Combined Power, without DRAM/display rails.
    /// This tracks thermal cost before thermal_state changes; nil until a clean Energy Model delta.
    @usableFromInline package var packagePowerW: Double?
    /// GPU time awake at any clock, 0...100; this does not measure capacity or power cost.
    @usableFromInline package var gpuResidencyPercent: Double?
    /// The GPU Energy rail alone, in watts. nil means unavailable; zero is a measured idle GPU.
    @usableFromInline package var gpuPowerW: Double?
}
