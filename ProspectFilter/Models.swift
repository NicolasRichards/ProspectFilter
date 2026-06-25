import Foundation

enum PlayerMode: String, CaseIterable, Identifiable {
    case batters = "Batters"
    case pitchers = "Pitchers"
    var id: String { rawValue }
}

// MARK: - MLB org / team types

struct Org: Identifiable, Hashable {
    let id: Int
    let name: String
}

struct AffiliateTeam: Identifiable, Hashable {
    let id: Int
    let name: String
    let level: String
    let sportId: Int
}

/// A player on a team's roster (pre-filter candidate).
struct RosterPlayer: Identifiable {
    let personId: Int
    let fullName: String
    let position: String       // abbreviation e.g. "SS", "P"
    let isPitcher: Bool
    let teamName: String
    let teamId: Int
    let sportId: Int
    let onIL: Bool
    var id: Int { personId }
}

// MARK: - Raw summed counts

/// Batting counts summed across one or more stops.
struct BatterCounts {
    var pa = 0.0, ab = 0.0, h = 0.0, bb = 0.0, hbp = 0.0, sf = 0.0
    var so = 0.0, sb = 0.0, tb = 0.0, cs = 0.0, gamesPlayed = 0.0

    static func + (lhs: BatterCounts, rhs: BatterCounts) -> BatterCounts {
        BatterCounts(pa: lhs.pa + rhs.pa, ab: lhs.ab + rhs.ab, h: lhs.h + rhs.h,
                     bb: lhs.bb + rhs.bb, hbp: lhs.hbp + rhs.hbp, sf: lhs.sf + rhs.sf,
                     so: lhs.so + rhs.so, sb: lhs.sb + rhs.sb, tb: lhs.tb + rhs.tb,
                     cs: lhs.cs + rhs.cs, gamesPlayed: lhs.gamesPlayed + rhs.gamesPlayed)
    }
}

/// Pitching counts. Innings stored as outs so they sum correctly.
struct PitcherCounts {
    var so = 0.0, bb = 0.0, h = 0.0, hr = 0.0, bf = 0.0, outs = 0.0
    var holds = 0.0, saves = 0.0, games = 0.0, gamesStarted = 0.0, earnedRuns = 0.0

    static func + (lhs: PitcherCounts, rhs: PitcherCounts) -> PitcherCounts {
        PitcherCounts(so: lhs.so + rhs.so, bb: lhs.bb + rhs.bb, h: lhs.h + rhs.h,
                      hr: lhs.hr + rhs.hr, bf: lhs.bf + rhs.bf, outs: lhs.outs + rhs.outs,
                      holds: lhs.holds + rhs.holds, saves: lhs.saves + rhs.saves,
                      games: lhs.games + rhs.games, gamesStarted: lhs.gamesStarted + rhs.gamesStarted,
                      earnedRuns: lhs.earnedRuns + rhs.earnedRuns)
    }

    /// SP if start share ≥ threshold; RP otherwise.
    static let startShareThreshold = 0.5
    var isStarter: Bool { games > 0 && gamesStarted / games >= Self.startShareThreshold }
}

/// One stop in a season (single team at a single level).
struct Stint: Identifiable {
    let id = UUID()
    let teamName: String
    let level: String
    let sportId: Int
    let batter: BatterCounts?
    let pitcher: PitcherCounts?
}

// MARK: - Metrics

enum BatterMetric: String, CaseIterable, Identifiable, Codable {
    case avg = "AVG", obp = "OBP", slg = "SLG", ops = "OPS", iso = "ISO"
    case sb = "SB", sbPct = "SB%", bbPct = "BB%", kPct = "K%", bbk = "BB/K"
    case g = "G"
    var id: String { rawValue }

    var defaultComparator: Comparator { self == .kPct ? .atMost : .atLeast }

    // Values stored in these units for user clarity:
    //   Rate stats (avg/obp/slg/ops/iso/bbk): raw decimal  (.310 entered as 0.310)
    //   Percentage stats (sbPct/bbPct/kPct): percent        (25.0 entered as 25)
    //   Count stats (sb/g): raw integer                     (20 entered as 20)
    var isPercent: Bool { self == .sbPct || self == .bbPct || self == .kPct }

    var placeholder: String {
        switch self {
        case .avg, .obp, .slg, .ops, .iso: return "0.000"
        case .sb, .g: return "0"
        case .bbk: return "0.00"
        case .sbPct, .bbPct, .kPct: return "0"
        }
    }

    var unitLabel: String {
        isPercent ? "%" : ""
    }
}

enum PitcherMetric: String, CaseIterable, Identifiable, Codable {
    case era = "ERA", whip = "WHIP", baa = "BAA"
    case kPct = "K%", bbPct = "BB%", kbbPct = "K-BB%"
    case g = "G", gs = "GS"
    var id: String { rawValue }

    var defaultComparator: Comparator {
        switch self {
        case .era, .whip, .baa, .bbPct: return .atMost
        default: return .atLeast
        }
    }

    var isPercent: Bool { self == .kPct || self == .bbPct || self == .kbbPct }

    var placeholder: String {
        switch self {
        case .era, .whip: return "0.00"
        case .baa: return "0.000"
        case .kPct, .bbPct, .kbbPct: return "0"
        case .g, .gs: return "0"
        }
    }

    var unitLabel: String { isPercent ? "%" : "" }
}

enum Comparator: String, CaseIterable, Identifiable, Codable {
    case atLeast = "≥", atMost = "≤"
    var id: String { rawValue }
}

struct BatterFilter: Identifiable, Codable, Equatable {
    var id: UUID
    var metric: BatterMetric
    var comparator: Comparator
    var value: Double

    init(metric: BatterMetric) {
        id = UUID()
        self.metric = metric
        comparator = metric.defaultComparator
        value = 0
    }
}

struct PitcherFilter: Identifiable, Codable, Equatable {
    var id: UUID
    var metric: PitcherMetric
    var comparator: Comparator
    var value: Double

    init(metric: PitcherMetric) {
        id = UUID()
        self.metric = metric
        comparator = metric.defaultComparator
        value = 0
    }
}

// MARK: - Match results

enum PitcherRole: String, CaseIterable, Identifiable {
    case all = "All", sp = "SP", rp = "RP"
    var id: String { rawValue }
}

enum BatterPosition: String, CaseIterable, Identifiable {
    case any = "Any"
    case c = "C", first = "1B", second = "2B", third = "3B"
    case ss = "SS", of = "OF", dh = "DH"
    var id: String { rawValue }
}

struct MatchResult: Identifiable {
    var id: Int { personId }
    let personId: Int
    let fullName: String
    let position: String
    let teamName: String
    let matchedLevel: String    // "AAA" or "Combined"
    let referenceSportId: Int?  // for status flag computation
    let age: Int?
    let onIL: Bool
    let levelChangeNote: String? // "now at AAA" / "now demoted to A" etc.
}

// MARK: - Level helpers

/// Short display abbreviation for a sport ID.
func levelAbbrev(sportId: Int) -> String {
    switch sportId {
    case 1: return "MLB"
    case 11: return "AAA"
    case 12: return "AA"
    case 13: return "A+"
    case 14: return "A"
    case 16: return "Rk-C"
    default: return ""
    }
}

let milbSportIds = [11, 12, 13, 14, 16]
let allSportIds  = [1, 11, 12, 13, 14, 16]

/// Order index — lower == higher level (MLB == 0).
func levelOrder(sportId: Int) -> Int {
    allSportIds.firstIndex(of: sportId) ?? Int.max
}

func teamLabel(team: String, level: String) -> String {
    level.isEmpty ? team : "\(team) (\(level))"
}
