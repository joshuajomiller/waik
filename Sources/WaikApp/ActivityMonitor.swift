import Foundation
import Combine
import os
import WaikCore

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

    // Why name+IP must both match: see the matching rationale documented on
    // `PollEvaluator.evaluate`. Briefly — name-only false-positives on Electron
    // IDE telemetry sockets; IP-only false-positives on every Fastly/Cloudflare
    // tenant sharing edges with the AI providers.
    private func poll() {
        let connections = SocketScanner.scan()
        let knownIPs = resolver.knownIPs
        let now = Date()

        let result = PollEvaluator.evaluate(
            connections: connections,
            previousSnapshot: previousSnapshot,
            watchedProcesses: watchedProcesses,
            knownIPs: knownIPs
        )
        previousSnapshot = result.nextSnapshot

        if let pending = result.detection {
            // Only refresh the keep-awake window on real byte movement.
            // Bare existence of an idle pooled HTTPS connection to an AI host
            // would otherwise pin the window forever (Claude Code keeps such
            // sockets open between requests).
            if result.sawTraffic {
                lastActivityAt = now
            }
            let identityChanged = lastDetection.map {
                $0.pid != pending.pid
                    || $0.processName != pending.processName
                    || $0.remoteAddress != pending.remoteAddress
            } ?? true
            if identityChanged {
                lastDetection = DetectionInfo(
                    timestamp: now,
                    pid: pending.pid,
                    processName: pending.processName,
                    remoteAddress: pending.remoteAddress,
                    remoteHost: resolver.hostFor(ip: pending.remoteAddress)
                )
            }
        }

        if result.sawTraffic {
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
