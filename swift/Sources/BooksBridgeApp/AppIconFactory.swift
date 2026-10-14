import AppKit

/// Shared artwork for the Dock and the adaptive monochrome menu bar icon.
public enum AppIconFactory {
    public static func menuBarImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "BookBridge", withExtension: "png", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 22, height: 22 * image.size.height / image.size.width)
        image.isTemplate = true
        return image
    }

    @MainActor
    public static func apply() {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Icons"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
