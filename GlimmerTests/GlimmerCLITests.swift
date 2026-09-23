//
//  GlimmerCLITests.swift
//
//  The `glimmer` command line: which launches it takes over, how arguments
//  parse, how a PC is found, and how results read and exit.
//

import Foundation
import Testing
@testable import Glimmer

struct GlimmerCLITests {

    private func host(_ name: String, id: String, address: String?, custom: String? = nil) -> Glimmer.Host {
        Host(id: id, name: name, customName: custom, localAddress: address, manualAddress: address,
             apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
    }

    @Test func theCommandNameOrABareWordTakesOverTheLaunch() {
        #expect(GlimmerCLI.isInvocation(["glimmer", "list"]))
        #expect(GlimmerCLI.isInvocation(["glimmer", "stream", "Tower", "Desktop"]))
        #expect(GlimmerCLI.isInvocation(["glimmer", "--help"]))
        // Through the cask's link, never a second copy of the app in the
        // terminal: alone it opens the app, and unknown flags get usage.
        #expect(GlimmerCLI.isInvocation(["glimmer"]))
        #expect(GlimmerCLI.isInvocation(["/opt/homebrew/bin/glimmer", "--version"]))
        // The app binary itself: a typo gets usage, not a second copy.
        #expect(GlimmerCLI.isInvocation(["/Applications/Glimmer.app/Contents/MacOS/Glimmer", "lsit"]))
        // No arguments, the login helper, Launch Services, Xcode and tests: the app.
        #expect(!GlimmerCLI.isInvocation(["/Applications/Glimmer.app/Contents/MacOS/Glimmer"]))
        #expect(!GlimmerCLI.isInvocation(["Glimmer"]))
        #expect(!GlimmerCLI.isInvocation(["Glimmer", "--launched-at-login"]))
        #expect(!GlimmerCLI.isInvocation(["Glimmer", "-psn_0_123456"]))
        #expect(!GlimmerCLI.isInvocation(["Glimmer", "-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!GlimmerCLI.isInvocation(["Glimmer", "-XCTest", "All"]))
    }

    @Test func argumentsParseIntoVerbFlagsAndPositionals() throws {
        let stream = try GlimmerCLI.parse(["stream", "Tower", "Steam Big Picture", "--force", "--wait"])
        #expect(stream.verb == .stream)
        #expect(stream.arguments == ["Tower", "Steam Big Picture"])
        #expect(stream.flags == ["--force", "--wait"])
        let pair = try GlimmerCLI.parse(["pair", "tower.local", "--pin", "0420"])
        #expect(pair.arguments == ["tower.local"])
        #expect(pair.pin == "0420")
        #expect(try GlimmerCLI.parse(["list", "Tower", "--help"]).verb == .help)
    }

    @Test func badArgumentsAreUsageErrors() {
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["pair", "tower.local", "--pin", "12a4"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["pair", "tower.local", "--pin"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["pair", "tower.local", "--pin", "١٢٣٤"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["list", "--wait"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["quit"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["wake", "Tower", "Den"]) }
        #expect(throws: GlimmerCLI.UsageError.self) { try GlimmerCLI.parse(["lsit"]) }
    }

    @Test func aPCMatchesByNameIdOrAddressIgnoringCase() {
        let hosts = [
            host("TOWER", id: "UUID-1", address: "192.0.2.10", custom: "Living Room"),
            host("den", id: "UUID-2", address: "den.local")
        ]
        #expect(GlimmerCLI.matchHost("living room", in: hosts)?.id == "UUID-1")
        #expect(GlimmerCLI.matchHost("tower", in: hosts)?.id == "UUID-1")
        #expect(GlimmerCLI.matchHost("uuid-2", in: hosts)?.id == "UUID-2")
        #expect(GlimmerCLI.matchHost("DEN.LOCAL", in: hosts)?.id == "UUID-2")
        #expect(GlimmerCLI.matchHost("192.0.2.10", in: hosts)?.id == "UUID-1")
        #expect(GlimmerCLI.matchHost("tow", in: hosts) == nil)
    }

    @Test func failuresMapToTheirExitCodes() {
        let exit = GlimmerCLI.Exit.self
        #expect(GlimmerCLI.exitCode(for: StreamError.hostUnreachable("connect to x timed out")) == exit.unreachable)
        #expect(GlimmerCLI.exitCode(for: StreamError.hostCertChanged("Tower's certificate changed.")) == exit.notPaired)
        #expect(GlimmerCLI.exitCode(for: StreamError.pairingFailed("pair it again")) == exit.notPaired)
        #expect(GlimmerCLI.exitCode(for: StreamError.pairingRejected) == exit.notPaired)
        #expect(GlimmerCLI.exitCode(for: StreamError.truncatedRead("eof")) == exit.unreachable)
        #expect(GlimmerCLI.exitCode(for: StreamError.launchFailed("Service Unavailable (code 503)")) == exit.failed)
        #expect(GlimmerCLI.exitCode(for: CancellationError()) == exit.failed)
    }

    @Test func failureTextPointsAtTheFix() {
        let tower = host("Tower", id: "UUID-1", address: "192.0.2.10")
        #expect(GlimmerCLI.message(for: StreamError.pairingFailed("x"), host: tower)
            == "Tower needs pairing again. Run: glimmer pair 192.0.2.10")
        #expect(GlimmerCLI.message(for: StreamError.hostUnreachable("timed out"), host: tower)
            == "Couldn't reach Tower. Make sure it's awake and on the same network.")
        let wedged = "Tower is awake, but its HTTPS listener is stuck. Restart Sunshine on the PC."
        #expect(GlimmerCLI.message(for: StreamError.sunshineNeedsRestart(wedged), host: tower) == wedged)
        #expect(GlimmerCLI.message(for: StreamError.launchFailed("Tower wouldn't quit the app."), host: tower)
            == "Tower wouldn't quit the app.")
    }

    /// `glimmer list` prints the readiness chip's words, with room for a long name.
    @Test func statusReadsLikeTheReadinessChip() {
        let now = Date()
        func status(_ state: HostLiveStatus.State, rtt: Int? = nil) -> String {
            ChipPresentation(live: HostLiveStatus(hostID: "a", state: state, rttMs: rtt, sunshineVersion: nil,
                                                  capturedAt: now), now: now).fullLabel
        }
        #expect(status(.idle, rtt: 3) == "Ready · 3 ms")
        #expect(status(.streamingApp(name: "A Very Long Game Title Indeed")) == "A Very Long Game Title Indeed running")
        #expect(status(.streamingUnknownApp(id: 9)) == "App running")
        #expect(status(.asleep, rtt: 9) == "Asleep")
        #expect(status(.certMismatch) == "Trust needed")
        #expect(ChipPresentation(live: nil).fullLabel == "Checking…")
    }

    /// The pair sheet's address cleanup applies before anything is printed or dialled.
    @MainActor @Test func pairRefusesAnAddressThatIsNotOne() async throws {
        let command = try GlimmerCLI.parse(["pair", "my gaming pc"])
        #expect(await GlimmerCLI.pair(command, model: AppModel()) == GlimmerCLI.Exit.usage)
    }

    @Test func aFailedPairSaysToRunItAgainNotToClickTryAgain() {
        for failure in [PairingFailure.timedOut, .rejected] {
            let line = GlimmerCLI.pairFailureMessage(failure, pc: "192.0.2.10")
            #expect(line.contains("192.0.2.10") && line.contains("glimmer pair") && !line.contains("Try Again"))
        }
        #expect(GlimmerCLI.pairFailureMessage(.unreachable, pc: "x") == PairingFailure.unreachable.message(pc: "x"))
    }

    @Test func csvQuotesNamesSoCommasAndQuotesSurvive() {
        let app = HostApp(id: 42, name: "Halo, \"Infinite\"", hdrCapable: true, hidden: false)
        #expect(GlimmerCLI.csvRow(app) == "\"Halo, \"\"Infinite\"\"\",42,true,false")
        #expect(GlimmerCLI.csvHeader.hasPrefix("Name,ID,HDR Support"))
    }

    @Test func jsonLineHasNumericTimingsAndNoRequestID() {
        let line = GlimmerCLI.jsonLine(["id": "req", "event": "live", "launch_path_ms": "812", "detail": "ok"])
        #expect(line == #"{"detail":"ok","event":"live","launch_path_ms":812}"#)
    }

    @Test func aSymlinkedExecutableResolvesToItsRealPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("Glimmer")
        try Data().write(to: binary)
        let link = folder.appendingPathComponent("glimmer-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        // The temporary folder itself sits behind /var -> /private/var.
        let realBinary = GlimmerMain.realPathIfDifferent(binary.path) ?? binary.path
        #expect(GlimmerMain.realPathIfDifferent(link.path) == realBinary)
        #expect(GlimmerMain.realPathIfDifferent(realBinary) == nil)
    }
}
