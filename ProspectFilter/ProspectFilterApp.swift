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
            Group {
                if showFilters {
                    FiltersView()
                } else {
                    MainView()
                }
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
            }
        }
    }
}
