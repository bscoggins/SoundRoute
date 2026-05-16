import XCTest
import CoreAudio
@testable import SoundRoute

/// Live tests that exercise the real CoreAudio device-enumeration path.
/// They require an actual audio environment (any Mac qualifies) but no
/// special permissions — these are safe to run in any local or CI context
/// that isn't a fully headless container.
final class AudioDeviceManagerSmokeTests: XCTestCase {

    func testInitializationSucceeds() {
        // Constructor performs initial enumeration and registers a HAL
        // property listener. A regression in either path would crash here.
        _ = AudioDeviceManager()
    }

    func testAtLeastOneOutputDeviceIsEnumerated() {
        // Every Mac has at least a built-in output device.
        let manager = AudioDeviceManager()
        XCTAssertFalse(
            manager.outputDevices.isEmpty,
            "Expected at least one output device on the test machine"
        )
    }

    func testEnumeratedDevicesHaveStableIdentifiers() {
        let manager = AudioDeviceManager()
        for device in manager.outputDevices + manager.inputDevices {
            XCTAssertFalse(device.uid.isEmpty, "\(device.name) is missing a UID")
            XCTAssertFalse(device.name.isEmpty, "Device id=\(device.id) is missing a name")
        }
    }

    func testDefaultOutputDeviceResolves() {
        let manager = AudioDeviceManager()
        XCTAssertNotNil(
            manager.getDefaultOutputDevice(),
            "Default output device should always resolve on a Mac"
        )
    }

    func testRefreshIsIdempotentWhenHardwareUnchanged() {
        let manager = AudioDeviceManager()
        let initialInputs = manager.inputDevices.map(\.uid).sorted()
        let initialOutputs = manager.outputDevices.map(\.uid).sorted()

        manager.refreshDevices()

        XCTAssertEqual(manager.inputDevices.map(\.uid).sorted(), initialInputs)
        XCTAssertEqual(manager.outputDevices.map(\.uid).sorted(), initialOutputs)
    }
}
