import Foundation

enum PreferenceKey {
    static let watchedProcesses = "watchedProcesses"
    static let batteryGuardEnabled = "batteryGuardEnabled"
    static let batteryGuardThreshold = "batteryGuardThreshold"
    static let onboardingCompleted = "onboardingCompleted"
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

    static let windowSeconds: TimeInterval = 45

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

    static let defaultBatteryGuardThreshold: Int = 20

    static var batteryGuardEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.batteryGuardEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.batteryGuardEnabled) }
    }

    static var batteryGuardThreshold: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: PreferenceKey.batteryGuardThreshold)
            return v > 0 ? v : defaultBatteryGuardThreshold
        }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.batteryGuardThreshold) }
    }

    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.onboardingCompleted) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.onboardingCompleted) }
    }
}
