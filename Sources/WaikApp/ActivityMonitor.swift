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

    var watchedProcesses: Set<String> = []

    private let resolver = ResolverCache()
    private var previousSnapshot: [String: ScannedConnection] = [:]
    private var timer: Timer?
    private let pollInterval: TimeInterval = 2.0

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

        for conn in connections {
            guard conn.remotePort == 443 else { continue }

            let key = "\(conn.pid)-\(conn.remoteAddress):\(conn.remotePort)"
            let prev = previousSnapshot[key]
            let bytesAdvanced = (prev != nil) && (prev!.bytesInBuffer != conn.bytesInBuffer)

            let nameMatch = watchedProcesses.contains(conn.processName)
            let ipMatch = knownIPs.contains(conn.remoteAddress)

            let active: Bool
            if nameMatch {
                active = true
            } else if ipMatch && (prev == nil || bytesAdvanced) {
                active = true
            } else {
                active = false
            }

            if active {
                detection = DetectionInfo(
                    timestamp: now,
                    pid: conn.pid,
                    processName: conn.processName,
                    remoteAddress: conn.remoteAddress,
                    remoteHost: resolver.hostFor(ip: conn.remoteAddress)
                )
                break
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
            lastDetection = detection
        }
    }
}
