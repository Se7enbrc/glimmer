// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os.log

// Exercises executable authorization without privilege or interface changes.
if CommandLine.arguments.dropFirst().elementsEqual(["--check-launch"]) { exit(0) }

let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "main")
os_log("Glimmer helper starting (pid %d)", log: log, type: .info, getpid())

if getuid() != 0 {
    os_log("Helper must run as root", log: log, type: .error)
    exit(1)
}

let suppressor = AWDLSuppressor()
suppressor.start()

let listener = NSXPCListener(machServiceName: glimmerHelperMachServiceName)
// The OS checks every peer's code signature before the delegate sees it, so
// only our signed app can ever reach HelperService.
listener.setConnectionCodeSigningRequirement(HelperService.designatedRequirement)
let service = HelperService(suppressor: suppressor)
listener.delegate = service
listener.resume()

os_log("Glimmer helper listening on %{public}@", log: log, type: .info, glimmerHelperMachServiceName)

RunLoop.main.run()
