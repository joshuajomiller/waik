import Foundation
import SwiftUI
import Combine
import AppKit
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
    @Published var manualOverride: ManualOverride = .none {
        didSet { reconcile() }
    }
    @Published var windowSeconds: TimeInterval = Preferences.windowSeconds {
        didSet {
            Preferences.windowSeconds = windowSeconds
            reconcile()
        }
    }
    @Published var watchedProcesses: Set<String> = Preferences.watchedProcesses {
        didSet {
            Preferences.watchedProcesses = watchedProcesses
            monitor.watchedProcesses = watchedProcesses
        }
    }
    @Published private(set) var daemonStatus: DaemonStatus = .unknown

    private let monitor = ActivityMonitor()
    private let helperClient = HelperClient()
    private let assertion = PowerAssertion()
    private var cancellables = Set<AnyCancellable>()
    private var reconcileTimer: Timer?

    init() {
        monitor.watchedProcesses = watchedProcesses

        monitor.$lastDetection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self else { return }
                self.detection = info
                self.reconcile()
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
    }

    func setOverride(_ override: ManualOverride) {
        manualOverride = override
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
        case (.idle, _):              return "moon"
        }
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
                if let det = detection {
                    let remaining = max(0, Int(windowSeconds - Date().timeIntervalSince(det.timestamp)))
                    return "Active — \(det.processName) (pid \(det.pid)) · \(remaining)s left"
                }
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
        let active: Bool
        switch manualOverride {
        case .forceAwake:
            active = true
        case .pause:
            active = false
        case .none:
            if let det = detection {
                active = now.timeIntervalSince(det.timestamp) < windowSeconds
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
