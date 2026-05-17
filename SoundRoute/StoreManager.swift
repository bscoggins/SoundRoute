import Foundation
import StoreKit

/// Owns StoreKit 2 product loading, transaction monitoring, and
/// entitlement state for the SoundRoute unlock IAP. Publishes a single
/// `isUnlocked` boolean that the rest of the app subscribes to.
///
/// On launch the manager:
///   1. Hydrates `isUnlocked` from a `UserDefaults` cache so the UI
///      doesn't flash a locked state for users who already own unlock.
///   2. Subscribes to `Transaction.updates` for real-time changes —
///      purchases, refunds, restores on other devices.
///   3. Re-verifies entitlement against `Transaction.currentEntitlements`
///      and overwrites the cache. The cache is for first-paint speed;
///      StoreKit is the source of truth.
@MainActor
final class StoreManager: ObservableObject {
    /// Single instance shared between the SwiftUI environment and the
    /// AppKit-side `AppDelegate` (which can't easily participate in the
    /// SwiftUI environment). Lazy — created on first access.
    static let shared = StoreManager()

    static let unlockProductID = "net.abefroman.SoundRoute.unlock"
    private static let entitlementCacheKey = "store.isUnlocked.cached"

    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var unlockProduct: Product?
    @Published private(set) var purchaseError: String?
    @Published private(set) var isPurchasing: Bool = false

    private var updatesTask: Task<Void, Never>?

    init() {
        isUnlocked = UserDefaults.standard.bool(forKey: Self.entitlementCacheKey)
        startListeningForTransactions()
        Task { await refreshFromStoreKit() }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Public API

    /// Trigger the StoreKit purchase flow for the unlock product.
    /// Flips `isUnlocked` on success; sets `purchaseError` on failure.
    func purchase() async {
        guard let product = unlockProduct else {
            purchaseError = "Product unavailable. Check your internet connection and try again."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
                purchaseError = nil
            case .userCancelled:
                purchaseError = nil
            case .pending:
                purchaseError = "Purchase pending — check Settings → App Store for approval."
            @unknown default:
                purchaseError = nil
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Re-pull entitlements from the App Store. Used when the customer
    /// previously purchased on a different device or had their receipt
    /// wiped. Required by App Store Review Guideline 3.1.1.
    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshFromStoreKit()
            purchaseError = nil
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Internals

    private func startListeningForTransactions() {
        // Detached so the long-lived listener loop doesn't sit on
        // MainActor between updates.
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    private func refreshFromStoreKit() async {
        // Load the product so we have a localized price for the UI.
        // A failure here is non-fatal — purchase() will surface a
        // clearer message if the user actually tries to buy.
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            unlockProduct = products.first
        } catch {
            // Intentionally swallowed — see comment above.
        }

        // Re-derive entitlement from StoreKit's authoritative answer.
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result,
               txn.productID == Self.unlockProductID,
               txn.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
        UserDefaults.standard.set(unlocked, forKey: Self.entitlementCacheKey)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = result else { return }
        await txn.finish()
        await refreshFromStoreKit()
    }
}
