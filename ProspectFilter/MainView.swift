import SwiftUI

@MainActor
final class MainViewModel: ObservableObject {
    @Published var orgs: [Org] = []
    @Published var orgId: Int? = nil
    @Published var sportId: Int? = nil          // nil = all MiLB levels
    @Published var maxAge: Int? = nil
    @Published var batterPos: BatterPosition = .any
    @Published var pitcherRole: PitcherRole = .all
    @Published var results: [MatchResult]? = nil
    @Published var searching = false
    @Published var errorMessage: String?

    let season = Calendar.current.component(.year, from: Date())

    func loadOrgs() async {
        if orgs.isEmpty { orgs = (try? await MLBClient.orgs(season: season)) ?? [] }
    }

    // MARK: - Search

    func search(filters: FilterSet, mode: PlayerMode) async {
        searching = true; errorMessage = nil; results = nil
        defer { searching = false }
        let sid = sportId, org = orgId, mx = maxAge, ssn = season
        let bPos = batterPos, pRole = pitcherRole

        do {
            // 1. Collect candidate roster players
            let roster = try await buildRoster(orgId: org, sportId: sid, season: ssn)

            // 2. Mode filter
            let modeFiltered = roster.filter { p in
                mode == .batters ? !p.isPitcher : p.isPitcher
            }

            // 3. Position filter
            let posFiltered = modeFiltered.filter { p in
                positionMatches(player: p, mode: mode, batterPos: bPos, pitcherRole: pRole,
                                filters: filters, sportId: sid)
            }

            // 4. Age filter — one API call; map reused for display
            var ageMap: [Int: Int] = [:]
            let candidates: [RosterPlayer]
            if let mx {
                ageMap = (try? await MLBClient.seasonAges(personIds: posFiltered.map(\.personId), season: ssn)) ?? [:]
                candidates = posFiltered.filter { p in
                    guard let a = ageMap[p.personId] else { return false }
                    return a <= mx
                }
            } else {
                candidates = posFiltered
            }

            // 5. Evaluate each candidate against stat line + filters
            var matched: [MatchResult] = []
            try await withThrowingTaskGroup(of: MatchResult?.self) { group in
                for player in candidates {
                    group.addTask {
                        await Self.evaluatePlayer(player, mode: mode, sid: sid,
                                                  filters: filters, pitcherRole: pRole,
                                                  age: ageMap[player.personId], season: ssn)
                    }
                }
                for try await r in group { if let r { matched.append(r) } }
            }

            // 6. Resolve status flags on matched set only
            let withFlags = try await resolveStatusFlags(matched: matched, season: ssn)
            results = withFlags.sorted { a, b in
                if let av = a.filterValues.first?.sortValue,
                   let bv = b.filterValues.first?.sortValue,
                   av != bv { return av > bv }
                return a.fullName < b.fullName
            }

        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    // MARK: - Roster building

    private func buildRoster(orgId: Int?, sportId: Int?, season: Int) async throws -> [RosterPlayer] {
        let teamList: [AffiliateTeam]
        if let orgId {
            let all = try await MLBClient.affiliateTeams(orgId: orgId, season: season)
            if let sid = sportId {
                teamList = all.filter { $0.sportId == sid }
            } else {
                teamList = all.filter { milbSportIds.contains($0.sportId) }
            }
        } else if let sid = sportId {
            teamList = try await MLBClient.teamsAtLevel(sportId: sid, season: season)
        } else {
            // All MiLB teams across all levels
            var all: [AffiliateTeam] = []
            try await withThrowingTaskGroup(of: [AffiliateTeam].self) { group in
                for sid in milbSportIds {
                    group.addTask { try await MLBClient.teamsAtLevel(sportId: sid, season: season) }
                }
                for try await teams in group { all.append(contentsOf: teams) }
            }
            teamList = all
        }

        var seen = Set<Int>()
        var roster: [RosterPlayer] = []
        try await withThrowingTaskGroup(of: [RosterPlayer].self) { group in
            for team in teamList {
                group.addTask { (try? await MLBClient.rosterPlayers(team: team, season: season)) ?? [] }
            }
            for try await players in group {
                for p in players where seen.insert(p.personId).inserted {
                    roster.append(p)
                }
            }
        }
        return roster
    }

    // MARK: - Per-player evaluation

    nonisolated static func evaluatePlayer(
        _ player: RosterPlayer,
        mode: PlayerMode,
        sid: Int?,            // selected sportId; nil = combined
        filters: FilterSet,
        pitcherRole: PitcherRole,
        age: Int?,
        season: Int
    ) async -> MatchResult? {
        do {
            if mode == .batters {
                let counts: BatterCounts?
                let matchedLevel: String
                let referenceSportId: Int?

                if let sid {
                    counts = try await MLBClient.batterCountsAtLevel(personId: player.personId, season: season, sportId: sid)
                    matchedLevel = levelAbbrev(sportId: sid)
                    referenceSportId = sid
                } else {
                    let (_, stints) = try await MLBClient.batterLines(personId: player.personId, season: season)
                    let milbStints = stints.filter { milbSportIds.contains($0.sportId) }
                    guard !milbStints.isEmpty else { return nil }
                    let milbCounts = milbStints.compactMap { $0.batter }.reduce(BatterCounts(), +)
                    counts = milbCounts.pa > 0 ? milbCounts : nil
                    matchedLevel = "Combined"
                    // Reference = highest MiLB level with stats
                    referenceSportId = milbStints
                        .compactMap { stint in stint.batter.map { _ in stint.sportId } }
                        .min(by: { levelOrder(sportId: $0) < levelOrder(sportId: $1) })
                }

                guard let c = counts, c.pa >= filters.minPA else { return nil }
                guard filters.batterFilters.allSatisfy({ Metrics.passes($0, counts: c) }) else { return nil }

                let filterValues = filters.batterFilters.map { f -> FilterValue in
                    let v = Metrics.compute(f.metric, from: c) ?? 0
                    return FilterValue(label: f.metric.rawValue, formatted: Metrics.format(f.metric, v), sortValue: v)
                }
                return MatchResult(
                    personId: player.personId, fullName: player.fullName,
                    position: player.position, teamName: player.teamName,
                    matchedLevel: matchedLevel, referenceSportId: referenceSportId,
                    age: age, onIL: player.onIL, levelChangeNote: nil, filterValues: filterValues)

            } else {
                // Pitchers
                let counts: PitcherCounts?
                let matchedLevel: String
                let referenceSportId: Int?

                if let sid {
                    counts = try await MLBClient.pitcherCountsAtLevel(personId: player.personId, season: season, sportId: sid)
                    matchedLevel = levelAbbrev(sportId: sid)
                    referenceSportId = sid
                } else {
                    let (_, stints) = try await MLBClient.pitcherLines(personId: player.personId, season: season)
                    let milbStints = stints.filter { milbSportIds.contains($0.sportId) }
                    guard !milbStints.isEmpty else { return nil }
                    let milbCounts = milbStints.compactMap { $0.pitcher }.reduce(PitcherCounts(), +)
                    counts = milbCounts.bf > 0 ? milbCounts : nil
                    matchedLevel = "Combined"
                    referenceSportId = milbStints
                        .compactMap { stint in stint.pitcher.map { _ in stint.sportId } }
                        .min(by: { levelOrder(sportId: $0) < levelOrder(sportId: $1) })
                }

                guard let c = counts else { return nil }
                let ip = Metrics.outsToIP(c.outs)
                guard ip >= filters.minIP else { return nil }

                // SP/RP filter
                switch pitcherRole {
                case .sp where !c.isStarter: return nil
                case .rp where c.isStarter: return nil
                default: break
                }

                guard filters.pitcherFilters.allSatisfy({ Metrics.passes($0, counts: c) }) else { return nil }

                let filterValues = filters.pitcherFilters.map { f -> FilterValue in
                    let v = Metrics.compute(f.metric, from: c) ?? 0
                    return FilterValue(label: f.metric.rawValue, formatted: Metrics.format(f.metric, v), sortValue: v)
                }
                return MatchResult(
                    personId: player.personId, fullName: player.fullName,
                    position: player.position, teamName: player.teamName,
                    matchedLevel: matchedLevel, referenceSportId: referenceSportId,
                    age: age, onIL: player.onIL, levelChangeNote: nil, filterValues: filterValues)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Position matching

    private func positionMatches(player: RosterPlayer, mode: PlayerMode, batterPos: BatterPosition,
                                 pitcherRole: PitcherRole, filters: FilterSet, sportId: Int?) -> Bool {
        if mode == .batters {
            if batterPos == .any { return true }
            if batterPos == .of { return ["LF", "CF", "RF", "OF"].contains(player.position) }
            return player.position == batterPos.rawValue
        } else {
            return true  // SP/RP classification applied post-stats
        }
    }

    // MARK: - Status flags

    private func resolveStatusFlags(matched: [MatchResult], season: Int) async throws -> [MatchResult] {
        guard !matched.isEmpty else { return [] }

        // Batch-resolve current team for all matched players
        let currentTeams = try await MLBClient.currentTeamInfo(personIds: matched.map(\.personId))

        // Fetch IL status for each unique current team
        let uniqueTeamIds = Set(currentTeams.values.compactMap(\.teamId))
        var ilMaps: [Int: [Int: Bool]] = [:]
        try await withThrowingTaskGroup(of: (Int, [Int: Bool]).self) { group in
            for tid in uniqueTeamIds {
                group.addTask { (tid, (try? await MLBClient.teamILStatus(teamId: tid, season: season)) ?? [:]) }
            }
            for try await (tid, map) in group { ilMaps[tid] = map }
        }

        return matched.map { r in
            let info = currentTeams[r.personId]
            let currentSportId = info?.sportId
            let currentTeamId = info?.teamId

            let onIL: Bool
            if let tid = currentTeamId, let ilMap = ilMaps[tid] {
                onIL = ilMap[r.personId] ?? r.onIL
            } else {
                onIL = r.onIL
            }

            var levelNote: String? = nil
            if let currentSid = currentSportId, let refSid = r.referenceSportId, currentSid != refSid {
                let currentOrder = levelOrder(sportId: currentSid)
                let refOrder = levelOrder(sportId: refSid)
                let currentLabel = levelAbbrev(sportId: currentSid)
                if currentOrder < refOrder {
                    levelNote = "now promoted to \(currentLabel)"
                } else {
                    levelNote = "now demoted to \(currentLabel)"
                }
            }

            return MatchResult(
                personId: r.personId, fullName: r.fullName,
                position: r.position, teamName: r.teamName,
                matchedLevel: r.matchedLevel, referenceSportId: r.referenceSportId,
                age: r.age, onIL: onIL, levelChangeNote: levelNote, filterValues: r.filterValues)
        }
    }
}

// MARK: - View

struct MainView: View {
    @EnvironmentObject private var filterStore: FilterStore
    @StateObject private var vm = MainViewModel()
    @AppStorage("playerMode") private var modeRaw: String = PlayerMode.batters.rawValue
    @State private var filterDebounce: Task<Void, Never>?

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .batters }

    private let levels: [(String, Int)] = [
        ("AAA", 11), ("AA", 12), ("A+", 13), ("A", 14), ("Rk-C", 16),
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Find Players at top so it's always visible
                Section {
                    Button {
                        Task { await vm.search(filters: filterStore.filters, mode: mode) }
                    } label: {
                        HStack {
                            if vm.searching { ProgressView().padding(.trailing, 4) }
                            Text(vm.searching ? "Searching…" : "Find Players")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(vm.searching)
                } footer: {
                    filterSummary
                }

                Section {
                    Picker("Mode", selection: $modeRaw) {
                        ForEach(PlayerMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Cohort") {
                    Picker("Organization", selection: $vm.orgId) {
                        Text("All organizations").tag(Int?.none)
                        ForEach(vm.orgs) { Text($0.name).tag(Int?.some($0.id)) }
                    }

                    Picker("Level", selection: $vm.sportId) {
                        Text("All MiLB").tag(Int?.none)
                        ForEach(levels, id: \.1) { Text($0.0).tag(Int?.some($0.1)) }
                    }

                    Picker("Max age", selection: $vm.maxAge) {
                        Text("Any").tag(Int?.none)
                        ForEach(Array(16...40), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }

                    if mode == .batters {
                        Picker("Position", selection: $vm.batterPos) {
                            ForEach(BatterPosition.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } else {
                        Picker("Role", selection: $vm.pitcherRole) {
                            ForEach(PitcherRole.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }

                if let error = vm.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if let results = vm.results {
                    Section(results.isEmpty
                            ? "No players match"
                            : "\(results.count) player\(results.count == 1 ? "" : "s")") {
                        ForEach(results) { r in
                            NavigationLink {
                                PlayerDetailView(personId: r.personId, fullName: r.fullName,
                                                 isPitcher: mode == .pitchers, season: vm.season)
                            } label: {
                                resultRow(r)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ProspectFilter")
            .task { await vm.loadOrgs() }
            .onChange(of: filterStore.filters) { _, _ in triggerAutoSearch() }
        }
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

    @ViewBuilder
    private var filterSummary: some View {
        let fs = filterStore.filters
        let filters = mode == .batters ? fs.batterFilters.map(filterDesc) : fs.pitcherFilters.map(filterDesc)
        let qual = mode == .batters ? "≥\(Int(fs.minPA)) PA" : "≥\(Int(fs.minIP)) IP"
        let parts = [qual] + filters
        Text(parts.joined(separator: " · "))
            .font(.caption)
    }

    private func filterDesc(_ f: BatterFilter) -> String {
        "\(f.metric.rawValue) \(f.comparator.rawValue) \(Metrics.format(f.metric, f.value))"
    }

    private func filterDesc(_ f: PitcherFilter) -> String {
        "\(f.metric.rawValue) \(f.comparator.rawValue) \(Metrics.format(f.metric, f.value))"
    }

    @ViewBuilder
    private func resultRow(_ r: MatchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(r.fullName).font(.headline)
                if r.onIL {
                    Text("IL").font(.caption.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.orange)
                }
                if let note = r.levelChangeNote {
                    Text(note).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            HStack(spacing: 4) {
                Text(r.position.isEmpty ? "—" : r.position)
                if let age = r.age { Text("· age \(age)") }
                Text("· \(r.matchedLevel)")
                if !r.teamName.isEmpty { Text("· \(r.teamName)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !r.filterValues.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(r.filterValues.enumerated()), id: \.offset) { _, fv in
                        Text("\(fv.label): \(fv.formatted)")
                            .monospacedDigit()
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }
}
