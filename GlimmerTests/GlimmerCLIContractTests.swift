//
//  GlimmerCLIContractTests.swift
//
//  The command line's contract: what each argument shape parses to or is
//  refused with, the exit status a bad invocation ends in, and the words the
//  help and failures use. Nothing here touches a PC, the model or defaults.
//

import Foundation
import Testing
@testable import Glimmer

struct GlimmerCLIContractTests {

    private func usageMessage(_ args: [String]) -> String? {
        do { _ = try GlimmerCLI.parse(args) } catch { return (error as? GlimmerCLI.UsageError)?.message }
        return nil
    }

    private func tower(address: String? = "192.0.2.10") -> Glimmer.Host {
        Host(id: "u", name: "Tower", customName: nil, localAddress: address, manualAddress: nil,
             apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
    }

    @Test func exitCodesAreTheDocumentedFive() {
        let exit = GlimmerCLI.Exit.self
        #expect([exit.ok, exit.failed, exit.usage, exit.unreachable, exit.notPaired] == [0, 1, 2, 3, 4])
        #expect(GlimmerCLI.usage.contains("Exit status: 0 success, 1 failure, 2 usage error, 3 PC unreachable, 4 PC not paired."))
    }

    @Test func theHelpNamesEveryVerbAndFlagTheParserTakes() {
        for verb in ["pair", "list", "stream", "quit", "wake", "help"] {
            #expect(GlimmerCLI.usage.contains("  \(verb)"), "\(verb)")
        }
        for flag in ["--pin", "--csv", "--force", "--wait", "--exit-after-first-frame", "--json"] {
            #expect(GlimmerCLI.usage.contains(flag), "\(flag)")
        }
    }

    @Test func noArgumentsAsksForTheHelpText() {
        #expect(usageMessage([]) == GlimmerCLI.usage)
    }

    @Test func anUnknownVerbIsNamedInCurlyQuotes() {
        #expect(usageMessage(["lsit"]) == "Unknown command “lsit”. Run “glimmer help” for the list.")
    }

    @Test func aFlagTheVerbDoesNotTakeIsNamed() {
        #expect(usageMessage(["wake", "Tower", "--csv"]) == "“glimmer wake” doesn't take --csv.")
        #expect(usageMessage(["quit", "Tower", "--wait"]) == "“glimmer quit” doesn't take --wait.")
        // --pin belongs to pair alone.
        #expect(usageMessage(["stream", "Tower", "--pin", "1234"]) == "“glimmer stream” doesn't take --pin.")
    }

    @Test func aPINMustBeExactlyFourASCIIDigits() throws {
        for bad in ["123", "12345", "12a4", ""] {
            #expect(usageMessage(["pair", "tower.local", "--pin", bad]) == "The PIN must be four digits.", "\(bad)")
        }
        #expect(try GlimmerCLI.parse(["pair", "--pin", "0042", "tower.local"]).pin == "0042")
        #expect(try GlimmerCLI.parse(["pair", "tower.local"]).pin == nil)
    }

    @Test func wrongArgumentCountsPointAtHelp() {
        let wrong = "Wrong arguments for “glimmer %@”. Run “glimmer help”."
        #expect(usageMessage(["stream"]) == String(format: wrong, "stream"))
        #expect(usageMessage(["stream", "a", "b", "c"]) == String(format: wrong, "stream"))
        #expect(usageMessage(["list", "a", "b"]) == String(format: wrong, "list"))
        #expect(usageMessage(["pair"]) == String(format: wrong, "pair"))
    }

    @Test func everyAllowedFlagParsesOntoItsVerb() throws {
        let stream = try GlimmerCLI.parse(["stream", "Tower", "--exit-after-first-frame", "--json"])
        #expect(stream.flags == ["--exit-after-first-frame", "--json"])
        #expect(stream.arguments == ["Tower"])
        #expect(try GlimmerCLI.parse(["list", "--csv"]).flags == ["--csv"])
        #expect(try GlimmerCLI.parse(["list", "Tower", "--csv"]).arguments == ["Tower"])
        #expect(try GlimmerCLI.parse(["wake", "Tower", "--wait"]).flags == ["--wait"])
        #expect(try GlimmerCLI.parse(["help", "stream"]).verb == .help)
        #expect(try GlimmerCLI.parse(["quit", "-h"]).verb == .help)
    }

    @MainActor @Test func aBadInvocationEndsWithTheUsageStatusBeforeAnythingRuns() async {
        #expect(await GlimmerCLI.run(["lsit"]) == GlimmerCLI.Exit.usage)
        #expect(await GlimmerCLI.run(["list", "--wait"]) == GlimmerCLI.Exit.usage)
        #expect(await GlimmerCLI.run(["stream"]) == GlimmerCLI.Exit.usage)
        #expect(await GlimmerCLI.run(["pair", "tower.local", "--pin", "12"]) == GlimmerCLI.Exit.usage)
    }

    @MainActor @Test func helpEndsSuccessfullyWhereverItIsAsked() async {
        #expect(await GlimmerCLI.run(["help"]) == GlimmerCLI.Exit.ok)
        #expect(await GlimmerCLI.run(["--help"]) == GlimmerCLI.Exit.ok)
        #expect(await GlimmerCLI.run(["stream", "Tower", "-h"]) == GlimmerCLI.Exit.ok)
    }

    @Test func aWedgedSunshineIsUnreachableAndAnyOtherErrorFails() {
        let wedged = StreamError.sunshineNeedsRestart("Restart Sunshine on the PC.")
        #expect(GlimmerCLI.exitCode(for: wedged) == GlimmerCLI.Exit.unreachable)
        #expect(GlimmerCLI.exitCode(for: URLError(.notConnectedToInternet)) == GlimmerCLI.Exit.failed)
        #expect(GlimmerCLI.message(for: URLError(.timedOut), host: tower()) == URLError(.timedOut).localizedDescription)
    }

    @Test func pairAgainNamesTheAddressTheCLIDials() {
        #expect(GlimmerCLI.notPairedMessage(tower()) == "Tower needs pairing again. Run: glimmer pair 192.0.2.10")
        #expect(GlimmerCLI.notPairedMessage(tower(address: nil)) == "Tower needs pairing again. Run: glimmer pair Tower")
    }

    @Test func aTimingOnlyBecomesANumberWhenItIsOne() {
        let line = GlimmerCLI.jsonLine(["event": "live", "build_ms": "pending", "launch_ms": "40"])
        #expect(line == #"{"build_ms":"pending","event":"live","launch_ms":40}"#)
        #expect(GlimmerCLI.jsonLine([:]) == "{}")
    }

    @Test func everyLineTheCLIPrintsFollowsTheCopyRules() {
        let lines = [GlimmerCLI.usage, GlimmerCLI.notPairedMessage(tower()),
                     GlimmerCLI.message(for: StreamError.hostUnreachable("x"), host: tower()),
                     GlimmerCLI.message(for: StreamError.hostTimedOut, host: tower())]
            + [PairingFailure.timedOut, .busy, .rejected].map { GlimmerCLI.pairFailureMessage($0, pc: "192.0.2.10") }
        for line in lines {
            #expect(!line.contains("—") && !line.contains("!"), "\(line)")
            #expect(!line.lowercased().contains("server") && !line.lowercased().contains("host "), "\(line)")
        }
    }
}
