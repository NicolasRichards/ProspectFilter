import SwiftUI

/// Runs `operation` for each item with at most `limit` running concurrently,
/// returning results in the same order as `items` regardless of which finishes
/// first. `operation` is expected to handle its own per-item failure (return
/// `nil`, an empty collection, or a sentinel case) — this only bounds how many
/// run at once, so a broad search can't fire an unbounded burst of requests at
/// the MLB Stats API and have most of them silently time out or get rate-limited.
private func mapConcurrently<Item: Sendable, Result: Sendable>(
    _ items: [Item],
    limit: Int,
    operation: @escaping @Sendable (Item) async -> Result
) async -> [Result] {
    guard limit > 0, !items.isEmpty else { return [] }
    var indexed: [(Int, Result)] = []
    indexed.reserveCapacity(items.count)
    var nextIndex = 0
    await withTaskGroup(of: (Int, Result).self) { group in
        func addNext() {
            guard nextIndex < items.count else { return }
            let index = nextIndex
            let item = items[index]
            nextIndex += 1
            group.addTask { (index, await operation(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        while let result = await group.next() {
            indexed.append(result)
            addNext()
        }
    }
    return indexed.sorted { $0.0 < $1.0 }.map(\.1)
}

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
    /// Set when a team roster fetch or player evaluation failed and was
    /// skipped rather than silently making the result count look complete.
    @Published var resultsIncomplete = false

    /// The mode the on-screen results were produced with. The list is rendered
    /// against this rather than the live picker, so flipping Batters/Pitchers
    /// can't reinterpret a batter list as pitchers before new results land.
    @Published private(set) var resultsMode: PlayerMode?

    var lastSearchedFilters: FilterSet?
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// A search that is no longer the current one drops its results instead
    /// of publishing them, so a slow search can't land on top of a newer one
    /// — and can't clear `searching` out from under it.
    private var generation = TaskGeneration()

    /// Computed, not stored — a long-lived instance (the app is rarely force-quit)
    /// must still pick up a new season on January 1 instead of freezing at
    /// whatever year it happened to be constructed in.
    var season: Int { currentSeasonYear() }

    /// Caps how many requests run at once for a broad search — "All
    /// organizations" + "All MiLB" can otherwise fan out to hundreds of teams
    /// and, per candidate player, several more requests each, all at once.
    private static let maxConcurrentRequests = 8

    /// Start a search, cancelling whatever was already in flight. The single
    /// entry point for both the button and the debounced auto-search, so there
    /// is only ever one live search.
    func startSearch(filters: FilterSet, mode: PlayerMode) {
        // Also cancels any pending debounced auto-search — otherwise a
        // filter edit's 700ms timer can still fire after this manual search
        // completes, re-running a stale duplicate search the user never asked for.
        debounceTask?.cancel()
        searchTask?.cancel()
        // Bump here, not inside `search`: the cancelled search is superseded the
        // moment this returns, so it can't publish in the gap before the new
        // search's first resume.
        let token = generation.next()
        searchTask = Task { [weak self] in
            await self?.search(filters: filters, mode: mode, token: token)
        }
    }

    func scheduleAutoSearch(filters: FilterSet, mode: PlayerMode) {
        // Auto-search only after the user has run one search explicitly. A
        // search already running is NOT a reason to skip: it gets cancelled and
        // replaced below, otherwise a change made mid-search is dropped for good.
        guard lastSearchedFilters != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.startSearch(filters: filters, mode: mode)
        }
    }

    func loadOrgs() async {
        if orgs.isEmpty { orgs = (try? await MLBClient.orgs(season: season)) ?? [] }
    }

    // MARK: - Search

    private func search(filters: FilterSet, mode: PlayerMode, token mine: Int) async {
        guard generation.isCurrent(mine) else { return }
        searching = true; errorMessage = nil; results = nil; resultsMode = nil; resultsIncomplete = false
        // Only the current search may hand the UI back: a superseded one leaves
        // the spinner to the search that replaced it.
        defer { if generation.isCurrent(mine) { searching = false } }
        let sid = sportId, org = orgId, mx = maxAge, ssn = season
        let bPos = batterPos, pRole = pitcherRole

        do {
            // 1. Collect candidate roster players
            let (roster, rosterIncomplete) = try await buildRoster(orgId: org, sportId: sid, season: ssn)

            // 2. Mode filter. `isBatter`/`isPitcher` aren't opposites — a
            // two-way player is both, and should turn up in either search.
            let modeFiltered = roster.filter { p in
                mode == .batters ? p.isBatter : p.isPitcher
            }

            // 3. Position filter
            let posFiltered = modeFiltered.filter { p in
                positionMatches(player: p, mode: mode, batterPos: bPos, pitcherRole: pRole,
                                filters: filters, sportId: sid)
            }

            // 4. Age filter — one API call; map reused for display
            var ageMap: [Int: Int] = [:]
            var ageFetchIncomplete = false
            let candidates: [RosterPlayer]
            if let mx {
                let (ages, incomplete) = await MLBClient.seasonAges(personIds: posFiltered.map(\.personId), season: ssn)
                ageMap = ages
                ageFetchIncomplete = incomplete
                candidates = posFiltered.filter { p in
                    guard let a = ageMap[p.personId] else { return false }
                    return a <= mx
                }
            } else {
                candidates = posFiltered
            }

            // 5. Evaluate each candidate against stat line + filters.
            // ageMap is a mutable local, so copy it before the task group. Sending
            // a var into concurrent closures is a data race by the Swift 6 rules.
            let ages = ageMap
            let outcomes = await mapConcurrently(candidates, limit: Self.maxConcurrentRequests) { player in
                await Self.evaluatePlayer(player, mode: mode, sid: sid,
                                          filters: filters, pitcherRole: pRole,
                                          age: ages[player.personId], season: ssn)
            }
            var matched: [MatchResult] = []
            var incomplete = rosterIncomplete || ageFetchIncomplete
            for outcome in outcomes {
                switch outcome {
                case .matched(let r): matched.append(r)
                case .notMatched: break
                case .failed: incomplete = true
                }
            }

            // 6. Resolve status flags on matched set only. A failure here (e.g. a
            // timeout on the extra IL/promotion lookup) must not discard results
            // that steps 1-5 already found and filtered correctly.
            let withFlags = (try? await resolveStatusFlags(matched: matched, season: ssn)) ?? matched
            // ≥ metrics (OBP, SB...) are better higher, so sort descending. ≤
            // metrics (ERA, K%...) are better lower — sorting descending for
            // those would put the worst still-qualifying value first.
            let firstComparator = mode == .batters
                ? filters.batterFilters.first?.comparator
                : filters.pitcherFilters.first?.comparator
            let sorted = withFlags.sorted { a, b in
                if let av = a.filterValues.first?.sortValue,
                   let bv = b.filterValues.first?.sortValue,
                   av != bv {
                    return firstComparator == .atMost ? av < bv : av > bv
                }
                return a.fullName < b.fullName
            }
            guard generation.isCurrent(mine) else { return }   // superseded
            results = sorted
            resultsMode = mode
            resultsIncomplete = incomplete

        } catch {
            // A cancelled search was replaced on purpose — not something to report.
            guard generation.isCurrent(mine), !Self.isCancellation(error) else { return }
            errorMessage = MLBClient.friendlyMessage(for: error)
            results = []
            resultsMode = mode
        }
        guard generation.isCurrent(mine) else { return }
        lastSearchedFilters = filters
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Roster building

    /// Returns the candidate roster plus whether any team's roster fetch
    /// failed. Reported back to the caller rather than published directly —
    /// this runs inside a search that might already be superseded by the
    /// time it finishes, and only the caller knows whether it still is.
    private func buildRoster(orgId: Int?, sportId: Int?, season: Int) async throws -> (roster: [RosterPlayer], incomplete: Bool) {
        var incomplete = false
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
            // All MiLB teams across all levels. Each level's team-list fetch
            // is independent, so one level failing must not abort the whole
            // search — the other levels' teams are still worth searching.
            var all: [AffiliateTeam] = []
            let teamLists: [[AffiliateTeam]?] = await withTaskGroup(of: (Int, [AffiliateTeam]?).self) { group in
                for sid in milbSportIds {
                    group.addTask { (sid, try? await MLBClient.teamsAtLevel(sportId: sid, season: season)) }
                }
                var bySport: [Int: [AffiliateTeam]?] = [:]
                for await (sid, teams) in group { bySport[sid] = teams }
                return milbSportIds.map { bySport[$0] ?? nil }
            }
            for maybeTeams in teamLists {
                guard let teams = maybeTeams else { incomplete = true; continue }
                all.append(contentsOf: teams)
            }
            teamList = all
        }

        var seen = Set<Int>()
        var roster: [RosterPlayer] = []
        let rosterLists: [[RosterPlayer]?] = await mapConcurrently(teamList, limit: Self.maxConcurrentRequests) { team in
            try? await MLBClient.rosterPlayers(team: team, season: season)
        }
        for maybePlayers in rosterLists {
            guard let players = maybePlayers else { incomplete = true; continue }
            for p in players where seen.insert(p.personId).inserted {
                roster.append(p)
            }
        }
        return (roster, incomplete)
    }

    // MARK: - Per-player evaluation

    /// Distinguishes "doesn't qualify" from "couldn't be evaluated" so a
    /// network failure can't be silently counted as a normal non-match.
    enum EvaluationOutcome: Sendable {
        case matched(MatchResult)
        case notMatched
        case failed
    }

    nonisolated static func evaluatePlayer(
        _ player: RosterPlayer,
        mode: PlayerMode,
        sid: Int?,            // selected sportId; nil = combined
        filters: FilterSet,
        pitcherRole: PitcherRole,
        age: Int?,
        season: Int
    ) async -> EvaluationOutcome {
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
                    guard !milbStints.isEmpty else { return .notMatched }
                    let milbCounts = milbStints.compactMap { $0.batter }.reduce(BatterCounts(), +)
                    counts = milbCounts.pa > 0 ? milbCounts : nil
                    matchedLevel = "Combined"
                    // Reference = highest MiLB level with stats
                    referenceSportId = milbStints
                        .compactMap { stint in stint.batter.map { _ in stint.sportId } }
                        .min(by: { levelOrder(sportId: $0) < levelOrder(sportId: $1) })
                }

                guard let c = counts, c.pa >= filters.minPA else { return .notMatched }
                guard filters.batterFilters.allSatisfy({ Metrics.passes($0, counts: c) }) else { return .notMatched }

                let filterValues = filters.batterFilters.map { f -> FilterValue in
                    let v = Metrics.compute(f.metric, from: c) ?? 0
                    return FilterValue(label: f.metric.rawValue, formatted: Metrics.format(f.metric, v), sortValue: v)
                }
                return .matched(MatchResult(
                    personId: player.personId, fullName: player.fullName,
                    position: player.position, teamName: player.teamName,
                    matchedLevel: matchedLevel, referenceSportId: referenceSportId,
                    age: age, onIL: player.onIL, levelChangeNote: nil, filterValues: filterValues))

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
                    guard !milbStints.isEmpty else { return .notMatched }
                    let milbCounts = milbStints.compactMap { $0.pitcher }.reduce(PitcherCounts(), +)
                    counts = milbCounts.bf > 0 ? milbCounts : nil
                    matchedLevel = "Combined"
                    referenceSportId = milbStints
                        .compactMap { stint in stint.pitcher.map { _ in stint.sportId } }
                        .min(by: { levelOrder(sportId: $0) < levelOrder(sportId: $1) })
                }

                guard let c = counts else { return .notMatched }
                let ip = Metrics.outsToIP(c.outs)
                guard ip >= filters.minIP else { return .notMatched }

                // SP/RP filter
                switch pitcherRole {
                case .sp where !c.isStarter: return .notMatched
                case .rp where c.isStarter: return .notMatched
                default: break
                }

                guard filters.pitcherFilters.allSatisfy({ Metrics.passes($0, counts: c) }) else { return .notMatched }

                let filterValues = filters.pitcherFilters.map { f -> FilterValue in
                    let v = Metrics.compute(f.metric, from: c) ?? 0
                    return FilterValue(label: f.metric.rawValue, formatted: Metrics.format(f.metric, v), sortValue: v)
                }
                return .matched(MatchResult(
                    personId: player.personId, fullName: player.fullName,
                    position: player.position, teamName: player.teamName,
                    matchedLevel: matchedLevel, referenceSportId: referenceSportId,
                    age: age, onIL: player.onIL, levelChangeNote: nil, filterValues: filterValues))
            }
        } catch {
            return .failed
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

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .batters }

    private let levels: [(String, Int)] = [
        ("AAA", 11), ("AA", 12), ("A+", 13), ("A", 14), ("Rk-C", 16),
    ]

    var body: some View {
        Form {
                // Find Players at top so it's always visible
                Section {
                    Button {
                        vm.startSearch(filters: filterStore.filters, mode: mode)
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

                Section {
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
                } header: {
                    TabSectionHeader(title: "Cohort", color: .green)
                }

                if let error = vm.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if let results = vm.results {
                    Section {
                        ForEach(results) { r in
                            NavigationLink {
                                // The mode these results were built with, not the
                                // live picker — see MainViewModel.resultsMode.
                                PlayerDetailView(personId: r.personId, fullName: r.fullName,
                                                 isPitcher: (vm.resultsMode ?? mode) == .pitchers,
                                                 season: vm.season)
                            } label: {
                                resultRow(r)
                            }
                        }
                    } header: {
                        TabSectionHeader(
                            title: results.isEmpty
                                ? "No players match"
                                : "\(results.count) player\(results.count == 1 ? "" : "s")",
                            color: .green
                        )
                    } footer: {
                        if vm.resultsIncomplete {
                            Text("Some teams or players couldn't be checked due to a network issue — this list may be incomplete. Try searching again.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        .tint(.green)
        .task { await vm.loadOrgs() }
        .onReceive(filterStore.$filters) { newFilters in
            vm.scheduleAutoSearch(filters: newFilters, mode: mode)
        }
        .onChange(of: vm.maxAge)      { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
        .onChange(of: vm.sportId)     { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
        .onChange(of: vm.orgId)       { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
        .onChange(of: vm.batterPos)   { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
        .onChange(of: vm.pitcherRole) { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
        .onChange(of: modeRaw)        { _, _ in vm.scheduleAutoSearch(filters: filterStore.filters, mode: mode) }
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
