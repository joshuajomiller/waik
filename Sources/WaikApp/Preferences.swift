import Foundation

enum PreferenceKey {
    static let disabledProcesses = "disabledProcesses"
    static let batteryGuardEnabled = "batteryGuardEnabled"
    static let batteryGuardThreshold = "batteryGuardThreshold"
    static let onboardingCompleted = "onboardingCompleted"
    // Legacy keys cleared on launch.
    static let legacyWindowSeconds = "windowSeconds"
    static let legacyWatchedProcesses = "watchedProcesses"
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
    ]

    static let windowSeconds: TimeInterval = 45

    static func clearLegacyKeys() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyWindowSeconds)
        // Earlier versions let users edit the watchlist freely. We've since
        // narrowed the model to "toggle each default on/off" — drop the
        // legacy free-form list so old custom entries don't linger.
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyWatchedProcesses)
    }

    /// User-disabled subset of `defaultWatchedProcesses`. Storing the disabled
    /// set (rather than the enabled set) means new defaults shipped in future
    /// versions are auto-enabled for existing users.
    static var disabledProcesses: Set<String> {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: PreferenceKey.disabledProcesses) {
                return Set(arr)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: PreferenceKey.disabledProcesses)
        }
    }

    /// The effective watchlist passed to `ActivityMonitor` — defaults minus
    /// anything the user has explicitly disabled.
    static var watchedProcesses: Set<String> {
        Set(defaultWatchedProcesses).subtracting(disabledProcesses)
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
