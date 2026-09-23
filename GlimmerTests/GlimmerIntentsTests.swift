//
//  GlimmerIntentsTests.swift
//
//  Shortcuts and Siri: which app a spoken name picks, and what counts as a
//  change to the PCs Siri knows by name.
//

import Testing
@testable import Glimmer

struct GlimmerIntentsTests {

    private func pc(customName: String? = nil, apps: [String]) -> Glimmer.Host {
        Glimmer.Host(id: "pc-1", name: "DESKTOP-7Q2", customName: customName, localAddress: nil, manualAddress: nil,
                     apps: apps.enumerated().map { LibraryApp(id: $0.offset + 1, name: $0.element, hdr: false, hidden: false) },
                     lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
    }

    @Test func spokenAppNameIgnoresCaseAccentsAndSpaces() {
        let host = pc(apps: ["Desktop", "Steam Big Picture", "Pokémon"])
        #expect(host.app(named: "steam big picture")?.name == "Steam Big Picture")
        #expect(host.app(named: "  Desktop ")?.name == "Desktop")
        #expect(host.app(named: "pokemon")?.name == "Pokémon")
    }

    @Test func exactNameWinsOverACaseOnlyMatch() {
        #expect(pc(apps: ["STEAM", "Steam"]).app(named: "Steam")?.id == 2)
    }

    @Test func unknownAppNameFindsNothing() {
        #expect(pc(apps: ["Desktop"]).app(named: "Steam") == nil)
    }

    @Test func siriKnowsThePCByTheNameShownInGlimmer() {
        #expect(PCEntity(host: pc(customName: "Living Room", apps: ["Desktop"])).name == "Living Room")
        #expect(PCEntity(host: pc(apps: ["Desktop"])).name == "DESKTOP-7Q2")
    }

    @Test func renameChangesWhatSiriKnowsButAReloadDoesNot() {
        let known = Set([PCEntity(host: pc(apps: ["Desktop"]))])
        #expect(Set([PCEntity(host: pc(apps: ["Desktop", "Steam"]))]) == known)
        #expect(Set([PCEntity(host: pc(customName: "Den", apps: ["Desktop"]))]) != known)
    }
}
