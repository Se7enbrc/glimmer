import Foundation

typealias DualSenseDeviceKey = UInt

enum DualSenseFaceButton: UInt8, CaseIterable, Sendable {
    case square = 0x10
    case cross = 0x20
    case circle = 0x40
    case triangle = 0x80
}

/// Learns associations from press edges, retaining ambiguous evidence until its window closes.
struct DualSenseBinder: Sendable {
    private struct Edge<ID: Hashable & Sendable>: Sendable {
        let id: ID
        let button: DualSenseFaceButton
        let time: TimeInterval
        var examined = false
    }

    static let window: TimeInterval = 0.040
    private var devices: Set<DualSenseDeviceKey> = []
    private var controllers: Set<ObjectIdentifier> = []
    private var bindings: [ObjectIdentifier: DualSenseDeviceKey] = [:]
    private var hidEdges: [Edge<DualSenseDeviceKey>] = []
    private var gcEdges: [Edge<ObjectIdentifier>] = []

    func hidDevice(for controllerID: ObjectIdentifier) -> DualSenseDeviceKey? { bindings[controllerID] }

    func controller(for deviceID: DualSenseDeviceKey) -> ObjectIdentifier? {
        bindings.first { $0.value == deviceID }?.key
    }

    mutating func connectDevices(_ ids: Set<DualSenseDeviceKey>) {
        devices.formUnion(ids)
        bindSinglePair()
    }

    mutating func connectControllers(_ ids: Set<ObjectIdentifier>) {
        controllers.formUnion(ids)
        bindSinglePair()
    }

    mutating func disconnectDevice(_ id: DualSenseDeviceKey) {
        devices.remove(id)
        if let controller = controller(for: id) { bindings[controller] = nil }
        hidEdges.removeAll { $0.id == id }
        gcEdges.removeAll()
        bindSinglePair()
    }

    mutating func disconnectController(_ id: ObjectIdentifier) {
        controllers.remove(id)
        bindings[id] = nil
        gcEdges.removeAll { $0.id == id }
        hidEdges.removeAll()
        bindSinglePair()
    }

    mutating func hid(deviceID: DualSenseDeviceKey, button: DualSenseFaceButton, at time: TimeInterval) {
        guard devices.contains(deviceID), controller(for: deviceID) == nil else { return }
        hidEdges.append(Edge(id: deviceID, button: button, time: time))
    }

    mutating func gc(controllerID: ObjectIdentifier, button: DualSenseFaceButton, at time: TimeInterval) {
        guard controllers.contains(controllerID), hidDevice(for: controllerID) == nil else { return }
        gcEdges.append(Edge(id: controllerID, button: button, time: time))
    }

    /// A second window allows all competitors of the matching GC edge to arrive.
    /// Call with a monotonic clock after delivering all edges up to that time.
    mutating func advance(to time: TimeInterval) {
        for index in hidEdges.indices {
            let edge = hidEdges[index]
            guard !edge.examined, edge.time + 2 * Self.window < time else { continue }
            hidEdges[index].examined = true
            guard controller(for: edge.id) == nil else { continue }
            let candidates = gcEdges.filter {
                $0.button == edge.button && abs($0.time - edge.time) <= Self.window
            }
            let controllerIDs = Set(candidates.map(\.id))
            guard controllerIDs.count == 1, let controllerID = controllerIDs.first,
                  hidDevice(for: controllerID) == nil else { continue }
            let competitors = hidEdges.filter { other in
                candidates.contains {
                    other.button == $0.button && abs(other.time - $0.time) <= Self.window
                }
            }
            guard Set(competitors.map(\.id)) == [edge.id] else { continue }
            bindings[controllerID] = edge.id
        }
        // Keep earlier evidence until every edge that could overlap it has matured.
        hidEdges.removeAll { $0.time + 4 * Self.window < time }
        gcEdges.removeAll { $0.time + 4 * Self.window < time }
        bindSinglePair()
    }

    private mutating func bindSinglePair() {
        let freeDevices = devices.subtracting(bindings.values)
        let freeControllers = controllers.subtracting(bindings.keys)
        guard freeDevices.count == 1, freeControllers.count == 1,
              let device = freeDevices.first, let controller = freeControllers.first else { return }
        bindings[controller] = device
    }
}
