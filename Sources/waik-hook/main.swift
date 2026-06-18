// waik-hook: tiny CLI invoked from Claude Code hooks, Codex notify, and
// Cursor hooks.
//
// Usage:
//   waik-hook claude turn_start
//   waik-hook claude turn_end
//   waik-hook claude waiting_for_input
//   waik-hook claude subagent_end
//   waik-hook codex turn_end
//   waik-hook codex waiting_for_input
//   waik-hook cursor turn_start
//   waik-hook cursor turn_end
//
// Reads ~/Library/Application Support/waik/control.port for the running app's
// port + token, then POSTs the event to http://127.0.0.1:<port>/event. If the
// file is missing or the connection fails, exits 0 silently — the agent must
// not be blocked by waik being absent.

import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { exit(0) }
let tool = args[1]
let event = args[2]

let home = FileManager.default.homeDirectoryForCurrentUser
let controlURL = home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("waik", isDirectory: true)
    .appendingPathComponent("control.port", isDirectory: false)

guard let raw = try? String(contentsOf: controlURL, encoding: .utf8) else { exit(0) }
let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
guard lines.count >= 2 else { exit(0) }
let port = lines[0].trimmingCharacters(in: .whitespaces)
let token = lines[1].trimmingCharacters(in: .whitespaces)
guard !port.isEmpty, !token.isEmpty, UInt16(port) != nil else { exit(0) }

// Read JSON payload from stdin if a hook piped one in. Claude Code hooks emit
// JSON with `session_id`, `cwd`, etc. Codex's notify wrapper pipes Codex's own
// JSON event payload to stdin.
var bodyJSON: [String: Any] = [:]
if isatty(fileno(stdin)) == 0 {
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    if !stdinData.isEmpty,
       let parsed = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
        bodyJSON = parsed
    }
}

let sessionId =
    (bodyJSON["session_id"] as? String)
    ?? (bodyJSON["turn-id"] as? String)
    ?? (bodyJSON["turn_id"] as? String)
    ?? (bodyJSON["conversation_id"] as? String)
    ?? "unknown"

let cwd =
    (bodyJSON["cwd"] as? String)
    ?? (bodyJSON["workspace_roots"] as? [String])?.first
    ?? FileManager.default.currentDirectoryPath

let payload: [String: Any] = [
    "tool": tool,
    "event": event,
    "session_id": sessionId,
    "cwd": cwd,
]

guard
    let body = try? JSONSerialization.data(withJSONObject: payload),
    let url = URL(string: "http://127.0.0.1:\(port)/event")
else { exit(0) }

var req = URLRequest(url: url, timeoutInterval: 1.0)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.setValue(token, forHTTPHeaderField: "X-Waik-Token")
req.httpBody = body

let sem = DispatchSemaphore(value: 0)
let task = URLSession.shared.dataTask(with: req) { _, _, _ in
    sem.signal()
}
task.resume()
_ = sem.wait(timeout: .now() + 1.0)
exit(0)
