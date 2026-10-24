// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreTelephony
import Foundation
import GlimmerEngine
import Network

/// Session-scoped hints never identify a carrier, network name or subscriber in shared diagnostics.
@MainActor final class IOSBandwidthSignals: NSObject, CTTelephonyNetworkInfoDelegate {
    let inputs: BandwidthInputs
    private let radio = CTTelephonyNetworkInfo()
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    private var host: String?
    private var lastPath: NWPath?
    private var foreground = true

    override init() {
        inputs = BandwidthInputs(.init(path: BandwidthPath(observedAt: ProcessInfo.processInfo.systemUptime),
                                      environment: Self.environment(foreground: true)))
        super.init()
    }

    func start(host: String) {
        guard monitor == nil else { return }
        self.host = host
        radio.delegate = self
        observe(ProcessInfo.thermalStateDidChangeNotification)
        observe(.NSProcessInfoPowerStateDidChange)
        observe(.CTServiceRadioAccessTechnologyDidChange)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.receive(path, from: monitor) }
        }
        monitor.start(queue: DispatchQueue(label: "io.ugfugl.Glimmer.bandwidthPath", qos: .utility))
        publish()
    }

    func stop() {
        monitor?.cancel()
        monitor?.pathUpdateHandler = nil
        monitor = nil
        lastPath = nil
        host = nil
        radio.delegate = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            let retainedHost = host
            stop()
            host = retainedHost
            publish()
        } else if let host { start(host: host) }
    }

    nonisolated func dataServiceIdentifierDidChange(_ identifier: String) {
        Task { @MainActor [weak self] in self?.publish() }
    }

    private func observe(_ name: Notification.Name) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
        observers.append(observer)
    }

    private func receive(_ path: NWPath, from monitor: NWPathMonitor) {
        guard self.monitor === monitor, foreground else { return }
        // An event may replace the route while keeping its interface type unchanged.
        generation &+= 1
        lastPath = path
        publish()
    }

    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime
        var facts = BandwidthPath(generation: generation, observedAt: now)
        if let path = lastPath, foreground {
            facts = Self.facts(path, generation: generation, now: now)
            if let host {
                let route = StreamDestinationProbe.destination(host: host)
                facts.mtu = route.mtu
                facts.tunnel = route.interfaceName == nil ? nil : route.tunnel
                // Default-path flags stay hints even when a fresh destination route agrees.
                if let name = route.interfaceName,
                   let interface = path.availableInterfaces.first(where: { $0.name == name }) {
                    facts.interface = Self.interface(interface.type)
                }
            }
            if facts.interface == .cellular, let service = radio.dataServiceIdentifier,
               let technology = radio.serviceCurrentRadioAccessTechnology?[service] {
                facts.radio = Self.radioHint(technology)
            }
        }
        inputs.update(.init(path: facts, environment: Self.environment(foreground: foreground)))
    }

    static func facts(_ path: NWPath, generation: UInt64, now: Double) -> BandwidthPath {
        let types: [NWInterface.InterfaceType] = [.other, .wiredEthernet, .wifi, .cellular]
        let type = types.first { path.usesInterfaceType($0) }
        var facts = BandwidthPath(generation: generation, observedAt: now,
            interface: type.map(interface) ?? .unknown, source: .defaultPath,
            satisfied: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained)
        facts.interfaces = types.filter { path.usesInterfaceType($0) }.map(interface)
        facts.ultraConstrained = path.isUltraConstrained
        switch path.linkQuality {
        case .unknown: facts.linkQuality = .unknown
        case .minimal: facts.linkQuality = .minimal
        case .moderate: facts.linkQuality = .moderate
        case .good: facts.linkQuality = .good
        @unknown default: facts.linkQuality = .unknown
        }
        return facts
    }

    private static func interface(_ type: NWInterface.InterfaceType) -> BandwidthPath.Interface {
        switch type {
        case .wiredEthernet: .wired
        case .wifi: .wifi
        case .cellular: .cellular
        case .other, .loopback: .other
        @unknown default: .unknown
        }
    }

    static func radioHint(_ value: String) -> BandwidthPath.Radio {
        switch value {
        case CTRadioAccessTechnologyLTE: .lte
        case CTRadioAccessTechnologyNR: .nr
        case CTRadioAccessTechnologyNRNSA: .nrNSA
        default: .other
        }
    }

    private static func environment(foreground: Bool) -> BandwidthEnvironment {
        var result = BandwidthEnvironment()
        result.foreground = foreground
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermal = .nominal
        case .fair: result.thermal = .fair
        case .serious: result.thermal = .serious
        case .critical: result.thermal = .critical
        @unknown default: result.thermal = .unknown
        }
        return result
    }
}
