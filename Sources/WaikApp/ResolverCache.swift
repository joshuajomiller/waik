import Foundation
import Darwin

final class ResolverCache: @unchecked Sendable {
    static let defaultHostnames: [String] = [
        "api.anthropic.com",
        "api.openai.com",
        "chatgpt.com",
        "generativelanguage.googleapis.com",
        // Cursor's gateway endpoints. The AWS-backed `api2` rotates across
        // an ELB pool so a single getaddrinfo() rarely covers the live IP,
        // but a resolved entry is still useful for hostFor() display when
        // it does land. The matching itself is name+CPU, not name+IP.
        "api2.cursor.sh",
        "api3.cursor.sh",
        "api.cursor.sh",
        "repo42.cursor.sh",
        "cursor.sh",
    ]

    private let hostnames: [String]
    private let queue = DispatchQueue(label: "com.waik.resolver")
    private var ipToHost: [String: String] = [:]
    private var refreshTimer: DispatchSourceTimer?
    private var lastRefreshAt: Date? = nil
    // Floor between manual refresh requests. The scheduled timer fires every
    // 5min regardless; this only debounces eager refreshes triggered by an
    // unknown-IP cache miss so a burst of new connections can't flood DNS.
    private let manualRefreshCooldown: TimeInterval = 15.0

    init(hostnames: [String] = ResolverCache.defaultHostnames) {
        self.hostnames = hostnames
        refresh()
        startTimer()
    }

    var knownIPs: Set<String> {
        queue.sync { Set(self.ipToHost.keys) }
    }

    func hostFor(ip: String) -> String? {
        queue.sync { self.ipToHost[ip] }
    }

    /// Request an out-of-band DNS refresh. Coalesces requests so multiple
    /// callers in quick succession trigger at most one round of `getaddrinfo`.
    func requestRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if let last = self.lastRefreshAt,
               Date().timeIntervalSince(last) < self.manualRefreshCooldown {
                return
            }
            self.refresh()
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshTimer = timer
    }

    private func refresh() {
        let names = hostnames
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var updated: [String: String] = [:]
            for h in names {
                for ip in Self.resolve(h) {
                    updated[ip] = h
                }
            }
            self.queue.async {
                self.ipToHost = updated
                self.lastRefreshAt = Date()
            }
        }
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>? = nil
        let err = getaddrinfo(host, "443", &hints, &result)
        if err != 0 { return [] }
        defer { freeaddrinfo(result) }

        var ips: [String] = []
        var cursor = result
        while let ai = cursor {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let family = ai.pointee.ai_family
            if family == AF_INET, let saPtr = ai.pointee.ai_addr {
                let sa = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var addr = sa.sin_addr
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                ips.append(String(cString: buf))
            } else if family == AF_INET6, let saPtr = ai.pointee.ai_addr {
                let sa = saPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var addr = sa.sin6_addr
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                ips.append(String(cString: buf))
            }
            cursor = ai.pointee.ai_next
        }
        return ips
    }
}
