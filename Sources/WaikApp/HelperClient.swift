import Foundation
import ServiceManagement
import WaikShared
import os

enum DaemonStatus: Sendable, Equatable {
    case unknown
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

@MainActor
final class HelperClient {
    private let logger = Logger(subsystem: "com.waik.app", category: "helper-client")
    private var connection: NSXPCConnection?

    func register() -> DaemonStatus {
        let service = SMAppService.daemon(plistName: WaikConstants.helperPlistName)
        do {
            try service.register()
            logger.info("Registered daemon")
        } catch {
            logger.error("Register failed: \(error.localizedDescription, privacy: .public)")
        }
        return mapStatus(service.status)
    }

    func status() -> DaemonStatus {
        let service = SMAppService.daemon(plistName: WaikConstants.helperPlistName)
        return mapStatus(service.status)
    }

    private func mapStatus(_ s: SMAppService.Status) -> DaemonStatus {
        switch s {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    func ping(_ completion: @escaping @Sendable (String?) -> Void) {
        let conn = connectionOrReconnect()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            completion(nil)
        } as? WaikHelperProtocol
        proxy?.ping { reply in completion(reply) }
    }

    func setSleepDisabled(_ disabled: Bool) {
        let conn = connectionOrReconnect()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("XPC error: \(error.localizedDescription, privacy: .public)")
        } as? WaikHelperProtocol
        proxy?.setSleepDisabled(disabled) { [logger] result in
            logger.info("setSleepDisabled(\(disabled, privacy: .public)) returned \(result, privacy: .public)")
        }
    }

    /// Blocking variant for use on the app-termination path, where an async
    /// message would be dropped when the process exits before XPC delivers it.
    /// The synchronous proxy runs the reply inline, so we don't return (and let
    /// the app finish quitting) until the helper has actually applied the change.
    func setSleepDisabledAndWait(_ disabled: Bool) {
        let conn = connectionOrReconnect()
        let proxy = conn.synchronousRemoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("XPC error (sync): \(error.localizedDescription, privacy: .public)")
        } as? WaikHelperProtocol
        proxy?.setSleepDisabled(disabled) { [logger] result in
            logger.info("setSleepDisabled(\(disabled, privacy: .public)) [sync] returned \(result, privacy: .public)")
        }
    }

    private func connectionOrReconnect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(
            machServiceName: WaikConstants.helperMachServiceName,
            options: .privileged
        )
        c.remoteObjectInterface = NSXPCInterface(with: WaikHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.logger.warning("XPC invalidated")
            }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.logger.warning("XPC interrupted")
            }
        }
        c.resume()
        connection = c
        return c
    }
}
