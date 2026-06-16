import Foundation
import Network
import Combine
import os

/// Loopback HTTP listener for agent hook events. Binds 127.0.0.1 on a
/// kernel-assigned ephemeral port (collision-proof) and publishes a control
/// file under `~/Library/Application Support/waik/control.port` containing
/// the chosen port and a per-launch shared-secret token. The `waik-hook`
/// CLI reads that file on each invocation and POSTs `/event` with the token.
///
/// The server is intentionally minimal: a hand-rolled HTTP/1.1 parser tuned
/// for the shape of requests `waik-hook` actually sends. Anything else
/// (keep-alive, chunked transfer, large bodies, GETs) is rejected. There's
/// no reason to take on a real HTTP stack to ferry ~120-byte JSON locally.
@MainActor
final class HookServer: ObservableObject {
    private let logger = Logger(subsystem: "com.waik.app", category: "hook-server")

    struct Session: Equatable, Identifiable {
        let tool: String
        let id: String
        let cwd: String?
        let startedAt: Date
    }

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var port: UInt16 = 0

    var anyRunning: Bool { !sessions.isEmpty }

    private var listener: NWListener?
    private var token: String = ""
    private var gcTimer: Timer?
    /// Sessions older than this with no terminating event are GC'd. A turn
    /// that legitimately runs longer than this is rare; a stuck session
    /// from a missed `Stop` hook is the failure mode worth bounding.
    private let sessionTtl: TimeInterval = 3600

    private static let controlFileDir: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support.appendingPathComponent("waik", isDirectory: true)
    }()

    static var controlFileURL: URL {
        controlFileDir.appendingPathComponent("control.port", isDirectory: false)
    }

    func start() {
        guard listener == nil else { return }
        let tok = Self.randomToken()
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: .any)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.onListenerStateChange(state)
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                Task { @MainActor in
                    self.handle(conn)
                }
            }
            l.start(queue: .global(qos: .utility))
            self.listener = l
            self.token = tok
            startGcTimer()
        } catch {
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func onListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let p = listener?.port?.rawValue {
                self.port = p
                writeControlFile(port: p, token: token)
                logger.info("Listening on 127.0.0.1:\(p, privacy: .public)")
            }
        case .failed(let err):
            logger.error("Listener failed: \(err.localizedDescription, privacy: .public)")
        case .cancelled:
            logger.info("Listener cancelled")
        default: break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        gcTimer?.invalidate()
        gcTimer = nil
        try? FileManager.default.removeItem(at: Self.controlFileURL)
        sessions.removeAll()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receiveRequest(on: conn, accumulated: Data())
    }

    /// Receives request bytes on the connection's background queue. Anything
    /// that mutates `sessions` or otherwise touches actor state hops via
    /// `Task { @MainActor }` before doing so.
    nonisolated private func receiveRequest(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error = error {
                Task { @MainActor in
                    self.respond(conn, status: 400, body: "read error: \(error.localizedDescription)")
                }
                return
            }
            var buf = accumulated
            if let d = data { buf.append(d) }

            guard let headerEnd = Self.findHeaderEnd(buf) else {
                if isComplete {
                    Task { @MainActor in
                        self.respond(conn, status: 400, body: "incomplete request")
                    }
                } else {
                    self.receiveRequest(on: conn, accumulated: buf)
                }
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd)
            let bodyStart = headerEnd + 4
            let bodyAlreadyRead = buf.count - bodyStart

            guard let parsed = HookRequest.parse(headerData: headerData) else {
                Task { @MainActor in
                    self.respond(conn, status: 400, body: "bad request")
                }
                return
            }

            let contentLen = parsed.contentLength
            if bodyAlreadyRead >= contentLen {
                let body = buf.subdata(in: bodyStart..<(bodyStart + contentLen))
                Task { @MainActor in
                    self.dispatch(parsed: parsed, body: body, conn: conn)
                }
            } else {
                self.receiveBody(
                    on: conn,
                    parsed: parsed,
                    needed: contentLen - bodyAlreadyRead,
                    accumulated: buf.subdata(in: bodyStart..<buf.count)
                )
            }
        }
    }

    nonisolated private func receiveBody(on conn: NWConnection, parsed: HookRequest, needed: Int, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let d = data { buf.append(d) }
            let got = data?.count ?? 0
            let remaining = needed - got
            if remaining <= 0 {
                Task { @MainActor in
                    self.dispatch(parsed: parsed, body: buf, conn: conn)
                }
            } else {
                self.receiveBody(on: conn, parsed: parsed, needed: remaining, accumulated: buf)
            }
        }
    }

    nonisolated private static func findHeaderEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            let upper = data.count - 4
            for i in 0...upper {
                if p[i] == 0x0d && p[i+1] == 0x0a && p[i+2] == 0x0d && p[i+3] == 0x0a {
                    return i
                }
            }
            return nil
        }
    }

    private func dispatch(parsed: HookRequest, body: Data, conn: NWConnection) {
        guard parsed.token == token else {
            respond(conn, status: 401, body: "unauthorized")
            return
        }
        guard parsed.method == "POST", parsed.path == "/event" else {
            respond(conn, status: 404, body: "not found")
            return
        }
        guard let event = HookEvent.parse(body) else {
            respond(conn, status: 400, body: "bad event")
            return
        }
        apply(event)
        respond(conn, status: 204, body: "")
    }

    private func apply(_ event: HookEvent) {
        let key = "\(event.tool)/\(event.sessionId)"
        switch event.event {
        case .turn_start:
            sessions[key] = Session(
                tool: event.tool,
                id: event.sessionId,
                cwd: event.cwd,
                startedAt: Date()
            )
            logger.info("turn_start \(event.tool, privacy: .public)/\(event.sessionId, privacy: .public)")
        case .turn_end, .waiting_for_input:
            sessions.removeValue(forKey: key)
            logger.info("session done \(event.tool, privacy: .public)/\(event.sessionId, privacy: .public)")
        case .subagent_end:
            // Parent turn still alive; ignore for state.
            logger.debug("subagent_end \(event.tool, privacy: .public)/\(event.sessionId, privacy: .public)")
        }
    }

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let reason = Self.httpReason(status)
        let payload = body.data(using: .utf8) ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var resp = head.data(using: .utf8) ?? Data()
        resp.append(payload)
        conn.send(content: resp, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func httpReason(_ status: Int) -> String {
        switch status {
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "OK"
        }
    }

    // MARK: - Control file + token

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeControlFile(port: UInt16, token: String) {
        let url = Self.controlFileURL
        let dir = Self.controlFileDir
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let tmp = dir.appendingPathComponent("control.port.tmp", isDirectory: false)
            let content = "\(port)\n\(token)\n"
            try content.write(to: tmp, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            logger.error("control file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - GC

    private func startGcTimer() {
        let t = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.gcStale() }
        }
        RunLoop.main.add(t, forMode: .common)
        gcTimer = t
    }

    private func gcStale() {
        let cutoff = Date().addingTimeInterval(-sessionTtl)
        let stale = sessions.filter { $0.value.startedAt < cutoff }
        if !stale.isEmpty {
            for k in stale.keys { sessions.removeValue(forKey: k) }
            logger.info("Garbage-collected \(stale.count, privacy: .public) stale session(s)")
        }
    }
}

// MARK: - Request parsing

private struct HookRequest {
    let method: String
    let path: String
    let contentLength: Int
    let token: String?

    static func parse(headerData: Data) -> HookRequest? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var contentLength = 0
        var token: String? = nil
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "content-length":
                contentLength = Int(value) ?? 0
            case "x-waik-token":
                token = value
            default:
                continue
            }
        }
        return HookRequest(method: method, path: path, contentLength: contentLength, token: token)
    }
}

// MARK: - Event model

struct HookEvent {
    enum Kind: String, Decodable {
        case turn_start
        case turn_end
        case waiting_for_input
        case subagent_end
    }
    let tool: String
    let event: Kind
    let sessionId: String
    let cwd: String?

    static func parse(_ body: Data) -> HookEvent? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let tool = obj["tool"] as? String,
            let eventStr = obj["event"] as? String,
            let kind = Kind(rawValue: eventStr),
            let sessionId = obj["session_id"] as? String
        else { return nil }
        let cwd = obj["cwd"] as? String
        return HookEvent(tool: tool, event: kind, sessionId: sessionId, cwd: cwd)
    }
}
