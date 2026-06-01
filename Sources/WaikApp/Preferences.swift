import Foundation

enum PreferenceKey {
    static let watchedProcesses = "watchedProcesses"
    // Legacy keys cleared on launch.
    static let legacyWindowSeconds = "windowSeconds"
}

enum Preferences {
    // Names here are matched against the kernel-recorded comm name (truncated
    // to 16 chars), which is what `ps -o comm` shows. Keep them ≤16 chars.
    static let defaultWatchedProcesses: [String] = [
        "claude",
        "codex",
        "Cursor",
        "Cursor Helper",
        "zed",
        "Code Helper",
        "Claude",
        "ChatGPT",
    ]

    static let windowSeconds: TimeInterval = 30

    static func clearLegacyKeys() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyWindowSeconds)
    }

    static var watchedProcesses: Set<String> {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: PreferenceKey.watchedProcesses) {
                return Set(arr)
            }
            return Set(defaultWatchedProcesses)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: PreferenceKey.watchedProcesses)
        }
    }
}
