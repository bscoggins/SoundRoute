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
    ///
    /// `AppStore.sync()` re-delivers entitlements through `Transaction.updates`,
    /// which our listener handles authoritatively. We deliberately don't
    /// re-query `Transaction.currentEntitlements` here — that's the
    /// cold-start path (which init owns) and re-querying would let an
    /// empty response clobber an entitlement that `handle(.verified)`
    /// just set during the sync.
    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
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
        // Empty currentEntitlements is treated as authoritative ("user
        // owns nothing") — this is required so refunds processed while
        // the app was closed re-lock on next launch. handle(.verified)
        // is the live-update path; refreshFromStoreKit is the cold-start
        // path.
        var snapshots: [EntitlementSnapshot] = []
        for await result in Transaction.currentEntitlements {
            snapshots.append(EntitlementSnapshot(verificationResult: result))
        }
        let unlocked = Self.derivedIsUnlocked(from: snapshots, targetProductID: Self.unlockProductID)
        isUnlocked = unlocked
        UserDefaults.standard.set(unlocked, forKey: Self.entitlementCacheKey)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = result else { return }
        await txn.finish()
        guard txn.productID == Self.unlockProductID else { return }
        // Authoritative: a verified transaction just arrived for our
        // product. If revocationDate is nil it's a purchase/restore;
        // if set it's a refund/revocation. Flip immediately — don't
        // wait on a follow-up currentEntitlements query.
        let snapshot = EntitlementSnapshot(
            productID: txn.productID,
            isVerified: true,
            revocationDate: txn.revocationDate
        )
        let unlocked = Self.derivedIsUnlocked(from: [snapshot], targetProductID: Self.unlockProductID)
        isUnlocked = unlocked
        UserDefaults.standard.set(unlocked, forKey: Self.entitlementCacheKey)
    }

    // MARK: - Pure entitlement derivation (testable)

    /// Pure data carrier describing what we care about in a Transaction
    /// for entitlement-derivation purposes. Decouples our decision logic
    /// from `StoreKit.Transaction` (which is hard to mock) so the
    /// predicate can be tested exhaustively without StoreKit at all.
    struct EntitlementSnapshot: Equatable {
        let productID: String
        let isVerified: Bool
        let revocationDate: Date?

        init(productID: String, isVerified: Bool, revocationDate: Date?) {
            self.productID = productID
            self.isVerified = isVerified
            self.revocationDate = revocationDate
        }

        init(verificationResult: VerificationResult<Transaction>) {
            switch verificationResult {
            case .verified(let txn):
                self.init(productID: txn.productID, isVerified: true, revocationDate: txn.revocationDate)
            case .unverified(let txn, _):
                self.init(productID: txn.productID, isVerified: false, revocationDate: txn.revocationDate)
            }
        }
    }

    /// Returns `true` iff any snapshot is a verified, non-revoked match
    /// for `targetProductID`. This is the single rule that governs
    /// whether SoundRoute considers the user "unlocked" — both the
    /// cold-start (`refreshFromStoreKit`) and live-update (`handle`)
    /// paths funnel through here.
    static func derivedIsUnlocked(
        from snapshots: [EntitlementSnapshot],
        targetProductID: String
    ) -> Bool {
        snapshots.contains { snap in
            snap.isVerified
                && snap.productID == targetProductID
                && snap.revocationDate == nil
        }
    }
}
