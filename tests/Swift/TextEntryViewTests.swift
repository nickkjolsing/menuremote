import AppKit
import SwiftUI

// Native, offline interaction checks; no TV, helper process, or saved preferences.
@main
@MainActor
enum TextEntryViewTests {
    static func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    static func waitForEditor(in window: NSWindow) async {
        let deadline = Date().addingTimeInterval(3)
        while !(window.firstResponder is NSTextView) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(window.firstResponder is NSTextView, "Text editor did not receive keyboard focus")
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            await runChecks()
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    static func runChecks() async {
        await checkSelectButton()
        await checkVolumeButtons()
        await checkAppActions()
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let activationDeadline = Date().addingTimeInterval(3)
        while (!NSApp.isActive || !window.isKeyWindow) && Date() < activationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(NSApp.isActive && window.isKeyWindow, "Test window did not activate")
        await settle()
        let compactHeight = hosting.fittingSize.height
        let navigationResponder = window.firstResponder

        func key(_ characters: String, code: UInt16) async {
            for type: NSEvent.EventType in [.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
            await settle()
        }

        model.handle(["event": "keyboard", "available": true, "focused": true])
        await settle()
        window.setContentSize(hosting.fittingSize)
        precondition(hosting.fittingSize.height > compactHeight + 30, "Composer did not appear")
        precondition(window.firstResponder === navigationResponder, "TV event stole navigation focus")
        await key("h", code: 4)
        precondition(model.textDraft.isEmpty, "Navigation keys were redirected into the composer")

        model.focusTextEntry()
        await waitForEditor(in: window)
        await key("h", code: 4)
        await key(" ", code: 49)
        await key("[", code: 33)
        precondition(model.textDraft == "h [", "Unexpected typing: draft=\(model.textDraft.debugDescription), editor=\(String(describing: (window.firstResponder as? NSTextView)?.string)), active=\(NSApp.isActive), keyWindow=\(window.isKeyWindow)")
        precondition(model.nowPlaying.state == "paused", "Space toggled playback while typing")
        await key("\u{7f}", code: 51)
        precondition(model.textDraft == "h ", "Delete did not edit the draft")
        let composerHeight = hosting.fittingSize.height
        await key("\r", code: 36)
        precondition(model.textSending, "Return did not send the draft")
        model.handle(["event": "text_sent", "request": model.textRequestID!])
        await settle()
        precondition(model.textSent, "Successful send did not show confirmation")
        precondition(abs(hosting.fittingSize.height - composerHeight) < 1, "Receipt moved the panel")
        await waitForEditor(in: window)
        await key("x", code: 7)
        precondition(model.textDraft == "x" && !model.textSent, "Receipt blocked continued typing")
        await key("\r", code: 36)
        model.handle(["event": "text_sent", "request": model.textRequestID!])
        await settle()
        try? await Task.sleep(for: .seconds(1.8))
        precondition(!model.textSent, "Sent confirmation did not reset automatically")
        precondition(abs(hosting.fittingSize.height - composerHeight) < 1, "Reset moved the panel")
        precondition(model.needsTextEntry && model.textDraft.isEmpty, "Reset changed the active field or draft")
        await waitForEditor(in: window)
        await key("x", code: 7)
        precondition(model.textDraft == "x", "Typing focus did not return after sending")

        model.handle(["event": "keyboard", "available": true, "focused": false])
        await settle()
        precondition(abs(hosting.fittingSize.height - compactHeight) < 1, "Composer did not disappear")
        await key("h", code: 4)
        precondition(model.textDraft == "x", "Leaving the field did not restore remote navigation")

        model.handle(["event": "keyboard", "available": false, "focused": true])
        await settle()
        precondition(abs(hosting.fittingSize.height - compactHeight) < 1, "Unsupported keyboard appeared")
        window.close()
        if let index = CommandLine.arguments.firstIndex(of: "--result"), index + 1 < CommandLine.arguments.count {
            try! "passed\n".write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        }
        print("Native text-entry checks passed: contextual visibility, focus, typing, send, dismissal")
    }

    static func checkAppActions() async {
        var updates = 0, quits = 0
        // No model, helper, paired device, updater network request, or actual quit.
        let hosting = NSHostingView(rootView: AppActionsBar(
            canCheckForUpdates: true, checkForUpdates: { updates += 1 }, quit: { quits += 1 }
        ).frame(width: 340, height: 50))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()

        func click(x: CGFloat) async {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 25),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            await settle()
        }

        await click(x: 90)
        await click(x: 310)
        precondition(updates == 1 && quits == 1, "App actions required a TV connection")
        hosting.rootView = AppActionsBar(
            canCheckForUpdates: false, checkForUpdates: { updates += 1 }, quit: { quits += 1 }
        ).frame(width: 340, height: 50)
        await settle()
        await click(x: 90)
        await click(x: 310)
        precondition(updates == 1 && quits == 2, "Updater readiness disabled Quit or allowed an unavailable check")
        window.close()
        print("Native app actions passed: update and quit without a TV; quit while updater is unavailable")
    }

    static func checkVolumeButtons() async {
        var decreases = 0, increases = 0
        let hosting = NSHostingView(rootView: VolumeStepButtons(
            canDecrease: true, canIncrease: true,
            decrease: { decreases += 1 }, increase: { increases += 1 }
        ).frame(width: 300, height: 50))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()

        func click(x: CGFloat) async {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 25),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            await settle()
        }

        await click(x: 15)
        await click(x: 285)
        precondition(decreases == 1 && increases == 1, "Volume buttons did not send separate up/down actions")
        hosting.rootView = VolumeStepButtons(
            canDecrease: false, canIncrease: true,
            decrease: { decreases += 1 }, increase: { increases += 1 }
        ).frame(width: 300, height: 50)
        await settle()
        await click(x: 15)
        await click(x: 285)
        precondition(decreases == 1 && increases == 2, "An unavailable direction sent a volume action")
        window.close()
        print("Native volume checks passed: up/down actions and unavailable direction")
    }

    static func checkSelectButton() async {
        var taps = 0, holds = 0
        let hosting = NSHostingView(rootView:
            Button { taps += 1 } label: {
                Circle().fill(.gray).frame(width: 52, height: 52).contentShape(Circle())
            }
            .buttonStyle(SelectButtonStyle { holds += 1 })
            .frame(width: 100, height: 100)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()

        func mouse(_ type: NSEvent.EventType, at point: NSPoint = NSPoint(x: 50, y: 50)) {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
        }

        mouse(.leftMouseDown)
        try? await Task.sleep(for: .milliseconds(50))
        mouse(.leftMouseUp)
        await settle()
        precondition(taps == 1 && holds == 0,
                     "Center click did not send exactly one Select: taps=\(taps), holds=\(holds)")

        mouse(.leftMouseDown)
        try? await Task.sleep(for: .milliseconds(650))
        mouse(.leftMouseUp)
        await settle()
        precondition(taps == 1 && holds == 1,
                     "Center hold sent a tap or failed: taps=\(taps), holds=\(holds)")

        mouse(.leftMouseDown)
        try? await Task.sleep(for: .milliseconds(50))
        mouse(.leftMouseUp)
        await settle()
        precondition(taps == 2 && holds == 1, "Center click stopped working after a hold")

        mouse(.leftMouseDown)
        try? await Task.sleep(for: .milliseconds(50))
        mouse(.leftMouseDragged, at: NSPoint(x: 95, y: 95))
        try? await Task.sleep(for: .milliseconds(650))
        mouse(.leftMouseUp, at: NSPoint(x: 95, y: 95))
        await settle()
        precondition(taps == 2 && holds == 1, "Dragging outside the center sent a command")
        window.close()
        print("Native center-button checks passed: click, hold without extra tap, click after hold, drag cancellation")
    }
}
