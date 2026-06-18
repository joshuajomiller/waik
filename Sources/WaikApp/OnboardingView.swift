import SwiftUI

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    let finish: () -> Void

    @State private var page: Int = 0
    @State private var lastInstallError: String? = nil
    private let pageCount: Int = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: introPage
                    case 1: daemonPage
                    case 2: hooksPage
                    default: launchPage
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 20)

            Divider()

            HStack {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.22)) { page -= 1 }
                }
                .disabled(page == 0)
                .opacity(page == 0 ? 0 : 1)

                Spacer()

                pageDots

                Spacer()

                if page < pageCount - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.22)) { page += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish", action: finish)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.22), value: page)
            }
        }
    }

    // MARK: - Pages

    private var introPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroIcon("bolt.fill", gradient: [.purple, .blue])

            Text("Welcome to waik")
                .font(.largeTitle.weight(.semibold))

            Text("waik listens for hooks that Claude Code, Codex, and Cursor already fire when they start or finish a turn — and holds your Mac awake while one is mid-task. The moment a turn ends, your Mac sleeps again.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var daemonPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroIcon(daemonStatusIcon, gradient: daemonGradient)

            Text("One-time approval")
                .font(.largeTitle.weight(.semibold))

            Text("waik uses a tiny helper daemon to disable system sleep — not just display sleep. macOS will ask you to approve it in **Login Items** the first time. You only need to do this once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack(spacing: 8) {
                Text("Status:")
                    .foregroundStyle(.secondary)
                Text(daemonStatusLabel)
                    .foregroundStyle(daemonStatusColor)
                    .fontWeight(.medium)
                Spacer()
                Button("Open Login Items…") {
                    coordinator.openLoginItemsSettings()
                }
                .controlSize(.small)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hooksPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroIcon("antenna.radiowaves.left.and.right", gradient: [.teal, .blue])

            Text("Install agent hooks")
                .font(.largeTitle.weight(.semibold))

            Text("waik adds entries to your `~/.claude/settings.json`, `~/.codex/config.toml`, and `~/.cursor/hooks.json` so each tool tells waik when it starts and finishes a turn. You can uninstall any time from the menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(coordinator.availableTools, id: \.self) { tool in
                    hookStatusRow(tool)
                }
            }

            if let err = lastInstallError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Install all") {
                    let errs = coordinator.installAllHooks()
                    lastInstallError = errs.isEmpty ? nil : errs.map { "\($0.key): \($0.value.localizedDescription)" }.joined(separator: " · ")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hookStatusRow(_ tool: String) -> some View {
        let status = coordinator.hookStatus[tool] ?? .notInstalled
        return HStack(spacing: 8) {
            Image(systemName: hookIcon(status))
                .foregroundStyle(hookColor(status))
            Text(tool)
                .font(.system(.callout, design: .monospaced))
            Spacer()
            Text(hookLabel(status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hookIcon(_ s: HookInstaller.ToolStatus) -> String {
        switch s {
        case .installed: return "checkmark.circle.fill"
        case .notInstalled: return "circle"
        case .mismatched: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle"
        }
    }

    private func hookColor(_ s: HookInstaller.ToolStatus) -> Color {
        switch s {
        case .installed: return .green
        case .notInstalled: return .secondary
        case .mismatched: return .orange
        case .unavailable: return Color.secondary.opacity(0.6)
        }
    }

    private func hookLabel(_ s: HookInstaller.ToolStatus) -> String {
        switch s {
        case .installed: return "installed"
        case .notInstalled: return "not installed"
        case .mismatched(let m): return m
        case .unavailable(let m): return m
        }
    }

    private var launchPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroIcon("arrow.up.forward.app.fill", gradient: [.indigo, .cyan])

            Text("Set and forget")
                .font(.largeTitle.weight(.semibold))

            Text("Start waik automatically every time you log in. You can change this any time from the menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Toggle("Launch waik at login", isOn: $coordinator.launchAtLogin)
                .toggleStyle(.switch)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroIcon(_ name: String, gradient: [Color]) -> some View {
        Image(systemName: name)
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(
                LinearGradient(
                    colors: gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .symbolRenderingMode(.hierarchical)
    }

    // MARK: - Daemon status presentation

    private var daemonStatusIcon: String {
        switch coordinator.daemonStatus {
        case .enabled: return "checkmark.shield.fill"
        case .requiresApproval: return "exclamationmark.shield.fill"
        case .notFound: return "xmark.shield.fill"
        case .notRegistered, .unknown: return "shield"
        }
    }

    private var daemonGradient: [Color] {
        switch coordinator.daemonStatus {
        case .enabled: return [.green, .mint]
        case .requiresApproval: return [.orange, .yellow]
        case .notFound: return [.red, .pink]
        case .notRegistered, .unknown: return [.gray, .secondary]
        }
    }

    private var daemonStatusColor: Color {
        switch coordinator.daemonStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notFound: return .red
        case .notRegistered, .unknown: return .secondary
        }
    }

    private var daemonStatusLabel: String {
        switch coordinator.daemonStatus {
        case .enabled: return "Approved"
        case .requiresApproval: return "Awaiting approval"
        case .notRegistered: return "Not registered"
        case .notFound: return "Helper binary missing"
        case .unknown: return "Checking…"
        }
    }
}
