import SwiftUI

@main
struct ProspectFilterApp: App {
    @StateObject private var filterStore = FilterStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(filterStore)
        }
    }
}

struct RootView: View {
    @State private var showFilters = true

    var body: some View {
        NavigationStack {
            ZStack {
                FiltersView()
                    .opacity(showFilters ? 1 : 0)
                    .allowsHitTesting(showFilters)
                    .accessibilityHidden(!showFilters)
                MainView()
                    .opacity(showFilters ? 0 : 1)
                    .allowsHitTesting(!showFilters)
                    .accessibilityHidden(showFilters)
            }
            .navigationTitle("ProspectFilter")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $showFilters) {
                        Text("Filters").tag(true)
                        Text("Find").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                if showFilters {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
        }
    }
}
