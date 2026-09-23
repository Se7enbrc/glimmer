//
//  GlimmerCLI+List.swift
//
//  `glimmer list`: the paired PCs with the launcher's live status, and
//  `glimmer list <pc> [--csv]`: the apps that PC offers right now.
//

import Foundation

extension GlimmerCLI {

    static func list(_ command: Command, model: AppModel) async -> Int32 {
        if let query = command.arguments.first {
            guard let host = resolveHost(query, model: model) else { return Exit.notPaired }
            return await listApps(on: host, csv: command.flags.contains("--csv"), model: model)
        }
        guard !model.hosts.isEmpty else {
            printError("No paired PCs. Pair one with: glimmer pair <address>")
            return Exit.ok
        }
        // One PC at a time: a handful of 2-second probes at most.
        for host in model.hosts {
            let live = await probe(host, model: model)
            print("\(host.displayName)\t\(AppModel.routeAddress(host))\t\(statusText(live))")
        }
        return Exit.ok
    }

    /// The readiness chip's words, with the round trip when there is one.
    nonisolated static func statusText(_ live: HostLiveStatus?) -> String {
        let word = MenuBarPresentation.readiness(live?.state, fresh: true) ?? "Unavailable"
        guard let rtt = live?.rttMs, live?.state != .asleep else { return word }
        return "\(word) · \(rtt) ms"
    }

    /// /serverinfo first, so a pairing or trust failure is named as one;
    /// then the live /applist over the same pinned connection.
    private static func listApps(on host: Host, csv: Bool, model: AppModel) async -> Int32 {
        let info = model.nativeServerInfo(for: host)
        guard info.serverCertPEM != nil else {
            printError(notPairedMessage(host))
            return Exit.notPaired
        }
        let client = NetworkClient(server: info)
        let apps: [HostApp]
        do {
            _ = try await client.fetchServerInfo()
            apps = try await client.appList()
            await client.shutdown()
        } catch {
            await client.shutdown()
            let code = exitCode(for: error)
            let text = message(for: error, host: host)
            printError(code == Exit.failed ? "Couldn't list the apps on \(host.displayName): \(text)" : text)
            return code
        }
        if csv {
            print(csvHeader)
            apps.forEach { print(csvRow($0)) }
        } else {
            apps.filter { !$0.hidden }.forEach { print($0.name) }
        }
        return Exit.ok
    }

    nonisolated static let csvHeader = "Name,ID,HDR Support,Hidden"

    nonisolated static func csvRow(_ app: HostApp) -> String {
        let name = "\"" + app.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return "\(name),\(app.id),\(app.hdrCapable),\(app.hidden)"
    }
}
