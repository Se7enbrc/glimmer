// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

struct ControllerDiagramTests {
    @Test func familySelectionDoesNotConfuseBackbonePlayStationEditionWithDualSense() {
        #expect(ControllerDiagramFamily.identify(category: "MFi",
            name: "Backbone One PlayStation Edition", controls: []).rawValue == "backbonePlayStation")
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

    @Test func premiumModelsKeepTheirOwnArtworkWhenTheCategoryIsGeneric() {
        #expect(ControllerDiagramFamily.identify(category: "PS5 Controller", name: "DualSense Edge", controls: []) == .dualSenseEdge)
        #expect(ControllerDiagramFamily.identify(category: "Xbox One", name: "Xbox Elite Wireless Controller", controls: []) == .xboxElite)
        #expect(ControllerDiagramFamily.identify(category: "DualSense", name: "Wireless Controller", controls: []) == .dualSense)
    }

    @Test func frontControlsFitInsideTheirShellAndDoNotOverlap() throws {
        let sources: [ControllerLayoutSource] = [.button(.a), .button(.b), .button(.x), .button(.y),
            .button(.menu), .button(.options), .button(.home), .button(.share)]
        for family in ControllerDiagramFamily.allCases {
            let shell = ControllerBodyShape(family: family).path(in: CGRect(x: 0, y: 0, width: 480, height: 330))
            let visibleSources = sources.filter { $0 != .button(.share) || (family != .dualShock && family != .xboxElite) }
            let placements = try visibleSources.map { source in
                try #require(ControllerDiagramGeometry.placement(.init(id: source, name: "", symbol: ""), family: family))
            }
            for (index, placement) in placements.enumerated() {
                #expect(shell.contains(placement.point), "\(family) \(visibleSources[index]) is outside its shell")
                for other in placements.dropFirst(index + 1) { #expect(placement.bounds.intersects(other.bounds) == false) }
            }
            for center in [family.leftStick, family.rightStick, family.dpad] { #expect(shell.contains(center)) }
        }
    }

    @Test func touchpadUsesItsPhysicalSurfaceForTheHitRegion() throws {
        for family in [ControllerDiagramFamily.dualSense, .dualSenseEdge, .dualShock] {
            let control = ControllerLayoutControl(id: .button(.touchpad), name: "Touchpad", symbol: "")
            let placement = try #require(ControllerDiagramGeometry.placement(control, family: family))
            #expect(placement.bounds == family.touchpad)
            #expect(placement.bounds.maxY < family.leftStick.y - family.stickDiameter / 2)
        }
    }

    @Test func rearTriggerHitRegionsMirrorThePhysicalSides() throws {
        let control = ControllerLayoutControl(id: .trigger(.left), name: "Left trigger", symbol: "")
        let front = try #require(ControllerDiagramGeometry.visiblePlacement(control, family: .dualSenseEdge, rear: false))
        let rear = try #require(ControllerDiagramGeometry.visiblePlacement(control, family: .dualSenseEdge, rear: true))
        #expect(front.point.x + rear.point.x == 480)
        #expect(rear.bounds.maxY > front.bounds.maxY)
        let face = ControllerLayoutControl(id: .button(.a), name: "Cross", symbol: "")
        #expect(ControllerDiagramGeometry.visiblePlacement(face, family: .dualSenseEdge, rear: true) == nil)
    }

    @Test func rawHIDUsesFamilySymbolsAndKeepsReportedGlyphs() {
        let source = ControllerLayoutSource.button(.a)
        let fallback = ControllerLayoutControl(id: source, name: "A", symbol: source.layoutSymbol)
        #expect(ControllerDiagramFamily.dualSense.symbol(for: fallback) == "xmark")
        #expect(ControllerDiagramFamily.xbox.symbol(for: fallback) == source.layoutSymbol)
        let reported = ControllerLayoutControl(id: source, name: "Cross", symbol: "xmark.circle")
        #expect(ControllerDiagramFamily.dualSense.symbol(for: reported) == "xmark.circle")
    }

    @Test func backboneEditionUsesObservedShellAndFaceLegend() {
        let family = ControllerDiagramFamily.identify(category: "MFi", name: "Backbone One PlayStation Edition", controls: [])
        let cross = ControllerLayoutControl(id: .button(.a), name: "Cross", symbol: ControllerMappedButton.a.layoutSymbol)
        #expect(family.darkShell == false)
        #expect(family.symbol(for: cross) == "xmark")
        for edition in [family, .backbone] {
            let capture = ControllerLayoutControl(id: .button(.share), name: "Capture", symbol: "square.and.arrow.up")
            let options = ControllerLayoutControl(id: .button(.options), name: "Options", symbol: "rectangle.on.rectangle.circle")
            #expect(edition.symbol(for: capture) == "viewfinder")
            #expect(edition.symbol(for: options) == "ellipsis")
        }
        #expect(family.leftStick == ControllerDiagramFamily.backbone.leftStick)
        #expect(family.rightStick == ControllerDiagramFamily.backbone.rightStick)
        #expect(ControllerDiagramFamily.identify(category: "MFi", name: "Backbone One", controls: []) == .backbone)
    }

    @Test func shouldersMeetTheBodyInsteadOfFloatingAboveIt() throws {
        for family in ControllerDiagramFamily.allCases {
            let shell = ControllerBodyShape(family: family).path(in: CGRect(x: 0, y: 0, width: 480, height: 330))
            let source = ControllerLayoutControl(id: .button(.leftShoulder), name: "Left shoulder", symbol: "")
            let shoulder = try #require(ControllerDiagramGeometry.placement(source, family: family))
            #expect(shell.contains(CGPoint(x: shoulder.point.x, y: shoulder.bounds.maxY - 1)))
        }
    }

    @Test func controlPathsAndHitRegionsStayAlignedAtEveryDisplayScale() throws {
        let sources: [ControllerLayoutSource] = [.button(.a), .button(.b), .button(.x), .button(.y),
            .button(.menu), .button(.options), .button(.home), .button(.share), .button(.touchpad),
            .button(.leftShoulder), .button(.rightShoulder), .trigger(.left), .trigger(.right),
            .button(.paddle1), .button(.paddle2), .button(.paddle3), .button(.paddle4)]
        for family in ControllerDiagramFamily.allCases {
            for source in sources {
                let control = ControllerLayoutControl(id: source, name: source.layoutName, symbol: source.layoutSymbol)
                let unsupported = (source == .button(.touchpad) && !family.isPlayStation)
                    || (source == .button(.share) && (family == .dualShock || family == .xboxElite))
                if unsupported {
                    #expect(ControllerDiagramGeometry.placement(control, family: family) == nil)
                    continue
                }
                let placement = try #require(ControllerDiagramGeometry.placement(control, family: family))
                let shape = ControllerButtonShape(family: family, placement: placement, source: source)
                for scale: CGFloat in [0.6, 1, 1.16, 2] {
                    let bounds = placement.bounds.applying(.init(scaleX: scale, y: scale))
                    let path = shape.path(in: bounds)
                    let center = CGPoint(x: placement.point.x * scale, y: placement.point.y * scale)
                    #expect(path.contains(center), "\(family) \(source) center is not clickable")
                    #expect(bounds.insetBy(dx: -scale, dy: -scale).contains(path.boundingRect))
                    let originPath = shape.path(in: CGRect(origin: .zero, size: bounds.size))
                        .applying(.init(translationX: bounds.minX, y: bounds.minY))
                    #expect(originPath.boundingRect == path.boundingRect)
                }
            }
        }
    }
}
