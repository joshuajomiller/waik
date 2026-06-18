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

        // If the bundle has changed since we last registered, the LWCR (content
        // hash) launchd cached now points at a bundle that no longer exists,
        // and the daemon enters a 10s respawn-fail loop forever. `register()`
        // is a no-op when "already registered," so the stale entry sticks.
        // Unregister first so the next register picks up the new bundle.
        if bundleFingerprintChanged() {
            do {
                try service.unregister()
                logger.info("Unregistered stale daemon registration")
            } catch {
                // Stale registration may already be invalid (the bundle it
                // referenced is gone). Pressing on with register() below is
                // still the right move — the unregister is best-effort.
                logger.warning("Unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            try service.register()
            logger.info("Registered daemon")
            recordBundleFingerprint()
        } catch {
            logger.error("Register failed: \(error.localizedDescription, privacy: .public)")
        }
        return mapStatus(service.status)
    }

    private static let fingerprintKey = "com.waik.helper.lastRegisteredFingerprint"

    /// Returns true when the running app's bundle path or build number differs
    /// from the one we last registered the daemon under. Either changing
    /// indicates the bundle launchd has cached is no longer the one on disk.
    ///
    /// A missing prior also counts: it's either a true first launch (cheap
    /// unregister no-ops) or a first launch with this code on a machine that
    /// already has a stale registration from an older waik build — in which
    /// case forcing the refresh is exactly what we want.
    private func bundleFingerprintChanged() -> Bool {
        let current = currentBundleFingerprint()
        let prior = UserDefaults.standard.string(forKey: Self.fingerprintKey)
        return prior != current
    }

    private func recordBundleFingerprint() {
        UserDefaults.standard.set(currentBundleFingerprint(), forKey: Self.fingerprintKey)
    }

    private func currentBundleFingerprint() -> String {
        let path = Bundle.main.bundleURL.path
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        return "\(path)#\(build)"
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
        // If the daemon isn't registered, the XPC call would queue a message
        // launchd will never deliver — and on the termination path the sync
        // variant would block waiting for a reply. Bail early.
        guard daemonReachable() else {
            logger.info("setSleepDisabled(\(disabled, privacy: .public)) skipped — daemon not enabled")
            return
        }
        let conn = connectionOrReconnect()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("XPC error: \(error.localizedDescription, privacy: .public)")
        } as? WaikHelperProtocol
        proxy?.setSleepDisabled(disabled) { [logger] result in
            logger.info("setSleepDisabled(\(disabled, privacy: .public)) returned \(result, privacy: .public)")
        }
    }

    /// Termination-path variant: send the message and wait up to `timeout`
    /// seconds for the helper to acknowledge before returning.
    ///
    /// We can't use `synchronousRemoteObjectProxyWithErrorHandler` here — if
    /// the daemon's launchd registration is stale (e.g., the bundle was
    /// replaced by a Sparkle update and the old LWCR UUID no longer resolves),
    /// the helper enters a 10s respawn-throttle loop and never answers. The
    /// sync proxy would then block the main thread until macOS's terminate
    /// watchdog SIGKILLs us — observed as a ~20s "hang on quit" in the wild.
    ///
    /// Instead: async proxy, semaphore wait with a hard ceiling. Better to
    /// leak the `SleepDisabled` flag for one boot than hang termination.
    func setSleepDisabledAndWait(_ disabled: Bool, timeout: TimeInterval = 1.5) {
        guard daemonReachable() else {
            logger.info("setSleepDisabledAndWait(\(disabled, privacy: .public)) skipped — daemon not enabled")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        let conn = connectionOrReconnect()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("XPC error (sync): \(error.localizedDescription, privacy: .public)")
            sem.signal()
        } as? WaikHelperProtocol
        proxy?.setSleepDisabled(disabled) { [logger] result in
            logger.info("setSleepDisabled(\(disabled, privacy: .public)) [sync] returned \(result, privacy: .public)")
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            logger.warning("setSleepDisabledAndWait(\(disabled, privacy: .public)) timed out after \(timeout, privacy: .public)s; daemon unreachable")
        }
    }

    private func daemonReachable() -> Bool {
        let svc = SMAppService.daemon(plistName: WaikConstants.helperPlistName)
        return svc.status == .enabled
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
