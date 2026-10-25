// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum RunningAppFailure: Error, Equatable {
    case ended
    case quitUnconfirmed
}

extension StreamSession {
    /// An explicit command rechecks the named occupant and never repeats an uncertain /cancel.
    public static func quitRunningApp(network: NetworkClient, expectedAppID: Int) async throws {
        let pc = await network.server.uniqueId
        try await launchMutations.performCommand(pc: pc) { _ in
            do {
                try await quitRunningAppChecked(network: network, expectedAppID: expectedAppID)
            } catch {
                await network.setRequestDeadline(nil)
                throw error
            }
            await network.setRequestDeadline(nil)
        }
    }

    package static func quitRunningAppChecked(network: NetworkClient, expectedAppID: Int) async throws {
        let server = await network.server
        guard server.serverCertPEM != nil else { throw NetworkClient.notPaired(server.serverName) }
        await network.setRequestDeadline(Date().addingTimeInterval(7))
        let info = try await network.fetchServerInfo()
        try Task.checkCancellation()
        if info.currentGameID == 0, !info.isBusy { return }
        guard info.currentGameID == expectedAppID else { throw TakeoverRequired(appID: info.currentGameID) }
        do {
            try await network.cancel()
        } catch {
            let fresh = try await network.fetchServerInfo()
            if fresh.currentGameID == 0, !fresh.isBusy { return }
            throw error
        }
        try await waitForQuit(network: network, expectedAppID: expectedAppID)
    }

    private static func waitForQuit(network: NetworkClient, expectedAppID: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let info = try await network.fetchServerInfo()
            if info.currentGameID == 0, !info.isBusy { return }
            guard info.currentGameID == expectedAppID else { throw TakeoverRequired(appID: info.currentGameID) }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RunningAppFailure.quitUnconfirmed
    }
}
