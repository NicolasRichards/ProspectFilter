import SwiftUI

struct FiltersView: View {
    @EnvironmentObject private var filterStore: FilterStore
    @AppStorage("playerMode") private var modeRaw: String = PlayerMode.batters.rawValue

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .batters }

    var body: some View {
        NavigationStack {
            Form {
                modePicker

                if mode == .batters {
                    batterQualifier
                    batterFiltersSection
                } else {
                    pitcherQualifier
                    pitcherFiltersSection
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Filter", action: addFilter)
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
        }
    }

    private var modePicker: some View {
        Section {
            Picker("Mode", selection: $modeRaw) {
                ForEach(PlayerMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Batters

    private var batterQualifier: some View {
        Section {
            HStack {
                Text("Minimum PA")
                Spacer()
                TextField("50", value: $filterStore.filters.minPA, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 60)
            }
        } header: {
            Text("Qualifier (always applied)")
        }
    }

    private var batterFiltersSection: some View {
        Section {
            if filterStore.filters.batterFilters.isEmpty {
                Text("Tap Add Filter to define a metric threshold.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach($filterStore.filters.batterFilters) { $f in
                    BatterFilterRow(filter: $f)
                }
                .onDelete { filterStore.filters.batterFilters.remove(atOffsets: $0) }
                .onMove { filterStore.filters.batterFilters.move(fromOffsets: $0, toOffset: $1) }
            }
        } header: {
            Text("Metric Filters (all must match)")
        } footer: {
            if !filterStore.filters.batterFilters.isEmpty {
                Text("Rates: enter as decimals (.300). Percentages: enter as numbers (25 for 25%). Swipe to delete.")
            }
        }
    }

    // MARK: - Pitchers

    private var pitcherQualifier: some View {
        Section {
            HStack {
                Text("Minimum IP")
                Spacer()
                TextField("20", value: $filterStore.filters.minIP, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 60)
            }
        } header: {
            Text("Qualifier (always applied)")
        }
    }

    private var pitcherFiltersSection: some View {
        Section {
            if filterStore.filters.pitcherFilters.isEmpty {
                Text("Tap Add Filter to define a metric threshold.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach($filterStore.filters.pitcherFilters) { $f in
                    PitcherFilterRow(filter: $f)
                }
                .onDelete { filterStore.filters.pitcherFilters.remove(atOffsets: $0) }
                .onMove { filterStore.filters.pitcherFilters.move(fromOffsets: $0, toOffset: $1) }
            }
        } header: {
            Text("Metric Filters (all must match)")
        } footer: {
            if !filterStore.filters.pitcherFilters.isEmpty {
                Text("ERA/WHIP: standard values. BAA as decimal (.250). Percentages as numbers (25 for 25%). Swipe to delete.")
            }
        }
    }

    // MARK: - Actions

    private func addFilter() {
        if mode == .batters {
            filterStore.filters.batterFilters.append(BatterFilter(metric: .obp))
        } else {
            filterStore.filters.pitcherFilters.append(PitcherFilter(metric: .era))
        }
    }
}

// MARK: - Filter rows

struct BatterFilterRow: View {
    @Binding var filter: BatterFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Metric", selection: $filter.metric) {
                ForEach(BatterMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: filter.metric) { _, m in
                filter.comparator = m.defaultComparator
                filter.value = 0
            }
            HStack(spacing: 12) {
                Picker("", selection: $filter.comparator) {
                    ForEach(Comparator.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 90)
                Spacer()
                TextField(filter.metric.placeholder, value: $filter.value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 70)
                if !filter.metric.unitLabel.isEmpty {
                    Text(filter.metric.unitLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct PitcherFilterRow: View {
    @Binding var filter: PitcherFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Metric", selection: $filter.metric) {
                ForEach(PitcherMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: filter.metric) { _, m in
                filter.comparator = m.defaultComparator
                filter.value = 0
            }
            HStack(spacing: 12) {
                Picker("", selection: $filter.comparator) {
                    ForEach(Comparator.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 90)
                Spacer()
                TextField(filter.metric.placeholder, value: $filter.value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 70)
                if !filter.metric.unitLabel.isEmpty {
                    Text(filter.metric.unitLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
