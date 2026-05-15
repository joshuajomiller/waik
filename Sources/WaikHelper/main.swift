import Foundation
import WaikShared
import os

let logger = Logger(subsystem: WaikConstants.helperLabel, category: "main")

// If we exit for any reason, make sure we don't leave the system un-sleepable.
atexit {
    _ = setSleepDisabledRaw(false)
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig) { _ in
        _ = setSleepDisabledRaw(false)
        _exit(0)
    }
}

logger.info("waik-helper \(WaikConstants.version, privacy: .public) starting")

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: WaikConstants.helperMachServiceName)
listener.delegate = delegate
listener.resume()

logger.info("Listening on \(WaikConstants.helperMachServiceName, privacy: .public)")

RunLoop.main.run()
