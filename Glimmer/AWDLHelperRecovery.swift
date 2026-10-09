import Foundation

/// Registration status can survive deletion of its launchd job. Only launchd's
/// explicit missing-service result permits replacing registration before release.
enum AWDLHelperRecovery {
    static func daemonJobMissing() async -> Bool {
        await Task.detached(priority: .utility) {
            await withCheckedContinuation { continuation in
                let once = SingleResume(continuation)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["print", "system/" + glimmerHelperMachServiceName]
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                process.terminationHandler = { process in
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    once.resume(confirmsMissingJob(status: process.terminationStatus,
                                                   error: String(data: data, encoding: .utf8) ?? ""))
                }
                do {
                    try process.run()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if once.resume(false), process.isRunning { process.terminate() }
                    }
                } catch {
                    once.resume(false)
                }
            }
        }.value
    }

    static func confirmsMissingJob(status: Int32?, error: String) -> Bool {
        status == 113 && error.contains(
            "Could not find service \"" + glimmerHelperMachServiceName + "\" in domain for system")
    }
}
