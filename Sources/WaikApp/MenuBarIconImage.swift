import AppKit

// MenuBarExtra's `label` only renders simple Text / Image content reliably —
// SwiftUI ZStacks with offsets get silently dropped or clipped. Compose the
// icon ourselves as an NSImage and hand it to `Image(nsImage:)`.
enum MenuBarIconImage {
    static func render(baseSymbol: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: baseSymbol, accessibilityDescription: nil)?
                            .withSymbolConfiguration(config) else {
            return NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage()
        }
        base.isTemplate = true
        return base
    }
}
