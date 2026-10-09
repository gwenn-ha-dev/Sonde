import SwiftUI

@main
struct CabasseApp: App {
    @State private var amp = AmpController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(amp: amp)
        } label: {
            MenuBarLabel(amp: amp)
        }
        .menuBarExtraStyle(.window)

        Window("Catalogue de radios", id: "catalog") {
            CatalogView(amp: amp)
        }
        .defaultSize(width: 420, height: 560)

        Window("Statistiques du flux", id: "stats") {
            StatsView(amp: amp)
        }
        .defaultSize(width: 360, height: 600)

        // Le panneau de la barre de menus, dans une fenêtre ordinaire. Il ne
        // s'ouvre que par `-window panel` : une capture d'écran ne peut pas
        // cliquer l'icône de la barre de menus sans la permission Accessibilité,
        // et le popover n'est pas une fenêtre de premier plan.
        Window("Sonde", id: "panel") {
            MenuView(amp: amp)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The menu bar icon. It also opens, at launch, the window named by the
/// `-window <catalog|stats|panel>` argument — how `outils/captures.sh` reaches a
/// view without clicking. The argument lives in the launch's argument domain
/// only: nothing is persisted.
private struct MenuBarLabel: View {
    let amp: AmpController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: amp.isPlaying ? "hifispeaker.fill" : "hifispeaker")
            .task {
                guard let id = UserDefaults.standard.string(forKey: "window"),
                      ["catalog", "stats", "panel"].contains(id) else { return }
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: id)
            }
    }
}
