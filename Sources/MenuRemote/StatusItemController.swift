import AppKit
import Combine
import SwiftUI

/// Owns the menu bar icon and the dropdown panel. The panel is sized from the
/// SwiftUI content's measured height so it grows and shrinks with it.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = RemoteModel()
    private let updater = AppUpdater()
    private var statusItem: NSStatusItem!
    private var panel: RemotePanel!
    private var hostingView: SizeReportingHostingView!
    private var outsideClickMonitor: Any?
    private var keyboardNotifications: KeyboardNotifications!
    private var contentSize = CGSize.zero
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        setIcon()

        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app stays running")

        hostingView = SizeReportingHostingView(rootView: AnyView(
            PanelContent().environmentObject(model).environmentObject(updater)
                .environment(\.showAbout) { [weak self] in
                    guard let self else { return }
                    self.closePanel()
                    AboutWindowController.shared.show(
                        updateControl: AboutUpdateButton().environmentObject(self.updater)
                    )
                }
        ))
        hostingView.onSizeChange = { [weak self] size in self?.resize(to: size) }
        panel = RemotePanel(content: hostingView)
        keyboardNotifications = KeyboardNotifications()
        keyboardNotifications.shouldPresent = { [weak self] in
            guard let self else { return false }
            return self.model.needsTextEntry && !self.panel.isVisible
        }
        keyboardNotifications.onOpen = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.showPanel()
        }
        model.$phase.combineLatest(model.$keyboardAvailable, model.$keyboardFocused)
            .map { phase, available, focused in phase == .connected && available && focused }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] needed in
                guard let self else { return }
                self.statusItem.button?.toolTip = needed
                    ? "MenuRemote — Type on \(self.model.deviceName)" : "MenuRemote"
                if needed && !self.panel.isVisible {
                    self.keyboardNotifications.show(for: self.model.deviceName)
                } else {
                    self.keyboardNotifications.clear()
                }
            }
            .store(in: &cancellables)
        // SwiftUI doesn't reliably announce size changes, so re-measure whenever
        // state that can change the layout changes.
        model.objectWillChange
            .sink { [weak self] in self?.hostingView.scheduleSizeReport() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.hostingView.scheduleSizeReport() }
            .store(in: &cancellables)
        panel.onCancel = { [weak self] in self?.closePanel() }
        updater.willCheckForUpdates = { [weak self] in self?.closePanel() }
        updater.start()

        if !model.hasSavedDevice || CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func setIcon() {
        statusItem.button?.image = StatusItemIcon.make()
    }

    // MARK: - Showing and hiding

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        contentSize = size
        let x = min(max(buttonRect.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: buttonRect.minY - 6 - size.height, width: size.width, height: size.height),
                       display: true)
        panel.makeKeyAndOrderFront(nil)
        keyboardNotifications.clear()
        // Opening the panel is explicit intent to type; TV events alone don't take focus.
        DispatchQueue.main.async { [weak self] in self?.model.focusTextEntry() }

        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        DispatchQueue.main.async { button.highlight(true) }
    }

    private func closePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Keeps the panel's top edge pinned under the menu bar while its height changes.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: ceil(size.width), height: ceil(size.height))
        frame.origin.y = top - frame.height
        guard frame != panel.frame else { return }
        // Animate growing (it reveals the new content); snap when shrinking so no
        // empty space lingers below content that has already disappeared.
        if panel.isVisible && frame.height > panel.frame.height {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: panel.isVisible)
        }
    }
}

private struct AboutUpdateButton: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        InfoUpdateButton(isEnabled: updater.canCheckForUpdates, action: updater.checkForUpdates)
    }
}

/// Borderless, translucent panel styled like a menu bar dropdown.
final class RemotePanel: NSPanel {
    var onCancel: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let radius: CGFloat = 12
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: radius)

        // The SwiftUI view gets a fixed, tall canvas pinned to the panel's top edge
        // and is never resized; the panel just reveals more or less of it. Resizing
        // it during the animation made the content jump.
        content.frame = NSRect(x: 0, y: background.bounds.height - Self.canvasHeight,
                               width: background.bounds.width, height: Self.canvasHeight)
        content.autoresizingMask = [.width, .minYMargin]
        background.addSubview(content)
        contentView = background
    }

    private static let canvasHeight: CGFloat = 1200

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Reports the SwiftUI content's ideal size when it may have changed, so the panel can match it.
final class SizeReportingHostingView: NSHostingView<AnyView> {
    var onSizeChange: ((CGSize) -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleSizeReport()
    }

    override func layout() {
        super.layout()
        scheduleSizeReport()
    }

    /// Measures on the next run loop pass, after SwiftUI has applied pending updates.
    func scheduleSizeReport() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.fittingSize)
        }
    }
}

private struct PanelContent: View {
    var body: some View {
        // Natural height, pinned to the top of the canvas (see RemotePanel).
        ContentView()
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

