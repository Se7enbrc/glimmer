// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

/// Owns the child through reaping, so timeout signals cannot target a reused PID.
/// A kernel-stuck child keeps this worker blocked; no later mutation may overtake it.
enum AWDLProcess {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let timedOut: Bool
        let truncated: Bool
        var succeeded: Bool { status == 0 && !timedOut && !truncated }
    }

    static func run(arguments: [String], executable: String = "/sbin/ifconfig",
                    timeout: Duration = .seconds(2), grace: Duration = .milliseconds(250),
                    outputLimit: Int = 65_536, captureErrors: Bool = false) -> Result? {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        for index in descriptors.indices where descriptors[index] < 3 {
            let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
            guard replacement >= 0 else {
                descriptors.forEach { close($0) }
                return nil
            }
            close(descriptors[index])
            descriptors[index] = replacement
        }
        defer { close(descriptors[0]) }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptors[1])
            return nil
        }
        let child = spawn(executable: executable, arguments: arguments, descriptors: descriptors, captureErrors: captureErrors)
        close(descriptors[1])
        guard let child else { return nil }
        return collect(child: child, descriptor: descriptors[0], timeout: timeout,
                       grace: grace, outputLimit: max(0, outputLimit))
    }

    private static func spawn(executable: String, arguments: [String], descriptors: [Int32], captureErrors: Bool) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        [SIGTERM, SIGINT, SIGPIPE, SIGCHLD].forEach { sigaddset(&defaults, $0) }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              !captureErrors || posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else { return nil }
        let argv = ([executable] + arguments).map { strdup($0) }
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"].map { (value: String) in strdup(value) }
        defer { (argv + environment).forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { return nil }
        var child: pid_t = 0
        let status = (argv + [nil]).withUnsafeBufferPointer { arguments in
            (environment + [nil]).withUnsafeBufferPointer { environment in
                posix_spawn(&child, executable, &actions, &attributes, arguments.baseAddress, environment.baseAddress)
            }
        }
        return status == 0 ? child : nil
    }

    private static func collect(child: pid_t, descriptor: Int32, timeout: Duration,
                                grace: Duration, outputLimit: Int) -> Result? {
        let deadline = ContinuousClock.now + timeout
        var killDeadline: ContinuousClock.Instant?
        var killed = false
        var timedOut = false
        var output = Data()
        var truncated = false
        var status: Int32 = 0
        while true {
            drain(descriptor, into: &output, limit: outputLimit, truncated: &truncated)
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child {
                drain(descriptor, into: &output, limit: outputLimit, truncated: &truncated)
                return Result(status: status, output: output, timedOut: timedOut, truncated: truncated)
            }
            // ECHILD means no live child remains to mutate the interface; fail closed.
            if waited < 0, errno == ECHILD { return nil }
            let now = ContinuousClock.now
            if !timedOut, now >= deadline {
                timedOut = true
                killDeadline = now + grace
                _ = kill(child, SIGTERM)
            } else if !killed, let killDeadline, now >= killDeadline {
                killed = true
                _ = kill(child, SIGKILL)
            }
            usleep(10_000)
        }
    }

    private static func drain(_ descriptor: Int32, into output: inout Data,
                              limit: Int, truncated: inout Bool) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Bound each drain so a continuously writing child cannot starve its deadline.
        for _ in 0..<16 {
            let count = read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            let retained = min(count, limit - output.count)
            output.append(contentsOf: bytes.prefix(retained))
            if retained < count { truncated = true }
        }
    }
}
