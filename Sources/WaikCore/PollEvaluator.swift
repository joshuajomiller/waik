import Foundation

public struct PendingDetection: Sendable, Equatable {
    public let pid: Int32
    public let processName: String
    public let remoteAddress: String

    public init(pid: Int32, processName: String, remoteAddress: String) {
        self.pid = pid
        self.processName = processName
        self.remoteAddress = remoteAddress
    }
}

public struct PollResult: Sendable, Equatable {
    /// The "primary" match used for UI display (prefers an IP-confirmed
    /// connection to a known AI host so the hostname surfaces). When the
    /// only matches are name-only (e.g. Cursor's rotating AWS pool), this
    /// falls back to the first such match.
    public let detection: PendingDetection?
    /// PIDs of every watched process observed with an established port-443
    /// connection this tick. ActivityMonitor samples CPU for *all* of them,
    /// not just `detection.pid`, so that activity on a secondary watched
    /// process (e.g. Cursor Helper streaming behind codex) still refreshes
    /// the keep-awake window.
    public let matchedPIDs: Set<Int32>
    public let sawTraffic: Bool
    public let nextSnapshot: [String: ScannedConnection]

    public init(
        detection: PendingDetection?,
        matchedPIDs: Set<Int32>,
        sawTraffic: Bool,
        nextSnapshot: [String: ScannedConnection]
    ) {
        self.detection = detection
        self.matchedPIDs = matchedPIDs
        self.sawTraffic = sawTraffic
        self.nextSnapshot = nextSnapshot
    }
}

/// Pure decision logic for a single polling tick. Given the connection table
/// observed this tick and the snapshot from the previous tick, returns:
///   - `detection`: the first established port-443 connection owned by a
///     watched process, or nil if no match. Matching is name-only; the CPU
///     delta gate in `ActivityMonitor` filters out non-AI traffic from named
///     processes (Electron telemetry sockets etc. don't burn enough CPU to
///     trip it). Strict IP matching was abandoned because Cursor's AWS-ELB
///     pool rotates faster than `getaddrinfo` can keep up.
///   - `sawTraffic`: heuristic for "real bytes moved" (new connection or a
///     changed send/receive buffer). Mostly only useful on first sighting —
///     `sbi_cc` reads zero on streaming SSE connections.
///   - `nextSnapshot`: the connection table keyed for the next tick's diff
public enum PollEvaluator {
    public static let monitoredPort: UInt16 = 443

    public static func evaluate(
        connections: [ScannedConnection],
        previousSnapshot: [String: ScannedConnection],
        watchedProcesses: Set<String>,
        knownIPs: Set<String>
    ) -> PollResult {
        var detection: PendingDetection? = nil
        var matchedPIDs: Set<Int32> = []
        var sawTraffic = false

        for conn in connections {
            guard conn.remotePort == monitoredPort else { continue }

            let key = snapshotKey(for: conn)
            let prev = previousSnapshot[key]
            let bytesAdvanced = prev.map { $0.bytesInBuffer != conn.bytesInBuffer } ?? false

            // Prefer a connection to a known AI host so the displayed
            // detection carries a recognizable hostname, but accept any
            // 443 connection from a watched process as a candidate.
            guard watchedProcesses.contains(conn.processName) else { continue }
            let ipMatch = knownIPs.contains(conn.remoteAddress)

            matchedPIDs.insert(conn.pid)

            if bytesAdvanced || prev == nil || conn.bytesInBuffer > 0 {
                sawTraffic = true
            }

            // First name-only match seeds detection; a later name+IP match
            // upgrades it so the UI gets the recognizable hostname.
            let currentIsNameOnly = detection.map { !knownIPs.contains($0.remoteAddress) } ?? false
            if detection == nil || (ipMatch && currentIsNameOnly) {
                detection = PendingDetection(
                    pid: conn.pid,
                    processName: conn.processName,
                    remoteAddress: conn.remoteAddress
                )
            }
        }

        var nextSnapshot: [String: ScannedConnection] = [:]
        nextSnapshot.reserveCapacity(connections.count)
        for conn in connections {
            nextSnapshot[snapshotKey(for: conn)] = conn
        }

        return PollResult(
            detection: detection,
            matchedPIDs: matchedPIDs,
            sawTraffic: sawTraffic,
            nextSnapshot: nextSnapshot
        )
    }

    public static func snapshotKey(for conn: ScannedConnection) -> String {
        "\(conn.pid)-\(conn.remoteAddress):\(conn.remotePort)"
    }
}
