# ProspectFilter

iOS and iPadOS app, also built for Mac Catalyst (SwiftUI, Swift 6, iOS 17.0+), that finds minor league players who meet stat thresholds the user defines: OBP, ERA, K%, SB and so on, across every organization or a single org, level or age group. Live on the App Store. A generalization of the owner's private PDBLScore app: same MLB Stats API plumbing, but with user-editable filters instead of fixed scoring.

## Workflow

The owner runs Claude Code locally on a Mac, in this folder, and opens the project in Xcode to find the latest changes. The owner does not use Terminal, so do not ask them to run git or shell commands; do the git work yourself. This folder is the only source; `~/Documents/Claude App Notes/ProspectFilter/` holds the owner's notes and assets (icon source, a saved filter set, a screenshot) and is read-only reference, never code.

- Build from the command line with `xcodebuild -project ProspectFilter.xcodeproj -scheme ProspectFilter -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` (verified on the owner's Mac, 2026-10-27). Do not report a build as passing unless one actually ran. There is no test target.
- Cloud sessions work on a fresh clone with no Xcode: say plainly that a change is unbuilt, push a `claude/...` branch, and merge it into `main` rather than copying its commits onto `main`.
- `ProspectFilter.xcodeproj` is hand-authored with synchronized folder groups (no XcodeGen). New files in `ProspectFilter/` are picked up without editing `project.pbxproj`.
- Before committing, review your own diff for regressions. Commit and push to `main` when the work is done.

## Layout

- `ProspectFilter/Models.swift`: core types (batter and pitcher counts, metrics, filters, match results)
- `MLBClient.swift`: MLB Stats API client (rosters, stats per level, current team, IL status, season ages)
- `Metrics.swift`: metric computation and pass/fail (`ipToOuts`, `outsToIP`, `compute`, `passes`, `format`)
- `FilterStore.swift`: the filter set (min PA, min IP, batter and pitcher filters), persisted as JSON
- `FiltersView.swift` (screen 1), `MainView.swift` + `MainViewModel` (screen 2: cohort, Find, results), `PlayerDetailView.swift`, `HelpView.swift`
- `TipJar.swift`, `TipJarSection.swift`, `ProspectFilter.storekit`
- `docs/`: GitHub Pages site (privacy and support page)

## Conventions and gotchas

- Percentage metrics (K%, BB%, SB%, K-BB%) are stored and entered as percent numbers (25 means 25%); `Metrics.compute` returns them times 100. Rate metrics (AVG, OBP and so on) are raw decimals.
- Starters versus relievers: a pitcher is a reliever when batters faced per appearance is under 10 (`PitcherCounts.relieverBFPerGame`), matching PDBLScore. BAA is hits / at-bats (not batters faced). Season age is the age on July 1 of the season.
- The current season (`currentSeasonYear()`, the search season and the detail screen's starting year) is the year in America/New_York, minus one before March 20, because minor league games don't start until the last week of March. The detail year bar can go up to the calendar year (`currentCalendarYear()`). "Now promoted to MLB" notes only show March 20 through September (`isDuringSeason()`): in the offseason a 40-man player's current team is the parent club.
- "All minor league levels" scans sportIds 11, 12, 13, 14 and 16, dedupes by personId, and judges the combined minor league line.
- Network fan-out is bounded (`mapConcurrently`, cap 8). Failed player lookups count as failures, not as non-matches, and show a "results may be incomplete" note.
- Results and per-player loads are guarded by generation tokens, so a superseded search or season switch can't overwrite newer results. Keep that pattern for any new async load.
- IL and promotion flags are resolved after filtering, only for matched players. A failure there falls back to unflagged results rather than discarding the search.
- Results rows deliberately do not show team names. Real affiliate names in an App Store screenshot caused a Guideline 4.1(a) rejection.
- App Store listing: never use the literal "MLB" or "MiLB" in the name, subtitle, description or keywords. Spell out "minor league" or "major league". In-app text and code are fine.
- Tip jar: consumable tips `com.nicolasrichards.ProspectFilter.tip.{small,medium,large}`; the `Transaction.updates` listener is a Task owned by `TipJar.shared`, started once from the `App` init (`startListening()`, idempotent).
- Version bumps are their own commits, titled like `Bump to 1.6 (10)`. The owner archives and uploads from Xcode.
- The repo is public on purpose (GitHub Pages), so never commit secrets.

## Docs

`README.md` is only the App Store description, one paragraph.
