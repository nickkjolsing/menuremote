// Renders the app icon and packs it into an .icns file.
// Usage: swift scripts/make_icon.swift Support/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.icns")

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024

    // macOS icon grid: 824pt squircle centered on a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 24 * scale
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.42, green: 0.16, blue: 0.62, alpha: 1),
        NSColor(red: 0.16, green: 0.06, blue: 0.28, alpha: 1),
        NSColor(red: 0.05, green: 0.03, blue: 0.09, alpha: 1),
    ])!.draw(in: tile, angle: -60)
    // Soft magenta glow, a nod to the default wallpaper.
    NSGradient(colors: [NSColor(red: 0.95, green: 0.35, blue: 0.95, alpha: 0.45), .clear])!
        .draw(in: tile, relativeCenterPosition: NSPoint(x: 0.6, y: -0.7))
    NSGraphicsContext.restoreGraphicsState()

    // Siri Remote glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 470 * scale, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = glyph.size
        glyph.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2,
                              width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
