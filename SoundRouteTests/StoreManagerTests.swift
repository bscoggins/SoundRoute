import XCTest
@testable import SoundRoute

/// Tests `StoreManager`'s observable contract and `UserDefaults`
/// entitlement cache behavior. The StoreKit-interaction paths (purchase,
/// transaction handling, refund) are exercised manually via the
/// `Products.storekit` configuration in Xcode — adding `SKTestSession`-
/// based automated tests is tracked as a v1.2+ improvement.
@MainActor
final class StoreManagerTests: XCTestCase {

    private static let cacheKey = "store.isUnlocked.cached"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        super.tearDown()
    }

    func testProductIDIsCanonical() {
        // Locks the product ID. If this changes, the ASC product
        // configuration must change to match — and any users who
        // purchased the old ID would lose entitlement.
        XCTAssertEqual(StoreManager.unlockProductID, "net.abefroman.SoundRoute.unlock")
    }

    func testFreshInstallStartsLocked() {
        let manager = StoreManager()
        XCTAssertFalse(manager.isUnlocked)
    }

    func testCachedUnlockedStateIsHydratedSynchronously() {
        UserDefaults.standard.set(true, forKey: Self.cacheKey)
        let manager = StoreManager()
        // Cache hydration is synchronous in init so the UI doesn't flash
        // a locked state for users who already own unlock. This must be
        // true before any StoreKit refresh completes.
        XCTAssertTrue(manager.isUnlocked)
    }

    func testCachedLockedStateIsHydrated() {
        UserDefaults.standard.set(false, forKey: Self.cacheKey)
        let manager = StoreManager()
        XCTAssertFalse(manager.isUnlocked)
    }

    func testInitialPurchaseErrorIsNil() {
        let manager = StoreManager()
        XCTAssertNil(manager.purchaseError)
    }

    func testInitialIsPurchasingIsFalse() {
        let manager = StoreManager()
        XCTAssertFalse(manager.isPurchasing)
    }

    // MARK: - derivedIsUnlocked predicate

    // These tests exhaustively cover the rule SoundRoute uses to decide
    // whether the user is unlocked. Both code paths (cold-start
    // refreshFromStoreKit + live-update handle) funnel through this
    // predicate, so covering it here covers every possible Transaction
    // shape without needing to drive StoreKit or SKTestSession.

    private static let target = StoreManager.unlockProductID
    private static let otherProduct = "net.abefroman.SoundRoute.other"

    private func snap(
        productID: String = target,
        verified: Bool = true,
        revoked: Bool = false
    ) -> StoreManager.EntitlementSnapshot {
        StoreManager.EntitlementSnapshot(
            productID: productID,
            isVerified: verified,
            revocationDate: revoked ? Date(timeIntervalSince1970: 1_000_000) : nil
        )
    }

    func testDerivedIsUnlockedReturnsFalseForEmptyInput() {
        XCTAssertFalse(StoreManager.derivedIsUnlocked(from: [], targetProductID: Self.target))
    }

    func testDerivedIsUnlockedReturnsTrueForVerifiedNonRevokedMatch() {
        XCTAssertTrue(StoreManager.derivedIsUnlocked(
            from: [snap()],
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedRejectsRevokedTransactions() {
        // The most important negative case — a refund must lock the user.
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(revoked: true)],
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedRejectsUnverifiedTransactions() {
        // Unverified transactions (failed JWS verification) must never
        // grant unlock — this is the integrity boundary.
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(verified: false)],
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedRejectsWrongProduct() {
        // Defensive: if our product ID ever changes and an old
        // transaction lingers, it must not unlock the new product.
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(productID: Self.otherProduct)],
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedRequiresAllThreePropertiesTogether() {
        // Each individual failure mode in isolation must still block.
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(productID: Self.otherProduct, verified: false, revoked: false)],
            targetProductID: Self.target
        ))
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(productID: Self.target, verified: false, revoked: true)],
            targetProductID: Self.target
        ))
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: [snap(productID: Self.otherProduct, verified: true, revoked: true)],
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedTrueIfAnyMatchInMixedList() {
        // Cold-start currentEntitlements may include unrelated or
        // revoked transactions alongside a valid one. A single valid
        // match is sufficient.
        let candidates: [StoreManager.EntitlementSnapshot] = [
            snap(productID: Self.otherProduct),         // wrong product
            snap(verified: false),                       // unverified
            snap(revoked: true),                         // revoked
            snap()                                       // valid match
        ]
        XCTAssertTrue(StoreManager.derivedIsUnlocked(
            from: candidates,
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedFalseIfNoMatchInMixedList() {
        // Every candidate fails at least one check → locked.
        let candidates: [StoreManager.EntitlementSnapshot] = [
            snap(productID: Self.otherProduct),
            snap(verified: false),
            snap(revoked: true),
            snap(productID: Self.otherProduct, verified: false, revoked: true)
        ]
        XCTAssertFalse(StoreManager.derivedIsUnlocked(
            from: candidates,
            targetProductID: Self.target
        ))
    }

    func testDerivedIsUnlockedHandlesMultipleValidMatches() {
        // Two valid grants for the same product (e.g., a re-sync that
        // surfaces the same entitlement twice) should still resolve to
        // unlocked — not error.
        XCTAssertTrue(StoreManager.derivedIsUnlocked(
            from: [snap(), snap()],
            targetProductID: Self.target
        ))
    }
}
