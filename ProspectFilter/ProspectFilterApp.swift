import SwiftUI

@main
struct ProspectFilterApp: App {
    @StateObject private var filterStore = FilterStore()
    @AppStorage("playerMode") private var playerMode: String = PlayerMode.batters.rawValue

    var body: some Scene {
        WindowGroup {
            TabView {
                FiltersView()
                    .tabItem { Label("Filters", systemImage: "slider.horizontal.3") }
                MainView()
                    .tabItem { Label("Find", systemImage: "magnifyingglass") }
            }
            .environmentObject(filterStore)
        }
    }
}
