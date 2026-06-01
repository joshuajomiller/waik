import SwiftUI

@main
struct WaikApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
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
