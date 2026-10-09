import AppKit
import Combine
import SwiftUI

/// Owns the menu bar icon and the dropdown panel. The panel is sized from the
/// SwiftUI content's measured height so it grows and shrinks with it.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = RemoteModel()
    private var statusItem: NSStatusItem!
    private var panel: RemotePanel!
    private var hostingView: SizeReportingHostingView!
    private var outsideClickMonitor: Any?
    private var contentSize = CGSize.zero
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        setIcon(playing: false)

        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app stays running")

        hostingView = SizeReportingHostingView(rootView: AnyView(PanelContent().environmentObject(model)))
        hostingView.onSizeChange = { [weak self] size in self?.resize(to: size) }
        panel = RemotePanel(content: hostingView)
        // SwiftUI doesn't reliably announce size changes, so re-measure whenever
        // state that can change the layout changes.
        model.objectWillChange
            .sink { [weak self] in self?.hostingView.scheduleSizeReport() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.hostingView.scheduleSizeReport() }
            .store(in: &cancellables)
        panel.onCancel = { [weak self] in self?.closePanel() }

        model.$nowPlaying.combineLatest(model.$phase)
            .sink { [weak self] nowPlaying, phase in
                self?.setIcon(playing: nowPlaying.isPlaying && phase == .connected)
            }
            .store(in: &cancellables)

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() }
        }
    }

    private func setIcon(playing: Bool) {
        let image = NSImage(systemSymbolName: playing ? "appletv.fill" : "appletv",
                            accessibilityDescription: "MenuRemote")
        image?.isTemplate = true
        statusItem.button?.image = image
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

