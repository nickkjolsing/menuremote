import AppKit

enum StatusItemIcon {
    static func make() -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "appletvremote.gen4",
                                   accessibilityDescription: "MenuRemote")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) else { return nil }

        // The symbol's text alignment rect excludes the ends of the remote.
        // Give the status button a plain image with the complete drawing bounds.
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            symbol.draw(in: NSRect(x: rect.midX - symbol.size.width / 2,
                                   y: rect.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MenuRemote"
        return image
    }
}
