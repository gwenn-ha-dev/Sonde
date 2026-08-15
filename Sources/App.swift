import SwiftUI

@main
struct CabasseApp: App {
    @State private var amp = AmpController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(amp: amp)
        } label: {
            Image(systemName: amp.isPlaying ? "hifispeaker.fill" : "hifispeaker")
        }
        .menuBarExtraStyle(.window)

        Window("Catalogue de radios", id: "catalog") {
            CatalogView(amp: amp)
        }
        .defaultSize(width: 420, height: 560)

        Window("Statistiques du flux", id: "stats") {
            StatsView(amp: amp)
        }
        .defaultSize(width: 360, height: 460)
    }
}
