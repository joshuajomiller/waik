import Foundation

enum PreferenceKey {
    static let windowSeconds = "windowSeconds"
    static let watchedProcesses = "watchedProcesses"
}

enum Preferences {
    static let defaultWatchedProcesses: [String] = [
        "claude",
        "codex",
        "cursor",
        "Cursor Helper (Renderer)",
        "Cursor Helper",
        "zed",
        "Code Helper (Renderer)",
        "Claude",
        "ChatGPT",
    ]

    static let defaultWindowSeconds: TimeInterval = 120

    static var windowSeconds: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: PreferenceKey.windowSeconds)
            return v > 0 ? v : defaultWindowSeconds
        }
        set {
            UserDefaults.standard.set(newValue, forKey: PreferenceKey.windowSeconds)
        }
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
