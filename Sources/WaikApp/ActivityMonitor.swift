import Foundation
import Combine
import os
import CProcInfo
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
    // After observing real activity, keep `trafficActive` true for this long
    // even if subsequent polls don't catch movement.
    private let trafficLingerSeconds: TimeInterval = 3.0
    private var lastTrafficAt: Date?
    private var pollInFlight = false

    // CPU-delta signal. `sbi_cc` (kernel TCP buffer occupancy) reads zero
    // continuously on streaming SSE connections because both the kernel and
    // userspace drain the buffer faster than any sampling rate we can afford
    // — verified empirically with 5Hz probes returning maxBuf=0 mid-stream.
    // Cumulative CPU time, in contrast, monotonically increases whenever the
    // watched process does real work (decoding tokens, redrawing TUI,
    // dispatching tool calls).
    //
    // Threshold: a watched process consuming more than `cpuDeltaThresholdNs`
    // nanoseconds of CPU per second of wall clock (= 0.5%) is considered
    // active. Idle Claude Code waiting for input typically sits well below
    // this; streaming a response easily exceeds it.
    private let cpuDeltaThresholdNsPerSec: UInt64 = 5_000_000  // 0.5% CPU
    private var lastCPUSample: (pid: Int32, cpuNs: UInt64, at: Date)? = nil

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTick()
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
    private func scheduleTick() {
        // Drop overlapping ticks. A previous scan still running means the
        // machine is slow under load — queuing more would only worsen it.
        guard !pollInFlight else { return }
        pollInFlight = true

        let watched = watchedProcesses
        let prevSnapshot = previousSnapshot
        let resolver = self.resolver

        Task.detached(priority: .utility) { [weak self] in
            let connections = SocketScanner.scan()
            let knownIPs = resolver.knownIPs

            // If a watched process is talking on 443 to an IP we don't yet
            // know, kick the resolver. CDN failover and host rotation can
            // otherwise leave us blind for up to the scheduled 5-minute tick.
            let hasUnknownWatchedIP = connections.contains { conn in
                conn.remotePort == PollEvaluator.monitoredPort
                    && watched.contains(conn.processName)
                    && !knownIPs.contains(conn.remoteAddress)
            }
            if hasUnknownWatchedIP {
                resolver.requestRefresh()
            }

            let result = PollEvaluator.evaluate(
                connections: connections,
                previousSnapshot: prevSnapshot,
                watchedProcesses: watched,
                knownIPs: knownIPs
            )
            var cpuNs: UInt64 = 0
            if let pid = result.detection?.pid {
                cpuNs = waik_pid_cpu_ns(pid)
            }
            await self?.commit(result: result, cpuNs: cpuNs, at: Date())
        }
    }

    private func commit(result: PollResult, cpuNs: UInt64, at now: Date) {
        defer { pollInFlight = false }
        previousSnapshot = result.nextSnapshot

        if let pending = result.detection {
            // CPU-delta is the primary activity signal — see the field comment
            // on `cpuDeltaThresholdNsPerSec` for why `sbi_cc` cannot stand on
            // its own. `result.sawTraffic` still wins on first sighting of a
            // new connection (prev==nil → considered traffic) so the keep-awake
            // engages immediately when a connection opens, before we have a
            // CPU sample to compare against.
            var cpuActive = false
            if let prev = lastCPUSample,
               prev.pid == pending.pid,
               cpuNs > prev.cpuNs
            {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0 {
                    let deltaNs = cpuNs - prev.cpuNs
                    let thresholdNs = UInt64(elapsed * Double(cpuDeltaThresholdNsPerSec))
                    cpuActive = deltaNs >= thresholdNs
                }
            }
            if cpuNs > 0 {
                lastCPUSample = (pending.pid, cpuNs, now)
            }

            if result.sawTraffic || cpuActive {
                lastActivityAt = now
                lastTrafficAt = now
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
        } else {
            // No matching connection — drop the CPU baseline so a future
            // re-detection of a different PID doesn't see a stale delta.
            lastCPUSample = nil
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
