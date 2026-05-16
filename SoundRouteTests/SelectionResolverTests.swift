import XCTest
import CoreAudio
@testable import SoundRoute

final class SelectionResolverTests: XCTestCase {

    private let micA = AudioDevice(id: 10, uid: "uid-mic-a", name: "Mic A", isInput: true)
    private let micB = AudioDevice(id: 11, uid: "uid-mic-b", name: "Mic B", isInput: true)
    private let speakers = AudioDevice(id: 20, uid: "uid-speakers", name: "Speakers", isInput: false)

    // MARK: - restoredDevice

    func testRestoredDeviceMatchesSavedUID() {
        let result = SelectionResolver.restoredDevice(
            from: [micA, micB],
            savedUID: "uid-mic-b",
            systemDefault: micA.id
        )
        XCTAssertEqual(result?.uid, "uid-mic-b")
    }

    func testRestoredDeviceFallsBackToSystemDefaultWhenSavedUIDAbsent() {
        let result = SelectionResolver.restoredDevice(
            from: [micA, micB],
            savedUID: "uid-disconnected",
            systemDefault: micA.id
        )
        XCTAssertEqual(result?.uid, "uid-mic-a")
    }

    func testRestoredDeviceFallsBackToSystemDefaultWhenSavedUIDEmpty() {
        let result = SelectionResolver.restoredDevice(
            from: [micA, micB],
            savedUID: "",
            systemDefault: micB.id
        )
        XCTAssertEqual(result?.uid, "uid-mic-b")
    }

    func testRestoredDeviceReturnsNilWhenNoMatchAndNoDefault() {
        let result = SelectionResolver.restoredDevice(
            from: [micA, micB],
            savedUID: "uid-disconnected",
            systemDefault: nil
        )
        XCTAssertNil(result)
    }

    func testRestoredDeviceReturnsNilWhenDeviceListEmpty() {
        let result = SelectionResolver.restoredDevice(
            from: [],
            savedUID: "uid-mic-a",
            systemDefault: 10
        )
        XCTAssertNil(result)
    }

    func testRestoredDevicePrefersSavedUIDOverSystemDefault() {
        // Even when the system default is present in the list, an explicit
        // saved selection wins.
        let result = SelectionResolver.restoredDevice(
            from: [micA, micB],
            savedUID: "uid-mic-b",
            systemDefault: micA.id
        )
        XCTAssertEqual(result?.uid, "uid-mic-b")
    }

    // MARK: - reconcile

    func testReconcileUnchangedWhenSameDevicePresent() {
        let result = SelectionResolver.reconcile(current: micA, against: [micA, speakers])
        XCTAssertEqual(result, .unchanged)
    }

    func testReconcileUpdatedWhenAudioDeviceIDChangedButUIDStable() {
        // Hot-plug refresh path: the OS reassigns AudioDeviceID but the UID
        // (kAudioDevicePropertyDeviceUID) is stable across reconnects.
        let refreshedMicA = AudioDevice(id: 99, uid: "uid-mic-a", name: "Mic A", isInput: true)
        let result = SelectionResolver.reconcile(current: micA, against: [refreshedMicA])

        guard case .updated(let device) = result else {
            return XCTFail("Expected .updated, got \(result)")
        }
        XCTAssertEqual(device.id, 99)
        XCTAssertEqual(device.uid, "uid-mic-a")
    }

    func testReconcileDisconnectedWhenUIDNoLongerPresent() {
        let result = SelectionResolver.reconcile(current: micA, against: [micB, speakers])
        XCTAssertEqual(result, .disconnected)
    }

    func testReconcileDisconnectedAgainstEmptyDeviceList() {
        let result = SelectionResolver.reconcile(current: micA, against: [])
        XCTAssertEqual(result, .disconnected)
    }
}
