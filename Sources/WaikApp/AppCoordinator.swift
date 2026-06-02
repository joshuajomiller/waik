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
    @Published private(set) var detection: DetectionInfo? = nil
    @Published private(set) var trafficActive: Bool = false
    @Published var manualOverride: ManualOverride = .none {
        didSet { reconcile() }
    }
    let windowSeconds: TimeInterval = Preferences.windowSeconds
    /// The canonical list of processes the app knows how to watch. The user
    /// can toggle each one on/off — adding ad-hoc names is intentionally
    /// not exposed; the default list is curated to match the AI tools that
    /// ship with a kernel-comm name we can reliably detect.
    let availableProcesses: [String] = Preferences.defaultWatchedProcesses
    @Published var disabledProcesses: Set<String> = Preferences.disabledProcesses {
        didSet {
            Preferences.disabledProcesses = disabledProcesses
            monitor.watchedProcesses = watchedProcesses
        }
    }
    /// The effective set passed to `ActivityMonitor` each tick.
    var watchedProcesses: Set<String> {
        Set(availableProcesses).subtracting(disabledProcesses)
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

    private let monitor = ActivityMonitor()
    private let helperClient = HelperClient()
    private let assertion = PowerAssertion()
    private var cancellables = Set<AnyCancellable>()
    private var reconcileTimer: Timer?
    private var onboardingWindow: NSWindow?

    init() {
        Preferences.clearLegacyKeys()
        monitor.watchedProcesses = watchedProcesses

        monitor.$lastDetection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                self.detection = info
                self.reconcile()
            }
            .store(in: &cancellables)

        monitor.$trafficActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.trafficActive = active
            }
            .store(in: &cancellables)

        daemonStatus = helperClient.register()
        monitor.start()
        startReconcileTimer()

        // Periodically refresh status so the UI reflects user approval changes.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.daemonStatus = self.helperClient.status()
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

    func isProcessEnabled(_ name: String) -> Bool {
        !disabledProcesses.contains(name)
    }

    func setProcessEnabled(_ name: String, _ enabled: Bool) {
        if enabled {
            disabledProcesses.remove(name)
        } else {
            disabledProcesses.insert(name)
        }
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

    struct EngagedDetail {
        let processName: String
        let pid: Int32
        let lastActivityAt: Date
        let windowSeconds: TimeInterval

        func remainingSeconds(at now: Date) -> Int {
            max(0, Int(windowSeconds - now.timeIntervalSince(lastActivityAt)))
        }
    }

    /// When non-nil, the menu should render a live countdown rather than a
    /// static `statusText`.
    var engagedDetail: EngagedDetail? {
        guard manualOverride == .none, state == .engaged else { return nil }
        guard let det = detection, let last = monitor.lastActivityAt else { return nil }
        return EngagedDetail(
            processName: det.processName,
            pid: det.pid,
            lastActivityAt: last,
            windowSeconds: windowSeconds
        )
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
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reconcileTimer = t
    }

    private func reconcile() {
        let now = Date()
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
            } else if let last = monitor.lastActivityAt {
                active = now.timeIntervalSince(last) < windowSeconds
            } else {
                active = false
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
