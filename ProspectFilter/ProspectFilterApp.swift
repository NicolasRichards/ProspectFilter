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
    @EnvironmentObject private var filterStore: FilterStore
    @StateObject private var vm = MainViewModel()
    @AppStorage("playerMode") private var modeRaw: String = PlayerMode.batters.rawValue
    @State private var showFilters = true
    @State private var filterDebounce: Task<Void, Never>?

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .batters }

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
        .environmentObject(vm)
        .onChange(of: filterStore.filters) { _, _ in triggerAutoSearch() }
    }

    private func triggerAutoSearch() {
        guard vm.results != nil, !vm.searching else { return }
        filterDebounce?.cancel()
        filterDebounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await vm.search(filters: filterStore.filters, mode: mode)
        }
    }
}
