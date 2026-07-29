import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                Text("This app finds batters or pitchers who meet certain metrics. Which metrics? The ones YOU set. You can be as general or restrictive as you wish. Add multiple filters to narrow the results, or just one to get almost everyone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                HelpSection(title: "Filters tab", color: .blue) {
                    HelpItem(icon: "person.2",         title: "Batters / Pitchers",
                             detail: "Toggle at the top switches between batter and pitcher mode.")
                    HelpItem(icon: "slider.horizontal.3", title: "Qualifier",
                             detail: "Sets the minimum PA or IP a player must have. Tap the number to change it. Reset restores the default (50 PA / 20 IP).")
                    HelpItem(icon: "plus.circle",      title: "Adding a filter",
                             detail: "Tap Add Filter, pick a metric (AVG, OBP, ERA, etc.), choose ≥ or ≤, then tap the value to set your cutoff on the wheel.")
                    HelpItem(icon: "minus.circle",     title: "Removing a filter",
                             detail: "Tap Edit, then the red circle next to any filter, then Delete. Tap Done when finished.")
                    HelpItem(icon: "arrow.up.arrow.down", title: "Reordering filters",
                             detail: "In Edit mode, drag the handle on the right to reorder. The first filter determines the sort order of results.")
                }

                HelpSection(title: "Find tab", color: .green) {
                    HelpItem(icon: "scope",            title: "Cohort",
                             detail: "Narrow by organization, level (AAA through Rookie), max age, and position or role.")
                    HelpItem(icon: "magnifyingglass",  title: "Find Players",
                             detail: "Tap Find Players to run the search. Results appear below, sorted by the first filter's value.")
                    HelpItem(icon: "arrow.clockwise",  title: "Auto-refresh",
                             detail: "After your first search, results update automatically whenever you change any filter or cohort setting.")
                    HelpItem(icon: "list.bullet",      title: "Results",
                             detail: "Each row shows position, age, level, team, and filter values. An IL badge marks injured players. A blue note flags a level change since their stats were compiled.")
                    HelpItem(icon: "person.crop.rectangle", title: "Player detail",
                             detail: "Tap any row to see their full stat line by level for the current season.")
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
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color, in: Capsule())
                .padding(.bottom, 14)

            content()
        }
    }
}

private struct HelpItem: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 16)
    }
}
