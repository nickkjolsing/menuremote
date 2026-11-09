// Run with: bash scripts/render_readme.sh (macOS only).
// Uses the app's real views with fictional playback data, entirely offline.
import AppKit
import SwiftUI

@main
struct ReadmeArtwork {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let model = RemoteModel(startAutomatically: false)
        model.phase = .connected
        model.deviceName = "Living Room"
        model.nowPlaying = NowPlaying([
            "state": "paused", "title": "Evening Mix",
            "artist": "Weekend Radio", "app": "Music",
            "position": 83, "total": 248,
            "features": ["set_position": true],
        ])
        model.volume = 42
        model.volumeAvailable = true
        model.powerOn = true

        // Registration defaults keep the expanded remote out of the user's preferences.
        let domain = "MenuRemote.ReadmePreview"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.register(defaults: ["showRemote": true])
        let view = PlayerView()
            .environmentObject(model)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, .dark)
            .frame(width: 340)
            .background(Color(red: 0.13, green: 0.13, blue: 0.15))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let snapshot = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        snapshot.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: snapshot)
        let player = NSImage(size: size)
        player.addRepresentation(snapshot)

        let width = 1200, height = 660, scale = 2
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: width * scale, pixelsHigh: height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(scale))
        transform.concat()

        color(0xf5f4f0).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        color(0xe8e5ed).setFill()
        NSBezierPath(roundedRect: NSRect(x: 680, y: 40, width: 480, height: 580),
                     xRadius: 24, yRadius: 24).fill()

        NSImage(contentsOfFile: "Support/AppIcon.icns")?
            .draw(in: NSRect(x: 72, y: 546, width: 64, height: 64))
        text("MenuRemote", x: 148, y: 565, size: 27, weight: .semibold)
        text("Apple TV,", x: 84, y: 414, size: 64, weight: .semibold)
        text("from your", x: 84, y: 338, size: 64, weight: .semibold)
        text("menu bar.", x: 84, y: 262, size: 64, weight: .semibold)
        text("Playback. Navigation. A click away.", x: 88, y: 190,
             size: 22, weight: .regular, ink: color(0x68656e))
        text("macOS 14+  /  Apple silicon", x: 88, y: 66,
             size: 16, weight: .medium, ink: color(0x68656e))

        let panel = NSRect(x: 750, y: (660 - size.height) / 2 - 10,
                           width: size.width, height: size.height)
        let outline = NSBezierPath(roundedRect: panel, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        color(0x222226).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        player.draw(in: panel)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let menuRect = NSRect(x: 1036, y: panel.maxY + 16, width: 54, height: 34)
        color(0xd6d1df).setFill()
        NSBezierPath(roundedRect: menuRect, xRadius: 8, yRadius: 8).fill()
        NSImage(systemSymbolName: "appletv.fill", accessibilityDescription: nil)?
            .draw(in: menuRect.insetBy(dx: 15, dy: 7))
        text("Actual interface · Sample playback", x: 775, y: 72,
             size: 14, weight: .regular, ink: color(0x68656e))

        NSGraphicsContext.restoreGraphicsState()
        let destination = URL(fileURLWithPath: "docs/images/menuremote.png")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
        print("Wrote \(destination.path)")
    }

    static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     weight: NSFont.Weight, ink: NSColor = color(0x26232b)) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: ink,
        ])
    }
}
