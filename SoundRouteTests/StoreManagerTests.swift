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
}
