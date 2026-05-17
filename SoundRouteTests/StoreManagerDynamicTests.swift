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

    func testPriorPurchaseIsDetectedOnInit() async throws {
        // Simulate the user having already purchased before this StoreManager
        // instance ever existed — the canonical "restore on fresh install"
        // scenario.
        let txn = try await session.buyProduct(productIdentifier: StoreManager.unlockProductID)
        XCTAssertNotNil(txn)

        let manager = StoreManager()
        try await waitFor(timeout: 5) { manager.isUnlocked }
        XCTAssertTrue(manager.isUnlocked)
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
