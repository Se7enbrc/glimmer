import Foundation
import os.log

let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "main")
os_log("Glimmer helper starting (pid %d)", log: log, type: .info, getpid())

if getuid() != 0 {
    os_log("Helper must run as root", log: log, type: .error)
    exit(1)
}

let suppressor = AWDLSuppressor()
suppressor.start()

let listener = NSXPCListener(machServiceName: GlimmerHelperMachServiceName)
let service = HelperService(suppressor: suppressor)
listener.delegate = service
listener.resume()

os_log("Glimmer helper listening on %{public}@", log: log, type: .info, GlimmerHelperMachServiceName)

RunLoop.main.run()
