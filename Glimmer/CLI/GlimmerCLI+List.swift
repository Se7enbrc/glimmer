//
//  GlimmerCLI+List.swift
//
//  `glimmer list [--csv]`: the paired PCs with the launcher's live status, and
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
        // One PC at a time: a handful of 2-second probes at most. The status
        // is the launcher chip's own words, untruncated.
        let csv = command.flags.contains("--csv")
        if csv { print(pcCSVHeader) }
        for host in model.hosts {
            let live = await probe(host, model: model)
            let fields = [host.displayName, AppModel.routeAddress(host), ChipPresentation(live: live).fullLabel]
            print(csv ? fields.map(csvField).joined(separator: ",") : fields.joined(separator: "\t"))
        }
        return Exit.ok
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
    nonisolated static let pcCSVHeader = "Name,Address,Status"

    nonisolated static func csvRow(_ app: HostApp) -> String {
        "\(csvField(app.name)),\(app.id),\(app.hdrCapable),\(app.hidden)"
    }

    /// Quoted, with inner quotes doubled, so commas and quotes in a name survive.
    nonisolated static func csvField(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
