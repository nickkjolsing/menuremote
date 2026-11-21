// macOS only: swift scripts/render_menubar.swift
import AppKit

let readable = CommandLine.arguments.contains("--readable")
let output = URL(fileURLWithPath: readable
    ? "build/info-previews/menubar-readable-options.png"
    : "build/info-previews/menubar-options.png")
let appIcon = NSImage(contentsOfFile: "Support/AppIcon.icns")!
let canvas = NSSize(width: 1000, height: 590)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = canvas

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, ink: NSColor = color(0x29262f)) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink,
    ])
}

func symbol(_ name: String, center: NSPoint, height: CGFloat, ink: NSColor,
            weight: NSFont.Weight = .regular) {
    let configuration = NSImage.SymbolConfiguration(pointSize: height * 0.8, weight: weight)
        .applying(.init(paletteColors: [ink]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    image.isTemplate = false
    let width = image.size.width * height / image.size.height
    image.draw(in: NSRect(x: center.x - width / 2, y: center.y - height / 2,
                          width: width, height: height))
}

func readableMark(_ kind: Int, center: NSPoint, height: CGFloat, dark: Bool) {
    let ink = color(dark ? 0xf4f3f6 : 0x29262f)
    if kind == 0 {
        symbol("appletvremote.gen4", center: center, height: height * 20 / 18,
               ink: ink, weight: .medium)
        return
    }
    let scale = height / 18
    let wide = kind == 3
    let width: CGFloat = (wide ? 16 : 12) * scale
    let stroke = 1.4 * scale
    let body = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                      width: width, height: height).insetBy(dx: stroke / 2, dy: stroke / 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: (wide ? 4.3 : 3.2) * scale,
                            yRadius: (wide ? 4.3 : 3.2) * scale)
    ink.setFill()
    ink.setStroke()
    if kind == 2 { shape.fill() } else {
        shape.lineWidth = stroke
        shape.stroke()
    }

    let diameter: CGFloat = (wide ? 7.8 : 5.8) * scale
    let wheelY = center.y + (wide ? 2.4 : 3.2) * scale
    let wheel = NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2,
                                          y: wheelY - diameter / 2,
                                          width: diameter, height: diameter))
    if kind == 2 {
        color(dark ? 0x303034 : 0xfbfbfc).setFill()
        wheel.fill()
    } else {
        wheel.lineWidth = 1.3 * scale
        wheel.stroke()
    }
    if wide {
        for offset: CGFloat in [-3, 3] {
            NSBezierPath(ovalIn: NSRect(x: center.x + offset * scale - 1.2 * scale,
                                       y: center.y - 5.5 * scale,
                                       width: 2.4 * scale, height: 2.4 * scale)).fill()
        }
    } else {
        let key = NSRect(x: center.x - 2 * scale, y: center.y - 5.6 * scale,
                         width: 4 * scale, height: 1.9 * scale)
        NSBezierPath(roundedRect: key, xRadius: 0.95 * scale, yRadius: 0.95 * scale).fill()
    }
}

func mark(_ kind: Int, center: NSPoint, height: CGFloat, dark: Bool) {
    if readable {
        readableMark(kind, center: center, height: height, dark: dark)
        return
    }
    let ink = dark ? color(0xf4f3f6) : color(0x29262f)
    switch kind {
    case 0, 1:
        symbol(kind == 0 ? "appletvremote.gen4" : "appletvremote.gen4.fill",
               center: center, height: height, ink: ink)
    case 2:
        let rect = NSRect(x: center.x - height / 2, y: center.y - height / 2,
                          width: height, height: height)
        ink.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height * 0.24, yRadius: height * 0.24).fill()
        symbol("appletvremote.gen4.fill", center: center, height: height * 0.7,
               ink: dark ? color(0x303034) : color(0xfbfbfc))
    default:
        // The .icns includes the standard transparent macOS icon margins.
        let edge = height * 1024 / 824
        appIcon.draw(in: NSRect(x: center.x - edge / 2, y: center.y - edge / 2,
                                width: edge, height: edge))
    }
}

func menuBar(_ kind: Int, rect: NSRect, dark: Bool) {
    let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(dark ? 0x363141 : 0xe9e4ef),
               ending: color(dark ? 0x27242e : 0xdcd5e4))!
        .draw(in: rect, angle: -25)
    let barHeight: CGFloat = readable ? 22 : 28
    let bar = NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
    color(dark ? 0x303034 : 0xfbfbfc).setFill()
    bar.fill()
    let ink = color(dark ? 0xf1f0f4 : 0x29262f)
    text("Finder", x: rect.minX + 13, y: bar.midY - 7, size: 11, weight: .semibold, ink: ink)
    let centerY = bar.midY
    mark(kind, center: NSPoint(x: rect.maxX - 142, y: centerY), height: 18, dark: dark)
    symbol("wifi", center: NSPoint(x: rect.maxX - 105, y: centerY), height: 12, ink: ink)
    symbol("battery.100percent", center: NSPoint(x: rect.maxX - 73, y: centerY), height: 11, ink: ink)
    text("9:41", x: rect.maxX - 42, y: bar.midY - 7, size: 11, weight: .medium, ink: ink)
    NSGraphicsContext.restoreGraphicsState()
    color(dark ? 0x24212b : 0xdad5e0).setStroke()
    shape.lineWidth = 0.5
    shape.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
color(0xf2f0f4).setFill()
NSRect(origin: .zero, size: canvas).fill()
text(readable ? "A clearer menu bar icon" : "Menu bar icon", x: 32, y: 540, size: 23, weight: .semibold)
text(readable ? "Simplified remote shapes designed for small sizes." : "The remote from the logo, in four treatments.", x: 33, y: 515,
     size: 13, ink: color(0x77717e))
text("Light appearance", x: 220, y: 480, size: 11, weight: .medium, ink: color(0x77717e))
text("Dark appearance", x: 600, y: 480, size: 11, weight: .medium, ink: color(0x77717e))

let labels = readable
    ? [("01  Larger outline", "Heavier, 20 pt high"),
       ("02  Simple outline", "Wheel + one button"),
       ("03  Simple solid", "Bold, fewer cutouts"),
       ("04  Wide remote", "Larger controls")]
    : [("01  Outline", "Light and familiar"),
              ("02  Filled", "The logo’s remote glyph"),
              ("03  Mono badge", "A small, solid mark"),
              ("04  App icon", "The full purple logo")]
for kind in 0..<4 {
    let y: CGFloat = 400 - CGFloat(kind) * 96
    text(labels[kind].0, x: 32, y: y + 35, size: 14, weight: .semibold)
    text(labels[kind].1, x: 32, y: y + 15, size: 11, ink: color(0x77717e))
    mark(kind, center: NSPoint(x: 177, y: y + 34), height: 30, dark: false)
    menuBar(kind, rect: NSRect(x: 220, y: y, width: 350, height: 64), dark: false)
    menuBar(kind, rect: NSRect(x: 600, y: y, width: 350, height: 64), dark: true)
}
text("Menu bars at native size. Icons at left enlarged for comparison.", x: 32, y: 49,
     size: 11, ink: color(0x77717e))
NSGraphicsContext.restoreGraphicsState()
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Rendered \(output.path)")
