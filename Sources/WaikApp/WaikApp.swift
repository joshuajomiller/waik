import SwiftUI

@main
struct WaikApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.iconSymbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}
