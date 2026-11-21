// Render the real About view and alternative action layouts, entirely offline.
// Run with: bash scripts/render_info.sh [--minimal-a | --hybrid]
import AppKit
import SwiftUI

private let iconBackground = NSImage(contentsOfFile: "Support/AboutLogoBackground.png")!
private let bitcoinLogo = NSImage(contentsOfFile: "Support/BitcoinMark.pdf")!
private let version = (try? String(contentsOfFile: "version.txt", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
private let bitcoinAddress: String? = {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "Support/Info.plist")),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["MenuRemoteBitcoinAddress"] as? String
}()

private struct PolishedConcept: View {
    let style: Int
    let height: CGFloat
    private let purple = Color(red: 0.47, green: 0.25, blue: 0.65)

    private var notes: some View {
        Link(destination: AppInformation.releaseNotesURL(for: version)) {
            HStack(spacing: 3) {
                Text("Release notes")
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium))
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var tintedUpdate: some View {
        Button {} label: {
            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(purple)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(purple.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(purple.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            AboutLogo(background: iconBackground)
                .padding(.bottom, 12)
            Text("MenuRemote").font(.system(size: 24, weight: .semibold, design: .rounded))
            HStack(spacing: 7) {
                Text("Version \(version)")
                if style >= 2 {
                    Text("·").foregroundStyle(.tertiary)
                    notes
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.top, 6)

            if style == 1 {
                HStack(spacing: 14) {
                    tintedUpdate
                    notes
                }
                .padding(6)
                .background(.primary.opacity(0.018), in: Capsule())
                .padding(.top, 25)
            } else if style == 3 {
                tintedUpdate.padding(.top, 25)
            } else {
                Button("Check for Updates…") {}
                    .buttonStyle(InfoUpdateButtonStyle())
                    .padding(.top, 25)
            }

            Spacer(minLength: 20)
            HStack(spacing: 6) {
                Image(nsImage: bitcoinLogo).resizable().scaledToFit().frame(width: 13, height: 13)
                Text(bitcoinAddress ?? "Your public Bitcoin address")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5)
            }
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 30)
        .frame(width: 350, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
private enum InfoPreviews {
    @MainActor
    static func snapshot<V: View>(_ view: V, dark: Bool = false, scale: CGFloat = 3) -> NSImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        return renderer.nsImage!
    }

    @MainActor
    static func actual(dark: Bool = false) -> NSImage {
        snapshot(AboutView(version: version, iconBackground: iconBackground, bitcoinAddress: bitcoinAddress,
                           bitcoinLogo: bitcoinLogo,
                           updateControl: InfoUpdateButton {}), dark: dark)
    }

    static func save(_ image: NSImage, to path: URL) throws {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: path)
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: "build/info-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let primary = actual()
        if CommandLine.arguments.contains("--logo-check") {
            for scale in 1...3 {
                try save(snapshot(AboutLogo(background: iconBackground), scale: CGFloat(scale)),
                         to: output.appendingPathComponent("logo-\(scale)x.png"))
            }
            for dark in [false, true] {
                for scale in [1, 2] {
                    let image = snapshot(AboutView(version: version, iconBackground: iconBackground,
                                                   bitcoinAddress: bitcoinAddress, bitcoinLogo: bitcoinLogo,
                                                   updateControl: InfoUpdateButton {}),
                                         dark: dark, scale: CGFloat(scale))
                    try save(image, to: output.appendingPathComponent("logo-check-\(dark ? "dark" : "light")-\(scale)x.png"))
                }
            }
            print("Rendered native logo and window at 1×, 2×, and 3×")
            return
        }
        if CommandLine.arguments.contains("--quiet-motion") {
            try renderQuietMotion(to: output)
            return
        }
        if CommandLine.arguments.contains("--hybrid") {
            let hybrid = snapshot(PolishedConcept(style: 3, height: primary.size.height))
            try board(images: [hybrid], labels: [], width: 490,
                      to: output.appendingPathComponent("info-hybrid.png"))
            return
        }
        if CommandLine.arguments.contains("--minimal-a") {
            try board(images: [primary], labels: [], width: 490, to: output.appendingPathComponent("info-a-minimal.png"))
            return
        }
        try save(primary, to: output.appendingPathComponent("about-light.png"))
        try save(actual(dark: true), to: output.appendingPathComponent("about-dark.png"))
        let images = [primary,
                      snapshot(PolishedConcept(style: 1, height: primary.size.height)),
                      snapshot(PolishedConcept(style: 2, height: primary.size.height))]
        for (index, image) in images.enumerated() {
            try save(image, to: output.appendingPathComponent("polished-\(index + 1).png"))
        }
        try board(images: images,
                  labels: [("01 / Soft capsule", "A gentle button, with notes beneath"),
                           ("02 / Paired actions", "A quiet toolbar for updates and notes"),
                           ("03 / Version link", "Release notes beside the build number")],
                  width: 1230, to: output.appendingPathComponent("info-polished-options.png"))
    }

    @MainActor
    static func board(images: [NSImage], labels: [(String, String)], width: CGFloat, to output: URL) throws {
        let height = images.map(\.size.height).max()! + (labels.isEmpty ? 170 : 220)
        let canvas = NSSize(width: width, height: height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.93, green: 0.925, blue: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas).fill()
        if !labels.isEmpty {
            text("MenuRemote", x: 36, y: height - 48, size: 18, weight: .semibold)
            text("Updates, release notes, and a quieter footer", x: 36, y: height - 70,
                 size: 12, ink: .secondaryLabelColor)
        }
        for (index, image) in images.enumerated() {
            let center = width / CGFloat(images.count) * (CGFloat(index) + 0.5)
            let frame = NSRect(x: center - image.size.width / 2, y: labels.isEmpty ? 70 : 90,
                               width: image.size.width, height: image.size.height + 30)
            let shape = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = NSSize(width: 0, height: -9)
            shadow.set()
            NSColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: NSRect(origin: frame.origin, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            for (offset, color) in [NSColor.systemRed, .systemGray, .systemGray].enumerated() {
                color.withAlphaComponent(offset == 0 ? 0.85 : 0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: frame.minX + 13 + CGFloat(offset) * 16,
                                            y: frame.maxY - 20, width: 9, height: 9)).fill()
            }
            if !labels.isEmpty {
                text(labels[index].0, x: frame.minX, y: 50, size: 12, weight: .semibold)
                text(labels[index].1, x: frame.minX, y: 30, size: 11, ink: .secondaryLabelColor)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        if !output.lastPathComponent.hasPrefix("frame-") {
            print("Rendered \(output.path)")
        }
    }

    @MainActor
    static func renderQuietMotion(to output: URL) throws {
        let frames = output.appendingPathComponent("quiet-motion-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for frame in 0..<90 {
            let time = Double(frame) / 30
            let pressing = time >= 0.35 && time < 0.51
            let scale: Double
            if pressing {
                let progress = (time - 0.35) / 0.16
                scale = 1 - 0.025 * (1 - pow(1 - progress, 3))
            } else if time >= 0.51 {
                let elapsed = time - 0.51
                let omega = 2 * Double.pi / 0.28
                let damped = omega * sqrt(1 - 0.72 * 0.72)
                scale = 1 - 0.025 * exp(-0.72 * omega * elapsed)
                    * (cos(damped * elapsed) + 0.72 * omega / damped * sin(damped * elapsed))
            } else {
                scale = 1
            }
            let progress = min(1, max(0, (time - 0.51) / 0.7))
            let angle = easedTurn(progress) * 360
            let view = AboutView(version: version, iconBackground: iconBackground, bitcoinAddress: bitcoinAddress,
                                 bitcoinLogo: bitcoinLogo,
                                 updateControl: Button {} label: { InfoUpdateButtonLabel(angle: angle) }
                                    .scaleEffect(scale).opacity(pressing ? 0.85 : 1))
            try board(images: [snapshot(view)], labels: [], width: 490,
                      to: frames.appendingPathComponent(String(format: "frame-%03d.png", frame)))
        }
        print("Rendered 90 frames to \(frames.path)")
    }

    static func easedTurn(_ progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        func curve(_ t: Double, _ first: Double, _ second: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * first + 3 * (1 - t) * t * t * second + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if curve(middle, 0.22, 0.25) < progress { low = middle } else { high = middle }
        }
        return curve((low + high) / 2, 0.7, 1)
    }

    static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     weight: NSFont.Weight = .regular, ink: NSColor = .labelColor) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink,
        ])
    }
}
