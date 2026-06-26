import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("This app finds batters or pitchers who meet certain metrics. Which metrics? The ones YOU set. You can be as general or restrictive as you wish. Add multiple filters to narrow the results, or just one to get almost everyone. You are in control.")
                    .font(.body)

                Group {
                    HelpSection(title: "Filters tab") {
                        HelpItem(title: "Batters / Pitchers",
                                 detail: "Toggle at the top of the Filters tab switches between batter and pitcher mode. Results and filter options update accordingly.")
                        HelpItem(title: "Qualifier",
                                 detail: "Sets the minimum plate appearances (batters) or innings pitched (pitchers) a player must have. Tap the number to edit it. Tap Reset to restore the default (50 PA / 20 IP).")
                        HelpItem(title: "Adding a filter",
                                 detail: "Tap Add Filter to add a metric threshold. Pick a metric from the dropdown (AVG, OBP, ERA, etc.), choose ≥ or ≤, then tap the value button to open the wheel and set your cutoff.")
                        HelpItem(title: "Removing a filter",
                                 detail: "Tap Edit (top left) to enter edit mode. Tap the red circle next to any filter, then Delete. Tap Done when finished.")
                        HelpItem(title: "Reordering filters",
                                 detail: "In Edit mode, drag the handle on the right of each filter row to reorder. The first filter also determines the sort order of results.")
                    }

                    HelpSection(title: "Find tab") {
                        HelpItem(title: "Cohort",
                                 detail: "Narrow the player pool by organization, level (AAA through Rookie), max age, and position or role before the stat filters are applied.")
                        HelpItem(title: "Find Players",
                                 detail: "Tap Find Players to run the search. Results appear below, sorted by the first filter's value.")
                        HelpItem(title: "Auto-refresh",
                                 detail: "After your first search, results update automatically whenever you change a filter, qualifier, cohort setting, or mode. No need to tap Find Players again.")
                        HelpItem(title: "Results",
                                 detail: "Each row shows the player's position, age, level, team, and their values for each active filter. An IL badge marks players currently on the injured list. A blue note appears if the player has since moved to a different level than where their stats were compiled.")
                        HelpItem(title: "Player detail",
                                 detail: "Tap any player row to see their full stat line broken out by level for the current season.")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("How to Use")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Helpers

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
    }
}

private struct HelpItem: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
