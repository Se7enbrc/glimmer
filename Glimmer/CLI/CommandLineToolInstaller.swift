//  CommandLineToolInstaller.swift
//  Glimmer › Install Command Line Tool…: links `glimmer` into /usr/local/bin for
//  installs Homebrew didn't make, after the administrator prompt macOS shows.

import AppKit

@MainActor
enum CommandLineToolInstaller {

    nonisolated static let linkPath = "/usr/local/bin/glimmer"

    /// Where a `glimmer` link on the default PATH already sits: Homebrew's, then ours.
    nonisolated static let knownLinks = ["/opt/homebrew/bin/glimmer", linkPath]

    static func install() {
        guard let executable = Bundle.main.executablePath else { return }
        if let existing = existingLink(to: executable) {
            show("The glimmer command is already installed.",
                 detail: "It's at \(existing). Run glimmer help in Terminal to see what it can do.")
            return
        }
        // A copy run from a disk image or Downloads moves or vanishes; the link would dangle.
        guard isInApplications(Bundle.main.bundlePath) else {
            show("Move Glimmer to Applications first.",
                 detail: "The command runs this copy of Glimmer, so it needs to stay where it is.")
            return
        }
        var error: NSDictionary?
        NSAppleScript(source: linkScript(to: executable))?.executeAndReturnError(&error)
        if let error {
            // -128: the administrator prompt was cancelled.
            guard (error[NSAppleScript.errorNumber] as? Int) != -128 else { return }
            let reason = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            Diag.warn("Install Command Line Tool failed: \(reason, privacy: .private)", "CLI")
            show("Couldn't install the glimmer command.", detail: "Try again with an administrator account.")
            return
        }
        show("The glimmer command is installed.", detail: "Run glimmer help in Terminal to see what it can do.")
    }

    /// The first known link that resolves to this executable, if any.
    nonisolated static func existingLink(to executable: String, among candidates: [String] = knownLinks) -> String? {
        let target = resolved(executable) ?? executable
        return candidates.first { resolved($0) == target }
    }

    nonisolated static func isInApplications(_ bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }

    /// `do shell script` with the path quoted once for the shell and once for AppleScript.
    nonisolated static func linkScript(to executable: String) -> String {
        let shellQuoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted) \(linkPath)"
        let appleScriptQuoted = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(appleScriptQuoted)\" with administrator privileges"
    }

    private nonisolated static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
