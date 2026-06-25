import Foundation

/// Metric computation and filter evaluation. No scoring — just values.
enum Metrics {

    // MARK: - IP conversion (baseball "decimal" innings are thirds, not tenths)

    static func ipToOuts(_ ip: Double) -> Double {
        let whole = ip.rounded(.towardZero)
        let frac = ((ip - whole) * 10).rounded()
        return whole * 3 + frac
    }

    static func outsToIP(_ outs: Double) -> Double { outs / 3.0 }

    // MARK: - Batter metric computation

    /// Returns the metric value in "filter units" (percent metrics × 100, counts raw).
    static func compute(_ metric: BatterMetric, from c: BatterCounts) -> Double? {
        switch metric {
        case .avg:
            return c.ab > 0 ? c.h / c.ab : nil
        case .obp:
            let denom = c.ab + c.bb + c.hbp + c.sf
            return denom > 0 ? (c.h + c.bb + c.hbp) / denom : nil
        case .slg:
            return c.ab > 0 ? c.tb / c.ab : nil
        case .ops:
            let obpDenom = c.ab + c.bb + c.hbp + c.sf
            guard c.ab > 0 || obpDenom > 0 else { return nil }
            let obp = obpDenom > 0 ? (c.h + c.bb + c.hbp) / obpDenom : 0.0
            let slg = c.ab > 0 ? c.tb / c.ab : 0.0
            return obp + slg
        case .iso:
            return c.ab > 0 ? (c.tb - c.h) / c.ab : nil
        case .sb:
            return c.sb
        case .sbPct:
            let attempts = c.sb + c.cs
            return attempts > 0 ? (c.sb / attempts) * 100 : nil
        case .bbPct:
            return c.pa > 0 ? (c.bb / c.pa) * 100 : nil
        case .kPct:
            return c.pa > 0 ? (c.so / c.pa) * 100 : nil
        case .bbk:
            return c.so > 0 ? c.bb / c.so : nil
        case .g:
            return c.gamesPlayed
        }
    }

    // MARK: - Pitcher metric computation

    static func compute(_ metric: PitcherMetric, from c: PitcherCounts) -> Double? {
        let ip = outsToIP(c.outs)
        switch metric {
        case .era:
            return ip > 0 ? (c.earnedRuns / ip) * 9.0 : nil
        case .whip:
            return ip > 0 ? (c.bb + c.h) / ip : nil
        case .baa:
            return c.bf > 0 ? c.h / c.bf : nil
        case .kPct:
            return c.bf > 0 ? (c.so / c.bf) * 100 : nil
        case .bbPct:
            return c.bf > 0 ? (c.bb / c.bf) * 100 : nil
        case .kbbPct:
            guard c.bf > 0 else { return nil }
            return ((c.so - c.bb) / c.bf) * 100
        case .g:
            return c.games
        case .gs:
            return c.gamesStarted
        }
    }

    // MARK: - Filter evaluation

    static func passes(_ filter: BatterFilter, counts: BatterCounts) -> Bool {
        guard let v = compute(filter.metric, from: counts) else { return false }
        return filter.comparator == .atLeast ? v >= filter.value : v <= filter.value
    }

    static func passes(_ filter: PitcherFilter, counts: PitcherCounts) -> Bool {
        guard let v = compute(filter.metric, from: counts) else { return false }
        return filter.comparator == .atLeast ? v >= filter.value : v <= filter.value
    }

    // MARK: - Formatting

    static func format(_ metric: BatterMetric, _ value: Double) -> String {
        switch metric {
        case .avg, .obp, .slg, .ops, .iso:
            return String(format: ".%03d", Int((value * 1000).rounded()))
        case .sb, .g:
            return String(format: "%.0f", value)
        case .sbPct, .bbPct, .kPct:
            return String(format: "%.1f%%", value)
        case .bbk:
            return String(format: "%.2f", value)
        }
    }

    static func format(_ metric: PitcherMetric, _ value: Double) -> String {
        switch metric {
        case .era, .whip:
            return String(format: "%.2f", value)
        case .baa:
            return String(format: ".%03d", Int((value * 1000).rounded()))
        case .kPct, .bbPct, .kbbPct:
            return String(format: "%.1f%%", value)
        case .g, .gs:
            return String(format: "%.0f", value)
        }
    }

    // MARK: - IP display

    static func formatIP(_ outs: Double) -> String {
        let whole = Int(outs / 3)
        let rem = Int(outs.truncatingRemainder(dividingBy: 3))
        return rem == 0 ? "\(whole).0" : "\(whole).\(rem)"
    }
}
