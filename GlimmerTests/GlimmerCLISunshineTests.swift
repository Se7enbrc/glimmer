// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  GlimmerCLISunshineTests.swift
//
//  The `glimmer` verbs against a fake Sunshine: what each prints to stdout and stderr, the exit
//  status the README documents, and the requests that reach the PC. Nothing leaves the process.
//

import Foundation
import os
import Testing
@testable import Glimmer

/// Captures what a verb writes, kept apart by stream.
final class CapturedTerminal: Sendable {
    private let text = OSAllocatedUnfairLock<(out: String, err: String)>(initialState: ("", ""))

    var out: String { text.withLock { $0.out } }
    var err: String { text.withLock { $0.err } }

    var write: @Sendable (String, Bool) -> Void {
        { [self] line, error in text.withLock { error ? $0.err.append(line) : $0.out.append(line) } }
    }
}

@MainActor
@Suite(.serialized)
struct GlimmerCLISunshineTests {

    private typealias CLI = GlimmerCLI
    private typealias Verb = @MainActor (CLI.Command, AppModel) async -> Int32

    /// Parses `args` as the shell would hand them over, then runs `verb` with its output captured.
    private func run(_ verb: Verb, _ args: [String], on fixture: FakePCModel) async throws -> (Int32, CapturedTerminal) {
        let command = try CLI.parse(args)
        let terminal = CapturedTerminal()
        let status = await CLITerminal.$write.withValue(terminal.write) { await verb(command, fixture.model) }
        fixture.settle()
        return (status, terminal)
    }

    private let certChanged: Result<ControlTransport.Response, StreamError> =
        .failure(.hostUnreachable("TLS cert mismatch"))

    // MARK: - list

    @Test func listPrintsEachPCWithTheReadinessChipsWords() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()], "applist": [FakePCModel.appList]])
        let fixture = try FakePCModel("cli-list", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.list, ["list"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.out == "Tower\t192.0.2.10\tReady · 3 ms\n")
        #expect(terminal.err.isEmpty)
        #expect(sunshine.paths == ["serverinfo", "applist"])
    }

    @Test func listAsCSVQuotesEveryField() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo(game: 7)], "applist": [FakePCModel.appList]])
        let fixture = try FakePCModel("cli-list-csv", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.list, ["list", "--csv"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.out == "Name,Address,Status\n\"Tower\",\"192.0.2.10\",\"Hades II running\"\n")
    }

    @Test func listWithNoPairedPCsSaysHowToPairOne() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("cli-list-empty", sunshine: sunshine)
        defer { fixture.remove() }

        let (status, terminal) = try await run(CLI.list, ["list"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.out.isEmpty)
        #expect(terminal.err == "No paired PCs. Pair one with: glimmer pair <address>\n")
        #expect(sunshine.requests.isEmpty)
    }

    @Test func listingAPCsAppsShowsTheVisibleOnesOrEveryOneAsCSV() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()], "applist": [FakePCModel.appList]])
        let fixture = try FakePCModel("cli-apps", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.list, ["list", "tower"], on: fixture)
        #expect(status == CLI.Exit.ok)
        #expect(terminal.out == "Desktop\nHades II\n")

        let (csvStatus, csv) = try await run(CLI.list, ["list", "192.0.2.10", "--csv"], on: fixture)
        #expect(csvStatus == CLI.Exit.ok)
        #expect(csv.out == """
            Name,ID,HDR Support,Hidden
            "Desktop",1,false,false
            "Hades II",7,true,false
            "Steam",9,false,true

            """)
        #expect(sunshine.paths == ["serverinfo", "applist", "serverinfo", "applist"])
        #expect(sunshine.requests.allSatisfy { $0.tls && $0.credential.pinnedCertPEM == FakePCModel.pin })
    }

    @Test func listingAppsOnAPCThatIsDownExitsUnreachable() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.unreachable]])
        let fixture = try FakePCModel("cli-apps-down", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.list, ["list", "Tower"], on: fixture)

        #expect(status == CLI.Exit.unreachable)
        #expect(terminal.err == AppModel.unreachableMessage("Tower") + "\n")
        #expect(terminal.out.isEmpty)
        #expect(sunshine.requests.map(\.tls) == [true, false])
    }

    @Test func listingAppsOnAPCWhoseCertificateChangedAsksToPairAgain() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [certChanged]])
        let fixture = try FakePCModel("cli-apps-cert", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.list, ["list", "Tower"], on: fixture)

        #expect(status == CLI.Exit.notPaired)
        #expect(terminal.err == "Tower needs pairing again. Run: glimmer pair 192.0.2.10\n")
        #expect(sunshine.paths == ["serverinfo"])
    }

    @Test func anUnknownPCIsNotPairedAndNothingIsSent() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("cli-unknown", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let verbs: [(Verb, String)] = [(CLI.list, "list"), (CLI.quit, "quit"), (CLI.stream, "stream"), (CLI.wake, "wake")]
        for (verb, name) in verbs {
            let (status, terminal) = try await run(verb, [name, "Den"], on: fixture)
            #expect(status == CLI.Exit.notPaired)
            #expect(terminal.err == "No paired PC matches “Den”. Run “glimmer list” to see them, or pair it with “glimmer pair”.\n")
        }
        #expect(sunshine.requests.isEmpty)
    }

    // MARK: - pair

    @Test func pairingAPCThatStillTrustsThisMacSaysSo() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()]])
        let fixture = try FakePCModel("cli-pair-known", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.pair, ["pair", "https://192.0.2.10:47990/pin"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.out == "Already paired with Tower.\n")
        #expect(sunshine.paths == ["serverinfo"])
        #expect(sunshine.requests.first?.tls == true)
    }

    @Test func pairingPrintsThePinThenPairsWithThePC() async throws {
        let hostIdentity = try await EphemeralCryptoIdentity.make(bits: 2048)
        let client = try await EphemeralCryptoIdentity.make(bits: 2048)
        let pc = FakePairingHost(host: hostIdentity, pin: "4821")
        let sunshine = FakeSunshine { request in
            request.path == "/serverinfo" ? try FakePCModel.serverInfo().get() : try pc.respond(request)
        }
        let fixture = try FakePCModel("cli-pair", sunshine: sunshine, identity: client)
        defer { fixture.remove() }

        let (status, terminal) = try await run(CLI.pair, ["pair", "192.0.2.10", "--pin", "4821"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.err == "On 192.0.2.10, open Sunshine's web page, choose PIN, and enter 4821.\n")
        #expect(terminal.out == "Paired with Tower.\n")
        #expect(fixture.model.hosts.map(\.id) == ["tower-id"])
        // No /applist answer: the PC is saved with pairing's stand-in Desktop.
        #expect(fixture.model.hosts.first?.apps.map(\.name) == ["Desktop"])
    }

    @Test func aPairThatCannotReachThePCFailsWithTheSharedCopy() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.unreachable]])
        let fixture = try FakePCModel("cli-pair-down", sunshine: sunshine)
        defer { fixture.remove() }

        let (status, terminal) = try await run(CLI.pair, ["pair", "192.0.2.10", "--pin", "4821"], on: fixture)

        #expect(status == CLI.Exit.failed)
        let failure = CLI.pairFailureMessage(.unreachable, pc: "192.0.2.10")
        #expect(terminal.err == "On 192.0.2.10, open Sunshine's web page, choose PIN, and enter 4821.\n\(failure)\n")
        #expect(terminal.out.isEmpty)
        #expect(fixture.store.defaults.integer(forKey: "hosts.size") == 0)
    }

    @Test func pairingSomethingThatIsNotAnAddressIsAUsageError() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("cli-pair-usage", sunshine: sunshine)
        defer { fixture.remove() }

        let (status, terminal) = try await run(CLI.pair, ["pair", "not an address"], on: fixture)

        #expect(status == CLI.Exit.usage)
        #expect(terminal.err == PairingFailure.addressHint + "\n")
        #expect(sunshine.requests.isEmpty)
    }

    // MARK: - quit

    @Test func quittingAnIdlePCSaysThereIsNothingToQuit() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()], "applist": [FakePCModel.appList]])
        let fixture = try FakePCModel("cli-quit-idle", sunshine: sunshine)
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.quit, ["quit", "Tower"], on: fixture)

        #expect(status == CLI.Exit.ok)
        #expect(terminal.out == "Tower isn't running an app.\n")
        #expect(!sunshine.paths.contains("cancel"))
    }

    @Test func quittingOnAPCThatIsDownOrDistrustedNamesTheFix() async throws {
        let down = try FakePCModel("cli-quit-down", sunshine: FakeSunshine.scripted([:]), rtt: .unreachable)
        defer { down.remove() }
        try down.pairTower()
        let (downStatus, downTerminal) = try await run(CLI.quit, ["quit", "Tower"], on: down)
        #expect(downStatus == CLI.Exit.unreachable)
        #expect(downTerminal.err == AppModel.unreachableMessage("Tower") + "\n")
        #expect(down.sunshine.requests.isEmpty)

        let distrusted = try FakePCModel("cli-quit-cert", sunshine: FakeSunshine.scripted(["serverinfo": [certChanged]]))
        defer { distrusted.remove() }
        try distrusted.pairTower()
        let (certStatus, certTerminal) = try await run(CLI.quit, ["quit", "Tower"], on: distrusted)
        #expect(certStatus == CLI.Exit.notPaired)
        #expect(certTerminal.err == "Tower needs pairing again. Run: glimmer pair 192.0.2.10\n")
        #expect(!distrusted.sunshine.paths.contains("cancel"))
    }

    // MARK: - stream

    @Test func streamingFromAPCThatIsDownSuggestsWakingIt() async throws {
        let fixture = try FakePCModel("cli-stream-down", sunshine: FakeSunshine.scripted([:]), rtt: .unreachable)
        defer { fixture.remove() }
        try fixture.pairTower(mac: "aa:bb:cc:dd:ee:01")

        let (status, terminal) = try await run(CLI.stream, ["stream", "Tower", "--wait"], on: fixture)

        #expect(status == CLI.Exit.unreachable)
        #expect(terminal.err == AppModel.unreachableMessage("Tower") + " To wake it: glimmer wake \"Tower\" --wait\n")
        #expect(fixture.sunshine.requests.isEmpty)
    }

    @Test func streamingFromADistrustedPCAsksToPairAgain() async throws {
        let fixture = try FakePCModel("cli-stream-cert", sunshine: FakeSunshine.scripted(["serverinfo": [certChanged]]))
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.stream, ["stream", "Tower"], on: fixture)

        #expect(status == CLI.Exit.notPaired)
        #expect(terminal.err == "Tower needs pairing again. Run: glimmer pair 192.0.2.10\n")
        #expect(fixture.sunshine.paths == ["serverinfo"])
    }

    @Test func streamingAnAppThePCDoesNotHaveListsTheOnesItDoes() async throws {
        let fixture = try FakePCModel("cli-stream-app", sunshine: FakeSunshine.scripted(["serverinfo": [FakePCModel.serverInfo()]]))
        defer { fixture.remove() }
        try fixture.pairTower()

        let (status, terminal) = try await run(CLI.stream, ["stream", "Tower", "Halo"], on: fixture)

        #expect(status == CLI.Exit.usage)
        #expect(terminal.err == "Glimmer doesn't know “Halo” on Tower. Its apps: Desktop\n")
        #expect(!fixture.sunshine.paths.contains("launch"))
    }

    // MARK: - wake

    @Test func wakingAPCWithoutAMacOrWithWakeOffNamesTheFixAndSendsNothing() async throws {
        let fixture = try FakePCModel("cli-wake", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()

        let (noMac, noMacTerminal) = try await run(CLI.wake, ["wake", "Tower"], on: fixture)
        #expect(noMac == CLI.Exit.failed)
        #expect(noMacTerminal.err == AppModel.wakeNoMacMessage("Tower") + "\n")

        try fixture.pairTower(mac: "aa:bb:cc:dd:ee:01")
        fixture.model.setWakeOnLAN(host, enabled: false, defaults: fixture.store.defaults)
        fixture.settle()
        let (off, offTerminal) = try await run(CLI.wake, ["wake", "Tower", "--wait"], on: fixture)
        #expect(off == CLI.Exit.failed)
        #expect(offTerminal.err == AppModel.wakeOffMessage("Tower") + "\n")
        #expect(fixture.sunshine.requests.isEmpty)
    }
}
