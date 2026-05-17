import XCTest
import StoreKit
import StoreKitTest
import Combine
@testable import SoundRoute

/// SKTestSession-driven tests that exercise the real StoreKit purchase
/// and restore code paths in `StoreManager` against a simulated store.
/// These complement the contract/cache tests in `StoreManagerTests` —
/// together they cover both the static observable state and the live
/// transaction-handling wiring.
///
/// Requires `Products.storekit` to be a bundle resource of the test
/// target (auto-included via the synchronized group).
@MainActor
final class StoreManagerDynamicTests: XCTestCase {

    private var session: SKTestSession!
    private var cancellables: Set<AnyCancellable> = []

    private static let cacheKey = "store.isUnlocked.cached"

    override func setUpWithError() throws {
        session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.clearTransactions()
        // Don't let cached state from a previous run pre-flip isUnlocked.
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    override func tearDownWithError() throws {
        session.clearTransactions()
        session = nil
        cancellables.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: -

    func testFreshSessionWithNoTransactionsStaysLocked() async throws {
        let manager = StoreManager()
        // Wait for the init's refreshFromStoreKit Task to settle.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(manager.isUnlocked)
    }

    func testProductLoadsFromConfiguration() async throws {
        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.unlockProduct != nil }
        XCTAssertEqual(manager.unlockProduct?.id, StoreManager.unlockProductID)
        // StoreKit exposes a localized price; we don't assert the exact
        // string (locale-dependent) but it should be non-empty.
        XCTAssertFalse(manager.unlockProduct?.displayPrice.isEmpty ?? true)
    }

    func testPurchaseFlipsIsUnlockedTrue() async throws {
        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.unlockProduct != nil }
        XCTAssertFalse(manager.isUnlocked)

        await manager.purchase()

        try await waitFor(timeout: 5) { manager.isUnlocked }
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertNil(manager.purchaseError)
    }

    // Note: the cold-start "prior purchase detected on init" scenario
    // (user purchased on device A, fresh install on device B) used to
    // live here as testPriorPurchaseIsDetectedOnInit. It was removed
    // when StoreManager.derivedIsUnlocked was extracted as a pure
    // predicate — that predicate is now exhaustively covered by
    // StoreManagerTests, and the remaining integration concern (does
    // Transaction.currentEntitlements actually surface a prior
    // purchase?) is a StoreKit-API contract, not our logic. The
    // pre-submission checklist's manual sandbox-tester step covers
    // the live StoreKit-API confirmation.

    func testRefundLocksTheUser() async throws {
        // A refund processed by App Review or by Apple arrives via
        // Transaction.updates as a verified Transaction with revocationDate
        // set. StoreManager.handle must lock the user immediately.
        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.unlockProduct != nil }

        await manager.purchase()
        try await waitFor(timeout: 5) { manager.isUnlocked }
        XCTAssertTrue(manager.isUnlocked, "Purchase must unlock before testing refund")

        // SKTestSession's refundTransaction delivers a revocation through
        // Transaction.updates that handle() picks up.
        let transactions = session.allTransactions()
        guard let purchased = transactions.first(where: { $0.productIdentifier == StoreManager.unlockProductID }) else {
            XCTFail("No purchased transaction available to refund")
            return
        }
        try await session.refundTransaction(identifier: UInt(purchased.identifier))

        try await waitFor(timeout: 5) { !manager.isUnlocked }
        XCTAssertFalse(manager.isUnlocked, "Refund must lock the user")
    }

    func testRestoreWithNoEntitlementStaysLocked() async throws {
        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.unlockProduct != nil }
        XCTAssertFalse(manager.isUnlocked)

        // No buyProduct call — the session has no transactions. Restore
        // must succeed silently without surfacing an error to the user
        // (a noisy "no purchases found" message is a known App Review
        // anti-pattern).
        await manager.restorePurchases()

        // Brief settle window in case anything fires asynchronously.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(manager.isUnlocked, "Restore with no entitlement must stay locked")
        XCTAssertNil(manager.purchaseError, "Restore with no entitlement must not surface an error")
    }

    func testRefreshFromStoreKitDoesNotKeepStaleUnlock() async throws {
        // Production scenario: user was unlocked, App Store processed a
        // refund while the app was closed, app launches. The cache says
        // true, but Transaction.currentEntitlements (on a fresh real
        // device) returns nothing. refreshFromStoreKit must trust the
        // empty result and re-lock — otherwise refunds never take effect
        // until the user manually restores.
        UserDefaults.standard.set(true, forKey: Self.cacheKey)
        // No buyProduct call — currentEntitlements will be empty.

        let manager = StoreManager()
        // Cache hydrates synchronously, so isUnlocked starts true.
        XCTAssertTrue(manager.isUnlocked, "Cache hydration must run synchronously")

        // After refreshFromStoreKit completes and finds nothing, the
        // user must be re-locked.
        try await waitFor(timeout: 5) { !manager.isUnlocked }
        XCTAssertFalse(
            manager.isUnlocked,
            "Empty currentEntitlements must override a stale cached unlock"
        )
    }

    func testRestorePurchasesPicksUpExistingEntitlement() async throws {
        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.unlockProduct != nil }
        XCTAssertFalse(manager.isUnlocked)

        // Simulate the user purchasing on a different device — the
        // current process has no transaction record until restore runs.
        _ = try await session.buyProduct(productIdentifier: StoreManager.unlockProductID)

        await manager.restorePurchases()

        try await waitFor(timeout: 5) { manager.isUnlocked }
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertNil(manager.purchaseError)
    }

    // MARK: - Helpers

    /// Polls `condition` until it returns true or `timeout` seconds have
    /// elapsed. Uses short sleeps rather than Combine because some of
    /// the relevant state transitions happen via StoreKit's own async
    /// sequences that don't surface through `@Published` projections in
    /// a way Combine can observe cheaply.
    private func waitFor(
        timeout: TimeInterval,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Condition never became true within \(timeout)s", file: file, line: line)
    }
}
