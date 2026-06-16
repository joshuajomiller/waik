import Foundation

enum PreferenceKey {
    static let disabledTools = "disabledTools"
    static let batteryGuardEnabled = "batteryGuardEnabled"
    static let batteryGuardThreshold = "batteryGuardThreshold"
    static let onboardingCompleted = "onboardingCompleted"
    // Legacy keys cleared on launch.
    static let legacyWindowSeconds = "windowSeconds"
    static let legacyWatchedProcesses = "watchedProcesses"
    static let legacyDisabledProcesses = "disabledProcesses"
}

enum Preferences {
    /// Tools waik knows how to listen to via their hook/notify mechanism.
    /// Each name is the key used in HookServer event payloads and in the
    /// hook installer's per-tool routines.
    static let supportedTools: [String] = [
        "claude",
        "codex",
    ]

    static func clearLegacyKeys() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyWindowSeconds)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyWatchedProcesses)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.legacyDisabledProcesses)
    }

    /// User-disabled subset of `supportedTools`. Storing the disabled set
    /// (rather than the enabled set) means tools added in future versions
    /// auto-enable for existing users.
    static var disabledTools: Set<String> {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: PreferenceKey.disabledTools) {
                return Set(arr)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: PreferenceKey.disabledTools)
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
