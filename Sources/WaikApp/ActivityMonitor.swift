import Foundation
import Combine
import os

struct DetectionInfo: Sendable, Equatable {
    let timestamp: Date
    let pid: Int32
    let processName: String
    let remoteAddress: String
    let remoteHost: String?
}

@MainActor
final class ActivityMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.waik.app", category: "monitor")

    @Published private(set) var lastDetection: DetectionInfo? = nil
    @Published private(set) var trafficActive: Bool = false

    // Updated every poll while a watched connection is live. Read by the
    // coordinator's reconcile timer; intentionally NOT @Published — pushing a
    // new Date every second would invalidate the MenuBarExtra body and
    // collapse any open submenu.
    private(set) var lastActivityAt: Date? = nil

    var watchedProcesses: Set<String> = []

    private let resolver = ResolverCache()
    private var previousSnapshot: [String: ScannedConnection] = [:]
    private var timer: Timer?
    private let pollInterval: TimeInterval = 1.0
    // After observing live traffic on a matched connection, keep `trafficActive`
    // true for this long even if subsequent polls don't catch a non-zero buffer.
    // Bridges the gap when sbi_cc happens to be 0 at sample time.
    private let trafficLingerSeconds: TimeInterval = 3.0
    private var lastTrafficAt: Date?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        logger.info("ActivityMonitor started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousSnapshot.removeAll()
        logger.info("ActivityMonitor stopped")
    }

    private func poll() {
        let connections = SocketScanner.scan()
        let knownIPs = resolver.knownIPs
        let now = Date()

        var detection: DetectionInfo? = nil
        var sawTraffic = false

        for conn in connections {
            guard conn.remotePort == 443 else { continue }

            let key = "\(conn.pid)-\(conn.remoteAddress):\(conn.remotePort)"
            let prev = previousSnapshot[key]
            let bytesAdvanced = (prev != nil) && (prev!.bytesInBuffer != conn.bytesInBuffer)

            let nameMatch = watchedProcesses.contains(conn.processName)
            let ipMatch = knownIPs.contains(conn.remoteAddress)

            // A connection counts as "an AI agent task" only when BOTH:
            //   1. The process is on the watchlist (claude/codex/ChatGPT/...)
            //   2. The remote IP is in the resolver cache for a known AI host.
            //
            // We deliberately do NOT trigger on either signal alone:
            //  - Name-only would false-positive on Electron IDEs (Cursor, Zed)
            //    whose helpers keep idle telemetry/sync sockets to their own
            //    backends.
            //  - IP-only would false-positive on every other service sharing
            //    Fastly/Cloudflare edge IPs (e.g. Google Drive hitting
            //    160.79.104.10) or any Google product, since
            //    `generativelanguage.googleapis.com` resolves into Google's
            //    general IP space (142.250.x.x).
            let active = nameMatch && ipMatch

            // Traffic indicator: any active connection with bytes in flight.
            // sbi_cc is current buffer occupancy (not cumulative) and is drained
            // fast, so accept fresh deltas or first-sighting as evidence too.
            if active && (bytesAdvanced || prev == nil || conn.bytesInBuffer > 0) {
                sawTraffic = true
            }

            if active && detection == nil {
                detection = DetectionInfo(
                    timestamp: now,
                    pid: conn.pid,
                    processName: conn.processName,
                    remoteAddress: conn.remoteAddress,
                    remoteHost: resolver.hostFor(ip: conn.remoteAddress)
                )
            }
        }

        var nextSnapshot: [String: ScannedConnection] = [:]
        nextSnapshot.reserveCapacity(connections.count)
        for conn in connections {
            let key = "\(conn.pid)-\(conn.remoteAddress):\(conn.remotePort)"
            nextSnapshot[key] = conn
        }
        previousSnapshot = nextSnapshot

        if let detection {
            lastActivityAt = now
            let identityChanged = lastDetection.map {
                $0.pid != detection.pid
                    || $0.processName != detection.processName
                    || $0.remoteAddress != detection.remoteAddress
            } ?? true
            if identityChanged {
                lastDetection = detection
            }
        }

        if sawTraffic {
            lastTrafficAt = now
        }
        let nextTrafficActive: Bool
        if let last = lastTrafficAt {
            nextTrafficActive = now.timeIntervalSince(last) < trafficLingerSeconds
        } else {
            nextTrafficActive = false
        }
        if trafficActive != nextTrafficActive {
            trafficActive = nextTrafficActive
        }
    }
}
