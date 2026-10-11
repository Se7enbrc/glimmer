// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Synchronization
import Testing
@testable import Glimmer

/// A fake awdl0: `down` and `up` flip it unless `sticky`, and a bare query lists its addresses.
private final class FakeInterface: Sendable {
    let isUp: Mutex<Bool>
    let commands = Mutex<[[String]]>([])
    let sticky: Bool

    init(up: Bool, sticky: Bool = false) {
        isUp = Mutex(up)
        self.sticky = sticky
    }

    func run(_ args: [String]) -> AWDLProcess.Result? {
        commands.withLock { $0.append(args) }
        switch args.last {
        case "down" where !sticky: isUp.withLock { $0 = false }
        case "up": isUp.withLock { $0 = true }
        case "awdl0":
            return .ifconfig(output: "awdl0: flags=8843<UP>\n\tinet6 fe80::1%awdl0 prefixlen 64 scopeid 0xb \n"
                + "\tinet6 fe80::2%awdl0 prefixlen 64\n\tether 00:00:00:00:00:00\n")
        default: break
        }
        return .ifconfig()
    }

    func suppressor() -> AWDLSuppressor {
        AWDLSuppressor(interfaceIsUp: { self.isUp.withLock { $0 } }, runIfconfig: { self.run($0) })
    }
}

private func drain(_ suppressor: AWDLSuppressor) async {
    await withCheckedContinuation { continuation in
        suppressor.afterPendingChanges { continuation.resume() }
    }
}

struct AWDLSuppressorTests {
    @Test func suppressDownsAndStripsLinkLocalAddresses() async {
        let awdl = FakeInterface(up: true)
        let suppressor = awdl.suppressor()
        HelperService(suppressor: suppressor).setAWDLDown(true, reason: "stream") { _ in }
        await drain(suppressor)
        #expect(awdl.commands.withLock { $0 } == [
            ["awdl0", "down"],
            ["awdl0"],
            ["awdl0", "inet6", "fe80::1%awdl0", "delete"],
            ["awdl0", "inet6", "fe80::2%awdl0", "delete"]
        ])
        #expect(!awdl.isUp.withLock { $0 })
    }

    @Test func suppressLeavesADownInterfaceAlone() async {
        let awdl = FakeInterface(up: false)
        let suppressor = awdl.suppressor()
        let parked = await withCheckedContinuation { continuation in
            HelperService(suppressor: suppressor).setAWDLDown(true, reason: "stream") { continuation.resume(returning: $0) }
        }
        await drain(suppressor)
        #expect(parked)
        #expect(awdl.commands.withLock { $0 }.isEmpty)
    }

    @Test func stubbornInterfaceGetsThreeAttempts() async {
        let awdl = FakeInterface(up: true, sticky: true)
        let suppressor = awdl.suppressor()
        suppressor.setSuppressing(true, reason: "stream")
        await drain(suppressor)
        #expect(awdl.commands.withLock { $0 }.filter { $0 == ["awdl0", "down"] }.count == 3)
        #expect(suppressor.reSuppressCount == 0)
    }

    @Test func reRaiseIsCountedAndSuppressedAgain() async {
        let awdl = FakeInterface(up: true)
        let suppressor = awdl.suppressor()
        suppressor.setSuppressing(true, reason: "stream")
        await drain(suppressor)
        awdl.isUp.withLock { $0 = true }
        suppressor.setSuppressing(true, reason: "heartbeat")
        await drain(suppressor)
        #expect(suppressor.reSuppressCount == 1)
        #expect(!awdl.isUp.withLock { $0 })
    }

    @Test func releaseBringsTheInterfaceBackUp() async {
        let awdl = FakeInterface(up: true)
        let suppressor = awdl.suppressor()
        let service = HelperService(suppressor: suppressor)
        service.setAWDLDown(true, reason: "stream") { _ in }
        await drain(suppressor)
        awdl.commands.withLock { $0.removeAll() }
        let released = await withCheckedContinuation { continuation in
            service.setAWDLDown(false, reason: "done") { continuation.resume(returning: $0) }
        }
        #expect(released)
        #expect(awdl.commands.withLock { $0 } == [["awdl0", "up"]])
    }
}
