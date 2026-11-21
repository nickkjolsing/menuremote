// Native, offline design studies. Run: bash scripts/render_remote.sh
import AppKit
import SwiftUI

private struct PreviewPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.23, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct RemoteConcept: View {
    let variant: Int
    @EnvironmentObject private var model: RemoteModel
    @Environment(\.colorScheme) private var scheme
    private var padSize: CGFloat { variant == 2 ? 128 : (variant == 1 ? 136 : 144) }
    private var panel: Color { scheme == .dark ? Color(white: 0.145) : Color(white: 0.965) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5)
                .padding(.horizontal, 16).padding(.top, 12)
            if variant == 0 {
                DPadView()
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 8)
            } else if variant == 2 {
                VStack(spacing: 12) {
                    pad
                    HStack(spacing: 0) {
                        action("chevron.backward", label: "Back", width: 52, height: 32, bare: true)
                        Rectangle().fill(.primary.opacity(0.09)).frame(width: 0.5, height: 13)
                        action("tv", label: "TV", width: 52, height: 32, bare: true)
                        Rectangle().fill(.primary.opacity(0.09)).frame(width: 0.5, height: 13)
                        action("playpause.fill", label: "Play/Pause", width: 52, height: 32, bare: true)
                    }
                    .background(.primary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 8)
            } else {
                HStack(spacing: variant == 3 ? 24 : 22) {
                    if variant == 3 { individualKeys } else { pad }
                    VStack(spacing: variant == 1 ? 10 : 12) {
                        action("chevron.backward", label: "Back")
                        action("tv", label: "TV")
                        action("playpause.fill", label: "Play/Pause")
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 340, height: 218)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var pad: some View {
        ZStack {
            if variant == 1 {
                RoundedRectangle(cornerRadius: 30).fill(.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 30).strokeBorder(.primary.opacity(0.09), lineWidth: 0.7)
            } else {
                Circle().fill(.primary.opacity(0.045))
                Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.7)
            }
            center(square: variant == 1)
            direction("chevron.up").offset(y: -(padSize / 2 - 20))
            direction("chevron.down").offset(y: padSize / 2 - 20)
            direction("chevron.left").offset(x: -(padSize / 2 - 20))
            direction("chevron.right").offset(x: padSize / 2 - 20)
        }
        .frame(width: padSize, height: padSize)
    }

    private func center(square: Bool) -> some View {
        Button {} label: {
            RoundedRectangle(cornerRadius: square ? 17 : 27)
                .fill(LinearGradient(colors: [.primary.opacity(0.14), .primary.opacity(0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: square ? 17 : 27)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 0.7))
                .frame(width: variant == 3 ? 44 : 52, height: variant == 3 ? 44 : 52)
        }
        .buttonStyle(PreviewPressStyle())
        .accessibilityLabel("Select; hold for context menu")
    }

    private func direction(_ name: String, keycap: Bool = false) -> some View {
        Button {} label: {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: keycap ? 40 : 36, height: keycap ? 40 : 36)
                .background {
                    if keycap {
                        RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.055))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PreviewPressStyle())
    }

    private var individualKeys: some View {
        ZStack {
            center(square: true)
            direction("chevron.up", keycap: true).offset(y: -47)
            direction("chevron.down", keycap: true).offset(y: 47)
            direction("chevron.left", keycap: true).offset(x: -47)
            direction("chevron.right", keycap: true).offset(x: 47)
        }
        .frame(width: 136, height: 136)
    }

    private func action(_ symbol: String, label: String, width: CGFloat = 44,
                        height: CGFloat = 36, bare: Bool = false) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: width, height: height)
                .background {
                    if !bare {
                        RoundedRectangle(cornerRadius: variant == 1 ? 13 : 19)
                            .fill(.primary.opacity(0.065))
                            .overlay(RoundedRectangle(cornerRadius: variant == 1 ? 13 : 19)
                                .strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
                    }
                }
        }
        .buttonStyle(PreviewPressStyle())
        .accessibilityLabel(label)
    }
}

@main
private enum RenderRemote {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = RemoteModel(startAutomatically: false)
        model.phase = .connected
        let output = URL(fileURLWithPath: "build/info-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let canvas = NSSize(width: 800, height: 700)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.95, green: 0.945, blue: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas).fill()
        text("Remote controls", x: 40, y: 650, size: 22, weight: .semibold)
        text("Four layouts for the remote section.", x: 40, y: 626, size: 12, secondary: true)
        let names = [("01 / Refined circle", "Closest to the current layout"),
                     ("02 / Soft square", "Softer geometry, clearer center"),
                     ("03 / Bottom bar", "Actions beneath the clickpad"),
                     ("04 / Individual keys", "Separate directional buttons")]
        for index in 0..<4 {
            let renderer = ImageRenderer(content: RemoteConcept(variant: index)
                .environmentObject(model).environment(\.colorScheme, .dark))
            renderer.scale = 3
            let image = renderer.nsImage!
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try png.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("remote-option-\(index + 1).png"))
            let x: CGFloat = index.isMultiple(of: 2) ? 40 : 420
            let y: CGFloat = index < 2 ? 374 : 88
            let rect = NSRect(x: x, y: y, width: 340, height: 218)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 15
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            NSColor(white: 0.145, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            NSGraphicsContext.restoreGraphicsState()
            image.draw(in: rect)
            text(names[index].0, x: x, y: y - 25, size: 13, weight: .semibold)
            text(names[index].1, x: x, y: y - 44, size: 11, secondary: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        let destination = output.appendingPathComponent("remote-options.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
        print("Rendered \(destination.path)")
    }

    static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     weight: NSFont.Weight = .regular, secondary: Bool = false) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: secondary ? NSColor(white: 0.46, alpha: 1) : NSColor(white: 0.16, alpha: 1),
        ])
    }
}
