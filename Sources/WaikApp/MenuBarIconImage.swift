import AppKit

// MenuBarExtra's `label` only renders simple Text / Image content reliably —
// SwiftUI ZStacks with offsets get silently dropped or clipped. Compose the
// icon ourselves as an NSImage and hand it to `Image(nsImage:)`.
enum MenuBarIconImage {
    static func render(baseSymbol: String, trafficActive: Bool) -> NSImage {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: baseSymbol, accessibilityDescription: nil)?
                            .withSymbolConfiguration(baseConfig) else {
            return NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage()
        }

        // Allow a couple of points of extra width so the overlay can sit outside
        // the base symbol's bounding box without being clipped.
        let extra: CGFloat = 4
        let size = NSSize(width: base.size.width + extra, height: base.size.height)

        let composite = NSImage(size: size)
        composite.lockFocus()
        defer {
            composite.unlockFocus()
            composite.isTemplate = true
        }

        // Base, left-aligned.
        base.draw(at: NSPoint(x: 0, y: 0),
                  from: NSRect(origin: .zero, size: base.size),
                  operation: .sourceOver,
                  fraction: 1.0)

        guard trafficActive else { return composite }

        let overlayConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
        guard let overlay = NSImage(systemSymbolName: "arrow.up.arrow.down",
                                    accessibilityDescription: nil)?
                                .withSymbolConfiguration(overlayConfig)
        else { return composite }

        // Bottom-right corner of the composite, nudged slightly so it visibly
        // sits beside (not on top of) the base symbol's lower-right.
        let x = size.width - overlay.size.width + 1
        let y: CGFloat = -1
        overlay.draw(at: NSPoint(x: x, y: y),
                     from: NSRect(origin: .zero, size: overlay.size),
                     operation: .sourceOver,
                     fraction: 1.0)
        return composite
    }
}
