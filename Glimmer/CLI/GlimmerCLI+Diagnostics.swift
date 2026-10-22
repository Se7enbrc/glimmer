// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin
import GlimmerEngine

extension GlimmerCLI {
    static func diagnostics(_ command: Command, source: URL = MacTelemetryCapture.logsDirectory) async -> Int32 {
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
                printLine("Keep the stream running for the six-second clock check, followed by one 30-second detailed recording.")
                printLine("Scheduling export and analysis afterward may take several more minutes.")
                printLine("Keep this terminal open. Capture files remain local in \(output.path).")
                let manifestURL = try await captureWithSignals(pid: pid, output: output, options: options)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(GlimmerDiagnosticCapture.Manifest.self,
                                                   from: Data(contentsOf: manifestURL))
                printLine("Capture: \(manifest.status). Evidence: \(manifestURL.path)")
                return manifest.status == "observed_rows_with_bounded_clock_anchors" ? Exit.ok : Exit.failed
            case "bundle":
                let manifestURL = try await Task.detached(priority: .utility) {
                    try DiagnosticEvidence.bundle(sessionID: identity, source: source, output: output)
                }.value
                struct Completion: Decodable { let complete: Bool }
                guard let data = GlimmerDiagnosticCapture.boundedRead(manifestURL, maximum: 4_194_304) else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let report = try JSONDecoder().decode(Completion.self, from: data)
                let status = report.complete ? "complete" : "incomplete"
                printLine("Evidence \(status): \(manifestURL.path). Read summary.md for missing evidence.")
                return report.complete ? Exit.ok : Exit.failed
            default:
                printError("Use “diagnostics capture <pid> <directory>” or “diagnostics bundle <session> <directory>”.")
                return Exit.usage
            }
        } catch {
            printError("Diagnostic operation failed: \(error.localizedDescription)")
            return Exit.failed
        }
    }

    private static func captureWithSignals(pid: Int32, output: URL, options: URL) async throws -> URL {
        let task = Task {
            try await GlimmerDiagnosticCapture.run(pid: pid, output: output, recordingOptions: options,
                progress: { message in Task { @MainActor in printLine(message) } })
        }
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            signal(SIGINT, oldInterrupt)
            signal(SIGTERM, oldTerminate)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}
