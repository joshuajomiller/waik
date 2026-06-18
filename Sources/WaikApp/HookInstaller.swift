import Foundation
import os

/// Stable, app-bundle-independent path that hook entries point at. The actual
/// `waik-hook` binary lives inside `waik.app/Contents/MacOS/`, but bundle paths
/// change whenever the user moves the .app or rebuilds at a different
/// location. Pointing hooks at a fixed user-domain path and refreshing the
/// binary there on every launch means hooks survive bundle relocation.
@MainActor
enum HookLauncher {
    static var stableURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("waik", isDirectory: true)
            .appendingPathComponent("waik-hook", isDirectory: false)
    }

    /// Copy the current bundle's `waik-hook` into the stable launcher path.
    /// Idempotent — same byte-identical contents are a no-op. Called once per
    /// launch from `AppCoordinator.init`. Returns silently on any I/O failure;
    /// the worst case is a stale stable copy, which the user already has if
    /// they haven't relaunched.
    static func refreshFromBundle() {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let source = exe.deletingLastPathComponent().appendingPathComponent("waik-hook")
        guard FileManager.default.isExecutableFile(atPath: source.path) else { return }

        let target = stableURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Fast path: skip copy if the destination already matches the
            // bundle copy byte-for-byte. Avoids touching mtime on no-op
            // relaunches and avoids needlessly invalidating a running
            // child invocation that might be reading the same file.
            if let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
               let dstAttrs = try? fm.attributesOfItem(atPath: target.path),
               let srcSize = srcAttrs[.size] as? NSNumber,
               let dstSize = dstAttrs[.size] as? NSNumber,
               srcSize == dstSize {
                if let srcData = try? Data(contentsOf: source),
                   let dstData = try? Data(contentsOf: target),
                   srcData == dstData {
                    return
                }
            }

            // Atomic replace: write to a sibling tmp, then rename. macOS
            // `replaceItemAt` handles "destination doesn't exist yet" by
            // moving the tmp into place.
            let tmp = target.appendingPathExtension("refresh-tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tmp.path
            )
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
        } catch {
            // Stale stable copy is acceptable; surfacing the error to the
            // user during launch would be more noise than signal.
        }
    }
}

/// Installs and removes waik's agent hooks in the per-tool config files.
///
/// **Claude Code** (`~/.claude/settings.json`): mutates the `hooks` object,
/// tagging every entry we own with `_waik: true` for clean uninstall.
///
/// **Codex CLI** (`~/.codex/config.toml`): rewrites the root `notify = [...]`
/// line to point at a generated bash chain wrapper that forwards events both
/// to waik-hook and to whatever notify program the user previously had set.
/// Restoring is just rewriting the line back to the saved original.
@MainActor
final class HookInstaller {
    private let logger = Logger(subsystem: "com.waik.app", category: "hook-installer")

    enum ToolStatus: Equatable {
        case notInstalled
        case installed
        case mismatched(String)  // user-edited or partially installed
        case unavailable(String) // config file not present / unreadable
    }

    /// Where installed hook commands point. Always the stable launcher path
    /// — bundle paths get refreshed on every launch ([HookLauncher.refreshFromBundle]),
    /// so this remains valid even if the user moves the .app.
    private static func waikHookBinaryPath() -> String? {
        let path = HookLauncher.stableURL.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - Public API

    func status(tool: String) -> ToolStatus {
        switch tool {
        case "claude": return claudeStatus()
        case "codex": return codexStatus()
        case "cursor": return cursorStatus()
        default: return .unavailable("unknown tool")
        }
    }

    @discardableResult
    func install(tool: String) -> Result<Void, Error> {
        switch tool {
        case "claude": return claudeInstall()
        case "codex": return codexInstall()
        case "cursor": return cursorInstall()
        default: return .failure(HookInstallerError.unsupportedTool(tool))
        }
    }

    @discardableResult
    func uninstall(tool: String) -> Result<Void, Error> {
        switch tool {
        case "claude": return claudeUninstall()
        case "codex": return codexUninstall()
        case "cursor": return cursorUninstall()
        default: return .failure(HookInstallerError.unsupportedTool(tool))
        }
    }

    // MARK: - Claude Code

    private static let claudeEvents: [(eventKey: String, waikEvent: String)] = [
        ("UserPromptSubmit", "turn_start"),
        ("Stop", "turn_end"),
        ("SubagentStop", "subagent_end"),
        ("Notification", "waiting_for_input"),
    ]

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func claudeStatus() -> ToolStatus {
        let url = Self.claudeSettingsURL
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable("no ~/.claude/settings.json")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else {
            return .notInstalled
        }
        var present = 0
        for (event, _) in Self.claudeEvents {
            if let arr = hooks[event] as? [Any], arr.contains(where: { Self.isWaikClaudeEntry($0) }) {
                present += 1
            }
        }
        if present == Self.claudeEvents.count { return .installed }
        if present == 0 { return .notInstalled }
        return .mismatched("\(present)/\(Self.claudeEvents.count) hook(s) installed")
    }

    private func claudeInstall() -> Result<Void, Error> {
        guard let bin = Self.waikHookBinaryPath() else {
            return .failure(HookInstallerError.binaryNotFound)
        }
        let url = Self.claudeSettingsURL
        let parentDir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            }
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            for (event, waikEvent) in Self.claudeEvents {
                var entries = (hooks[event] as? [Any]) ?? []
                entries.removeAll { Self.isWaikClaudeEntry($0) }
                let entry: [String: Any] = [
                    "_waik": true,
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(bin)\" claude \(waikEvent)",
                        ]
                    ],
                ]
                entries.append(entry)
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try Self.atomicWriteJSON(root, to: url)
            logger.info("Claude hooks installed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func claudeUninstall() -> Result<Void, Error> {
        let url = Self.claudeSettingsURL
        guard
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .success(())  // nothing to remove
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            return .success(())
        }
        for (event, _) in Self.claudeEvents {
            guard var entries = hooks[event] as? [Any] else { continue }
            entries.removeAll { Self.isWaikClaudeEntry($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        do {
            try Self.atomicWriteJSON(root, to: url)
            logger.info("Claude hooks removed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func isWaikClaudeEntry(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any] else { return false }
        return (dict["_waik"] as? Bool) == true
    }

    // MARK: - Cursor

    // Cursor 1.7+ ships a `~/.cursor/hooks.json` lifecycle-hook surface that
    // covers both the IDE and the Cursor CLI. waik only needs the two events
    // that bracket a turn:
    //   beforeSubmitPrompt — fires after the user hits send, before the
    //                        backend request → turn_start
    //   stop               — fires when the agent loop ends → turn_end
    // There is no equivalent of Claude's `Notification` event for "waiting on
    // the user," so we don't try to emit `waiting_for_input` for Cursor; the
    // assertion simply drops when `stop` fires.
    private static let cursorEvents: [(eventKey: String, waikEvent: String)] = [
        ("beforeSubmitPrompt", "turn_start"),
        ("stop", "turn_end"),
    ]

    private static var cursorHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    private func cursorStatus() -> ToolStatus {
        let url = Self.cursorHooksURL
        guard let data = try? Data(contentsOf: url) else {
            return .notInstalled
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else {
            return .notInstalled
        }
        var present = 0
        for (event, _) in Self.cursorEvents {
            if let arr = hooks[event] as? [Any], arr.contains(where: { Self.isWaikCursorEntry($0) }) {
                present += 1
            }
        }
        if present == Self.cursorEvents.count { return .installed }
        if present == 0 { return .notInstalled }
        return .mismatched("\(present)/\(Self.cursorEvents.count) hook(s) installed")
    }

    private func cursorInstall() -> Result<Void, Error> {
        guard let bin = Self.waikHookBinaryPath() else {
            return .failure(HookInstallerError.binaryNotFound)
        }
        let url = Self.cursorHooksURL
        let parentDir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            var root: [String: Any] = ["version": 1]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
                if root["version"] == nil { root["version"] = 1 }
            }
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            for (event, waikEvent) in Self.cursorEvents {
                var entries = (hooks[event] as? [Any]) ?? []
                entries.removeAll { Self.isWaikCursorEntry($0) }
                let entry: [String: Any] = [
                    "_waik": true,
                    "type": "command",
                    "command": "\"\(bin)\" cursor \(waikEvent)",
                ]
                entries.append(entry)
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try Self.atomicWriteJSON(root, to: url)
            logger.info("Cursor hooks installed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func cursorUninstall() -> Result<Void, Error> {
        let url = Self.cursorHooksURL
        guard
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .success(())
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            return .success(())
        }
        for (event, _) in Self.cursorEvents {
            guard var entries = hooks[event] as? [Any] else { continue }
            entries.removeAll { Self.isWaikCursorEntry($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        do {
            try Self.atomicWriteJSON(root, to: url)
            logger.info("Cursor hooks removed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Identify entries waik owns. Primary marker is `_waik: true`; we also
    /// match by command prefix as a fallback in case a future Cursor version
    /// strips unknown JSON fields.
    private static func isWaikCursorEntry(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any] else { return false }
        if (dict["_waik"] as? Bool) == true { return true }
        if let cmd = dict["command"] as? String {
            let needle = "\"\(HookLauncher.stableURL.path)\" cursor "
            if cmd.hasPrefix(needle) { return true }
        }
        return false
    }

    // MARK: - Codex CLI

    private static var codexConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    private static var codexWrapperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("waik", isDirectory: true)
            .appendingPathComponent("codex-notify.sh", isDirectory: false)
    }

    private static var codexBackupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("waik", isDirectory: true)
            .appendingPathComponent("codex-notify-original.json", isDirectory: false)
    }

    private func codexStatus() -> ToolStatus {
        let url = Self.codexConfigURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .unavailable("no ~/.codex/config.toml")
        }
        let (notify, _) = Self.findRootNotifyLine(in: text)
        guard let arr = notify.flatMap(Self.parseNotifyArray) else { return .notInstalled }
        if let first = arr.first, first == Self.codexWrapperURL.path {
            return .installed
        }
        return .notInstalled
    }

    private func codexInstall() -> Result<Void, Error> {
        guard let bin = Self.waikHookBinaryPath() else {
            return .failure(HookInstallerError.binaryNotFound)
        }
        let configURL = Self.codexConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .failure(HookInstallerError.codexConfigMissing)
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .failure(HookInstallerError.codexConfigUnreadable)
        }

        // Capture user's existing notify so uninstall can restore it.
        let (existingLine, _) = Self.findRootNotifyLine(in: text)
        let originalArray: [String] = existingLine.flatMap(Self.parseNotifyArray) ?? []
        // Don't double-wrap: if existing notify already points at our wrapper,
        // treat install as a refresh and keep whatever backup we previously
        // saved.
        let isAlreadyWrapped = originalArray.first == Self.codexWrapperURL.path

        let backupURL = Self.codexBackupURL
        if !isAlreadyWrapped {
            do {
                try FileManager.default.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let backupData = try JSONSerialization.data(
                    withJSONObject: ["notify": originalArray],
                    options: [.prettyPrinted]
                )
                try backupData.write(to: backupURL, options: .atomic)
            } catch {
                return .failure(error)
            }
        }

        // Determine which "original" the wrapper should chain to. If we're
        // refreshing, read it from our backup (the value in config.toml at
        // refresh time IS our wrapper, not the user's real notify).
        var chainTo: [String] = originalArray
        if isAlreadyWrapped, let data = try? Data(contentsOf: backupURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["notify"] as? [String] {
            chainTo = arr
        }

        do {
            try writeCodexWrapper(waikHookPath: bin, chainTo: chainTo)
        } catch {
            return .failure(error)
        }

        let newLine = "notify = [\"\(Self.codexWrapperURL.path)\"]"
        let rewritten = Self.replaceOrInsertRootNotify(in: text, with: newLine)

        do {
            let tmp = configURL.appendingPathExtension("waik-tmp")
            try rewritten.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
            logger.info("Codex notify wrapper installed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func codexUninstall() -> Result<Void, Error> {
        let configURL = Self.codexConfigURL
        let backupURL = Self.codexBackupURL
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .success(())
        }

        var restoredArr: [String] = []
        if let data = try? Data(contentsOf: backupURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["notify"] as? [String] {
            restoredArr = arr
        }

        let rewritten: String
        if restoredArr.isEmpty {
            rewritten = Self.removeRootNotify(in: text)
        } else {
            let restoredLine = "notify = [" + restoredArr.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            rewritten = Self.replaceOrInsertRootNotify(in: text, with: restoredLine)
        }

        do {
            let tmp = configURL.appendingPathExtension("waik-tmp")
            try rewritten.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
            try? FileManager.default.removeItem(at: Self.codexWrapperURL)
            try? FileManager.default.removeItem(at: backupURL)
            logger.info("Codex notify wrapper removed")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func writeCodexWrapper(waikHookPath: String, chainTo: [String]) throws {
        let wrapperURL = Self.codexWrapperURL
        try FileManager.default.createDirectory(
            at: wrapperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let escapedHook = shellEscape(waikHookPath)
        let chainExec: String
        if chainTo.isEmpty {
            chainExec = ""
        } else {
            let cmd = shellEscape(chainTo[0])
            let staticArgs = chainTo.dropFirst().map(shellEscape).joined(separator: " ")
            chainExec = #"""
# Chain to the user's prior notify program.
exec \#(cmd) \#(staticArgs) "$@"
"""#
        }
        let script = #"""
#!/usr/bin/env bash
# Generated by waik. Forwards Codex notify events to waik-hook and then to
# the user's original notify program (if any). Codex appends the event JSON
# as the LAST argv; we inspect it to classify the event.
JSON="${@: -1}"
{
    case "$JSON" in
        *'"agent-turn-complete"'*)
            printf '%s' "$JSON" | \#(escapedHook) codex turn_end >/dev/null 2>&1 || true
            ;;
        *'"approval-requested"'*|*'"plan-mode-prompt"'*)
            printf '%s' "$JSON" | \#(escapedHook) codex waiting_for_input >/dev/null 2>&1 || true
            ;;
    esac
} &
\#(chainExec)
"""#
        let tmp = wrapperURL.appendingPathExtension("waik-tmp")
        try script.write(to: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(wrapperURL, withItemAt: tmp)
    }

    private func shellEscape(_ s: String) -> String {
        // Single-quote the string for bash; escape any embedded single quotes.
        let escaped = s.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
    }

    // MARK: - TOML root-notify hand-editing

    /// Find the root-level `notify = ...` line (before any `[section]` header).
    /// Returns (lineContents, lineIndex). Multi-line array values are NOT
    /// supported — most configs use the single-line form; if multi-line is
    /// detected, the caller treats this as "not installed".
    private static func findRootNotifyLine(in text: String) -> (String?, Int?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("[") { return (nil, nil) }  // entered a section
            if trimmed.hasPrefix("notify") {
                // Quick syntactic check: matches `notify[whitespace]=[whitespace][...`
                if let eq = trimmed.firstIndex(of: "=") {
                    let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                    if key == "notify" {
                        return (line, i)
                    }
                }
            }
        }
        return (nil, nil)
    }

    private static func parseNotifyArray(_ line: String) -> [String]? {
        // Extract between the first '[' and the last ']' on the line.
        guard let lb = line.firstIndex(of: "["), let rb = line.lastIndex(of: "]") else {
            return nil
        }
        let inner = line[line.index(after: lb)..<rb]
        // Naive scan: collect contents of each "..." double-quoted string.
        var out: [String] = []
        var current: String?
        var escape = false
        for ch in inner {
            if escape {
                current?.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if ch == "\"" {
                if current == nil {
                    current = ""
                } else {
                    out.append(current!)
                    current = nil
                }
                continue
            }
            if current != nil {
                current?.append(ch)
            }
        }
        return out
    }

    private static func replaceOrInsertRootNotify(in text: String, with newLine: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("[") { break }
            if trimmed.hasPrefix("notify") {
                if let eq = trimmed.firstIndex(of: "="),
                   trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "notify" {
                    lines[i] = newLine
                    replaced = true
                    break
                }
            }
        }
        if !replaced {
            // Insert at top — root keys must precede any section header.
            lines.insert(newLine, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func removeRootNotify(in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("[") { break }
            if trimmed.hasPrefix("notify") {
                if let eq = trimmed.firstIndex(of: "="),
                   trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "notify" {
                    lines.remove(at: i)
                    return lines.joined(separator: "\n")
                }
            }
        }
        return text
    }

    // MARK: - Atomic JSON writer

    private static func atomicWriteJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.appendingPathExtension("waik-tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

enum HookInstallerError: LocalizedError {
    case unsupportedTool(String)
    case binaryNotFound
    case codexConfigMissing
    case codexConfigUnreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let t): return "Unsupported tool: \(t)"
        case .binaryNotFound: return "waik-hook binary not found next to the app — rebuild or reinstall waik."
        case .codexConfigMissing: return "~/.codex/config.toml not found; install or launch Codex once first."
        case .codexConfigUnreadable: return "~/.codex/config.toml could not be read."
        }
    }
}
