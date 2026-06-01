import SwiftUI
import Sparkle

@main
struct WaikApp: App {
    @StateObject private var coordinator = AppCoordinator()

    // SPUStandardUpdaterController must live for the app's lifetime — Sparkle
    // hooks NSApplication lifecycle to schedule update checks.
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(updater: updaterController.updater)
                .environmentObject(coordinator)
        } label: {
            Image(nsImage: MenuBarIconImage.render(
                baseSymbol: coordinator.iconSymbolName,
                trafficActive: coordinator.trafficActive
            ))
        }
        .menuBarExtraStyle(.window)
    }
}
