//
//  GlimmerMain.swift
//
//  The process entry point. A bare word in argv[1] runs the `glimmer` command
//  line headlessly; anything else (no arguments, --launched-at-login, -psn_*,
//  -NS*, Xcode and test arguments) starts the app exactly as before.
//

import Darwin
import Foundation

@main
@MainActor
enum GlimmerMain {
    static func main() {
        reexecIfSymlinked()
        guard GlimmerCLI.isInvocation(CommandLine.arguments) else {
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
