// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Testing
@testable import Glimmer

struct ControllerDiagramTests {
    @Test func familySelectionDoesNotConfuseBackbonePlayStationEditionWithDualSense() {
        #expect(ControllerDiagramFamily.identify(category: "MFi", name: "Backbone One PlayStation Edition", controls: []) == .backbone)
        #expect(ControllerDiagramFamily.identify(category: "DualSense", name: "Wireless Controller", controls: []) == .dualSense)
        #expect(ControllerDiagramFamily.identify(category: "Xbox One", name: "Controller", controls: []) == .xbox)
        #expect(ControllerDiagramFamily.identify(category: "MFi", name: "Controller", controls: []) == .generic)
        #expect(ControllerDiagramFamily.identify(category: "PS4 Controller", name: "Wireless Controller", controls: []) == .dualShock)
    }

    @Test func disconnectedControllerKeepsItsSavedFamily() {
        let device = ControllerLayoutDevice(id: "saved", name: "Wireless Controller", identity: nil,
            owner: .type("fixture"), reader: nil, controller: nil, controls: [], nintendoLabels: false,
            savedCategory: "DualShock 4")
        #expect(device.diagramFamily == .dualShock)
    }

    @Test func familyLayoutsKeepPhysicalStickAndDpadPositions() {
        let xbox = ControllerDiagramFamily.xbox
        let playStation = ControllerDiagramFamily.dualSense
        #expect(xbox.leftStick.y < xbox.rightStick.y)
        #expect(xbox.dpad.y == xbox.rightStick.y)
        #expect(playStation.leftStick.y == playStation.rightStick.y)
        #expect(playStation.dpad.y < playStation.leftStick.y)
        #expect(ControllerDiagramFamily.backbone.leftStick.x < 100)
        #expect(ControllerDiagramFamily.backbone.rightStick.x > 380)
    }

    @Test func appleBackButtonAliasesSurviveUnknownAliasesAndRearViewMirrorsSides() throws {
        let aliases: Set<String> = ["unrecognized", GCButtonElementName.backLeftButton(position: 0).rawValue]
        let position = try #require(ControllerLayoutReader.position(aliases: aliases))
        #expect(position == .backLeftPrimary)
        let control = ControllerLayoutControl(id: .extra("back"), name: "Back", symbol: "button.horizontal", position: position)
        let placement = try #require(ControllerDiagramGeometry.placement(control, family: .dualSense))
        #expect(placement.rear)
        #expect(placement.point.x > 240)
        #expect(ControllerLayoutReader.position(aliases: ["button 37"]) == nil)
    }

    @Test func triggerAndFaceControlsHaveDistinctPhysicalPositions() throws {
        for family in ControllerDiagramFamily.allCases {
            let sources: [ControllerLayoutSource] = [.button(.a), .button(.b), .button(.x), .button(.y),
                .button(.menu), .button(.options), .button(.leftShoulder), .button(.rightShoulder),
                .trigger(.left), .trigger(.right)]
            let points = try sources.map { source in
                try #require(ControllerDiagramGeometry.placement(.init(id: source, name: "", symbol: ""), family: family)).point
            }
            #expect(Set(points.map { "\($0.x),\($0.y)" }).count == sources.count)
            #expect(points[8].y < points[6].y)
            #expect(points[9].y < points[7].y)
        }
    }

    @Test func unknownExtraPositionsAreNotInvented() {
        let control = ControllerLayoutControl(id: .extra("hid-button-37"), name: "Extra button", symbol: "button.horizontal")
        #expect(ControllerDiagramGeometry.placement(control, family: .generic) == nil)
    }
}
