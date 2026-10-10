import Foundation

/// Confirm launchd state before replacing a service that cannot acknowledge release.
enum AWDLHelperRecovery {
    enum Layout: Equatable, Sendable {
        case current, legacyActive, legacyIdle, missing, unknown
    }

    static func daemonJobMissing() async -> Bool {
        await daemonLayout() == .missing
    }

    static func daemonLayout() async -> Layout {
        let result = await Task.detached(priority: .utility) {
            AWDLProcess.run(arguments: ["print", "system/" + glimmerHelperMachServiceName],
                            executable: "/bin/launchctl", captureErrors: true)
        }.value
        guard let result, !result.timedOut, !result.truncated, result.status & 0x7f == 0 else { return .unknown }
        return layout(status: result.status >> 8, output: String(data: result.output, encoding: .utf8) ?? "")
    }

    static func layout(status: Int32?, output: String) -> Layout {
        if confirmsMissingJob(status: status, error: output) { return .missing }
        guard status == 0, output.hasPrefix("system/" + glimmerHelperMachServiceName + " = {") else { return .unknown }
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().components(separatedBy: " = ")
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let current = "Contents/Library/LaunchServices/Glimmer Network Helper.app/Contents/MacOS/" + glimmerHelperMachServiceName
        if fields["program identifier"] == current + " (mode: 2)" { return .current }
        guard fields["program identifier"] == "Contents/MacOS/" + glimmerHelperMachServiceName + " (mode: 2)" else {
            return .unknown
        }
        // A clean idle exit follows confirmed restoration; a never-run job has no work to release.
        if fields["state"] == "not running", fields["active count"] == "0", fields["pid"] == nil,
           fields["last terminating signal"] == nil,
           fields["last exit code"] == "0" || fields["runs"] == "0" { return .legacyIdle }
        return .legacyActive
    }

    @MainActor static func prepareMigration(layout: () async -> Layout,
                                            release: () async -> Bool, sleep: (Duration) async throws -> Void,
                                            keepCurrent: () async -> Bool = { true },
                                            maxReleases: Int = 30) async -> Bool {
        // Bounded: an unreachable helper or unparseable launchctl must not stall setup forever.
        for _ in 0..<maxReleases {
            switch await layout() {
            case .missing, .legacyIdle: return true
            case .current:
                if await keepCurrent() { return false }
                fallthrough
            case .legacyActive, .unknown:
                if await release() { return true }
                try? await sleep(.seconds(1))
            }
        }
        Diag.notice("AWDL helper release unconfirmed after \(maxReleases) tries; replacing", "Stream")
        return true
    }

    static func confirmsMissingJob(status: Int32?, error: String) -> Bool {
        status == 113 && error.contains(
            "Could not find service \"" + glimmerHelperMachServiceName + "\" in domain for system")
    }
}
