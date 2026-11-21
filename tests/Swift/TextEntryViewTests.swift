import AppKit
import SwiftUI

// Native, offline interaction checks; no TV, helper process, or saved preferences.
@main
@MainActor
enum TextEntryViewTests {
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    static func waitForEditor(in window: NSWindow) {
        let deadline = Date().addingTimeInterval(3)
        while !(window.firstResponder is NSTextView) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(window.firstResponder is NSTextView, "Text editor did not receive keyboard focus")
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "MenuRemote.TextEntryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteModel(startAutomatically: false, defaults: defaults)
        model.handle(["event": "connected", "device": ["id": "test-tv", "name": "Living Room"]])
        model.handle(["event": "keyboard", "available": true, "focused": false])
        model.nowPlaying = NowPlaying(["state": "paused", "title": "Sample"])
        let hosting = NSHostingView(rootView: PlayerView()
            .environmentObject(model).environmentObject(AppUpdater())
            .defaultAppStorage(defaults).frame(width: 340))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settle()
        let compactHeight = hosting.fittingSize.height
        let navigationResponder = window.firstResponder

        func key(_ characters: String, code: UInt16) {
            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
            settle()
        }

        model.handle(["event": "keyboard", "available": true, "focused": true])
        settle()
        window.setContentSize(hosting.fittingSize)
        precondition(hosting.fittingSize.height > compactHeight + 30, "Composer did not appear")
        precondition(window.firstResponder === navigationResponder, "TV event stole navigation focus")
        key("h", code: 4)
        precondition(model.textDraft.isEmpty, "Navigation keys were redirected into the composer")

        model.focusTextEntry()
        waitForEditor(in: window)
        key("h", code: 4)
        key(" ", code: 49)
        key("[", code: 33)
        precondition(model.textDraft == "h [", "Remote shortcuts intercepted typing")
        precondition(model.nowPlaying.state == "paused", "Space toggled playback while typing")
        key("\u{7f}", code: 51)
        precondition(model.textDraft == "h ", "Delete did not edit the draft")
        let composerHeight = hosting.fittingSize.height
        key("\r", code: 36)
        precondition(model.textSending, "Return did not send the draft")
        model.handle(["event": "text_sent", "request": model.textRequestID!])
        settle()
        precondition(model.textSent, "Successful send did not show confirmation")
        precondition(abs(hosting.fittingSize.height - composerHeight) < 1, "Receipt moved the panel")
        waitForEditor(in: window)
        key("x", code: 7)
        precondition(model.textDraft == "x" && !model.textSent, "Receipt blocked continued typing")
        key("\r", code: 36)
        model.handle(["event": "text_sent", "request": model.textRequestID!])
        settle()
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        precondition(!model.textSent, "Sent confirmation did not reset automatically")
        precondition(abs(hosting.fittingSize.height - composerHeight) < 1, "Reset moved the panel")
        precondition(model.needsTextEntry && model.textDraft.isEmpty, "Reset changed the active field or draft")
        waitForEditor(in: window)
        key("x", code: 7)
        precondition(model.textDraft == "x", "Typing focus did not return after sending")

        model.handle(["event": "keyboard", "available": true, "focused": false])
        settle()
        precondition(abs(hosting.fittingSize.height - compactHeight) < 1, "Composer did not disappear")
        key("h", code: 4)
        precondition(model.textDraft == "x", "Leaving the field did not restore remote navigation")

        model.handle(["event": "keyboard", "available": false, "focused": true])
        settle()
        precondition(abs(hosting.fittingSize.height - compactHeight) < 1, "Unsupported keyboard appeared")
        window.close()
        print("Native text-entry checks passed: contextual visibility, focus, typing, send, dismissal")
    }
}
