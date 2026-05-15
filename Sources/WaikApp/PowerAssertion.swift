import Foundation
import IOKit
import IOKit.pwr_mgt
import os

final class PowerAssertion {
    private let logger = Logger(subsystem: "com.waik.app", category: "power")
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func acquire(reason: String) {
        guard !held else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            held = true
            logger.info("IOPMAssertion acquired id=\(id, privacy: .public)")
        } else {
            logger.error("IOPMAssertion failed: \(result)")
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
        logger.info("IOPMAssertion released")
    }

    deinit {
        if held {
            IOPMAssertionRelease(assertionID)
        }
    }
}
