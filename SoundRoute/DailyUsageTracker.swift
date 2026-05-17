import Foundation
import SwiftUI

/// Sole free-tier counter for SoundRoute. Tracks how many seconds of
/// routing the user has consumed today, persists across app launches
/// so quit-and-relaunch can't reset it, and self-stops + fires a
/// callback when the daily cap is reached.
///
/// Rolls over to zero at local midnight. `dateProvider` is injectable
/// so tests can drive rollover deterministically without waiting for
/// an actual day boundary.
///
/// Not `@MainActor` so it can be touched from `AudioManager`'s
/// non-isolated methods. All real-world access happens on the main
/// thread; the `Timer.scheduledTimer` closure fires on the main RunLoop
/// because `start` is invoked from the UI thread.
final class DailyUsageTracker: ObservableObject {
    /// 30 minutes of free routing per day. Tight enough to land the
    /// paywall as a conversion event (vinyl users finish Side A right
    /// around the limit); generous enough to provide a real "try with
    /// your hardware" window. Heavier users — full albums, podcast
    /// recording, all-day work setups — pay.
    static let dailyLimitSeconds: Int = 30 * 60

    @Published private(set) var secondsUsedToday: Int = 0

    private let totalKey = "freeUsage.totalSecondsToday"
    private let dateKey = "freeUsage.lastResetDate"
    private let userDefaults: UserDefaults
    private let dateProvider: () -> Date

    private var timer: Timer?
    private var onLimitReached: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.userDefaults = userDefaults
        self.dateProvider = dateProvider
        rolloverIfNeeded()
    }

    /// Seconds of free routing the user has left today. Clamped to
    /// `[0, dailyLimitSeconds]`.
    var remainingSecondsToday: Int {
        max(0, Self.dailyLimitSeconds - secondsUsedToday)
    }

    /// `true` when the user has consumed today's full budget.
    var isLimitReached: Bool {
        remainingSecondsToday == 0
    }

    /// Begin counting against the daily budget. `onLimitReached` fires
    /// exactly once if the counter hits the daily cap during this
    /// session (whether the cap was approached gradually via ticking or
    /// was already reached at the moment of `start`).
    ///
    /// Calling `start` while already running cancels the previous
    /// callback and begins fresh.
    func start(onLimitReached: @escaping () -> Void) {
        stop()
        rolloverIfNeeded()
        if isLimitReached {
            onLimitReached()
            return
        }
        self.onLimitReached = onLimitReached
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Stop counting. Safe to call repeatedly; safe to call when not
    /// running. Does NOT fire the limit-reached callback.
    func stop() {
        timer?.invalidate()
        timer = nil
        onLimitReached = nil
    }

    /// Single tick — increments the counter by one second, persists,
    /// and fires the limit-reached callback when the cap is hit.
    /// Exposed at `internal` so unit tests can drive expiry
    /// deterministically without RunLoop dependencies; production drives
    /// this via the scheduled `Timer` in `start`.
    func tick() {
        rolloverIfNeeded()
        let nextValue = min(Self.dailyLimitSeconds, secondsUsedToday + 1)
        secondsUsedToday = nextValue
        userDefaults.set(nextValue, forKey: totalKey)
        if isLimitReached {
            let callback = onLimitReached
            stop()
            callback?()
        }
    }

    /// Bulk-record N seconds against today's budget without ticking.
    /// Test convenience; not used by production code. Negative or zero
    /// inputs are no-ops.
    func recordUsage(seconds: Int) {
        guard seconds > 0 else { return }
        rolloverIfNeeded()
        secondsUsedToday = min(Self.dailyLimitSeconds, secondsUsedToday + seconds)
        userDefaults.set(secondsUsedToday, forKey: totalKey)
    }

    /// Compares stored reset-date day to today's day; resets the
    /// counter and persists a fresh reset date if a midnight has passed.
    private func rolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: dateProvider())
        let lastReset = userDefaults.object(forKey: dateKey) as? Date
        let lastResetDay = lastReset.map { Calendar.current.startOfDay(for: $0) }

        if lastResetDay != today {
            secondsUsedToday = 0
            userDefaults.set(0, forKey: totalKey)
            userDefaults.set(today, forKey: dateKey)
        } else {
            secondsUsedToday = userDefaults.integer(forKey: totalKey)
        }
    }
}
