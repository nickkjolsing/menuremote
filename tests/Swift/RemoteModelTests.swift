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

    static func testDeviceListRefreshesAndReadsHardwareAndSoftware() {
        withModel { model in
            model.showDevicePicker()
            model.handle(["event": "devices", "devices": [[
                "id": "future-tv", "name": "Living Room", "paired": false,
                "model": "Apple TV 4K (4th generation)", "software": "tvOS 27.1", "build": "24J123",
            ]]])
            precondition(model.devices.map(\.id) == ["future-tv"])
            precondition(model.devices[0].model == "Apple TV 4K (4th generation)")
            precondition(model.devices[0].software == "tvOS 27.1")
            precondition(model.devices[0].softwareBuild == "24J123")
            model.choose(model.devices[0])
            precondition(model.pairing?.device.id == "future-tv")
            model.handle(["event": "devices", "devices": []])
            precondition(model.devices.isEmpty, "Old results should clear on rescan")
        }
    }

    static func testVariableSpeedPlaybackShowsPauseAndCanToggle() {
        withModel { model in
            model.handle(["event": "connected", "device": oldDevice])
            model.handle([
                "event": "now_playing", "state": "seeking", "title": "Sample",
                "position": 10.0, "total": 100.0,
            ])
            precondition(model.nowPlaying.isPlaying, "Variable speed playback should show Pause")
            precondition(!model.nowPlaying.isIdle)
            model.playPause()
            precondition(model.nowPlaying.state == "paused", "Clicking Pause should pause optimistically")
            model.handle(["event": "now_playing", "state": "paused", "title": "Sample"])
            precondition(!model.nowPlaying.isPlaying)
            model.playPause()
            precondition(model.nowPlaying.state == "playing", "Clicking Play should resume")
        }
    }

    static func testDeviceNamesSurviveRelaunchAndRefreshOnConnection() {
        let suite = "MenuRemoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteModel(startAutomatically: false, defaults: defaults)
        model.handle(["event": "connected", "device": oldDevice])
        let restored = RemoteModel(startAutomatically: false, defaults: defaults)
        precondition(restored.deviceName == "Apple TV 4K")
        restored.handle(["event": "connected", "device": ["id": "old-tv", "name": "Living Room"]])
        let renamed = RemoteModel(startAutomatically: false, defaults: defaults)
        precondition(renamed.deviceName == "Living Room")
    }

    static func testTextNeedsCapabilityAndFocusAndOnlyClearsOnMatchingAcknowledgement() {
        withModel { model in
            model.handle(["event": "connected", "device": oldDevice])
            model.textDraft = "Café 🎬"
            precondition(!model.canSendText)
            model.handle(["event": "keyboard", "available": true, "focused": false])
            precondition(!model.canSendText)
            model.handle(["event": "keyboard", "available": true, "focused": true])
            precondition(model.canSendText)
            model.sendText()
            let request = model.textRequestID!
            precondition(model.textSending && !model.canSendText)
            precondition(model.textDraft == "Café 🎬")
            model.handle(["event": "text_sent", "request": "old-request"])
            precondition(model.textSending && !model.textDraft.isEmpty)
            model.handle(["event": "text_sent", "request": request])
            precondition(!model.textSending && model.textDraft.isEmpty && model.textSent)
        }
    }

    static func testTextFailureRetainsDraftAndDisconnectInvalidatesAcknowledgements() {
        withModel { model in
            model.handle(["event": "connected", "device": oldDevice])
            model.handle(["event": "keyboard", "available": true, "focused": true])
            model.textDraft = "Keep this draft"
            model.sendText()
            model.handle(["event": "error", "command": "text",
                          "request": model.textRequestID!, "message": "Try again"])
            precondition(!model.textSending && model.textError == "Try again")
            precondition(model.textDraft == "Keep this draft")
            model.sendText()
            let request = model.textRequestID!
            model.handle(["event": "disconnected"])
            model.handle(["event": "text_sent", "request": request])
            precondition(!model.canSendText && !model.textSending)
            precondition(model.textDraft == "Keep this draft")
        }
    }

    static func testSwitchingDevicesClearsDraftAndIgnoresOldKeyboardEvents() {
        withModel { model in
            model.handle(["event": "connected", "device": oldDevice])
            model.handle(["event": "keyboard", "available": true, "focused": true])
            model.textDraft = String(repeating: "a", count: 4097)
            precondition(!model.canSendText)
            model.textDraft = "Private draft"
            model.sendText()
            let request = model.textRequestID!
            model.showDevicePicker()
            model.handle(["event": "keyboard", "available": true, "focused": true])
            model.handle(["event": "text_sent", "request": request])
            precondition(!model.keyboardAvailable && !model.textSending)
            precondition(model.textDraft.isEmpty && !model.textSent)
        }
    }

    static func testTextEntryFollowsTVFocusAndStopsWhenConnectionIsLost() {
        withModel { model in
            model.handle(["event": "connected", "device": oldDevice])
            model.handle(["event": "keyboard", "available": true, "focused": false])
            precondition(!model.needsTextEntry)
            let initialRequest = model.textFocusRequest
            model.handle(["event": "keyboard", "available": true, "focused": true])
            precondition(model.needsTextEntry)
            precondition(model.textFocusRequest == initialRequest, "TV events must not take keyboard focus")
            model.focusTextEntry()
            precondition(model.textFocusRequest != initialRequest, "Explicit opening should allow typing")
            model.handle(["event": "keyboard", "available": true, "focused": false])
            precondition(!model.needsTextEntry)
            model.handle(["event": "keyboard", "available": false, "focused": true])
            precondition(!model.needsTextEntry, "Unsupported fields should not reveal a composer")
            model.handle(["event": "keyboard", "available": true, "focused": true])
            model.handle(["event": "disconnected"])
            precondition(!model.needsTextEntry)
        }
    }

    static func main() {
        testOldConnectionEventsDoNotDismissDevicePicker()
        testOldConnectionDoesNotCancelReplacementPairing()
        testScanFailureStopsSpinnerAndAllowsRetry()
        testDeviceListRefreshesAndReadsHardwareAndSoftware()
        testVariableSpeedPlaybackShowsPauseAndCanToggle()
        testDeviceNamesSurviveRelaunchAndRefreshOnConnection()
        testTextNeedsCapabilityAndFocusAndOnlyClearsOnMatchingAcknowledgement()
        testTextFailureRetainsDraftAndDisconnectInvalidatesAcknowledgements()
        testSwitchingDevicesClearsDraftAndIgnoresOldKeyboardEvents()
        testTextEntryFollowsTVFocusAndStopsWhenConnectionIsLost()
        print("All 10 remote model tests passed")
    }
}
