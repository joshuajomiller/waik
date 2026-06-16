import SwiftUI
import Sparkle

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let updater: SPUUpdater

    @State private var toolsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)

            if let warn = coordinator.daemonStatusText {
                separator
                daemonWarning(warn)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            separator

            controlsSection
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            separator

            toolsSection
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            separator

            CheckForUpdatesRow(updater: updater)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            separator

            quitButton
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 0.5)
    }

    // MARK: - Status header

    @ViewBuilder
    private var statusSection: some View {
        if let engaged = coordinator.engagedDetail {
            engagedHeader(engaged)
        } else {
            simpleHeader
        }
    }

    private func engagedHeader(_ engaged: AppCoordinator.EngagedDetail) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: .accentColor, pulsing: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep-awake engaged")
                    .font(.system(.headline, design: .rounded))
                Text(engagedSubtitle(engaged))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func engagedSubtitle(_ engaged: AppCoordinator.EngagedDetail) -> String {
        let toolPart = engaged.tools.joined(separator: " · ")
        if engaged.sessionCount == 1 {
            return toolPart
        }
        return "\(toolPart) · \(engaged.sessionCount) sessions"
    }

    private var simpleHeader: some View {
        HStack(spacing: 10) {
            StatusDot(color: idleStatusColor, pulsing: false)
            Text(coordinator.statusText)
                .font(.system(.headline, design: .rounded))
            Spacer()
        }
    }

    private var idleStatusColor: Color {
        switch coordinator.manualOverride {
        case .forceAwake: return .orange
        case .pause:      return .secondary
        case .none:       return .secondary
        }
    }

    private func daemonWarning(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Button("Open Login Items…") {
                coordinator.openLoginItemsSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 22)
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 2) {
            ToggleRow(
                label: "Force keep awake",
                systemImage: "bolt.fill",
                tint: .orange,
                isOn: forceAwakeBinding
            )
            ToggleRow(
                label: "Pause monitoring",
                systemImage: "pause.fill",
                tint: .secondary,
                isOn: pauseBinding
            )
            ToggleRow(
                label: "Launch at login",
                systemImage: "arrow.up.forward.app.fill",
                tint: .accentColor,
                isOn: $coordinator.launchAtLogin
            )
            ToggleRow(
                label: "Sleep on low battery",
                systemImage: "battery.25",
                tint: .green,
                isOn: $coordinator.batteryGuardEnabled
            )
            if coordinator.batteryGuardEnabled {
                batteryThresholdRow
            }
        }
    }

    private var batteryThresholdRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)
            Text("Below")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $coordinator.batteryGuardThreshold, in: 5...95, step: 5) {
                Text("\(coordinator.batteryGuardThreshold)%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 30, alignment: .leading)
            }
            .controlSize(.mini)
            Spacer()
            if let battery = coordinator.batteryState {
                Text(batteryHint(for: battery))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private func batteryHint(for state: BatteryReader.State) -> String {
        let pct = Int(state.percentage.rounded())
        return state.onBattery ? "battery \(pct)%" : "on AC · \(pct)%"
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

    // MARK: - Agent hooks

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoverButton {
                toolsExpanded.toggle()
            } content: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Agent hooks")
                    Spacer()
                    Text("\(installedCount)/\(coordinator.availableTools.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(toolsExpanded ? 90 : 0))
                }
            }

            if toolsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(coordinator.availableTools, id: \.self) { tool in
                        toolRow(tool)
                    }
                }
                .padding(.leading, 26)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toolsExpanded)
    }

    private var installedCount: Int {
        coordinator.hookStatus.values.filter {
            if case .installed = $0 { return true } else { return false }
        }.count
    }

    private func toolRow(_ tool: String) -> some View {
        let status = coordinator.hookStatus[tool] ?? .notInstalled
        let enabled = coordinator.isToolEnabled(tool)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .opacity(enabled ? 1.0 : 0.45)
                Spacer()
                statusBadge(status)
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { coordinator.setToolEnabled(tool, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            actionRow(tool: tool, status: status)
        }
    }

    @ViewBuilder
    private func actionRow(tool: String, status: HookInstaller.ToolStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .installed:
                Button("Uninstall") { _ = coordinator.uninstallHooks(tool: tool) }
                    .buttonStyle(.link).controlSize(.mini)
            case .notInstalled, .mismatched:
                Button("Install") { _ = coordinator.installHooks(tool: tool) }
                    .buttonStyle(.link).controlSize(.mini)
                if case .mismatched(let msg) = status {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            case .unavailable(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func statusBadge(_ status: HookInstaller.ToolStatus) -> some View {
        let (label, tint): (String, Color)
        switch status {
        case .installed: (label, tint) = ("installed", .green)
        case .notInstalled: (label, tint) = ("not installed", .secondary)
        case .mismatched: (label, tint) = ("partial", .orange)
        case .unavailable: (label, tint) = ("n/a", Color.secondary.opacity(0.6))
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Quit

    private var quitButton: some View {
        HoverButton {
            coordinator.quit()
        } content: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Quit waik")
                Spacer()
                Text("⌘Q")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .keyboardShortcut("q")
    }
}

// MARK: - Components

private struct StatusDot: View {
    let color: Color
    let pulsing: Bool

    var body: some View {
        if pulsing {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 3.5) + 1) / 2
                ZStack {
                    Circle()
                        .fill(color)
                        .opacity(0.25 + phase * 0.35)
                        .frame(width: 18, height: 18)
                        .blur(radius: 3)
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                }
                .frame(width: 18, height: 18)
            }
            .frame(width: 18, height: 18)
        } else {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .frame(width: 18, height: 18)
        }
    }
}

private struct ToggleRow: View {
    let label: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(isOn ? tint : Color.secondary)
                    .frame(width: 16)
                Text(label)
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

private struct HoverButton<Content: View>: View {
    let action: () -> Void
    let content: () -> Content

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

private struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering || configuration.isPressed
                          ? Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07)
                          : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Updates

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesRow: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        HoverButton {
            updater.checkForUpdates()
        } content: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Check for updates…")
                Spacer()
            }
            .opacity(viewModel.canCheckForUpdates ? 1.0 : 0.5)
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
