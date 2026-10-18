// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

extension GlimmerCLI {
    static func diagnostics(_ command: Command) async -> Int32 {
        let action = command.arguments[0]
        let identity = command.arguments[1]
        let output = URL(fileURLWithPath: (command.arguments[2] as NSString).expandingTildeInPath,
                         isDirectory: true)
        do {
            switch action {
            case "capture":
                guard let pid = Int32(identity), pid > 0,
                      let options = Bundle.main.url(forResource: "hitch-recording-options", withExtension: "json") else {
                    printError("Supply a running Glimmer PID and use the installed app's diagnostic command.")
                    return Exit.usage
                }
                printLine("Recording 15 minutes. Exporting scheduling evidence afterward can take up to 20 minutes.")
                printLine("Keep this terminal open. Capture files remain local in \(output.path).")
                let manifestURL = try await GlimmerDiagnosticCapture.run(pid: pid, output: output,
                                                                         recordingOptions: options)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(GlimmerDiagnosticCapture.Manifest.self,
                                                   from: Data(contentsOf: manifestURL))
                printLine("Capture: \(manifest.status). Evidence: \(manifestURL.path)")
                return manifest.status == "observed_row_bounds_verified" ? Exit.ok : Exit.failed
            case "bundle":
                let source = MacTelemetryCapture.logsDirectory
                let manifestURL = try await Task.detached(priority: .utility) {
                    try DiagnosticEvidence.bundle(sessionID: identity, source: source, output: output)
                }.value
                printLine("Evidence saved: \(manifestURL.path). Read summary.md for coverage and missing evidence.")
                return Exit.ok
            default:
                printError("Use “diagnostics capture <pid> <directory>” or “diagnostics bundle <session> <directory>”.")
                return Exit.usage
            }
        } catch {
            printError("Diagnostic operation failed: \(error.localizedDescription)")
            return Exit.failed
        }
    }
}
