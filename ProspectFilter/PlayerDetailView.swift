import SwiftUI

@MainActor
final class PlayerDetailViewModel: ObservableObject {
    @Published var batterStints: [Stint] = []
    @Published var pitcherStints: [Stint] = []
    @Published var loading = true
    @Published var errorMessage: String?

    func load(personId: Int, season: Int, isPitcher: Bool) async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            if isPitcher {
                let (_, stints) = try await MLBClient.pitcherLines(personId: personId, season: season)
                pitcherStints = stints.filter { ($0.pitcher?.bf ?? 0) > 0 }
            } else {
                let (_, stints) = try await MLBClient.batterLines(personId: personId, season: season)
                batterStints = stints.filter { ($0.batter?.pa ?? 0) > 0 }
            }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    /// Stints aggregated by level (handles multiple stints at the same level).
    func batterByLevel() -> [(level: String, sportId: Int, counts: BatterCounts)] {
        var map: [Int: BatterCounts] = [:]
        var levelName: [Int: String] = [:]
        for s in batterStints {
            guard let b = s.batter else { continue }
            map[s.sportId, default: BatterCounts()] = map[s.sportId, default: BatterCounts()] + b
            levelName[s.sportId] = s.level
        }
        return allSportIds.compactMap { sid in
            guard let c = map[sid], let lvl = levelName[sid] else { return nil }
            return (level: lvl, sportId: sid, counts: c)
        }
    }

    func pitcherByLevel() -> [(level: String, sportId: Int, counts: PitcherCounts)] {
        var map: [Int: PitcherCounts] = [:]
        var levelName: [Int: String] = [:]
        for s in pitcherStints {
            guard let p = s.pitcher else { continue }
            map[s.sportId, default: PitcherCounts()] = map[s.sportId, default: PitcherCounts()] + p
            levelName[s.sportId] = s.level
        }
        return allSportIds.compactMap { sid in
            guard let c = map[sid], let lvl = levelName[sid] else { return nil }
            return (level: lvl, sportId: sid, counts: c)
        }
    }
}

struct PlayerDetailView: View {
    let personId: Int
    let fullName: String
    let isPitcher: Bool
    @State private var season: Int

    @EnvironmentObject private var filterStore: FilterStore
    @StateObject private var vm = PlayerDetailViewModel()

    private let minYear = 2005
    private var maxYear: Int { Calendar.current.component(.year, from: Date()) }

    init(personId: Int, fullName: String, isPitcher: Bool, season: Int) {
        self.personId = personId
        self.fullName = fullName
        self.isPitcher = isPitcher
        _season = State(initialValue: season)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                yearBar
                if vm.loading {
                    ProgressView("Loading \(season) line…")
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else if let err = vm.errorMessage {
                    Text(err).foregroundStyle(.red).padding()
                } else if isPitcher {
                    pitcherContent
                } else {
                    batterContent
                }
            }
            .padding()
        }
        .navigationTitle(fullName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: season) { await vm.load(personId: personId, season: season, isPitcher: isPitcher) }
    }

    // MARK: - Year bar

    private var yearBar: some View {
        HStack {
            Button { if season > minYear { season -= 1 } } label: {
                Image(systemName: "chevron.left.circle.fill").font(.title2)
            }.disabled(season <= minYear)
            Spacer()
            Text(String(season)).font(.title3.weight(.semibold)).monospacedDigit()
            Spacer()
            Button { if season < maxYear { season += 1 } } label: {
                Image(systemName: "chevron.right.circle.fill").font(.title2)
            }.disabled(season >= maxYear)
        }
    }

    // MARK: - Batter content

    @ViewBuilder
    private var batterContent: some View {
        let levels = vm.batterByLevel()
        if levels.isEmpty {
            Text("No batting stats found for \(season).")
                .foregroundStyle(.secondary)
        } else {
            let filters = filterStore.filters.batterFilters
            ForEach(levels, id: \.sportId) { row in
                batterLevelCard(row.level, row.counts, filters: filters)
            }
            if levels.count > 1 {
                let combined = levels.map(\.counts).reduce(BatterCounts(), +)
                let milb = levels.filter { milbSportIds.contains($0.sportId) }.map(\.counts).reduce(BatterCounts(), +)
                batterLevelCard("Combined (MiLB)", milb, filters: filters)
                if levels.contains(where: { $0.sportId == 1 }) {
                    batterLevelCard("Combined (All)", combined, filters: filters)
                }
            }
        }
    }

    private func batterLevelCard(_ label: String, _ c: BatterCounts, filters: [BatterFilter]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    statCell("PA", String(format: "%.0f", c.pa))
                    statCell("G",  String(format: "%.0f", c.gamesPlayed))
                    statCell("AVG", Metrics.format(.avg, Metrics.compute(.avg, from: c) ?? 0))
                }
                GridRow {
                    statCell("OBP", Metrics.format(.obp, Metrics.compute(.obp, from: c) ?? 0))
                    statCell("SLG", Metrics.format(.slg, Metrics.compute(.slg, from: c) ?? 0))
                    statCell("OPS", Metrics.format(.ops, Metrics.compute(.ops, from: c) ?? 0))
                }
                GridRow {
                    statCell("ISO", Metrics.format(.iso, Metrics.compute(.iso, from: c) ?? 0))
                    statCell("K%",  Metrics.format(BatterMetric.kPct, Metrics.compute(BatterMetric.kPct, from: c) ?? 0))
                    statCell("BB%", Metrics.format(BatterMetric.bbPct, Metrics.compute(BatterMetric.bbPct, from: c) ?? 0))
                }
                GridRow {
                    statCell("SB",  Metrics.format(.sb, Metrics.compute(.sb, from: c) ?? 0))
                    if let sbp = Metrics.compute(.sbPct, from: c) {
                        statCell("SB%", Metrics.format(.sbPct, sbp))
                    } else {
                        statCell("SB%", "—")
                    }
                    statCell("BB/K", Metrics.format(.bbk, Metrics.compute(.bbk, from: c) ?? 0))
                }
            }
            if !filters.isEmpty {
                filterResults(filters.map { f in
                    (label: "\(f.metric.rawValue) \(f.comparator.rawValue) \(Metrics.format(f.metric, f.value))",
                     passes: Metrics.passes(f, counts: c))
                })
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Pitcher content

    @ViewBuilder
    private var pitcherContent: some View {
        let levels = vm.pitcherByLevel()
        if levels.isEmpty {
            Text("No pitching stats found for \(season).")
                .foregroundStyle(.secondary)
        } else {
            let filters = filterStore.filters.pitcherFilters
            ForEach(levels, id: \.sportId) { row in
                pitcherLevelCard(row.level, row.counts, filters: filters)
            }
            if levels.count > 1 {
                let milb = levels.filter { milbSportIds.contains($0.sportId) }.map(\.counts).reduce(PitcherCounts(), +)
                pitcherLevelCard("Combined (MiLB)", milb, filters: filters)
            }
        }
    }

    private func pitcherLevelCard(_ label: String, _ c: PitcherCounts, filters: [PitcherFilter]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text(c.isStarter ? "SP" : "RP")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    statCell("IP",  Metrics.formatIP(c.outs))
                    statCell("G",   String(format: "%.0f", c.games))
                    statCell("GS",  String(format: "%.0f", c.gamesStarted))
                }
                GridRow {
                    statCell("ERA",  Metrics.format(.era,  Metrics.compute(.era,  from: c) ?? 0))
                    statCell("WHIP", Metrics.format(.whip, Metrics.compute(.whip, from: c) ?? 0))
                    statCell("BAA",  Metrics.format(.baa,  Metrics.compute(.baa,  from: c) ?? 0))
                }
                GridRow {
                    statCell("K%",    Metrics.format(PitcherMetric.kPct, Metrics.compute(PitcherMetric.kPct, from: c) ?? 0))
                    statCell("BB%",   Metrics.format(PitcherMetric.bbPct, Metrics.compute(PitcherMetric.bbPct, from: c) ?? 0))
                    statCell("K-BB%", Metrics.format(.kbbPct, Metrics.compute(.kbbPct, from: c) ?? 0))
                }
            }
            if !filters.isEmpty {
                filterResults(filters.map { f in
                    (label: "\(f.metric.rawValue) \(f.comparator.rawValue) \(Metrics.format(f.metric, f.value))",
                     passes: Metrics.passes(f, counts: c))
                })
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Shared components

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func filterResults(_ results: [(label: String, passes: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Active filters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(results, id: \.label) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.passes ? .green : .red)
                        .font(.caption)
                    Text(r.label).font(.caption).foregroundStyle(.primary)
                }
            }
        }
    }
}
