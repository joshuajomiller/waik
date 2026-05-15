import Foundation
import WaikShared
import os

final class HelperService: NSObject, WaikHelperProtocol {
    private let logger = Logger(subsystem: WaikConstants.helperLabel, category: "service")

    func ping(reply: @escaping (String) -> Void) {
        reply("waik-helper \(WaikConstants.version)")
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Int32) -> Void) {
        let result = setSleepDisabledRaw(disabled)
        logger.info("setSleepDisabled(\(disabled, privacy: .public)) = \(result, privacy: .public)")
        reply(result)
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: WaikConstants.helperLabel, category: "listener")

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        let teamID = ProcessInfo.processInfo.environment["WAIK_TEAM_ID"] ?? ""
        if #available(macOS 13.0, *), !teamID.isEmpty {
            let req = "anchor apple generic and identifier \"\(WaikConstants.appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
            conn.setCodeSigningRequirement(req)
        }

        conn.exportedInterface = NSXPCInterface(with: WaikHelperProtocol.self)
        conn.exportedObject = HelperService()
        conn.invalidationHandler = { [weak self] in
            self?.logger.info("Connection invalidated")
        }
        conn.interruptionHandler = { [weak self] in
            self?.logger.info("Connection interrupted")
        }
        conn.resume()
        logger.info("Accepted new XPC connection")
        return true
    }
}
