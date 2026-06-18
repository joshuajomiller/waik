import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement
import os

enum KeepAwakeState: Sendable, Equatable {
    case idle
    case engaged
}

enum ManualOverride: String, Sendable, Equatable {
    case none
    case forceAwake
    case pause
}

@MainActor
final class AppCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "com.waik.app", category: "coordinator")

    @Published private(set) var state: KeepAwakeState = .idle
    @Published private(set) var sessions: [String: HookServer.Session] = [:]
    @Published var manualOverride: ManualOverride = .none {
        didSet { reconcile() }
    }

    /// Tools waik knows how to install hooks for. The user can disable a
    /// tool here without uninstalling its hooks; events for disabled tools
    /// are ignored when computing engagement.
    let availableTools: [String] = Preferences.supportedTools
    @Published var disabledTools: Set<String> = Preferences.disabledTools {
        didSet { Preferences.disabledTools = disabledTools }
    }
    var enabledTools: Set<String> {
        Set(availableTools).subtracting(disabledTools)
    }

    @Published private(set) var daemonStatus: DaemonStatus = .unknown
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var batteryGuardEnabled: Bool = Preferences.batteryGuardEnabled {
        didSet {
            Preferences.batteryGuardEnabled = batteryGuardEnabled
            reconcile()
        }
    }
    @Published var batteryGuardThreshold: Int = Preferences.batteryGuardThreshold {
        didSet {
            Preferences.batteryGuardThreshold = batteryGuardThreshold
            reconcile()
        }
    }
    @Published private(set) var batteryState: BatteryReader.State? = BatteryReader.current()

    @Published private(set) var hookStatus: [String: HookInstaller.ToolStatus] = [:]

    let hookServer = HookServer()
    let hookInstaller = HookInstaller()
    private let helperClient = HelperClient()
    private let assertion = PowerAssertion()
    private var cancellables = Set<AnyCancellable>()
    private var reconcileTimer: Timer?
    private var onboardingWindow: NSWindow?

    init() {
        Preferences.clearLegacyKeys()
        // Refresh the stable `waik-hook` launcher copy from this bundle. Hook
        // entries (and the Codex chain wrapper) point at the stable path
        // rather than the bundle, so moving or rebuilding the .app silently
        // re-points itself on the next launch without requiring a re-install.
        HookLauncher.refreshFromBundle()

        hookServer.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                self?.sessions = s
                self?.reconcile()
            }
            .store(in: &cancellables)

        daemonStatus = helperClient.register()
        // We launch in `.idle`, and `apply()` only runs on state *transitions*,
        // so without this an instance that inherited a stale `SleepDisabled=1`
        // lease (e.g. a prior instance was force-quit while engaged) would never
        // clear it and the Mac couldn't sleep on lid-close. Push the idle state
        // explicitly to reconcile the helper with reality on every launch.
        helperClient.setSleepDisabled(false)
        hookServer.start()
        refreshHookStatus()
        startReconcileTimer()

        // Periodically refresh daemon + hook installer status so the UI
        // reflects user approval changes and manual edits.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.daemonStatus = self.helperClient.status()
                self.refreshHookStatus()
            }
        }

        // Release the sleep lease on any clean termination (logout, shutdown,
        // or a quit that didn't route through `quit()`). The helper is an
        // on-demand daemon that persists `SleepDisabled` across its own reaping,
        // so if we don't actively clear it on the way out a stale `1` survives
        // and the Mac can't sleep on lid-close until the next launch reconciles.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hookServer.stop()
                self?.helperClient.setSleepDisabledAndWait(false)
            }
        }

        // Defer onboarding to the next runloop tick so the NSApplication has
        // finished launching by the time we try to put a window on screen.
        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    private func showOnboardingIfNeeded() {
        guard !Preferences.onboardingCompleted else { return }

        let view = OnboardingView(coordinator: self) { [weak self] in
            Preferences.onboardingCompleted = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to waik"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setOverride(_ override: ManualOverride) {
        manualOverride = override
    }

    func isToolEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
    }

    func setToolEnabled(_ name: String, _ enabled: Bool) {
        if enabled {
            disabledTools.remove(name)
        } else {
            disabledTools.insert(name)
        }
        reconcile()
    }

    func refreshHookStatus() {
        var next: [String: HookInstaller.ToolStatus] = [:]
        for tool in availableTools {
            next[tool] = hookInstaller.status(tool: tool)
        }
        if hookStatus != next { hookStatus = next }
    }

    func installHooks(tool: String) -> Result<Void, Error> {
        let r = hookInstaller.install(tool: tool)
        refreshHookStatus()
        return r
    }

    func uninstallHooks(tool: String) -> Result<Void, Error> {
        let r = hookInstaller.uninstall(tool: tool)
        refreshHookStatus()
        return r
    }

    func installAllHooks() -> [String: Error] {
        var errs: [String: Error] = [:]
        for tool in availableTools {
            if case .failure(let e) = hookInstaller.install(tool: tool) {
                errs[tool] = e
            }
        }
        refreshHookStatus()
        return errs
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                logger.info("Registered main app login item")
            } else {
                try service.unregister()
                logger.info("Unregistered main app login item")
            }
        } catch {
            logger.error("Login item toggle failed: \(error.localizedDescription, privacy: .public)")
            // Roll back the published value so the toggle reflects reality.
            let actual = service.status == .enabled
            if actual != launchAtLogin {
                launchAtLogin = actual
            }
        }
    }

    func quit() {
        apply(.idle)
        hookServer.stop()
        // Drain the SleepDisabled clear before AppKit's terminate sequence
        // begins. The willTerminate observer also calls this — keeping it as a
        // safety net for non-user quit paths (logout, shutdown, Sparkle's
        // AppleEvent) — but doing it here means the user-driven Quit doesn't
        // depend on willTerminate firing in a context that lets the XPC reply
        // come back.
        helperClient.setSleepDisabledAndWait(false)
        NSApp.terminate(nil)
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var iconSymbolName: String {
        switch (state, manualOverride) {
        case (.engaged, _):           return "bolt.fill"
        case (.idle, .pause):         return "pause.circle"
        // Outline bolt for idle: same brand family as the engaged `bolt.fill`,
        // with filled/unfilled communicating the state. Crucially not a moon
        // — Focus mode owns the crescent in the menu bar.
        case (.idle, _):              return "bolt"
        }
    }

    struct EngagedDetail: Equatable {
        let tools: [String]      // distinct tool names with active sessions
        let sessionCount: Int
    }

    /// Non-nil while running on hook signals (no manual override, no battery
    /// guard, no pause). The menu renders this as a session summary.
    var engagedDetail: EngagedDetail? {
        guard manualOverride == .none, state == .engaged else { return nil }
        let active = activeSessions
        guard !active.isEmpty else { return nil }
        let tools = Array(Set(active.map { $0.tool })).sorted()
        return EngagedDetail(tools: tools, sessionCount: active.count)
    }

    private var activeSessions: [HookServer.Session] {
        sessions.values.filter { enabledTools.contains($0.tool) }
    }

    var statusText: String {
        switch manualOverride {
        case .forceAwake:
            return "Forced awake"
        case .pause:
            return "Monitoring paused"
        case .none:
            switch state {
            case .engaged:
                return "Keep-awake engaged"
            case .idle:
                return "Idle"
            }
        }
    }

    var daemonStatusText: String? {
        switch daemonStatus {
        case .enabled, .unknown:
            return nil
        case .notRegistered:
            return "Daemon not registered"
        case .requiresApproval:
            return "Daemon awaiting approval — open Login Items in Settings"
        case .notFound:
            return "Daemon binary not found in app bundle"
        }
    }

    private func startReconcileTimer() {
        // Battery state + manual overrides still need a periodic recheck even
        // when no hook events fire, so the reconcile timer stays.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reconcileTimer = t
    }

    private func reconcile() {
        if let refreshed = BatteryReader.current(), refreshed != batteryState {
            batteryState = refreshed
        }

        let active: Bool
        switch manualOverride {
        case .forceAwake:
            active = true
        case .pause:
            active = false
        case .none:
            if isBatteryGuardActive {
                active = false
            } else {
                active = !activeSessions.isEmpty
            }
        }

        let next: KeepAwakeState = active ? .engaged : .idle
        if next != state {
            apply(next)
            state = next
        }
    }

    /// True when the user has enabled the battery guard, the machine is
    /// currently on battery, and the level is below the threshold. Desktops
    /// (no internal battery) always return false.
    var isBatteryGuardActive: Bool {
        guard batteryGuardEnabled, let s = batteryState else { return false }
        return s.onBattery && s.percentage < Double(batteryGuardThreshold)
    }

    private func apply(_ newState: KeepAwakeState) {
        switch newState {
        case .engaged:
            assertion.acquire(reason: "waik: agent task in progress")
            helperClient.setSleepDisabled(true)
            logger.info("Engaging keep-awake")
        case .idle:
            assertion.release()
            helperClient.setSleepDisabled(false)
            logger.info("Releasing keep-awake")
        }
    }
}
