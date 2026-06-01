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
    public let detection: PendingDetection?
    public let sawTraffic: Bool
    public let nextSnapshot: [String: ScannedConnection]

    public init(
        detection: PendingDetection?,
        sawTraffic: Bool,
        nextSnapshot: [String: ScannedConnection]
    ) {
        self.detection = detection
        self.sawTraffic = sawTraffic
        self.nextSnapshot = nextSnapshot
    }
}

/// Pure decision logic for a single polling tick. Given the connection table
/// observed this tick and the snapshot from the previous tick, returns:
///   - `detection`: the first matching (watched-process × known-AI-host)
///     connection observed on port 443, or nil if no match
///   - `sawTraffic`: whether *real bytes* were observed moving on any matching
///     connection (a new connection or a non-empty / changed send/receive
///     buffer)
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
        var sawTraffic = false

        for conn in connections {
            guard conn.remotePort == monitoredPort else { continue }

            let key = snapshotKey(for: conn)
            let prev = previousSnapshot[key]
            let bytesAdvanced = prev.map { $0.bytesInBuffer != conn.bytesInBuffer } ?? false

            let nameMatch = watchedProcesses.contains(conn.processName)
            let ipMatch = knownIPs.contains(conn.remoteAddress)
            let active = nameMatch && ipMatch

            if active && (bytesAdvanced || prev == nil || conn.bytesInBuffer > 0) {
                sawTraffic = true
            }

            if active && detection == nil {
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
            sawTraffic: sawTraffic,
            nextSnapshot: nextSnapshot
        )
    }

    public static func snapshotKey(for conn: ScannedConnection) -> String {
        "\(conn.pid)-\(conn.remoteAddress):\(conn.remotePort)"
    }
}
