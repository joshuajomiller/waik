import XCTest
@testable import WaikCore

final class PollEvaluatorTests: XCTestCase {
    private let watched: Set<String> = ["claude", "Code Helper"]
    private let knownIPs: Set<String> = ["1.2.3.4", "5.6.7.8"]

    private func conn(
        pid: Int32 = 1000,
        name: String = "claude",
        ip: String = "1.2.3.4",
        port: UInt16 = 443,
        bytes: UInt32 = 0
    ) -> ScannedConnection {
        ScannedConnection(
            pid: pid,
            processName: name,
            remoteAddress: ip,
            remotePort: port,
            bytesInBuffer: bytes
        )
    }

    // MARK: - port filter

    func test_ignoresNonPort443() {
        let c = conn(port: 80)
        let r = PollEvaluator.evaluate(
            connections: [c],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertNil(r.detection)
        XCTAssertFalse(r.sawTraffic)
    }

    // MARK: - matching

    func test_noNameMatch_noDetection() {
        let c = conn(name: "Finder", bytes: 100)
        let r = PollEvaluator.evaluate(
            connections: [c],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertNil(r.detection)
        XCTAssertFalse(r.sawTraffic)
    }

    func test_noIPMatch_noDetection() {
        let c = conn(ip: "9.9.9.9", bytes: 100)
        let r = PollEvaluator.evaluate(
            connections: [c],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertNil(r.detection)
        XCTAssertFalse(r.sawTraffic)
    }

    func test_nameAndIPMatch_firstSighting_yieldsDetectionAndTraffic() {
        let c = conn()
        let r = PollEvaluator.evaluate(
            connections: [c],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertEqual(r.detection?.pid, 1000)
        XCTAssertEqual(r.detection?.processName, "claude")
        XCTAssertEqual(r.detection?.remoteAddress, "1.2.3.4")
        XCTAssertTrue(r.sawTraffic, "first sighting of a matching connection counts as traffic")
    }

    // MARK: - byte-delta heuristic

    func test_steadyZeroBytes_noTraffic() {
        let prev = conn(bytes: 0)
        let cur = conn(bytes: 0)
        let r = PollEvaluator.evaluate(
            connections: [cur],
            previousSnapshot: [PollEvaluator.snapshotKey(for: prev): prev],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertNotNil(r.detection, "identity is still detected even when idle")
        XCTAssertFalse(r.sawTraffic, "idle pooled connection must not count as traffic")
    }

    func test_byteDelta_yieldsTraffic() {
        let prev = conn(bytes: 0)
        let cur = conn(bytes: 1024)
        let r = PollEvaluator.evaluate(
            connections: [cur],
            previousSnapshot: [PollEvaluator.snapshotKey(for: prev): prev],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertTrue(r.sawTraffic)
    }

    func test_steadyNonZeroBuffer_yieldsTraffic() {
        let prev = conn(bytes: 512)
        let cur = conn(bytes: 512)
        let r = PollEvaluator.evaluate(
            connections: [cur],
            previousSnapshot: [PollEvaluator.snapshotKey(for: prev): prev],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertTrue(r.sawTraffic, "buffer with bytes still in flight counts as traffic")
    }

    // MARK: - multiple connections

    func test_firstMatchingConnection_wins() {
        let a = conn(pid: 1001, ip: "1.2.3.4")
        let b = conn(pid: 1002, ip: "5.6.7.8")
        let r = PollEvaluator.evaluate(
            connections: [a, b],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertEqual(r.detection?.pid, 1001)
    }

    func test_nonMatchingDoesNotBlockMatching() {
        let noise = conn(pid: 2000, name: "Finder", ip: "9.9.9.9", bytes: 9999)
        let real  = conn(pid: 3000)
        let r = PollEvaluator.evaluate(
            connections: [noise, real],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertEqual(r.detection?.pid, 3000)
        XCTAssertTrue(r.sawTraffic)
    }

    // MARK: - snapshot

    func test_nextSnapshotKeysEveryConnection() {
        let a = conn(pid: 1)
        let b = conn(pid: 2, port: 80)
        let r = PollEvaluator.evaluate(
            connections: [a, b],
            previousSnapshot: [:],
            watchedProcesses: watched,
            knownIPs: knownIPs
        )
        XCTAssertEqual(r.nextSnapshot.count, 2)
        XCTAssertEqual(r.nextSnapshot[PollEvaluator.snapshotKey(for: a)], a)
        XCTAssertEqual(r.nextSnapshot[PollEvaluator.snapshotKey(for: b)], b)
    }
}
