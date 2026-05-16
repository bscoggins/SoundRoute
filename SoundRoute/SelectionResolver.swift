import Foundation
import CoreAudio

/// Pure decisions about which `AudioDevice` to select, extracted from the
/// view layer so they can be unit-tested without spinning up CoreAudio or
/// SwiftUI state.
enum SelectionResolver {
    /// Resolves which device to restore after launch.
    /// Prefers a previously-saved UID match; falls back to the system default;
    /// returns nil if neither resolves to a present device.
    static func restoredDevice(
        from devices: [AudioDevice],
        savedUID: String,
        systemDefault: AudioDeviceID?
    ) -> AudioDevice? {
        if !savedUID.isEmpty,
           let saved = devices.first(where: { $0.uid == savedUID }) {
            return saved
        }
        if let systemDefault {
            return devices.first { $0.id == systemDefault }
        }
        return nil
    }

    /// Re-resolves a currently-selected device against a refreshed device list.
    /// Same UID + same transient `AudioDeviceID` → `.unchanged`.
    /// Same UID + different `AudioDeviceID` → `.updated(refreshed)` (typical
    /// after hot-plug refreshes the system's device list).
    /// UID no longer present → `.disconnected`.
    static func reconcile(current: AudioDevice, against devices: [AudioDevice]) -> Reconciliation {
        guard let updated = devices.first(where: { $0.uid == current.uid }) else {
            return .disconnected
        }
        if updated.id == current.id {
            return .unchanged
        }
        return .updated(updated)
    }

    enum Reconciliation: Equatable {
        case unchanged
        case updated(AudioDevice)
        case disconnected
    }
}
