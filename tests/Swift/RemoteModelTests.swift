import Foundation

// A standalone harness keeps these tests runnable with Command Line Tools alone.
@main
@MainActor
enum RemoteModelTests {
    static func withModel(_ test: (RemoteModel) -> Void) {
        let suite = "MenuRemoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(RemoteModel(startAutomatically: false, defaults: defaults))
    }

    static let oldDevice: [String: Any] = [
        "id": "old-tv", "name": "Apple TV 4K", "paired": true,
    ]

    static func testOldConnectionEventsDoNotDismissDevicePicker() {
        withModel { model in
            model.showDevicePicker()
            let events: [[String: Any]] = [
                ["event": "connecting", "id": "old-tv"],
                ["event": "reconnecting", "seconds": 2],
                ["event": "disconnected", "reason": "Connection lost"],
                ["event": "asleep", "device": oldDevice],
                ["event": "needs_pairing", "device": oldDevice],
                ["event": "connected", "device": oldDevice],
            ]
            for event in events {
                model.handle(event)
                precondition(model.phase == .choosingDevice, "Picker dismissed by \(event)")
                precondition(model.pairing == nil, "Old TV started pairing")
            }
            model.handle(["event": "devices", "devices": [[
                "id": "new-tv", "name": "Apple TV 4K", "model": "AppleTV18,1",
            ]]])
            precondition(model.devices.map(\.id) == ["new-tv"])
            precondition(!model.scanning)
            // A successful background connection is available if the user goes back.
            model.closeDevicePicker()
            precondition(model.phase == .connected)
        }
    }

    static func testOldConnectionDoesNotCancelReplacementPairing() {
        withModel { model in
            model.showDevicePicker()
            let replacement = AppleTVDevice([
                "id": "new-tv", "name": "Apple TV 4K", "paired": false,
            ])!
            model.choose(replacement)
            model.handle(["event": "connected", "device": oldDevice])
            model.handle(["event": "needs_pairing", "device": oldDevice])
            precondition(model.pairing?.device.id == "new-tv")
            model.handle(["event": "pairing", "state": "done"])
            model.handle(["event": "connected", "device": [
                "id": "new-tv", "name": "Apple TV 4K", "paired": true,
            ]])
            precondition(model.pairing == nil)
            precondition(model.phase == .connected)
            precondition(model.hasSavedDevice)
        }
    }

    static func testScanFailureStopsSpinnerAndAllowsRetry() {
        withModel { model in
            model.showDevicePicker()
            model.handle(["event": "error", "command": "scan", "message": "Network unavailable"])
            precondition(!model.scanning)
            precondition(model.scanError == "Network unavailable")
            precondition(model.phase == .choosingDevice)
            model.scan()
            precondition(model.scanning)
            precondition(model.scanError == nil)
        }
    }

    static func testUnclassifiedDevicesRemainSelectable() {
        withModel { model in
            model.showDevicePicker()
            model.handle(["event": "devices", "devices": [], "other_devices": [[
                "id": "future-tv", "name": "Living Room", "paired": false,
            ]]])
            precondition(model.devices.isEmpty)
            precondition(model.otherDevices.map(\.id) == ["future-tv"])
            model.choose(model.otherDevices[0])
            precondition(model.pairing?.device.id == "future-tv")
            model.handle(["event": "devices", "devices": []])
            precondition(model.otherDevices.isEmpty, "Old fallback results should clear on rescan")
        }
    }

    static func main() {
        testOldConnectionEventsDoNotDismissDevicePicker()
        testOldConnectionDoesNotCancelReplacementPairing()
        testScanFailureStopsSpinnerAndAllowsRetry()
        testUnclassifiedDevicesRemainSelectable()
        print("All 4 device picker tests passed")
    }
}
