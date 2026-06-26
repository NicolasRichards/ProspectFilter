import SwiftUI

private let defaultMinPA = 50.0
private let defaultMinIP = 20.0

struct FiltersView: View {
    @EnvironmentObject private var filterStore: FilterStore
    @AppStorage("playerMode") private var modeRaw: String = PlayerMode.batters.rawValue

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .batters }

    var body: some View {
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
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
                if filterStore.filters.minPA != defaultMinPA {
                    Button("Reset") { filterStore.filters.minPA = defaultMinPA }
                        .font(.caption)
                }
            }
            Button(action: addFilter) {
                Label("Add Filter", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Qualifier (always applied)")
        }
    }

    private var batterFiltersSection: some View {
        Section {
            if filterStore.filters.batterFilters.isEmpty {
                Text("No metric filters yet.")
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
        }
    }

    // MARK: - Pitchers

    private var pitcherQualifier: some View {
        Section {
            HStack {
                Text("Minimum IP")
                Spacer()
                TextField("20", value: $filterStore.filters.minIP, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
                if filterStore.filters.minIP != defaultMinIP {
                    Button("Reset") { filterStore.filters.minIP = defaultMinIP }
                        .font(.caption)
                }
            }
            Button(action: addFilter) {
                Label("Add Filter", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Qualifier (always applied)")
        }
    }

    private var pitcherFiltersSection: some View {
        Section {
            if filterStore.filters.pitcherFilters.isEmpty {
                Text("No metric filters yet.")
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
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Metric", selection: $filter.metric) {
                ForEach(BatterMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: filter.metric) { _, m in
                filter.comparator = m.defaultComparator
                filter.value = m.defaultValue
                showPicker = false
            }
            HStack(spacing: 12) {
                Picker("", selection: $filter.comparator) {
                    ForEach(Comparator.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 90)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showPicker.toggle() }
                } label: {
                    Text(Metrics.format(filter.metric, filter.value))
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .buttonStyle(.bordered)
                .tint(showPicker ? .accentColor : nil)
            }
            if showPicker {
                MetricValuePicker(values: filter.metric.pickerValues,
                                  current: filter.value,
                                  format: { Metrics.format(filter.metric, $0) },
                                  onSelect: {
                                      filter.value = $0
                                      withAnimation(.easeInOut(duration: 0.2)) { showPicker = false }
                                  })
                .frame(height: 150)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PitcherFilterRow: View {
    @Binding var filter: PitcherFilter
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Metric", selection: $filter.metric) {
                ForEach(PitcherMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: filter.metric) { _, m in
                filter.comparator = m.defaultComparator
                filter.value = m.defaultValue
                showPicker = false
            }
            HStack(spacing: 12) {
                Picker("", selection: $filter.comparator) {
                    ForEach(Comparator.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 90)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showPicker.toggle() }
                } label: {
                    Text(Metrics.format(filter.metric, filter.value))
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .buttonStyle(.bordered)
                .tint(showPicker ? .accentColor : nil)
            }
            if showPicker {
                MetricValuePicker(values: filter.metric.pickerValues,
                                  current: filter.value,
                                  format: { Metrics.format(filter.metric, $0) },
                                  onSelect: {
                                      filter.value = $0
                                      withAnimation(.easeInOut(duration: 0.2)) { showPicker = false }
                                  })
                .frame(height: 150)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared wheel picker (UIViewRepresentable avoids SwiftUI Form scroll-intercept bug)

struct MetricValuePicker: UIViewRepresentable {
    let values: [Double]
    let current: Double
    let format: (Double) -> String
    let onSelect: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        // Disable touch-delay on the Form's backing UIScrollView so the first
        // scroll gesture isn't intercepted before reaching the picker.
        DispatchQueue.main.async {
            var v: UIView? = picker.superview
            while let sv = v {
                if let scrollView = sv as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    break
                }
                v = sv.superview
            }
        }
        return picker
    }

    func updateUIView(_ uiView: UIPickerView, context: Context) {
        context.coordinator.parent = self
        let idx = values.firstIndex(where: { abs($0 - current) < 0.0005 })
            ?? values.firstIndex(where: { $0 >= current })
            ?? 0
        // Only reload when row count changes (metric changed); avoid disrupting scroll.
        if uiView.numberOfRows(inComponent: 0) != values.count {
            uiView.reloadAllComponents()
        }
        if uiView.selectedRow(inComponent: 0) != idx {
            uiView.selectRow(idx, inComponent: 0, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: MetricValuePicker
        init(_ parent: MetricValuePicker) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            parent.values.count
        }

        func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
            parent.format(parent.values[row])
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.onSelect(parent.values[row])
        }
    }
}
