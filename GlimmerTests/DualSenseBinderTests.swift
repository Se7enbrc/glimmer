import Foundation
import Testing
@testable import Glimmer

struct DualSenseBinderTests {
    private final class Controller {}
    private let first = Controller()
    private let second = Controller()
    private let third = Controller()
    private var firstID: ObjectIdentifier { ObjectIdentifier(first) }
    private var secondID: ObjectIdentifier { ObjectIdentifier(second) }
    private var thirdID: ObjectIdentifier { ObjectIdentifier(third) }

    private func twoPads() -> DualSenseBinder {
        var binder = DualSenseBinder()
        binder.connectDevices([1, 2])
        binder.connectControllers([firstID, secondID])
        return binder
    }

    @Test func singlePairBindsInEitherConnectOrder() {
        for hidFirst in [true, false] {
            var binder = DualSenseBinder()
            if hidFirst { binder.connectDevices([1]) }
            binder.connectControllers([firstID])
            if !hidFirst { binder.connectDevices([1]) }
            #expect(binder.hidDevice(for: firstID) == 1)
            #expect(binder.controller(for: 1) == firstID)
        }
    }

    @Test func multiplePadsStartUnbound() {
        let binder = twoPads()
        #expect(binder.hidDevice(for: firstID) == nil)
        #expect(binder.controller(for: 1) == nil)
    }

    @Test(arguments: DualSenseFaceButton.allCases)
    func learnsEveryFaceButton(button: DualSenseFaceButton) {
        var binder = twoPads()
        binder.hid(deviceID: 2, button: button, at: 1)
        binder.gc(controllerID: firstID, button: button, at: 1.025)
        binder.advance(to: 1.050)
        #expect(binder.hidDevice(for: firstID) == nil)
        binder.advance(to: 1.081)
        #expect(binder.hidDevice(for: firstID) == 2)
        #expect(binder.controller(for: 2) == firstID)
        #expect(binder.hidDevice(for: secondID) == 1)
    }

    @Test func acceptsGCBeforeHID() {
        var binder = twoPads()
        binder.gc(controllerID: secondID, button: .square, at: 0)
        binder.hid(deviceID: 1, button: .square, at: 0.030)
        binder.advance(to: 0.111)
        #expect(binder.hidDevice(for: secondID) == 1)
    }

    @Test(arguments: [0.040, 0.040001])
    func windowBoundary(delay: Double) {
        var binder = twoPads()
        binder.hid(deviceID: 1, button: .cross, at: 0)
        binder.gc(controllerID: firstID, button: .cross, at: delay)
        binder.advance(to: 0.100)
        #expect((binder.hidDevice(for: firstID) == 1) == (delay <= 0.040))
    }

    @Test func differentButtonsDoNotMatch() {
        var binder = twoPads()
        binder.hid(deviceID: 1, button: .cross, at: 1)
        binder.gc(controllerID: firstID, button: .circle, at: 1)
        binder.advance(to: 2)
        #expect(binder.controller(for: 1) == nil)
    }

    @Test func competingControllersStayUnboundAfterEvidenceExpires() {
        var binder = twoPads()
        binder.gc(controllerID: secondID, button: .cross, at: 0)
        binder.hid(deviceID: 1, button: .cross, at: 0.030)
        binder.gc(controllerID: firstID, button: .cross, at: 0.060)
        for time in [0.111, 0.161, 0.180, 1] { binder.advance(to: time) }
        #expect(binder.controller(for: 1) == nil)
        #expect(binder.controller(for: 2) == nil)
    }

    @Test func lateHIDCompetitorPreventsMatch() {
        var binder = twoPads()
        binder.hid(deviceID: 1, button: .triangle, at: 0)
        binder.gc(controllerID: firstID, button: .triangle, at: 0.039)
        binder.advance(to: 0.050)
        binder.hid(deviceID: 2, button: .triangle, at: 0.078)
        binder.advance(to: 0.159)
        #expect(binder.hidDevice(for: firstID) == nil)
    }

    @Test func simultaneousPadsAreAmbiguous() {
        var binder = twoPads()
        for device: UInt in [1, 2] { binder.hid(deviceID: device, button: .cross, at: 0) }
        for id in [firstID, secondID] { binder.gc(controllerID: id, button: .cross, at: 0) }
        binder.advance(to: 0.081)
        #expect(binder.controller(for: 1) == nil)
        #expect(binder.controller(for: 2) == nil)
    }

    @Test func freshPressCanResolveEarlierAmbiguity() {
        var binder = twoPads()
        binder.hid(deviceID: 1, button: .cross, at: 0)
        binder.gc(controllerID: firstID, button: .cross, at: 0)
        binder.gc(controllerID: secondID, button: .cross, at: 0)
        binder.advance(to: 0.200)
        binder.hid(deviceID: 1, button: .circle, at: 1)
        binder.gc(controllerID: firstID, button: .circle, at: 1)
        binder.advance(to: 1.081)
        #expect(binder.controller(for: 1) == firstID)
    }

    @Test func bindingSurvivesUnrelatedConnectionsAndPresses() {
        var binder = DualSenseBinder()
        binder.connectDevices([1])
        binder.connectControllers([firstID])
        binder.connectDevices([2, 3])
        binder.connectControllers([secondID, thirdID])
        binder.hid(deviceID: 1, button: .cross, at: 0)
        binder.gc(controllerID: secondID, button: .cross, at: 0)
        binder.advance(to: 1)
        #expect(binder.controller(for: 1) == firstID)
        #expect(binder.hidDevice(for: secondID) == nil)
    }

    @Test func eitherDisconnectRemovesBothDirections() {
        for removeHID in [true, false] {
            var binder = twoPads()
            binder.hid(deviceID: 1, button: .cross, at: 0)
            binder.gc(controllerID: firstID, button: .cross, at: 0)
            binder.advance(to: 0.081)
            if removeHID { binder.disconnectDevice(1) } else { binder.disconnectController(firstID) }
            #expect(binder.controller(for: 1) == nil)
            #expect(binder.hidDevice(for: firstID) == nil)
            #expect(binder.controller(for: 2) == secondID)
        }
    }

    @Test func disconnectLeavesSinglePairAndReconnectStartsFresh() {
        var binder = twoPads()
        binder.disconnectDevice(2)
        binder.disconnectController(secondID)
        #expect(binder.controller(for: 1) == firstID)
        binder.connectDevices([2])
        binder.connectControllers([secondID])
        #expect(binder.controller(for: 2) == secondID)
    }

    @Test func unknownAndDisconnectedSourcesCannotSupplyEvidence() {
        var binder = twoPads()
        binder.hid(deviceID: 3, button: .cross, at: 0)
        binder.gc(controllerID: thirdID, button: .cross, at: 0)
        binder.advance(to: 0.081)
        binder.connectDevices([3])
        binder.connectControllers([thirdID])
        binder.advance(to: 0.090)
        #expect(binder.controller(for: 3) == nil)
        binder.hid(deviceID: 3, button: .circle, at: 1)
        binder.disconnectDevice(3)
        binder.connectDevices([3])
        binder.gc(controllerID: thirdID, button: .circle, at: 1.010)
        binder.advance(to: 1.100)
        #expect(binder.controller(for: 3) == nil)
    }
}
