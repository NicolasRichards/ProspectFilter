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

    /// Ordered picker values (integer arithmetic avoids float accumulation).
    var pickerValues: [Double] {
        switch self {
        case .avg:   return stride(from: 100, through: 400, by: 5).map { Double($0) / 1000 }
        case .obp:   return stride(from: 100, through: 500, by: 5).map { Double($0) / 1000 }
        case .slg:   return stride(from: 100, through: 750, by: 5).map { Double($0) / 1000 }
        case .ops:   return stride(from: 200, through: 1300, by: 10).map { Double($0) / 1000 }
        case .iso:   return stride(from: 0, through: 350, by: 5).map { Double($0) / 1000 }
        case .sb:    return stride(from: 0, through: 60, by: 1).map(Double.init)
        case .sbPct: return stride(from: 0, through: 100, by: 5).map(Double.init)
        case .bbPct: return stride(from: 0, through: 30, by: 1).map(Double.init)
        case .kPct:  return stride(from: 0, through: 45, by: 1).map(Double.init)
        case .bbk:   return stride(from: 0, through: 200, by: 5).map { Double($0) / 100 }
        case .g:     return stride(from: 0, through: 162, by: 5).map(Double.init)
        }
    }

    /// Sensible starting value when a new filter is added.
    var defaultValue: Double {
        switch self {
        case .avg:   return 0.250
        case .obp:   return 0.330
        case .slg:   return 0.400
        case .ops:   return 0.720
        case .iso:   return 0.150
        case .sb:    return 10
        case .sbPct: return 65
        case .bbPct: return 10
        case .kPct:  return 25
        case .bbk:   return 0.50
        case .g:     return 50
        }
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

    var pickerValues: [Double] {
        switch self {
        case .era:    return stride(from: 0, through: 1000, by: 25).map { Double($0) / 100 }
        case .whip:   return stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }
        case .baa:    return stride(from: 100, through: 400, by: 5).map { Double($0) / 1000 }
        case .kPct:   return stride(from: 0, through: 45, by: 1).map(Double.init)
        case .bbPct:  return stride(from: 0, through: 25, by: 1).map(Double.init)
        case .kbbPct: return stride(from: -10, through: 40, by: 1).map(Double.init)
        case .g:      return stride(from: 0, through: 80, by: 5).map(Double.init)
        case .gs:     return stride(from: 0, through: 35, by: 1).map(Double.init)
        }
    }

    var defaultValue: Double {
        switch self {
        case .era:    return 4.00
        case .whip:   return 1.30
        case .baa:    return 0.250
        case .kPct:   return 22
        case .bbPct:  return 10
        case .kbbPct: return 10
        case .g:      return 20
        case .gs:     return 10
        }
    }
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
        value = metric.defaultValue
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
        value = metric.defaultValue
    }
}

// MARK: - Match results

struct FilterValue {
    let label: String
    let formatted: String
    let sortValue: Double
}

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
    let filterValues: [FilterValue]  // metric values for the active filters, in filter order
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
