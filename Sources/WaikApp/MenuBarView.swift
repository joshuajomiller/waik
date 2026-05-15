import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        Text(coordinator.statusText)

        if let warn = coordinator.daemonStatusText {
            Text(warn).foregroundStyle(.secondary)
            Button("Open Login Items…") {
                coordinator.openLoginItemsSettings()
            }
        }

        Divider()

        Toggle("Force keep awake", isOn: forceAwakeBinding)
        Toggle("Pause monitoring", isOn: pauseBinding)

        Divider()

        Menu("Activity window") {
            ForEach(windowOptions, id: \.self) { sec in
                Button(label(for: sec)) {
                    coordinator.windowSeconds = TimeInterval(sec)
                }
            }
        }

        Menu("Watched processes") {
            ForEach(Array(coordinator.watchedProcesses).sorted(), id: \.self) { name in
                Text(name)
            }
        }

        Divider()

        Button("Quit waik") { coordinator.quit() }
            .keyboardShortcut("q")
    }

    private var windowOptions: [Int] { [30, 60, 120, 300, 600] }

    private func label(for sec: Int) -> String {
        let mark = Int(coordinator.windowSeconds) == sec ? "✓ " : "   "
        if sec < 60 { return "\(mark)\(sec) s" }
        return "\(mark)\(sec / 60) min"
    }

    private var forceAwakeBinding: Binding<Bool> {
        Binding(
            get: { coordinator.manualOverride == .forceAwake },
            set: { coordinator.setOverride($0 ? .forceAwake : .none) }
        )
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { coordinator.manualOverride == .pause },
            set: { coordinator.setOverride($0 ? .pause : .none) }
        )
    }
}
