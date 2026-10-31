import Foundation
import StoreKit

/// Loads and purchases the optional "buy us a coffee" tips.
///
/// The tips are consumable in-app purchases — nothing is unlocked, so there is
/// no entitlement to track. We just finish each transaction and show a thank-you.
@MainActor
@Observable
final class TipJar {
    static let productIDs = [
        "com.nicolasrichards.ProspectFilter.tip.small",
        "com.nicolasrichards.ProspectFilter.tip.medium",
        "com.nicolasrichards.ProspectFilter.tip.large",
    ]

    /// Shared so the tip screen and the app-level transaction listener see the
    /// same state. The transaction listener is owned here too — see
    /// `startListening`.
    static let shared = TipJar()

    /// Loaded products, sorted cheapest first.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasing: Product.ID?
    private(set) var didTip = false
    /// Products with a purchase that came back `.pending` (Ask to Buy) and is
    /// waiting on approval. Tracked per-product, not a single flag — the
    /// purchase button re-enables as soon as `.pending` is returned (see
    /// `purchasing`'s `defer` below), so a user can start a second tip while
    /// the first is still awaiting approval, and each needs its own state.
    private(set) var pendingApprovals: Set<Product.ID> = []
    /// The last purchase attempt threw, or came back unverified — for example
    /// Screen Time blocks in-app purchases, or the connection dropped.
    private(set) var purchaseFailed = false
    /// Set when the products failed to load or fewer than requested came back.
    private(set) var loadFailed = false

    @ObservationIgnored private var updatesListener: Task<Void, Never>?

    /// Called each time the tip screen appears, and by its Retry button.
    func load() async {
        // A failure message belongs to the visit it happened in
        purchaseFailed = false
        guard products.count < Self.productIDs.count, !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // A retry that returns fewer tiers must not remove buttons that already work
            if loaded.count > products.count {
                products = loaded.sorted { $0.price < $1.price }
            }
            loadFailed = products.count < Self.productIDs.count
        } catch {
            loadFailed = true
        }
    }

    /// Finishes any transaction that completes outside the purchase call
    /// (Ask to Buy approvals, retries after an interruption). Started once
    /// from the `App` init and owned here, so it outlives any window or the
    /// tip screen; calling it again does nothing.
    func startListening() {
        guard updatesListener == nil else { return }
        updatesListener = Task {
            for await update in Transaction.updates {
                await self.handle(update)
            }
        }
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        // Finish unverified transactions too: a tip unlocks nothing, and an
        // unfinished transaction is redelivered on every launch.
        await update.unsafePayloadValue.finish()
        // Only thank someone waiting on an Ask to Buy approval for THIS
        // product. Matching by productID (not just "any pending exists")
        // means a second tip that's still pending isn't mistakenly
        // cleared/thanked by the first one's approval. Anything whose
        // product isn't in pendingApprovals is a leftover transaction
        // redelivered at launch, not a new tip.
        if case .verified(let transaction) = update, pendingApprovals.remove(transaction.productID) != nil {
            didTip = true
        }
    }

    func purchase(_ product: Product) async {
        guard purchasing == nil else { return }
        purchasing = product.id
        purchaseFailed = false
        defer { purchasing = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                // Finished even if unverified, for the same reason as the listener.
                await verification.unsafePayloadValue.finish()
                if case .verified = verification {
                    didTip = true
                } else {
                    purchaseFailed = true
                }
            case .pending:
                pendingApprovals.insert(product.id)
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch StoreKitError.userCancelled {
            // Cancelling the Apple Account sign-in arrives as a thrown error
            // rather than a .userCancelled result; it isn't a failure either way
        } catch {
            purchaseFailed = true
        }
    }
}
