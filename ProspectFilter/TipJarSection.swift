import SwiftUI
import StoreKit

/// The optional "buy us a coffee" support block, shown at the bottom of HelpView.
///
/// Mirrors the tip jar in the movie apps (ReelRankings / WeeklyMovies), with
/// baseball wording and a `baseball` tier icon in place of `movieclapper` —
/// that symbol needs iOS 18 and this app ships back to iOS 17.
struct TipJarSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    private let tipJar = TipJar.shared

    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6784826914")!

    var body: some View {
        VStack(spacing: 16) {
            Text("Enjoying the app? ⚾️")
                .font(.title3.bold())

            Text("This app is 100% free, ad-free and tracking free, a gift meant for every baseball fan. Have a little extra and want to say thanks? Only do this if you really can afford to!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Text("☕ Buy us a coffee?")
                    .font(.headline)

                if tipJar.didTip {
                    Text("Thank you so much. 💛")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .padding(.vertical, 8)
                } else if !tipJar.pendingApprovals.isEmpty {
                    Text("Waiting for approval. Thank you!")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if tipJar.loadFailed {
                    Text("Tip options couldn't load right now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if tipJar.products.isEmpty {
                    ProgressView()
                        .padding(.vertical, 12)
                } else {
                    ForEach(tipJar.products, id: \.id) { product in
                        tipRow(balls: ballCount(for: product), product: product)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                Button {
                    requestReview()
                } label: {
                    Label("Rate us", systemImage: "star.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openURL(appStoreURL)
                } label: {
                    Label("App Store", systemImage: "arrow.up.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Text("Made with love by Nicolas Richards")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .task { await tipJar.load() }
    }

    private func tipRow(balls: Int, product: Product) -> some View {
        Button {
            Task { await tipJar.purchase(product) }
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    ForEach(0..<balls, id: \.self) { _ in
                        Image(systemName: "baseball")
                    }
                }
                .foregroundStyle(.tint)

                Text(tierName(for: balls))
                    .foregroundStyle(.primary)

                Spacer()

                if tipJar.purchasing == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.headline)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(tipJar.purchasing != nil)
    }

    private func tierName(for balls: Int) -> String {
        switch balls {
        case 1: "Small tip"
        case 2: "Medium tip"
        default: "Large tip"
        }
    }

    /// Ball count keyed off the product's own ID, not its position in a
    /// price-sorted list — that list can have fewer than 3 entries whenever
    /// not every tier is approved yet, which would otherwise mislabel tiers.
    private func ballCount(for product: Product) -> Int {
        if product.id.hasSuffix(".small") { return 1 }
        if product.id.hasSuffix(".medium") { return 2 }
        return 3
    }
}
