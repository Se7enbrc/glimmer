//
//  GlimmerMain.swift
//
//  The process entry point. Run as `glimmer`, or with a bare word in argv[1],
//  it's the command line; anything else (no arguments, --launched-at-login,
//  -psn_*, -NS*, Xcode and test arguments) starts the app; hosted tests skip its launch.
//

import AppKit
import Darwin
import Foundation

@main
@MainActor
enum GlimmerMain {
    static func main() {
        reexecIfSymlinked()
        guard GlimmerCLI.isInvocation(CommandLine.arguments) else {
            // The test host shares the app's defaults domain and must not run its launch.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
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
