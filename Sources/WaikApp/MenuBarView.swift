import SwiftUI
import Sparkle

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let updater: SPUUpdater

    var body: some View {
        VStack(spacing: 8) {
            statusCard

            if let warn = coordinator.daemonStatusText {
                warningCard(warn)
            }

            controlsCard

            toolsCard

            footerCard
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 320)
        // Force the popover to size to the content's intrinsic height
        // instead of expanding to whatever default min-height the system
        // popover wants to apply.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Status

    private var statusCard: some View {
        GlassCard(tint: coordinator.engagedDetail != nil ? .accentColor : nil) {
            Group {
                if let engaged = coordinator.engagedDetail {
                    engagedHeader(engaged)
                } else {
                    simpleHeader
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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

    // MARK: - Daemon warning

    private func warningCard(_ text: String) -> some View {
        GlassCard(tint: .orange) {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        GlassCard {
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
            .padding(6)
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

    private var toolsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Agent hooks")
                    Spacer()
                    Text("\(installedCount)/\(coordinator.availableTools.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.availableTools, id: \.self) { tool in
                        toolRow(tool)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 14)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            .padding(6)
        }
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
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.18), lineWidth: 0.5)
            )
    }

    // MARK: - Footer (updates + quit)

    private var footerCard: some View {
        GlassCard {
            VStack(spacing: 2) {
                CheckForUpdatesRow(updater: updater)
                quitButton
            }
            .padding(6)
        }
    }

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

// MARK: - Glass card container

private struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(cardBackground)
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            if let tint {
                shape.fill(tint.opacity(0.10))
            }
            shape
                .inset(by: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || configuration.isPressed
                          ? Color.primary.opacity(configuration.isPressed ? 0.10 : 0.06)
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
