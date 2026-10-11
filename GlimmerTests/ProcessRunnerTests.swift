// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Foundation
import Synchronization
import Testing
@testable import Glimmer

// The test target compiles its own AWDLProcess for the helper sources; the app has another.
private typealias LaunchctlResult = Glimmer.AWDLProcess.Result

struct AWDLHelperLayoutProbeTests {
    private static let job = "system/" + glimmerHelperMachServiceName
    private static let current = job + " = {\n\tprogram identifier = Contents/Library/LaunchServices/"
        + "Glimmer Network Helper.app/Contents/MacOS/" + glimmerHelperMachServiceName + " (mode: 2)\n}\n"
    private static let missing = "Could not find service \"" + glimmerHelperMachServiceName + "\" in domain for system"

    private func probe(_ result: LaunchctlResult?) async -> (AWDLHelperRecovery.Layout, [[String]]) {
        let calls = Mutex<[[String]]>([])
        let layout = await AWDLHelperRecovery.daemonLayout { args in
            calls.withLock { $0.append(args) }
            return result
        }
        return (layout, calls.withLock { $0 })
    }

    private func exited(_ code: Int32, _ output: String, signal: Int32 = 0) -> LaunchctlResult {
        LaunchctlResult(status: code << 8 | signal, output: Data(output.utf8), timedOut: false, truncated: false)
    }

    @Test func asksLaunchctlForTheHelperJob() async {
        let (layout, calls) = await probe(exited(0, Self.current))
        #expect(layout == .current)
        #expect(calls == [["print", Self.job]])
    }

    @Test func exitCode113WithTheMissingMessageIsMissing() async {
        #expect(await probe(exited(113, Self.missing)).0 == .missing)
        #expect(await probe(exited(1, Self.missing)).0 == .unknown)
    }

    @Test func anUntrustworthyRunIsUnknown() async {
        #expect(await probe(nil).0 == .unknown)
        #expect(await probe(exited(0, Self.current, signal: 9)).0 == .unknown)
        let timedOut = LaunchctlResult(status: 0, output: Data(Self.current.utf8), timedOut: true, truncated: false)
        #expect(await probe(timedOut).0 == .unknown)
        let truncated = LaunchctlResult(status: 0, output: Data(Self.current.utf8), timedOut: false, truncated: true)
        #expect(await probe(truncated).0 == .unknown)
    }
}

@MainActor
struct GlimmerCLIHandOffTests {
    private typealias Key = CommandChannel.Key
    private typealias Event = CommandChannel.Event

    private let tower = Host(id: "tower-id", name: "Tower", customName: nil, localAddress: "192.0.2.10",
                             manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil,
                             appVersion: nil, macAddress: nil)
    private let desktop = LibraryApp(id: 881_448_767, name: "Desktop", hdr: false, hidden: false)

    /// Runs a hand-off whose app answers `first`, then queues `later` on the reply inbox.
    private func handOff(flags: Set<String> = [], opens: Bool = true, first: [String: String]?,
                         later: [[String: String]] = []) async -> (Int32, CapturedTerminal, [[String: String]]) {
        let terminal = CapturedTerminal()
        var requests: [[String: String]] = []
        let command = GlimmerCLI.Command(verb: .stream, arguments: ["Tower"], flags: flags)
        let status = await GlimmerCLI.$terminal.withValue(terminal.write) {
            await GlimmerCLI.handOff(app: desktop, host: tower, takeover: true, command: command,
                                     open: { opens ? NSRunningApplication.current : nil },
                                     post: { request, replies in
                requests.append(request)
                replies.requestID = "req"
                later.forEach { replies.receive($0.merging([Key.id: "req"]) { old, _ in old }) }
                return first
            })
        }
        return (status, terminal, requests)
    }

    @Test func anAcceptedStreamReturnsAtOnceWithoutWait() async {
        let (status, terminal, requests) = await handOff(first: [Key.event: Event.accepted])
        #expect(status == GlimmerCLI.Exit.ok)
        #expect(terminal.out == "Glimmer is starting Desktop on Tower.\n")
        #expect(requests == [[Key.verb: "stream", Key.host: "tower-id", Key.app: "881448767", Key.takeover: "1"]])
    }

    @Test func noAppOrNoAnswerFails() async {
        let (closed, _, none) = await handOff(opens: false, first: [Key.event: Event.accepted])
        #expect(closed == GlimmerCLI.Exit.failed)
        #expect(none.isEmpty)
        let (silent, terminal, _) = await handOff(first: nil)
        #expect(silent == GlimmerCLI.Exit.failed)
        #expect(terminal.err == "Glimmer didn't answer. Open it and try again.\n")
    }

    @Test func aRejectionPrintsTheAppsReason() async {
        let (status, terminal, _) = await handOff(first: [Key.event: Event.rejected, Key.detail: "Busy."])
        #expect(status == GlimmerCLI.Exit.failed)
        #expect(terminal.err == "Busy.\n")
    }

    @Test func firstFrameEndsTheWaitUnlessAskedToWaitForTheEnd() async {
        let live = [Key.event: Event.live]
        let ended = [Key.event: Event.ended]
        let (firstFrame, _, _) = await handOff(flags: ["--exit-after-first-frame"], first: [Key.event: Event.accepted],
                                               later: [live, [Key.event: Event.ended, Key.detail: "Lost."]])
        #expect(firstFrame == GlimmerCLI.Exit.ok)
        let (clean, _, _) = await handOff(flags: ["--wait"], first: [Key.event: Event.accepted], later: [live, ended])
        #expect(clean == GlimmerCLI.Exit.ok)
        let (lost, terminal, _) = await handOff(flags: ["--wait", "--json"], first: [Key.event: Event.accepted],
                                                later: [live, [Key.event: Event.ended, Key.detail: "Lost."]])
        #expect(lost == GlimmerCLI.Exit.failed)
        #expect(terminal.out == "{\"event\":\"live\"}\n{\"detail\":\"Lost.\",\"event\":\"ended\"}\n")
        #expect(terminal.err == "Lost.\n")
    }
}
