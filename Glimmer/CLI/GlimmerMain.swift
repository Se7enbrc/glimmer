// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  GlimmerMain.swift
//
//  The process entry point. Run as `glimmer`, or with a bare word in argv[1],
//  it's the command line; anything else (no arguments, --launched-at-login,
//  -psn_*, -NS*, Xcode and test arguments) starts the app; hosted tests skip its launch.
//

import GlimmerEngine
import AppKit
import Darwin
import Foundation

@main
@MainActor
enum GlimmerMain {
    static func main() {
        #if DEBUG
        // Launch Services can reopen a test app without its fixture environment.
        // Refuse before any production model or persistent storage is initialized.
        if Bundle.main.bundleIdentifier == "io.ugfugl.Glimmer.JourneyHost" {
            let environment = ProcessInfo.processInfo.environment
            guard environment["GLIMMER_UI_TESTING"] == "journey",
                  environment["GLIMMER_JOURNEY_DIRECTORY"] != nil else {
                FileHandle.standardError.write(Data("The isolated journey host requires its fixture environment.\n".utf8))
                exit(EX_USAGE)
            }
        }
        #endif
        _ = ResourceTelemetry.mainThreadID   // recorded here, on the main thread
        reexecIfSymlinked()
        guard GlimmerCLI.isInvocation(CommandLine.arguments) else {
            #if DEBUG
            if PersistentStorage.isTesting, ProcessInfo.processInfo.environment["GLIMMER_JOURNEY_DIRECTORY"] != nil {
                JourneyMacApp.main()
                return
            }
            #endif
            // The test host shares the app's defaults domain and must not run its launch.
            if PersistentStorage.isTesting {
                GlimmerApp.registerDefaults()
                NSApplication.shared.run()
                return
            }
            GlimmerApp.main()
            return
        }
        GlimmerCLI.start(arguments: Array(CommandLine.arguments.dropFirst()))
    }

    /// Run through a symlink (Homebrew's `glimmer`), Bundle.main and so the
    /// defaults domain resolve to the link's folder. Re-exec through the real
    /// path; argv is unchanged, so the verb still routes.
    private static func reexecIfSymlinked() {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0,
              let path = buffer.withUnsafeBufferPointer({ $0.baseAddress.map { String(cString: $0) } }),
              let real = realPathIfDifferent(path) else { return }
        execv(real, CommandLine.unsafeArgv)
    }

    /// The fully resolved path when it differs from `path`, else nil.
    nonisolated static func realPathIfDifferent(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real == path ? nil : real
    }
}
