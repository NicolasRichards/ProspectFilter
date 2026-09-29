import Foundation

/// Talks to the free MLB Stats API (statsapi.mlb.com).
enum MLBClient {

    static let base = "https://statsapi.mlb.com/api/v1"

    enum ClientError: LocalizedError {
        case badResponse
        var errorDescription: String? { "The MLB data service returned an unexpected response." }
    }

    /// A message safe to show a user — raw `DecodingError`/`URLError` text
    /// (e.g. "The data couldn't be read because it is missing.") stays out
    /// of the UI; only our own already-friendly `ClientError` passes through.
    static func friendlyMessage(for error: Error) -> String {
        if let clientError = error as? ClientError {
            return clientError.errorDescription ?? "Something went wrong."
        }
        if error is URLError {
            return "Couldn't reach the MLB data service. Check your connection and try again."
        }
        return "Couldn't load data right now. Please try again."
    }

    // MARK: - Networking core

    /// Caps how many requests are in flight to the MLB Stats API at once,
    /// no matter how many call sites — nested or sibling — try to fire
    /// concurrently. This is the actual concurrency backstop for the whole
    /// app: every request funnels through `get`, so gating it here bounds
    /// real network concurrency regardless of how deeply a caller's own
    /// fan-out is nested (e.g. a per-player loop that itself triggers a
    /// per-level fan-out).
    private actor RequestGate {
        private let limit: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(limit: Int) { self.limit = limit }

        func acquire() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                active -= 1
            } else {
                waiters.removeFirst().resume()
                // A waiter takes the freed slot directly, so `active` is unchanged.
            }
        }
    }

    private static let gate = RequestGate(limit: 8)

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        await gate.acquire()
        defer { Task { await gate.release() } }
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("ProspectFilter/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Orgs

    static func orgs(season: Int) async throws -> [Org] {
        let resp: TeamsResponse = try await get("teams", ["sportId": "1", "season": "\(season)"])
        return resp.teams
            .filter { $0.active ?? true }
            .map { Org(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }

    static func affiliateTeams(orgId: Int, season: Int) async throws -> [AffiliateTeam] {
        let resp: TeamsResponse = try await get(
            "teams",
            ["sportIds": allSportIds.map(String.init).joined(separator: ","), "season": "\(season)"]
        )
        return resp.teams
            .filter { $0.id == orgId || $0.parentOrgId == orgId }
            .map { AffiliateTeam(id: $0.id, name: $0.name, level: $0.sport?.name ?? "", sportId: $0.sport?.id ?? 0) }
            .sorted { levelOrder(sportId: $0.sportId) < levelOrder(sportId: $1.sportId) }
    }

    static func teamsAtLevel(sportId: Int, season: Int) async throws -> [AffiliateTeam] {
        let resp: TeamsResponse = try await get("teams", ["sportId": "\(sportId)", "season": "\(season)"])
        return resp.teams.map {
            AffiliateTeam(id: $0.id, name: $0.name, level: $0.sport?.name ?? "", sportId: $0.sport?.id ?? sportId)
        }
    }

    // MARK: - Rosters

    /// Players on a team's full-season roster (active or IL only).
    static func rosterPlayers(team: AffiliateTeam, season: Int) async throws -> [RosterPlayer] {
        let resp: RosterResponse = try await get(
            "teams/\(team.id)/roster", ["rosterType": "fullSeason", "season": "\(season)"])
        return (resp.roster ?? []).compactMap { e -> RosterPlayer? in
            // A roster slot with no usable person record (missing id/name)
            // is skipped rather than failing the whole team's decode.
            guard let personId = e.person.id, let fullName = e.person.fullName else { return nil }
            // Every entry the API returns is part of this team's full-season
            // roster in some capacity — don't second-guess that by excluding
            // anyone whose status isn't literally "Active"/"Injured"; a
            // routine short-lived status (Paternity List, Bereavement List,
            // Restricted List, etc.) shouldn't make a qualifying player
            // silently vanish from search. Only "Injured"-containing
            // statuses get the IL badge.
            let s = e.status?.description ?? "Active"
            let onIL = s.contains("Injured")
            // A two-way player (position abbreviation "TWP") pitches and
            // bats — searchable from either mode, not just one.
            let posType = e.position?.type
            let posAbbrev = e.position?.abbreviation
            let isTwoWay = posAbbrev == "TWP"
            let isPurePitcher = posType == "Pitcher" || posAbbrev == "P"
            return RosterPlayer(
                personId: personId, fullName: fullName,
                position: posAbbrev ?? "",
                isPitcher: isTwoWay || isPurePitcher,
                isBatter: isTwoWay || !isPurePitcher,
                teamName: team.name, teamId: team.id, sportId: team.sportId, onIL: onIL)
        }
    }

    /// IL status map for a team (personId → onIL). Used for status-flag resolution.
    static func teamILStatus(teamId: Int, season: Int) async throws -> [Int: Bool] {
        let resp: RosterResponse = try await get(
            "teams/\(teamId)/roster", ["rosterType": "fullSeason", "season": "\(season)"])
        var out: [Int: Bool] = [:]
        for e in resp.roster ?? [] {
            guard let personId = e.person.id else { continue }
            let s = e.status?.description ?? "Active"
            out[personId] = s.contains("Injured")
        }
        return out
    }

    // MARK: - Ages (season age as of July 1 of the season year)

    /// Returns the known ages plus whether any chunk failed to load — a
    /// failure must not be indistinguishable from "this player has no
    /// birth date," since the caller uses a missing age to exclude a
    /// candidate from a Max Age search.
    static func seasonAges(personIds: [Int], season: Int) async -> (ages: [Int: Int], incomplete: Bool) {
        var out: [Int: Int] = [:]
        var incomplete = false
        for start in stride(from: 0, to: personIds.count, by: 100) {
            let chunk = Array(personIds[start..<min(start + 100, personIds.count)])
            guard let resp: PeopleBirthResponse = try? await get(
                "people", ["personIds": chunk.map(String.init).joined(separator: ",")]) else {
                incomplete = true
                continue
            }
            for p in resp.people {
                if let bd = p.birthDate, let age = seasonAge(birthDate: bd, season: season) {
                    out[p.id] = age
                }
            }
        }
        return (out, incomplete)
    }

    /// MLB seasons and birth dates are always Gregorian, regardless of the
    /// device's Region/Calendar setting — an explicit calendar here matches
    /// the en_US_POSIX locale already used for the birth-date parse below,
    /// rather than letting a non-Gregorian system calendar (Buddhist,
    /// Japanese, Hebrew, ...) skew the cutoff date and every computed age.
    private static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private static func seasonAge(birthDate: String, season: Int) -> Int? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = gregorianUTC
        df.timeZone = gregorianUTC.timeZone
        guard let dob = df.date(from: birthDate) else { return nil }
        var comps = DateComponents()
        comps.year = season; comps.month = 7; comps.day = 1
        guard let july1 = gregorianUTC.date(from: comps) else { return nil }
        return gregorianUTC.dateComponents([.year], from: dob, to: july1).year
    }

    // MARK: - Current team info (for status flags)

    struct CurrentTeamInfo {
        let teamId: Int?
        let sportId: Int?
    }

    static func currentTeamInfo(personIds: [Int]) async throws -> [Int: CurrentTeamInfo] {
        var out: [Int: CurrentTeamInfo] = [:]
        for start in stride(from: 0, to: personIds.count, by: 100) {
            let chunk = Array(personIds[start..<min(start + 100, personIds.count)])
            let resp: PersonCurrentTeamResponse = try await get(
                "people",
                ["personIds": chunk.map(String.init).joined(separator: ","),
                 "hydrate": "currentTeam"])
            for p in resp.people {
                out[p.id] = CurrentTeamInfo(teamId: p.currentTeam?.id, sportId: p.currentTeam?.sport?.id)
            }
        }
        return out
    }

    // MARK: - Season stats

    static func batterLines(personId: Int, season: Int) async throws -> (BatterCounts, [Stint]) {
        var bySport: [Int: [HitSplit]] = [:]
        // Each level's fetch is independent, so a transient failure at one
        // level (e.g. a level this player never played at) must not discard
        // the other levels' already-fetched, successful data.
        await withTaskGroup(of: (Int, [HitSplit]).self) { group in
            for sid in allSportIds {
                group.addTask {
                    let resp: HitStatsResponse? = try? await get(
                        "people/\(personId)/stats",
                        ["stats": "season", "group": "hitting", "season": "\(season)", "sportId": "\(sid)"])
                    return (sid, resp?.stats.flatMap { $0.splits } ?? [])
                }
            }
            for await (sid, splits) in group { bySport[sid] = splits }
        }
        var agg = BatterCounts()
        var stints: [Stint] = []
        for sid in allSportIds {
            for split in (bySport[sid] ?? []) where split.team != nil {
                let c = split.stat.counts
                agg = agg + c
                stints.append(Stint(teamName: split.team?.name ?? "—",
                                    level: levelAbbrev(sportId: sid), sportId: sid,
                                    batter: c, pitcher: nil))
            }
        }
        return (agg, stints)
    }

    static func pitcherLines(personId: Int, season: Int) async throws -> (PitcherCounts, [Stint]) {
        var bySport: [Int: [PitchSplit]] = [:]
        // Same reasoning as batterLines: don't let one level's failure
        // discard every other level's already-fetched data.
        await withTaskGroup(of: (Int, [PitchSplit]).self) { group in
            for sid in allSportIds {
                group.addTask {
                    let resp: PitchStatsResponse? = try? await get(
                        "people/\(personId)/stats",
                        ["stats": "season", "group": "pitching", "season": "\(season)", "sportId": "\(sid)"])
                    return (sid, resp?.stats.flatMap { $0.splits } ?? [])
                }
            }
            for await (sid, splits) in group { bySport[sid] = splits }
        }
        var agg = PitcherCounts()
        var stints: [Stint] = []
        for sid in allSportIds {
            for split in (bySport[sid] ?? []) where split.team != nil {
                let c = split.stat.counts
                agg = agg + c
                stints.append(Stint(teamName: split.team?.name ?? "—",
                                    level: levelAbbrev(sportId: sid), sportId: sid,
                                    batter: nil, pitcher: c))
            }
        }
        return (agg, stints)
    }

    /// Batting counts aggregated at ONE level (handles multiple stints at the same level).
    static func batterCountsAtLevel(personId: Int, season: Int, sportId: Int) async throws -> BatterCounts? {
        let resp: HitStatsResponse = try await get(
            "people/\(personId)/stats",
            ["stats": "season", "group": "hitting", "season": "\(season)", "sportId": "\(sportId)"])
        var agg = BatterCounts(); var any = false
        for g in resp.stats { for sp in g.splits where sp.team != nil { agg = agg + sp.stat.counts; any = true } }
        return any ? agg : nil
    }

    /// Pitching counts aggregated at ONE level.
    static func pitcherCountsAtLevel(personId: Int, season: Int, sportId: Int) async throws -> PitcherCounts? {
        let resp: PitchStatsResponse = try await get(
            "people/\(personId)/stats",
            ["stats": "season", "group": "pitching", "season": "\(season)", "sportId": "\(sportId)"])
        var agg = PitcherCounts(); var any = false
        for g in resp.stats { for sp in g.splits where sp.team != nil { agg = agg + sp.stat.counts; any = true } }
        return any ? agg : nil
    }
}

// MARK: - Decodable DTOs

private struct TeamsResponse: Decodable { let teams: [TeamDTO] }
private struct TeamDTO: Decodable {
    let id: Int; let name: String; let parentOrgId: Int?; let sport: NamedRef?; let active: Bool?
}
private struct NamedRef: Decodable { let id: Int?; let name: String? }

private struct RosterResponse: Decodable { let roster: [RosterEntry]? }
private struct RosterEntry: Decodable { let person: PersonRef; let position: Position?; let status: RosterStatus? }
private struct RosterStatus: Decodable { let description: String? }
// Optional, unlike most id/name fields, so one roster slot with a missing
// person record (a data gap, a placeholder entry) doesn't throw out the
// whole team's roster — rosterPlayers/teamILStatus skip just that entry.
private struct PersonRef: Decodable { let id: Int?; let fullName: String? }
private struct Position: Decodable { let abbreviation: String?; let type: String? }

private struct PeopleBirthResponse: Decodable { let people: [PersonBirth] }
private struct PersonBirth: Decodable { let id: Int; let birthDate: String? }

private struct PersonCurrentTeamResponse: Decodable { let people: [PersonCurrentTeam] }
private struct PersonCurrentTeam: Decodable {
    let id: Int
    let currentTeam: TeamRef?
}
private struct TeamRef: Decodable { let id: Int; let sport: NamedRef? }

private struct HitStatsResponse: Decodable { let stats: [HitStatGroup] }
private struct HitStatGroup: Decodable { let splits: [HitSplit] }
private struct HitSplit: Decodable { let team: NamedRef?; let stat: HitStat }
private struct HitStat: Decodable {
    let plateAppearances: Int?
    let atBats: Int?
    let hits: Int?
    let baseOnBalls: Int?
    let hitByPitch: Int?
    let sacFlies: Int?
    let strikeOuts: Int?
    let stolenBases: Int?
    let caughtStealing: Int?
    let totalBases: Int?
    let gamesPlayed: Int?

    var counts: BatterCounts {
        BatterCounts(
            pa: Double(plateAppearances ?? 0), ab: Double(atBats ?? 0),
            h: Double(hits ?? 0), bb: Double(baseOnBalls ?? 0),
            hbp: Double(hitByPitch ?? 0), sf: Double(sacFlies ?? 0),
            so: Double(strikeOuts ?? 0), sb: Double(stolenBases ?? 0),
            tb: Double(totalBases ?? 0), cs: Double(caughtStealing ?? 0),
            gamesPlayed: Double(gamesPlayed ?? 0))
    }
}

private struct PitchStatsResponse: Decodable { let stats: [PitchStatGroup] }
private struct PitchStatGroup: Decodable { let splits: [PitchSplit] }
private struct PitchSplit: Decodable { let team: NamedRef?; let stat: PitchStat }
private struct PitchStat: Decodable {
    let strikeOuts: Int?
    let baseOnBalls: Int?
    let hits: Int?
    let homeRuns: Int?
    let battersFaced: Int?
    let holds: Int?
    let saves: Int?
    let gamesPitched: Int?
    let gamesStarted: Int?
    let earnedRuns: Int?
    let inningsPitched: String?

    var counts: PitcherCounts {
        let ip = Double(inningsPitched ?? "0") ?? 0
        return PitcherCounts(
            so: Double(strikeOuts ?? 0), bb: Double(baseOnBalls ?? 0),
            h: Double(hits ?? 0), hr: Double(homeRuns ?? 0),
            bf: Double(battersFaced ?? 0), outs: Metrics.ipToOuts(ip),
            holds: Double(holds ?? 0), saves: Double(saves ?? 0),
            games: Double(gamesPitched ?? 0), gamesStarted: Double(gamesStarted ?? 0),
            earnedRuns: Double(earnedRuns ?? 0))
    }
}
