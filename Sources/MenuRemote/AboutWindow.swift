import AppKit
import SwiftUI

enum AppInformation {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MenuRemote"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let iconBackground = Bundle.main.url(forResource: "AboutLogoBackground", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    static let bitcoinLogo = Bundle.main.url(forResource: "BitcoinMark", withExtension: "pdf")
        .flatMap { NSImage(contentsOf: $0) }

    static func releaseNotesURL(for version: String?) -> URL {
        let releases = URL(string: "https://github.com/nickkjolsing/menuremote/releases")!
        guard let version else { return releases }
        return releases.appendingPathComponent("tag").appendingPathComponent("v\(version)")
    }

    static let bitcoinAddress: String? = {
        let address = (Bundle.main.object(forInfoDictionaryKey: "MenuRemoteBitcoinAddress") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return address?.isEmpty == false ? address : nil
    }()
}

/// Render the remote at the display's native resolution rather than shrinking a bitmap glyph.
struct AboutLogo: View {
    var background: NSImage
    var side: CGFloat = 76

    var body: some View {
        ZStack {
            Image(nsImage: background).resizable().interpolation(.high)
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: side * 470 / 1024, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct AboutView<UpdateControl: View>: View {
    var name = AppInformation.name
    var version = AppInformation.version
    var iconBackground = AppInformation.iconBackground
    var bitcoinAddress = AppInformation.bitcoinAddress
    var bitcoinLogo = AppInformation.bitcoinLogo
    var updateControl: UpdateControl
    @State private var copyReceipt: UUID?
    var body: some View {
        VStack(spacing: 0) {
            if let iconBackground {
                AboutLogo(background: iconBackground)
                    .padding(.bottom, 12)
            }
            Text(name).font(.system(size: 24, weight: .semibold, design: .rounded))
            HStack(spacing: 7) {
                Text(version.map { "Version \($0)" } ?? "Development build")
                Text("·").foregroundStyle(.tertiary)
                Link(destination: AppInformation.releaseNotesURL(for: version)) {
                    HStack(spacing: 3) {
                        Text("Release notes")
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            updateControl
                .buttonStyle(InfoUpdateButtonStyle())
                .padding(.top, 25)
            Spacer(minLength: 20)
            if let bitcoinAddress {
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(bitcoinAddress, forType: .string) {
                        copyReceipt = UUID()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let bitcoinLogo {
                            Image(nsImage: bitcoinLogo).resizable().scaledToFit()
                                .frame(width: 13, height: 13)
                                .accessibilityHidden(true)
                        }
                        Text(bitcoinAddress)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy Bitcoin address")
                .accessibilityLabel("Copy Bitcoin receiving address")
                .accessibilityValue(bitcoinAddress)
                .overlay(alignment: .bottom) {
                    if copyReceipt != nil {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .offset(y: 17)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: copyReceipt) {
                    guard copyReceipt != nil else { return }
                    try? await Task.sleep(for: .seconds(1.6))
                    if !Task.isCancelled { copyReceipt = nil }
                }
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 30)
        .frame(width: 350, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InfoUpdateButton: View {
    var isEnabled = true
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        Button {
            if !reduceMotion {
                withAnimation(.timingCurve(0.22, 0.7, 0.25, 1, duration: 0.7)) {
                    angle += 360
                }
            }
            action()
        } label: {
            InfoUpdateButtonLabel(angle: angle)
        }
        .buttonStyle(InfoUpdateButtonStyle())
        .disabled(!isEnabled)
    }
}

struct InfoUpdateButtonLabel: View {
    var angle = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(angle))
                .accessibilityHidden(true)
            Text("Check for Updates")
        }
    }
}

/// A soft press and a small spring back, with the layout kept still.
struct InfoUpdateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var purple: Color {
        colorScheme == .dark
            ? Color(red: 0.76, green: 0.59, blue: 0.89)
            : Color(red: 0.47, green: 0.25, blue: 0.65)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(purple)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(purple.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(purple.opacity(0.10), lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    private init() {}

    func show(updateControl: some View) {
        if window == nil {
            let hosting = NSHostingView(rootView: AboutView(updateControl: updateControl))
            let window = AboutWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "About \(AppInformation.name)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class AboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct ShowAboutKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showAbout: () -> Void {
        get { self[ShowAboutKey.self] }
        set { self[ShowAboutKey.self] = newValue }
    }
}
